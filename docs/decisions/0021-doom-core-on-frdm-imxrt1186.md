# 0021: DOOM's CORE entries on FRDM-IMXRT1186

- Date: 2026-10-20
- Status: Accepted (owner, 2026-10-20).
- Scope: running decision 0008's three CORE entries (`doom_core_input`,
  `doom_core_step`, `doom_core_render`) on the Cortex-M33 of an FRDM-IMXRT1186
  under Zephyr, headless, and the evidence that accepts it. The hosted program,
  the entries' contracts and the native lanes are unchanged.

## Context

- **Footprint.** After [decision 0018](0018-narrow-buffer-elements.md), the 394
  resident buffers of the three entries hold, for E1M1 at 320x200 (calculated
  from the catalog's counts times the element widths; no allocation was
  measured):
  - writable (persistent, output, scratch; 191 buffers): 2,586.8 KB;
  - read-only (resources; 203 buffers): 14,154.0 KB, most of it the WAD's data
    held three times;
  - the `core_state` scalars: 1,968 B.
- **The board** (survey of 2026-10-20 from IMXRT1180RM Rev.9, UM12450 Rev.2.0,
  schematic SPF-95302_a4 and Zephyr v4.4.2's board files):
  - on-chip SRAM 1,536 KB in total (CM7 TCM 512 KB, CM33 TCM 256 KB, OCRAM
    768 KB): too small for the writable part;
  - HyperRAM 8 MB on FlexSPI1 port B, at `0x3800_0000` from the CM33. Zephyr's
    `frdm_imxrt1186/mimxrt1186/cm33` already uses it as `zephyr,sram`; the ROM
    initialises it from the XMCD at offset `0x800` of the boot NOR, so only on
    a NOR boot;
  - QSPI NOR 16 MB (W25Q128JV) on FlexSPI2 port A, the default boot flash,
    memory-mapped at `0x1400_0000` (secure alias) for execute- and read-in-place;
  - HyperFlash 64 MB, reserved: enabling it changes 11 solder-blob jumpers and
    disconnects part of ECAT1's MII paths and the SINC2/SINC3 signals.
- **The board is dedicated to this project** (owner, 2026-10-20). The AVB/TSN
  switch project that shared it is on hold, and its image in the QSPI NOR may
  be replaced.
- **What the hosted program does between entries** (`examples/doom/core/full/native_loop.rb`):
  - opens the session once, from the original objects (`nativeprep.rb`);
  - per tic, writes the key table or a demo's command, then the step's wipe
    count, then seven render-side cells copied from game-side cells, and reads
    eight scalars it passes to the render entry;
  - checks two cells before calls (`renderer_jobmode` is 0 since
    2026-10-21, decision 0008; no pending rebirth).

  The session open needs the original game objects and the IWAD, which the
  board cannot hold beside the session. Everything per tic is cell copies and
  checks over the session's own buffers.
- **Arithmetic width.** The CORE sources declare `# spinel: int64`
  ([decision 0019](0019-target-integer-width.md)), so the entries compute in
  signed 64 bits on the 32-bit M33. That is correct, and slow; the owner plans
  a 32-bit rewrite separately.

## Decision

**One copy of the WAD's data.** `status_bar_data`, `renderer_wad_data` and
`hud_data` are each the whole IWAD (`table:waddata`, `u8`, 4,196,020 elements
for `doom1.wad`). They become one resource buffer, the other two names aliases
of it through the schema's existing `#alias` rows, as the executor's banks are
aliases of Jobs' banks. This saves 8,392,040 B (8,195.4 KB): the read-only part
falls from 14,154.0 KB to about 5,958.6 KB (calculated), which leaves about
10,425 KB of the 16 MB NOR for the boot data and the program. The hosted
footprint falls by the same amount.

**A host-prepared session image.** The session at open is produced on the host
by the existing route (`tests/doom-core/native.sh` already holds it equal to
the CRuby route's, cell for cell) and written as one image with two parts:

- the resource buffers, placed in the QSPI NOR and read in place through the
  memory-mapped window, never copied to RAM;
- the initial contents of the writable buffers and of `core_state`, copied
  from the NOR into HyperRAM once at boot.

The image records each buffer's element type, count and offset from the
generated schema, and a digest the board checks before the first tic.
Implemented: the image format is in [examples/doom/core/README.md](../../examples/doom/core/README.md#the-session-image), and the bound resource in [buffer-boundary.md](../core/buffer-boundary.md#bound-storage-decision-0021).

**Resources at an address the boundary did not allocate.** The buffer
boundary today allocates every buffer it passes. A `resource` buffer may
instead be bound to a caller-supplied address and count, read-only, under the
boundary's existing entry validation, alignment and count-times-size checks.
This changes the boundary's contract, for the `resource` role only.

**The board loop is a CORE Ruby application** through
[decision 0014](0014-core-applications-on-zephyr-plan.md)'s application tool.
Per tic it does exactly what `native_loop.rb` does between the entries, on the
board's copy of the session: the demo command (headless, so no key table), the
input, step and render entries, the cell copies, and the two checks. It loads
no WAD and opens no session itself. 0014's tool must:

- call the three DOOM entries from the application's loop;
- take resident buffers of this size, the resources at the bound NOR address
  and the writable buffers in HyperRAM;
- generate the Zephyr glue for `frdm_imxrt1186/mimxrt1186/cm33`.

**The board lane.** A new lane builds the entries and the application for
`thumbv8m.main-none-eabi` through the existing freestanding route, writes the
image and the program to the QSPI NOR through the i.MX8MP's LinkServer (the
route `e040-frdm` and `bm040-frdm` use for FRDM-MCXN947), and reads results
from the console.

**Acceptance.** For DEMO1 to DEMO3, the board prints the sha256 of every
frame's `renderer_screen`, and every digest equals the recorded frames of
`tests/doom-core/fixtures/screens`, the same frames `screens.sh` and `native.sh`
check. A failing entry prints its 0007 status and stops. The run also records
the wall time per tic, as information, not as a bound. With the single WAD
copy, the hosted lanes `entries`, `state`, `tick`, `verify` and `screens` pass
on both hosts.

**Writing the board.** The lane may write the QSPI NOR without a further
confirmation (owner, 2026-10-20). The AVB/TSN project keeps its own image, so
nothing is read out first.

**Out of scope:** keys, an LCD over FlexIO, and interactive play. They follow
once the headless lane is accepted.

## Why not the alternatives

- **A hand-written C loop**, as `e040-frdm`'s driver is. Smaller and sooner,
  but it repeats `native_loop.rb`'s per-tic writes in a second language,
  outside the CORE checks.
- **Keeping the three WAD copies.** They fit the NOR with 2,230 KB to spare,
  too little for the boot data and the program with any margin.
- **The hosted program on the board.** `bin/doom.rb` needs Spinel's GC and
  runtime and the original objects beside the session, which the 8 MB of
  HyperRAM cannot hold. It also gives up what the board run is meant to show:
  the CORE entries running with no runtime.
- **HyperFlash for the resources.** It fits with room to spare, but needs
  soldering and gives up board signals; with one WAD copy the NOR is enough.
- **On-chip SRAM only.** 1,536 KB is below the writable part alone.

## Consequences

- A second board joins the hardware lanes, with its own flash route and a
  board-only lane that the hosts cannot run.
- A resource bound to a NOR address is the first CORE buffer whose memory the
  boundary does not own.
- The single WAD copy changes the entries' buffer list and the generated
  schema.
- 0014's application tool grows to drive entries it did not generate, with
  buffers in two memories.
- The per-tic timing at 64-bit arithmetic becomes measured evidence for the
  owner's 32-bit rewrite.

## Clarification (2026-10-20): one demo per write, and the board application's declarations

The owner settled these on 2026-10-20, while planning the board lane. They
narrow how the accepted direction is built; they do not change it.

- **One demo per write.** DEMO1, DEMO2 and DEMO3 open different maps (E1M5,
  E1M3, E1M7), so each needs its own session image. Measured with
  `tools/doom/session-image.rb`, each is about 6.15 MB of resources and
  2.61 MB of writable contents, so the three together (about 26.3 MB) do not
  fit the 16 MB NOR. 139 of the 205 read-only buffers (6,039,585 B) are
  identical across the three images. The lane writes one demo's image and
  program per write, and rewrites the NOR for each demo. The image format
  stays as it is. A shared format, with the common resources stored once and
  zero runs left out of the writable part, waits until it is needed.
- **Compiler runtime helpers are admitted on the board lane.** At 64 bits on
  the M33, the entries may call the compiler's runtime helpers, such as
  `__aeabi_ldivmod`. The lane admits them and records which helpers the linked
  objects call. 0014's production-build refusal of these helpers for
  application entries is unchanged.
- **The DOOM entries are built apart from the application** and linked into
  it. They pass through none of 0014's pipeline steps, as 0014 §8 already
  states.
- **The application's declarations.**
  - `core_session "<entries dir>"` names the three entries' contracts. The
    tool reads them with `entries/fields.tsv` and the image's `image.tsv`,
    generates `DoomCore.input`, `DoomCore.step` and `DoomCore.render`, which
    take the scalar arguments only, and binds every buffer argument to the
    session's storage by `fields.tsv`.
  - An application entry receives a session buffer by naming a parameter
    after it, as it receives a `state`.
  - A `core_state` slot is read and written through generated constants
    (`Slot::NAME`, one level, as 0014's D5 admits).
  - Placement is a build argument, `--session-image DIR`, not a source
    declaration. Resources are read in place at the image's NOR address.
    The writable buffers are placed in HyperRAM, and `writable.bin` is copied
    there at boot.
  - One tic runs per release of an existing `every_ms` trigger. A tic longer
    than the period is recorded as skipped releases, with no new keyword.
  - Each frame's digests are computed by a `core_extern` with a C provider
    that reads `renderer_screen`, and printed over a `uart:` channel. A CORE
    helper refuses the additions and products modulo 2^32 and 2^64 these
    digests need. Per-tic time comes from `Clock.cycles`.
    - Two of the digests are the FNV-1a 64 view and full digests. They are
      what `tests/doom-core/fixtures/screens` records, so the lane compares
      them with the recording directly.
    - The third was the sha256 this record named, until the owner's
      decision of 2026-10-21 below removed it.
  - Each `DoomCore` member answers its entry's 0007 status as its value. The
    application prints a nonzero one on the console with the tic and the
    entry, and stops.
  - On the host, the application's entry is run release after release under
    CRuby (`CoreApp::SessionHost`), with the `DoomCore` calls executing the
    CORE source in CRuby. It is one entry in one context, so 0014's
    event-driven host runner adds nothing here.
  - The application declares `# spinel: int64` (decision 0019 lets an
    application choose it freely). Its numbers are printed in hexadecimal: at
    64 bits a decimal digit needs a division, which the M33 makes a
    runtime-helper call, and 0014 refuses that in an application entry.
- **Writing the board** goes through the LinkServer on the i.MX8MP, the route
  `tests/freestanding/frdm-host.sh` and `e040/run_frdm.sh` use for
  FRDM-MCXN947.
- **An unknown extern bound** (the owner's decision, 2026-10-20). The step and
  render entries have loops without a derived bound (112 and 74 of them in
  their thumbv8m reports), so `DoomCore.step` and `DoomCore.render` cannot
  carry a true `bound iterations <expr>`.
  - An extern line may declare `bound iterations unknown "<reason>"`. An
    empty reason is refused.
  - An entry that calls such an extern has loop_bound `unknown`, naming the
    extern and the reason (docs/core/core-report.md).
  - The application tool admits that only for the DoomCore members
    `core_session` generates, and records it in `build.json` with the reason.
    An application's own extern declaring it is refused.
  - Every other realtime property, and the derivation of the application's
    own loops, stay enforced.
  - **The board application's DoomCore entry, and the board lane, make no
    realtime claim.** They are built under the realtime profile with
    loop_bound unknown through DoomCore. `DoomCore.input`'s work derives, and
    it carries its bound.
- **The demo's commands** (the coordinator's decision, 2026-10-20, within the owner's
  `core_session` and 0021's rule that resources are read-only).
  - `tools/doom/session-image.rb --demo DEMOn` records where the demo lump is
    inside the IWAD the image holds, as `#demo DEMOn offset N tics T`. The
    lump is checked by `examples/doom/lib/doom/demo.rb`'s rules (version 109,
    one player, a DEMOMARKER), and a broken lump is refused.
  - `core_session` makes that `Image::DEMO_OFFSET` and `Image::DEMO_TICS`.
  - The application receives `renderer_wad_data` as a read-only session
    argument. A resource is admitted as an argument only from the session,
    and the build refuses an entry whose kernel report says it writes one.
- **The board's first run overflowed the scheduler thread's stack** (found
  2026-10-21; the coordinator treated the fix as a correction of the stack
  measurement, since stack_budget already claims the stack actually used).
  - On the board, DEMO1 faulted right after `SPC_RUNNING`: the current thread
    was the scheduler thread, with PSP equal to PSPLIM at the bottom of its
    stack.
  - The cause is in the measurement. On Thumb, a function whose largest
    outgoing argument area is 2047 bytes or more does not reserve call frames
    in its frame, and neither clang's `.su` nor the kernel's frame-size
    diagnostic counts them. In the image, the session wrappers moved sp by
    3536 bytes (`DoomCore.step`, `.su` 296) and 3432 (`DoomCore.render`,
    `.su` 336) to call their entries. Inside the entries, `sp_doom_core_step`
    moved it by 3504, `sp_dc_st_g_ticker` by 3480 and `sp_doom_core_render`
    by 3016.
  - The kernel's report and the application tool's `.su` frames now add
    these frames (docs/core/core-report.md), each named in the evidence. The
    scheduler thread's requirement for DEMO1 went from 14,588 to 21,228
    bytes: the step entry's kernel_stack is 16,744 and the render entry's
    16,616.
  - The board lane's console reader stops at a Zephyr fault, a refused
    session or a second boot, and names it.
- **The board's console is framed** (found 2026-10-21, on the rerun with the
  corrected stack). The run reached `D` after 5026 tics with no fault. The
  board loop writes its lines on its `console` channel, so each one reaches
  the UART as a 0014 transport frame: 0xA5, channel, length, payload. The
  lane's readers had read plain text.
  - The app is unchanged. `tools/doom/board-frames.rb` decodes the frames by
    that contract (`tools/app/lib/core_app/console.rb`). It refuses a frame
    on another channel, a length outside the channel's 1..136, a payload
    that is not one loop line, and a console that ends inside a frame.
  - **Where the lane reads from.** The write's own reset starts the image
    before the console is open, so the log begins inside that earlier run.
    `rt_console` records the console's length just before its own reset.
    `board-frames.rb --from` reads from the first boot banner after that
    length, and fails on any further banner, searched in the raw bytes.
  - On the console the implementer captured from the run (693,691 bytes), the reader
    finds 5026 frames, each the recorded one, ended after 5026 tics; the
    median tic is 163.1 ms, as information. That capture was not taken
    through the corrected `rt_console`.

## Owner's decision, 2026-10-21: no sha256 on the board

The board stops computing each frame's sha256. Acceptance compares the two
FNV-1a 64 digests (view and full) with `tests/doom-core/fixtures/screens`, as
the lane already does. Those digests are what the recording holds, so the
sha256 was never compared with a recording. The board profile of 2026-10-21
measured the sha256 at 16.7 ms of a 143 ms tic. The "Acceptance" paragraph's
sha256 is superseded by this.

## Owner's decision, 2026-10-21: the screen in DTCM

`renderer_screen` (64,000 B) moves from HyperRAM to the CM33's DTCM. The
other writable buffers stay in HyperRAM.

- **Boot.** The board copies the screen's initial value from the NOR's
  writable part once at boot, as it does for the other writable buffers.
  This is correct for any image and takes 1.72 ms.
- **Space.** DTCM then holds the screen and the scheduler stack: 86,264 of
  131,072 B.
- **Measurement.** On DEMO1's first 500 tics, the tic median fell from 94.0
  to 90.7 ms, and every one of the 50 sampled tics was faster. `exec_run`
  fell from 19.4 to 16.5 ms per tic.
