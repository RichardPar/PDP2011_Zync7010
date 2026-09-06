# PetaLinux build, in Docker

The host (Linux Mint 22, so Ubuntu 24.04 underneath) can't build PetaLinux
2023.2, so this does it in an Ubuntu 22.04 container instead.

## Why

`petalinux-build` on the host dies with:

```
ERROR: Failed to spawn fakeroot worker to run ...: [Errno 32] Broken pipe
ERROR: Failed to build u-boot.
```

It looks like it's running out of memory but isn't — it survives swap and
`vm.overcommit_memory=1` — and it isn't a bad recipe either, since it fails on a
different one each run. It's a glibc mismatch: PetaLinux's `pseudo` was built
against glibc 2.35 (Ubuntu 22.04) and the host has 2.39. Docker keeps the host
kernel but gives you a 2.35 userspace, which is what `pseudo` wants, so the build
goes through.

## What you need

- Docker, with your user in the `docker` group (no sudo).
- The installer at `/home/richard/Xilinx/Projects/petalinux-v2023.2-10121855-installer.run`.
- A hardware XSA at `deploy/pdp2011_zynq_wrapper.xsa` (rebuild it in Vivado if the
  design moved).
- ~60 GB free — the install is ~40 GB, plus the build tree.

## Where things live

The heavy stuff sits in bind-mounted host dirs, so it survives the container
exiting and the image itself stays small:

| Host | In container | What |
|---|---|---|
| `docker/` (here) | build context | Dockerfile + scripts |
| `/home/richard/petalinux-docker/2023.2` | `/opt/petalinux/2023.2` | the PetaLinux install (~40 GB) |
| `/home/richard/petalinux-docker/work` | `/home/plnx/work` | the project + build tree |
| `<project>/deploy` | `/deploy` | XSA in, `BOOT.BIN.docker` out |

`plnx.sh` finds the install and build tree on its own: it prefers a
`../.petalinux-docker/` sibling of the project (portable for a fresh clone), and
falls back to `~/petalinux-docker` if that's where the state actually lives — the
case on this box. Override either with `PLNX_INSTALL=` / `PLNX_WORK=` if you keep
them somewhere else.

The container runs as `plnx` with the host uid/gid (1000), so anything it writes
stays owned by `richard`.

## Running it

```bash
cd docker
./plnx.sh image     # tool image (Ubuntu 22.04 + PetaLinux packages), ~5 min
./plnx.sh install   # install PetaLinux into the persistent dir, ~15 min / ~40 GB, EULAs auto-accepted
./plnx.sh build     # create the project, import the XSA, full build, package BOOT.BIN
```

The first `build` is long — Yocto fetches and compiles the world. It leaves
`deploy/BOOT.BIN.docker`; flash it with `../scripts/flash_bootbin_net.sh` (or
rename it `BOOT.BIN.new` and use that).

`./plnx.sh shell` drops you into the container to poke around.

## The customizations come from the repo

`build` doesn't lean on a hand-tweaked project. It makes a fresh one, drops the
tracked customizations from `../petalinux/meta-user` on top, and re-applies the
couple of config bits meta-user can't carry (ext4-on-SD rootfs, the
`uio_pdrv_genirq.of_id=generic-uio` bootarg). So a clone on another machine
builds the same image — the recipes (`pdp11-diskd`, `pdp11-netd`, `tu58fs`,
`picocom`, `pdp11-scripts`), the reserved-memory and UIO device-tree bits, and
the kernel config all come along.

If all you touched is the bitstream and you just want a new BOOT.BIN,
`./plnx.sh package` repackages it around the current `deploy/pdp2011_zynq.bit`
and the already-built fsbl/u-boot — no full rebuild.
