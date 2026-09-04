# pdp11-diskd

Serves the PDP-11's RL disk from image files on the ARM side — a fake SD card in
Linux. The PL (`sddisk.vhd`) is an AXI-Lite slave with an interrupt, exposed as a
UIO device; this daemon waits on the interrupt, does the file I/O, and hands the
sector back through the PL's buffer. RT-11 boots off it and never knows the
difference.

The recipe ships three things: the daemon (`/usr/bin/pdp11-diskd`), its SysV
init script, and `dlctl` (`/usr/bin/dlctl`), the client for the runtime image-swap
API. It `RDEPENDS` on `curl`, which `dlctl` uses.

## How it talks to the PL

The UIO region is a handful of registers:

| Offset | Meaning |
|---|---|
| `0x000`–`0x3FC` | sector buffer — low 128 words are one 256-byte RL02 sector |
| `0x800` | STATUS: bit0 = request pending, bit1 = is_write |
| `0x804` | BLOCK: 24-bit linear sector index |
| `0x808` | DONE: daemon writes here when finished (bit0 = error) |

An RL02 sector is 256 bytes; the daemon serves the native 256 (`offset = local ×
256`, low 128 words only), so the image is a plain RL02 `.dsk`. `BLOCK` is a
linear index across all units, so the daemon splits it:

```
unit  = BLOCK / 40960     (which image file — DL0, DL1, …)
local = BLOCK % 40960     (sector within that file)
```

Each unit is a separate file (10 MB each). Two units work; DL2/DL3 hang the core,
so in practice it's DL0 + DL1.

## Running it

```
pdp11-diskd [-v] [-s] [-r] [-d] [-p <port>] [-D <dir>] [-l <log>] <dl0.img> [<dl1.img> …]
```

- positional image files map to DL0, DL1, … in order
- `-r` pulse the PDP-11 reset once we're serving (so a cold boot lands in RT-11)
- `-v` log every request; `-s` byte-swap (default off, it's correct as-is)
- `-p` REST API port (default 8080, `-p 0` disables); `-D` the dir `/images` lists
- `-l` log file (default `/var/log/pdp11-diskd.log`)

It auto-starts at boot from the init script, serving `/srv/pdp11/dl0.img` (and
`dl1.img` if present) with `-r`.

## REST API — swap disks without a reboot

The daemon runs a small HTTP server (its own thread) so you can change disks on a
running machine:

| | |
|---|---|
| `GET  /status` | per-unit loaded state + counters |
| `GET  /images` | `*.img` files available in the image dir |
| `POST /load?unit=N&path=P` | load image P into DL*N* (GET also works) |
| `POST /unload?unit=N` | unload DL*N* |

A swap is atomic against disk I/O — a mutex is held across each sector transfer,
so a load can't land mid-request. RT-11 rules still apply: don't swap DL0 (the
system device), and only swap a unit that's idle (nothing with a file open on
it). There's no "unmount" — RT-11 re-reads the directory every access.

### dlctl

`dlctl` wraps the API with curl:

```
dlctl status
dlctl list
dlctl load 1 games.img      # bare name resolves under /srv/pdp11
dlctl unload 1
```

From a dev host, `scripts/dlctl.sh` in the repo does the same over the network
and can `push`/`swap` a local image onto the board first.

## Building

Part of the PetaLinux image, so a normal `./build.sh` (or `docker/plnx.sh build`)
picks it up. For a fast iteration on just this recipe, `scripts/build_pdp11_diskd.sh`
cross-compiles it in the container and drops the ARM binary in `deploy/`;
`scripts/deploy_pdp11_diskd.sh` pushes it to a running board (creating a blank
`dl1.img` if there isn't one) and restarts it.

The source is single-file C with a Makefile; `-pthread` is on the Makefile rule
itself so it survives bitbake's `CFLAGS` override.
