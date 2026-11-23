# 0023: DOOM's board lane on the FRDM-IMXRT1186's Cortex-M7

- Date: 2026-10-21
- Status: Accepted (owner, 2026-10-21): the move to the Cortex-M7, the boot
  route and the stack-overflow detection below. The rest is the
  implementation plan, within those choices.
- Scope: the board lane of [decision 0021](0021-doom-core-on-frdm-imxrt1186.md)
  moves from the Cortex-M33 (240 MHz) to the Cortex-M7 (792 MHz) of the same
  board. The entries, their contracts, decision 0022's arithmetic and the
  acceptance (the recorded FNV-1a 64 frames) are unchanged.

## Context

- **The goal.** The owner's target is 40 tics per second, 25 ms a tic. On the
  M33, DEMO1's first 500 tics took a median of 94.0 ms on 2026-10-21, after
  three changes: decision 0022's wrapper changes, the board no longer
  computing sha256, and the stack in DTCM. That is about 27% of the target.
- **The M7.** It runs at 792 MHz, with 32 KB instruction and 32 KB data
  caches, and 512 KB of TCM, split 256/256 by default.
- **The survey** of 2026-10-21 used IMXRT1180RM Rev.9, UM12450, Zephyr v4.4.2
  and LinkServer 26.3.123. Its findings:
  - **Boot.** The ROM always starts the M33 (RM §12.1). The M7 stays in
    reset until software on the M33 releases it (RM §12.10).
    - An M7-only boot needs fuses (BOOT_CFG7), which are out of bounds.
    - Zephyr's supported route builds two images with sysbuild: an M33
      image with `CONFIG_SECOND_CORE_MCUX` that releases the M7, and the M7
      image.
  - **Memory, in the M7's view.**

    | memory | address |
    |---|---|
    | QSPI NOR | `0x0400_0000` |
    | HyperRAM | `0x2800_0000` |
    | ITCM | `0x0` |
    | DTCM | `0x2000_0000` |
    | OCRAM1 (cacheable) | `0x2048_0000` |

    - The ROM initialises HyperRAM from the boot image's XMCD, which is the
      M33 image.
    - Zephyr's stock `cm7` target puts SRAM in the 256 KB DTCM and disables
      `hyperram0`.
  - **Writing and debug.** LinkServer writes the NOR through the M33 (the
    primary core), as it does today. It can attach to the M7 (`--core cm7`).
    Attaching to a NOR-booted M7 is untested.
  - **Console.** Zephyr's M7 console is LPUART3. The board's enumerated VCOM
    is LPUART1, and LPUART3's VCOM needs jumper J34, which is out of bounds.
  - **Stack overflow detection.** The M7 (v7-M) has no PSPLIM. Zephyr then
    uses an MPU stack guard. The application tool refuses
    `CONFIG_MPU_STACK_GUARD` today, because its stack check does not model
    the guard. On the M33, PSPLIM is what caught the overflow of 2026-10-21.

## Decision

1. **The lane runs DOOM on the M7.**
2. **Boot through Zephyr's sysbuild** (owner).
   - **The M33 image** is a small launcher at NOR 0 with the boot container
     and the XMCD. It releases the M7, and gives the M7 access to the AON
     LPUART1 and the memories it uses.
   - **The M7 image** is the DOOM board application.
   - No jumper or fuse is changed.
3. **The MPU stack guard, modelled** (owner).
   - The application tool's stack check learns `CONFIG_MPU_STACK_GUARD`: the
     guard region's size and its placement in the stack object.
   - Overflow is still caught at run time, as PSPLIM catches it on the M33.
   - Turning `HW_STACK_PROTECTION` off is not an option.
4. **Memory on the M7, the first layout:**
   - code runs from the NOR in place (`CONFIG_CM7_BOOT_FROM_FLASH`);
   - resources are read in place from the NOR at `0x0400_0000 + offset`;
   - writable buffers are in HyperRAM at `0x2800_0000`, through a board
     overlay that enables `hyperram0`;
   - the screen and the scheduler stack are in the M7's DTCM (0021's
     decision of 2026-10-21, carried over).
   - Hot code may move to ITCM later, as a measured change.
5. **NOR layout.** Zephyr puts the M7 code partition at `0x720000`, which is
   where the session image is today. One of the two moves. Every offset
   stays recorded in the board table, and the session base becomes the M7's
   FlexSPI2 window, not `CONFIG_FLASH_BASE_ADDRESS`.
6. **Console on LPUART1 from the M7**, through an overlay. If the M7 cannot
   reach it, the M33 launcher relays the console over a mailbox. The relay is
   the fallback and needs its own review.
7. **Toolchain for `thumbv7em.none-eabi`, cortex-m7.** These are measured or
   remade for the new target, not carried over:
   - the target refusals and the SysTick/NVIC compatibles;
   - the StackBudget per-call row;
   - the unreserved-call-frame threshold;
   - `helpers.tsv`'s v7e-m libgcc rows;
   - the reserves' hand-traced paths.

   The board objects are expected to confirm that 0022's intrinsics and
   wrapper lowering carry over, since pointers stay 32 bits.

## Acceptance

- The board lane at `DEMOS=DEMO1 TICS=500` passes on the M7, with the
  firmware's session id checked, during the work. DEMO1 to DEMO3 run once at
  the end of the development.
- **Stack overflow.** A planted overflow on the M7 is caught at run time by
  the MPU guard, and the lane reports it by name.
- **Profile.** The board profile and the PC sampler run on the M7, and the
  tic median is reported beside the M33's figures.

## Consequences

- The board lane builds two images, and the M33 launcher becomes part of
  what the session id covers.
- The M33 lane's tools stay. The M33 target remains buildable for the
  application suites that use it.
