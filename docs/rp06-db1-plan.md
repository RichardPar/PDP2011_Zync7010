# Add a second RP06 drive (DB1:) to the RH11/RH70 controller

## Context

The core exposes exactly one massbus drive today. That limit is hardcoded in three
places in `vivado/pdp2011_core/core/rh11.vhd`, and every *drive* status register in
that file is a scalar rather than a per-drive value — the file was written as a
single-drive RM06 and never grew a unit dimension (unlike `rl11.vhd`, which has
supported DL0..DL3 from the start).

The goal is a second RP06 pack, `DB1:`, so a guest can have a system pack plus a
data pack (e.g. 2.11BSD on DB0 with a scratch pack on DB1), swappable at runtime
through the existing `dlctl` / REST API the way DL1 already is.

Decisions taken up front:

- **Two drives only** (DB0 + DB1). Not a build-time generic, not four.
- **Same AXI bridge.** DB1 is a second image file on the PS reached through the
  existing single `sddisk` instance at `0x43010000`. The unit number is folded
  into the 24-bit linear BLOCK address the way `rl11.vhd:653-657` already does for
  DL0..DL3, and `pdp11-hostd` divides it back out. **No block-design, address-map,
  IRQ, UIO or device-tree changes.** `rh11.vhd` is the only file that changes on
  the FPGA side.
- **Per-drive status + position fidelity.** RPDS, RPER1/2, RPDC, RPDA, RPOF become
  per-drive and are selected by the RPCS2 unit field; RPAS becomes a real per-drive
  attention bitmap. Controller registers (RPCS1, RPWC, RPBA, RPBAE, RPCS2, RPCS3)
  stay shared — that is correct massbus behaviour, not a shortcut.

### Resource reality check (read this first)

From the 2026-09-07 20:54 build (`vivado/pdp2011_zynq/utilization.rpt`,
`timing_summary.rpt`):

```
Slice LUTs        15510 / 17600   88.13 %
  LUT as Logic    14456 / 17600   82.14 %
Slice Registers   10693 / 35200   30.38 %
Slice              4397 /  4400   99.93 %   <-- every slice on the die is occupied
WNS  +0.703 ns on a 10 ns clock; critical path 2.474 ns logic / 6.231 ns route (71.6 % routing)
```

Earlier notes saying "33 % LUT" are stale — 33 % is roughly the *flip-flop*
number. The design is LUT- and congestion-limited: ~2090 spare LUT sites, all
scattered inside slices that are otherwise full.

Two consequences that shape the whole design:

- **Duplicate storage, never duplicate datapath.** Extra flip-flops are free
  (30 % used). Extra adders, comparators and address arithmetic are not.
- The current critical path is inside the **AXI interconnect**
  (`axi_interconn_gp0/xbar/...`), not `rh11`, so the new muxes are unlikely to
  become the critical path themselves — but congestion can still push routing
  delay up everywhere. Build the bitstream early, not last.

---

## Design

### 1. `rh11.vhd` — per-drive state

Declare near `rh11.vhd:166`, following the `rl11.vhd:169-174` `dnca_type` /
`dnhs_type` pattern so the style matches the file:

```vhdl
-- two RP06 drives: db0, db1. Controller registers (cs1/wc/ba/bae/cs2/cs3) stay
-- scalar and shared; everything that lives IN the drive is indexed per unit.
type drvbit_t   is array(1 downto 0) of std_logic;
type drvvec8_t  is array(1 downto 0) of std_logic_vector(7 downto 0);
type drvvec16_t is array(1 downto 0) of std_logic_vector(15 downto 0);
```

| Signal(s) | Decl today | Type |
|---|---|---|
| `rmds_ata`, `rmds_pip`, `rmds_mol`, `rmds_wrl`, `rmds_lst`, `rmds_pgm`, `rmds_dpr`, `rmds_dry`, `rmds_vv`, `rmds_om` | `rh11.vhd:207-217` | `drvbit_t` |
| `rmda_ta`, `rmda_sa` | `rh11.vhd:186-187` | `drvvec8_t` |
| `rmdc` | `rh11.vhd:256` | `drvvec16_t` |
| `rmof_fmt`, `rmof_eci`, `rmof_hci`, `rmof_ofd` | `rh11.vhd:250-253` | `drvbit_t` |
| `rmer1_*` (16 flags) | `rh11.vhd:220-235` | `drvbit_t` each |
| `rmer2_*` (8 flags) | `rh11.vhd:265-272` | `drvbit_t` each |
| `rmds_ataset` | `rh11.vhd:301` | `drvbit_t` |

**`rmds_err` stays scalar.** It is a pure function of ER1/ER2 (`:461-466`) and is
read at only two places — `:564` (RPDS of the selected drive) and `:676` (RPCS1
write, selected drive). Feed it the *selected-drive* ER1/ER2 values and keep the
single 24-input OR. Arraying it would cost LUTs for no behavioural gain. Same for
`rmcs1_tre` at `:450`, which references `rmer1_iae` / `rmer2_ivc`.

Stays shared: `rmcs1_*`, `rmwc`, `wcp`, `rmba`, `rmbae`, `rmcs2_*`, `rmcs3_*`,
`rmmr1`, `rmmr2`, `rmla_sc`, `noofsec`/`nooftrk`/`noofcyl`, `work_bar`,
`sectorcounter`, `nxm`, `rmclock*`, `rmcs1_rdyset`, all `sdcard_*`.

### 1a. Two index expressions — and never `conv_integer(rmcs2_u)`

```vhdl
signal usel     : integer range 0 to 1;   -- LIVE:    the drive RPCS2 currently selects
signal cur_unit : integer range 0 to 1;   -- LATCHED: the drive the running command belongs to
...
usel <= conv_integer(rmcs2_u(0 downto 0));   -- bit 0 only; ned covers units 2..7
```

`rmcs2_u` is 3 bits and the guest can write 2..7, so `conv_integer` over the whole
field would index a 2-element array out of range. Slicing bit 0 makes that
structurally impossible; NED (§5) is what actually reports the missing drive.

### 1b. Single-mux discipline (the LUT budget depends on this)

Introduce **one** muxed copy of each wide value rather than indexing at every
textual reference:

```vhdl
-- the drive the current command runs on: one mux, reused by ca_offset/sd_addr
-- and by the busmaster's header words.
cur_dc <= rmdc(cur_unit);
cur_ta <= rmda_ta(cur_unit);
cur_sa <= rmda_sa(cur_unit);
```

Then `ca_offset` (`:1285-1307`), `sd_addr` (`:1309-1341`) and the four busmaster
reads become a **pure textual rename** (`rmdc`→`cur_dc` etc.) — no structural
change, and the mux is provably instantiated once.

Equally important: keep the position-increment datapath at `:1043-1060` and
`:1110-1127` **single-instance**. Read through `cur_dc`/`cur_ta`/`cur_sa`, compute
once, write back to `rmda_sa(cur_unit)` etc. Do *not* write it as two duplicated
`if cur_unit = 0 / = 1` bodies — that replicates ~40 LUTs of adders and
comparators.

This also sidesteps a VHDL-93 parser risk: slice-of-indexed-name
(`rmda_ta(cur_unit)(4 downto 0)`) is avoided entirely because everything goes
through the flat aliases.

### 2. The latched-unit rule

**Rule: `cur_unit` for everything inside the `if rmcs1_go = '1'` block
(`:880-1166`) and the entire backend address path; `usel` for the register file
(`:538-824`) and the derived combinationals (`:450`, `:457`, `:461`).**

An important correction to the obvious rationale: `rh11.vhd:662` refuses *any*
register write while GO=1 with RMR, except RPAS (`"00111"`) and RPMR1 (`"01010"`) —

```vhdl
if rmcs1_go = '1' and bus_addr(5 downto 1) /= "00111" and bus_addr(5 downto 1) /= "01010" then
   rmer1_rmr <= '1';
```

so **the guest physically cannot change RPCS2's unit field mid-command in this
core**, and live indexing would in fact be safe today. Latch anyway:

- GO / FNC / RDY are controller-wide; there is no per-drive GO. Any future
  relaxation of `:662` — e.g. someone implementing real overlapped seek — would
  silently corrupt the wrong drive's position registers.
- It costs 1 flip-flop and no LUTs, since `cur_unit` and `usel` are both 1-bit
  mux selects.

Latch it at `:670-679`, in the RPCS1 low-byte write, alongside GO:

```vhdl
   if rmcs1_sc = '0' then
      rmcs1_go <= bus_dato(0);
      cur_unit <= usel;                  -- this command belongs to the selected drive
      if rmds_err = '0' then
         rmds_ata(usel) <= '0';          -- NOTE: usel, not cur_unit - see below
      end if;
   end if;
```

`rmcs1_go` is a signal, so the `:880` block first fires on the next `nclk` edge, by
which time `cur_unit` has settled. Also initialise `cur_unit <= 0` at `:483-491`
and in the `rmcs2_clr` block at `:1207`.

**`cur_unit` sites** — the function decode / command body (`:880-1166`),
including every `rmds_dry <= '1'`, `rmds_ataset <= '1'`, `rmds_vv <= '1'`, `rmer*`
set; the multi-sector position auto-increment at `:1043-1060` and `:1110-1127`;
`ca_offset` / `sd_addr` / `dn_offset` (`:1285-1341`); and the four busmaster
*reads* at `:1405`, `:1409`, `:1419`, `:1423`.

The busmaster FSM (`:1345-1588`) only **reads** `rmdc` and `rmda_ta & rmda_sa` — to
build the read-header words. It never increments them; all the stepping is in the
GO block in the `nclk` process. That keeps the per-drive rewrite confined to one
process plus four cross-phase reads.

`sd_addr`/`ca_offset`/`dn_offset` must use `cur_unit` because they feed `sddisk`
continuously via the port map at `:392`, and `sdcard_read_start`/`write_start` are
only asserted inside the GO block (`:1033`, `:1100`) — so `cur_unit` is always
valid and stable while a request is in flight.

**Two sites that look like command state but must be `usel`:**

- `:677` `rmds_ata <= '0'` on an RPCS1 write. This executes *before* GO takes
  effect, so `cur_unit` still holds the previous command's unit. Guard it against
  a nonexistent drive too: `if rmcs2_u(2 downto 1) = "00" then rmds_ata(usel) <= '0'; end if;`
- `:721` / `:724` (`rmds_wrl <= '1'` / `rmds_vv <= '0'` from an RPMR1 write).
  RPMR1 is one of `:662`'s two exceptions, so this **is** permitted while GO=1 —
  the one write-side path that can fire mid-transfer. `usel` is still correct
  (RPCS2 can't have changed), but it deserves a comment saying so.

**Cross-phase note:** `cur_unit` is written in the `nclk` process and consumed in
the `clk` process (via `cur_dc`/`cur_ta`/`cur_sa` at `:1405-1423`). Opposite phases
of the same clock, and `rmdc`/`rmda_*` are *already* read cross-phase there today —
no new CDC. Comment it so nobody later "fixes" it.

### 3. RPAS — real attention summary

```vhdl
-- one ATA bit per drive, bits 7..0 = drives 7..0. Only db0/db1 exist.
rmas <= "000000" & rmds_ata(1) & rmds_ata(0);
```

- **Read** (`:571-572`): `bus_dati <= "00000000" & rmas;`
- **Write-1-to-clear**, replacing `:715-716` (low byte, where all RPAS bits live):
  ```vhdl
  when "00111" =>
     if bus_dato(0) = '1' then rmds_ata(0) <= '0'; end if;
     if bus_dato(1) = '1' then rmds_ata(1) <= '0'; end if;
  ```
  and replace the high-byte case at `:794-795` with `null;`. This is not a
  cosmetic cleanup: today *both* branches clear unconditionally, so a word write
  ran the clear twice, and a `DATOB` to the odd byte wrongly cleared. W1C on the
  low byte alone is the correct behaviour.
- **`rmds_ataset` becomes per-drive.** Reset both at `:486`; unroll the
  single-shot transfer at `:858-861` over both units; all thirteen
  `rmds_ataset <= '1'` sites in the function decode become `(cur_unit)`.
- **Interrupt condition** at `:501`:
  ```vhdl
  if rmcs1_ie = '1'
     and (rmcs1_rdyset = '1' or rmds_ataset(0) = '1' or rmds_ataset(1) = '1') then
  ```
  An explicit OR, not `or_reduce` — the file is VHDL-93 with `STD_LOGIC_ARITH` /
  `STD_LOGIC_UNSIGNED` and never pulls in `ieee.std_logic_misc`.
- **Priority hazard, pre-existing and unchanged:** `:858-861` sits *after* the
  register-write block in the same process, so last-assignment-wins means a
  same-edge RPAS write-clear loses to a pending `ataset`. That is the physically
  correct resolution and matches today's behaviour.
- **Boot ROM round-trip works, and gets more correct.** `mov rpas(r1),rpas(r1)`
  (`m9312h-pdp2011.mac:217`) is a DATI followed by a DATO of the value read, so
  W1C clears exactly the drives that were asserting. It also isn't refused by
  `:662` (RPAS is an exception), and by then GO is already clear anyway.

### 4. `dn_offset` — folding the unit into the block address

RP06 = 815 × 19 × 22 = **340 670** blocks/unit; two units = 681 340, well inside
2²⁴. (`disks/211bsd-rp06.img` is 174 423 552 B = 340 671 blocks — one block of
slop, never addressed.)

`dn_offset` is already declared at `rh11.vhd:336` and never assigned — a leftover
from the RL11 template. Because the unit is a *single bit*, the RL11's shift-add
multiply degenerates into a select: `dn_offset` is either 0 or one constant, which
synthesises to ~11 AND gates that fold into the adder, versus ~40 LUTs for a real
shift-add tree. Insert after `:1307`:

```vhdl
-- drive number offset : the linear block stride of one complete pack, so db1's
-- image is served from the same 24-bit address space as db0 and pdp11-hostd
-- divides the unit back out (same trick as rl11.vhd's dn_offset, but with only
-- two drives it's a select rather than a multiply).
-- Any new rh_type needs its stride added here AND unit_sectors in pdp11-hostd.c.
   with rh_type select unit_stride <=
      conv_std_logic_vector(rh_noofcyl * 2048, 24) when 1,    --           RM06
      conv_std_logic_vector(rh_noofcyl * 4096, 24) when 2,    --           RP2G
      conv_std_logic_vector(171798, 24) when 4,               -- 411*19*22 RP04/RP05
      conv_std_logic_vector(500384, 24) when 5,               -- 823*19*32 RM05
      conv_std_logic_vector(340670, 24) when 6,               -- 815*19*22 RP06
      conv_std_logic_vector(1008000, 24) when 7,              -- 630*32*50 RP07
      conv_std_logic_vector(0, 24) when others;

   dn_offset <= unit_stride when cur_unit = 1 else "000000000000000000000000";
```

**Types 1 and 2 use 2048 / 4096 per cylinder, not `nooftrk*noofsec`** — their
`sd_addr` branches (`:1310`, `:1313`) are bit-concatenations, not packed
multiplies. Getting that backwards is the easiest bug in this change.

Add the offset **once**, not inside each `when rh_type = N` branch: rename the
existing selected expression to `sd_addr_geo` and finish with

```vhdl
   sd_addr <= sd_addr_geo + dn_offset;
```

`rh_type` is a constant-bound integer port (`unibus.vhd:1966`,
`zynq_top.vhd:318` = 6), so synthesis constant-folds the select and only the RP06
branch survives. One adder either way; this form is the smaller diff and provably
single-instance.

24-bit ceiling: types 4/5/6/7 are all safe with two units (RP07 worst case
2 016 000). Types 1 and 2 need `rh_noofcyl ≤ 4096` / `≤ 2048` respectively or
unit 1 aliases over unit 0 — comment it, don't add hardware. Shipped config is
`rh_type => 6` and is unaffected.

### 5. NED and the dispatch gate at `:899`

```vhdl
   rmcs2_ned <= '0' when rmcs2_u(2 downto 1) = "00" else '1';   -- two drives: db0, db1
```

Cheaper than what's there now (2-bit compare vs 3-bit). Units 2..7 keep returning
NED, which is the correct massbus response and is what makes a guest's drive probe
stop at DB1. The plumbing already works: NED → `rmcs1_tre` (`:450`) →
`rmcs1_sc` (`:448`) → `:674` gates GO on `rmcs1_sc = '0'`, so a command to a
nonexistent drive never sets GO and the guest sees NED+TRE+SC.

**Keep the `elsif` at `:899-901`, repurposed as a hard array-index guard** rather
than deleting it:

```vhdl
   elsif rmcs2_ned = '1' then
    -- unreachable: sc/ned gates go at :674. Belt and braces so a nonexistent
    -- unit can never reach the per-drive arrays below.
```

It folds into the existing priority chain for ~1 term and documents the invariant.
Combined with indexing on `rmcs2_u(0)` only (§1a), an out-of-range index is
structurally impossible.

**Cheap fidelity win (2 LUTs):** a real RH11 reports DPR=0 and MOL=0 for an absent
drive. With `usel = rmcs2_u(0)`, reading RPDS with unit 4 selected would otherwise
return DB0's status. At `:564`, mask them: `(rmds_mol(usel) and not rmcs2_ned)` and
`(rmds_dpr(usel) and not rmcs2_ned)`. Do *not* extend this to ER1/ER2/DC/DA/OF —
that's a ~30 LUT AND array and no driver depends on it once NED+TRE are set.

### 6. `error_reset` needs scoping (easy to miss)

`error_reset` is set from two places with different meanings:

- `:1240`, inside the `rmcs2_clr` block — controller CLR, must clear **both** drives.
- `:957`, DRIVE CLEAR (fnc `00100`) — must clear **only** `cur_unit`'s ER1/ER2.

Add one register and one bit:

```vhdl
signal error_reset_u   : integer range 0 to 1 := 0;
signal error_reset_all : std_logic := '1';
```

`:957` sets `error_reset <= '1'; error_reset_u <= cur_unit;` (leaving
`error_reset_all` at '0'); `:484` and `:1240` also set `error_reset_all <= '1'`.
Then `:1243-1275` becomes a loop over `u in 0 to 1` gated on
`error_reset_all = '1' or u = error_reset_u`. Every assignment in that block is a
constant '0', so this lands on the flip-flop clock-enable and is essentially free.
`rmmr1`/`rmmr2` at `:1272-1273` stay unconditional.

### 7. Reset defaults for an unloaded DB1

`rh11.vhd:1209-1220` unconditionally forces `mol='1'`, `dpr='1'`, `dry='1'`,
`vv='1'` (two `FIXME, set according to sdcard state?` comments). Keep that for
**both** drives, and loop the reset over both units — replace the scalar
assignments at `:1190-1191`, `:1210-1220`, `:1226` with `for u in 0 to 1 loop`, the
way `rl11.vhd:328-335` unrolls its four units.

The core cannot know whether the PS has an image loaded: `sddisk.vhd` has no
PS→core status path. So an unloaded DB1 presents as an online drive with good
media and fails only at first access — `pdp11-hostd.c:963-970` logs "no image for
unit" and completes with `done_error` → `sdcard_error` → `rmer1_dck`, i.e. the
guest sees a media error rather than "no such drive". That is inherent to the
no-block-design-changes constraint and is exactly what DB0 does today. Document
it. The clean fix later is one spare bit per unit in the `sddisk` AXI status
register driving `rmds_mol(u)` — a follow-up, not part of this work.

### 8. `unibus.vhd` / `zynq_top.vhd` / `front_panel.vhd` — no change

The drive count is internal to `rh11.vhd`; no new generic, no new ports. The
component declaration at `unibus.vhd:522-591`, the `rh0:` instance at `:1901-1970`
and `zynq_top.vhd:314-318` are untouched. `sddisk` is instantiated *inside*
`rh11.vhd` at `:385-434` with `sdcard_addr => sd_addr`, so the bridge is untouched
too. `front_panel.vhd` keys its DMA light off NPR activity only — unit-agnostic.

### 9. `pdp11-hostd.c` — PS side

Nearly all of it is already unit-generic. The substantive change is two fields.

1. **`g_rh` at `:171-176`:**
   ```c
   .buf_words = 256, .sector_bytes = 512, .max_units = 2,
   .unit_sectors = 340670, .required = 0,   /* RP06: 815 cyl x 19 trk x 22 sec;
                                             * must match rh11.vhd's unit_stride */
   ```
   `MAX_UNITS` is 4 (`:97`), so `imgfd[]`/`imgpath[]` already have room.

2. **No change needed** in `serve_bus` (`:899-911` already takes the divide branch
   when `max_units > 1`; the `dlfix` re-split at `:944-955` is RL-only),
   `parse_unit_spec` (`:470-491` already parses `"rh1"` generically —
   `max_units` in `load_image:412` / `do_unload:445` is the only gate),
   `save_config`/`load_config` (already loop to `max_units`, so `RH1=` round-trips;
   an existing `diskd.conf` with only `RH0=` loads fine — **no migration step**),
   or `build_status_json` (`:576-606` already loops).

3. **`-R` becomes repeatable** rather than gaining a `unit:path` syntax — this
   keeps the existing `-R /srv/pdp11/db0.img` invocation working byte-for-byte.
   At `:1597` swap `const char *rh_seed_img` for `char *rh_seed[MAX_UNITS]` +
   `rh_seed_n`; at `:1633` accumulate with the same bounds check the RL positional
   args use at `:1640-1641`; at `:1669-1675` loop the seeding, keeping RH's
   non-fatal-on-failure behaviour; and `:1677`'s `rh_seed_img` test becomes
   `rh_seed_n`. Usage string at `:1607-1610`.

4. **Stale comments** at `:15-16`, `:97`, `:146-147` ("RH uses only unit 0",
   "unused when max_units==1").

5. **`pdp11-hostd.init` — the one real footgun.** Because `-R` is positional, DB1
   must never be passed without DB0 or DB1's image lands in unit 0:
   ```sh
   DB1=/srv/pdp11/db1.img
   RHARG=""
   [ -f "$DB0" ] && RHARG="-R $DB0"
   # strict order: DB1 only ever seeds unit 1, and only when DB0 filled unit 0
   [ -f "$DB0" ] && [ -f "$DB1" ] && RHARG="$RHARG -R $DB1"
   ```

### 10. Docs / helper scripts

- `README.md:388` — the "there is one drive only" paragraph is the load-bearing
  one; rewrite it around the `dn_offset` folding. Also `:352` ("DB0 is the only RH
  unit anyway" → swap DB1 freely, never DB0), and `:41`, `:124`, `:310`, `:538`.
- `scripts/dlctl.sh:4` "(DB0, one drive only)" → "(DB0, DB1)"; `:13` unit spec.
- `scripts/rp06_boot.sh:13-17` — its header quotes the `elsif rmcs2_u /= "000"`
  comment and says "there's no unit argument". Add an optional unit argument: one
  word in the deposited bootstrap (`MOV #0,@#176710` → `MOV #<unit>,@#176710`).
- `scripts/rh11_probe.sh` — extend to probe both units (see verification 4a).

---

## Files to change

| File | Scale |
|---|---|
| `vivado/pdp2011_core/core/rh11.vhd` | the bulk: ~45 signals arrayed, ~280 reference lines re-indexed |
| `petalinux/.../pdp11-hostd/files/pdp11-hostd.c` | ~30 lines, mostly the `g_rh` initialiser and `-R` |
| `petalinux/.../pdp11-hostd/files/pdp11-hostd.init` | 3 lines |
| `scripts/dlctl.sh`, `scripts/rp06_boot.sh`, `scripts/rh11_probe.sh` | comments + optional unit arg |
| `README.md` | ~6 spots |

Untouched: `sddisk.vhd`, `unibus.vhd`, `zynq_top.vhd`, `front_panel.vhd`,
`m9312h-pdp2011.mac`, `vivado/scripts/02_create_bd.tcl`, `system-user.dtsi`.

---

## Verification

There is no testbench in the repo and neither `ghdl` nor `nvc` is installed.

**Phase 0 — syntax/elaboration, seconds, no synthesis.** Vivado ships `xvhdl`
(check `$VIVADO/bin/xvhdl` — I did not confirm it is present on this install):

```
source $VIVADO/settings64.sh
xvhdl --work work vivado/pdp2011_core/core/sddisk.vhd vivado/pdp2011_core/core/rh11.vhd
```

Run it after every edit chunk. It catches the two things most likely to go wrong
here: aggregate-vs-element type mismatches on `(others => '0')` into array
elements, and slice-of-indexed-name parsing. If `xvhdl` isn't available, synthesis
is the fallback and §1b's flat aliases matter even more.

**Phase 1 — prove the PS side alone, on the *existing* bitstream.** This is the
big schedule win. With `max_units=2` and `unit_sectors=340670`, DB0's behaviour is
bit-identical: every block the current bitstream emits is < 340670, so
`block / 340670 == 0` and `block % 340670 == block`.

```
scripts/build_pdp11_hostd.sh && scripts/deploy_pdp11_hostd.sh
scripts/dlctl.sh status            # RH: 2 units, unit_sectors 340670
scripts/dlctl.sh push disks/db1.img db1.img && scripts/dlctl.sh load rh1 db1.img
# reboot the board -> diskd.conf must replay RH0 *and* RH1
```

2.11BSD must still boot off DB0 unchanged throughout. That proves the whole C-side
change set before a single Vivado run.

*Note:* `scripts/deploy_pdp11_hostd.sh:19` targets `192.168.10.185` while
`dlctl.sh:21` and `flash_bootbin_net.sh:7` use `.192`. Pre-existing, but it will
bite here.

**Phase 2 — make `db1.img`.** At least `340670 * 512 = 174 423 040` bytes, and it
**must be writable**: `load_image` opens `O_RDWR | O_SYNC` (`:419`), so a
read-only file fails the load outright, while a *short* file loads fine and then
fails per-sector into `rmer1_dck`.

```
dd if=/dev/zero of=disks/db1.img bs=1M count=167
# plant a signature in block 0 so the dn_offset test can't pass by accident
printf '\x11\x11%.0s' $(seq 1 256) | dd of=disks/db1.img bs=512 count=1 conv=notrunc
```

**Phase 3 — Vivado, with an early gate.** `./build.sh bitstream` (~10-12 min;
impl alone was 3 m 14 s at `-jobs 4` per `04_build.log`). Insert a utilisation
check *between* synth and impl rather than discovering a placement failure ten
minutes in:

```tcl
open_run synth_1 -name synth_1
report_utilization -hierarchical
```

If total Slice LUTs exceed ~16 800 (95 %), stop and apply the mitigations below
before running impl. Then `cd docker && ./plnx.sh package` (repackages BOOT.BIN
around the new bitstream, no full Yocto rebuild) → `scripts/flash_bootbin_net.sh`
→ **power-cycle** (a warm reboot won't reload the PL).

**Phase 4 — proof, in increasing order of strength.**

*4a. ODT register probe, no OS.* Extend `scripts/rh11_probe.sh` (currently
examine-only `L`/`E` pairs at `:24-31`; this needs deposits, so borrow the `L`/`D`
idiom from `rp06_boot.sh`):
- Deposit `000001` into `176710` (RPCS2) → examine `176712` (RPDS): DB1's own
  DRY/VV/MOL/DPR. Examine `176710`: NED (bit 12) must be **0**.
- Deposit `000002` → NED must be **1**, and `176700` must show TRE (bit 14) and
  SC (bit 15).
- Write different values to `176734` (RPDC) under unit 0 vs unit 1 and read each
  back — proves RPDC is genuinely per-drive, not shared.
- RPAS: SEEK on DB1 (CS2=1, DC=1, CS1=`000005`), then examine `176716` → must read
  `000002`, not `000001`. Deposit `000002` → re-examine → `000000`. That validates
  the whole per-drive attention bitmap in four keystrokes.

*4b. The decisive `dn_offset` test, no OS.* Run the unit-parameterised
`rp06_boot.sh` with unit=1 against the signature image, then examine location `0`
in ODT: it must read `011111`, not DB0's boot block. Cross-check
`/var/log/pdp11-hostd.log` for `DB1: REQ#n READ block 340670 (unit 1 sec 0,
offset 0)`. **This single test proves the entire hardware change** — latched unit,
per-drive DC/DA, and the 340670 stride.

*4c. 2.11BSD.* This is the RH-capable guest here; its `rp` driver supports 8 units.
`MAKEDEV rp1`, `disklabel -w -r /dev/rrp1a rp06`, `newfs`, `mount`, write and
verify. Then the test that actually exercises the latch: concurrent large `dd`
off `/dev/rrp0a` and `/dev/rrp1a`, checksums on both. Snapshot `db0.img` off the
board first — an aliasing bug shows up as DB0 corruption.
(RT-11 V5.3 as shipped here has DL/DM/DU/DY/RK handlers and no RP06 handler, so
it is not a useful vehicle for this — confirm before spending time on it.)

*4d. XXDP, optional but highest fidelity.* `ZRJ*` (RP04/05/06 drive functional)
and `ZRHA` (RH11 controller) hit unit select, NED and the attention summary
directly — precisely this change's surface.

**Regressions to re-check:** DB0 still boots 2.11BSD; the rk→rl→rp auto-boot
fallover still reaches DB0; `scripts/rl0_boot.sh` still works (RL11 is a separate
`sddisk` instance and is logically untouched, but the die is more congested now).

---

## Risks

**R1 — resource and congestion, the dominant risk.** Estimated cost:

| Item | LUTs | FFs |
|---|---|---|
| Per-drive storage (ds 10 + er1 16 + er2 8 + dc 16 + ta 8 + sa 8 + of 4 + ataset 1), one extra copy | 0 | +71 |
| `cur_unit`, `error_reset_u`, `error_reset_all` | ~2 | +3 |
| Read-path muxes (DS, ER1, ER2, DC, DA, OF) | 40-70 | 0 |
| `cur_dc`/`cur_ta`/`cur_sa` mux | ~25 | 0 |
| `dn_offset` add (constant, folds into the adder) | ~15 | 0 |
| Write-side unit demux (mostly merges into existing clock enables) | 30-60 | 0 |
| RPAS bitmap + W1C | ~4 | 0 |
| Narrower NED compare | −1 | 0 |
| **Total** | **~115-175** | **~+74** |

Flip-flops are a non-issue. ~150 LUTs is 0.85 % of the device and *should* fit the
~2090 free sites, but with **zero free slices** Vivado must repack, and routing
will degrade from an already-thin 0.703 ns. Mitigations in order:

1. The synth-only utilisation gate (Phase 3) — cheap early exit.
2. `04_build.tcl` sets no synth/impl strategy today. Add
   `STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE = AreaOptimized_high`, and if timing slips,
   `STRATEGY Performance_ExplorePostRoutePhysOpt` on `impl_1`.
3. Micro-saving: narrow `rmdc` to 13 bits per drive (bits 15..13 are never used;
   pad on read at `:611`/`:619`) — ~6 LUTs, 6 FFs.
4. **Plan B if it genuinely won't fit:** make `rmer1_*`/`rmer2_*` shared again.
   Recovers ~60 LUTs at a real fidelity cost (a DB1 error would surface in DB0's
   ER1). Back pocket — don't start here.

**R2 — no PS→core "unit loaded" path.** See §7. An unloaded DB1 looks online and
fails as a media error. Inherent to the constraints; follow-up work.

**R3 — no overlapped seek across drives.** `:662`'s RMR interlock plus a single
shared GO/FNC/RDY means a driver that tries to seek DB1 while DB0 transfers gets
RMR. 2.11BSD's `rp` driver serialises and won't hit this. Document it — and it is
exactly why `cur_unit` is worth latching rather than relying on the interlock.

**R4 — VHDL-93 mechanics.** Avoid slice-of-indexed-name and arithmetic directly on
array elements inside deep expressions; §1b's flat aliases make both impossible,
with the bonus of a provably single mux.

**R5 — stride mismatch** between `rh11.vhd`'s `unit_stride` and
`pdp11-hostd.c`'s `unit_sectors` silently reads the wrong file at the wrong
offset. Verification 4b exists to catch it; keep the two constants commented as a
pair.

**R6 — `-R` ordering** in the init script (§9.5) — the most likely operational
footgun.

**R7 — `rmds_err` and `usel` must stay locked together.** `rmds_err` is derived
from the *selected* drive's ER1/ER2, and `:676` (`if rmds_err = '0' then
rmds_ata(usel) <= '0'`) evaluates against the selected drive. That is correct only
because both use `usel`. Do not "optimise" one of them to `cur_unit`.

**R8 — auto-boot still only boots DB0** (`m9312h-pdp2011.mac:76` does `clr r0`
before `br rpgo`). Correct for a system-pack-on-DB0 layout; booting DB1 is a
manual ODT operation. Out of scope.

**Back out** by reverting `rh11.vhd` alone — the daemon with `max_units=2` is
harmless against a one-drive core.

---

## Suggested sequencing

1. `pdp11-hostd.c` + init script + docs → build, deploy, verify against the
   **existing** bitstream (Phase 1). Fully reversible, zero FPGA risk, and
   independently useful.
2. `rh11.vhd`, in this order: types and declarations → RPAS/`ataset` →
   register file (`usel` sites) → GO block (`cur_unit` sites) → `error_reset`
   scoping → `dn_offset`/`sd_addr`. Syntax-check after each chunk.
3. Synth-only utilisation gate before committing to impl.
4. Full build → flash → power-cycle → Phase 4b (the signature-block test) first.
