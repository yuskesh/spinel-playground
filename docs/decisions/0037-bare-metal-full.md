# 0037: Full on a Cortex-M33 with no RTOS

- Date: 2026-11-12
- Status: Accepted by the owner on 2026-11-12 (the plan: picolibc built with
  LLVM 23.1.1, QEMU's mps2-an521 first and the FRDM-MCXN947 after it, and
  this record).
- Scope: `tools/bare-full`, `tests/bare-full`. Stages 1 to 3 run on QEMU's
  mps2-an521; stage 4 ran the same programs once on the FRDM-MCXN947 board,
  and stage 5 on a Raspberry Pi Pico (RP2040, a Cortex-M0+).

## Context

Full is a Spinel program with the hosted runtime and its collector, as opposed
to core, which allocates nothing ([architecture](../architecture.md)). Full has
run on a Cortex-M33 under Zephyr since decision
[0032](0032-neutron-npu-route.md) (`tools/npu`, the FRDM-MCXN947): Zephyr
supplied the C library, the console, the clock and the static constructors.
Core has run with no RTOS since decision
[0017](0017-baremetal-compiler-runtime.md) (`bm040`). Full with no RTOS had
not been tried: the cell "bare-metal Cortex-M33 / full" was empty.

Without an RTOS, three things the runtime needs come from nowhere: a C library,
the start-up that runs constructors, and the few POSIX calls the runtime makes
(`write`, `clock_gettime`, `getenv` and the ones it can do without).

## Options

1. **Zephyr's C library, taken out of Zephyr.** `tools/npu`'s host selects
   picolibc (`CONFIG_PICOLIBC`), built inside a Zephyr build with Zephyr's
   toolchain and configuration. Taking it out ties this route to a Zephyr
   build and its toolchain while not using Zephyr.
2. **picolibc built with LLVM 23.1.1.** The same library the Zephyr route uses,
   built with the compiler that builds everything else, configured for this
   use, pinned and recorded like compiler-rt's builtins (0017).
3. **newlib from Arm's GNU toolchain.** Larger, built by GCC, and its locking
   and reentrancy hooks need more stubs.

## Decision

Option 2. picolibc 1.8.12, built with the official LLVM 23.1.1 and recorded
in [its installation record](../toolchains/picolibc-1.8.12/INSTALLATION-RECORD.md),
taken as `BAREMETAL_PICOLIBC`. compiler-rt's builtins are 0017's, as
`BAREMETAL_BUILTINS`.

- **The same runtime as 0032.** `tools/bare-full/spinel-bare-full` compiles the
  pinned runtime's members with `tools/npu`'s defines, header stand-ins and
  forced header, read from there and not copied. No vendor change.
- **The slab is off, the first collection at 16 KB.** The slab reserves a
  4 MB arena (`SP_SLAB_ARENA`), the whole RAM of mps2-an521; `getenv` answers
  `SPINEL_GC_SLAB=0` and `SPINEL_GC_THRESHOLD_KB=16`, as `tools/npu`'s host does.
- **The platform is small and named.** `tools/bare-full/platform/common` has the
  start-up (copy `.data`, clear `.bss`, run `.init_array`, call the program),
  `_exit`, the fault handler and the POSIX layer: `write` to the UART,
  `clock_gettime` from SysTick, and `open`, `stat`, `lseek` and the context calls
  failing with `ENOSYS`. A board is a directory with its console, clock and
  linker script: `platform/an521` and `platform/frdm-mcxn947` (since
  2026-11-23 a chip family, `chip/<family>/`, and a board value file,
  `board/<name>.yaml`; see the layout note at the end). The reset
  entry runs before C, as bm040-frdm's does (MSPLIM, MSP, VTOR), and makes
  one register write the board names before the stack is used: on the MCX
  N947, the clocks of the RAM blocks the stack and heap are in.
- **The FRDM-MCXN947 board.** Its console is bm040-frdm's LPUART code. Its
  RAM is the 320 KB Zephyr gives CPU0 (0x30000000, RAMA to RAMF) rather than
  bm040-frdm's 32 KB of RAMA, which the runtime's `.bss` alone outgrows; the
  stack is 32 KB. The core clock is what the boot ROM leaves: the board reads
  it from SCG and SYSCON at start and prints the registers on a
  `BAREFULL\tCLOCK` line, so the clock is observed, not assumed.
- **Constructors run.** The runtime installs its `inspect` hooks from static
  constructors. The linker script keeps `.init_array` and the start-up calls
  `__libc_init_array`; without them every `inspect` printed `{}`.
- **The heap is what the linker leaves.** `__heap_start` follows `.bss`,
  `__heap_end` is the stack's bottom, or a size given with `--heap-kb`.
  Running out raises the runtime's out-of-memory error.
- **The console's protocol.** The start-up prints `BAREFULL\tBEGIN`, and `_exit`
  prints `BAREFULL\tGC\t<collections>` and `BAREFULL\tEXIT\t<status>`; a fault
  prints `BAREFULL\tFATAL\tfault`. A board may print lines of its own, also
  starting `BAREFULL\t`, right after `BEGIN`. Every other line is the
  program's output.

## Limits

- Integer is 32 bits on this target (`sp_int` is `intptr_t`): a result past
  `2**31 - 1` raises `RangeError: integer overflow in <operator>`.
  Decision [0019](0019-target-integer-width.md) sets integer widths on 32-bit
  targets; it is not changed here.
- No files, processes, signals, threads or `Fiber`: the calls fail with `ENOSYS`.
  `getenv` knows only the two settings above.
- Only what the platform defines links. When the program reaches a call to
  an OS function neither picolibc nor `posix.c` defines, the link stops with
  `undefined symbol`, not the run; a part in the image whose call is not
  reached does not stop it. Counted on the Cortex-M33 runtime archive with
  `llvm-nm -u`: of the 235 functions it needs from outside, picolibc defines
  119, compiler-rt's builtins 20 and `posix.c` 19; 77 (files and
  directories, sockets, processes, `nanosleep`, `poll`, `select`, `pause`,
  `crypt`, `getentropy`, `__atomic_fetch_add_8`) are defined by none. Tried once on mps2-an521 after stage
  5: `Marshal` stops (`sp_io`'s socket write and `sp_cold`'s sleep need
  `send`, `getsockopt`, `fcntl`, `poll` and `nanosleep`), `String#crypt`
  stops (`crypt(3)`), and `Digest::MD5` and `Digest::SHA256` link and print
  the published digests of "abc".
- One program per image; `_exit` stops the core in a loop.
- Measured with the programs in `tests/bare-full/programs` only.
- The board runs are by hand, once each: there is no board lane in
  `tests/bare-full`, and the suite builds for the Cortex-M33 only. A
  power-on boot, as opposed to the probe's reset, was not tried on the FRDM
  board.
- On the RP2040 the program runs on core 0 alone, and the `__atomic_*`
  calls are atomic only there (stage 5).

## Evidence

`sh tests/bare-full/run.sh` on Debian 13, 2026-11-12: 18 passed, 0 failed,
13 s. Three programs print their hand-written expected output under QEMU
mps2-an521 and exit 0; `gc.rb` collected 43 times. `oom.rb` with a 64 KB heap
stops with `unhandled exception: out of memory` and exit 1. Every link map's
inputs are the program's objects, the runtime, picolibc and the builtins, and
no loaded image names the checkout. The controls (a planted wrong expectation,
the input check without libc.a, a planted path) fail as they should.

Image sizes on mps2-an521 (`llvm-size`, at 1ef7ac58): `basics.rb` 252,960 B of text, 1,180 B of data,
45,440 B of bss; `gc.rb` 208,596 / 1,100 / 70,848. The heap that leaves for
`gc.rb`, the RAM between `.bss` and the stack, is 4,056,832 B; that is room,
not use. Capped with `--heap-kb`, `gc.rb` prints its expected output with
64 KB and runs out of memory with 48 KB (after the same 43 collections), so it
needs between the two. This was measured once by hand, not by the suite.

### The FRDM-MCXN947 board, 2026-11-12

Built with `--board frdm-mcxn947` on Debian 13 and run once by hand on the
board, with no Zephyr and nothing of NXP's SDK in the image. Each flash image
was written at 0x10000000 with LinkServer the way `tests/freestanding/frdm-host.sh`
writes bm040-frdm's (exit 0, "Finished writing Flash successfully"), with its
sha256 checked after the copy, and the console was read from a probe reset.

| Program | Image (text / data / bss) | Console |
|---|---|---|
| `basics.rb` | 253,556 / 1,180 / 45,440 B | its `.out` exactly, `GC 0`, `EXIT 0` |
| `float.rb` | 195,508 / 772 / 33,328 B | its `.out` exactly, `GC 0`, `EXIT 0` |
| `gc.rb` | 209,200 / 1,100 / 70,848 B | its `.out` exactly, `GC 43`, `EXIT 0` |
| `oom.rb`, `--heap-kb 64` | 177,784 / 772 / 43,816 B | `unhandled exception: out of memory`, `GC 3`, `EXIT 1` |

`gc.rb`'s heap on the board is 222,976 B, and it collected the same 43
times as on QEMU. The clock line was the same in all four:
`SCG_CSR=0x03000000` (the system clock from FIRC), `FIRCCFG=0x00000000`
(48 MHz), `AHBCLKDIV=0x00000000` (divided by 1): 48 MHz. `AHBCLKCTRL0` read
`0x000047ff` after the reset entry had set bits 2 to 8, so what the boot ROM
left in those bits is not known.

### The Raspberry Pi Pico (RP2040), 2026-11-12

Stage 5, on the owner's request of 2026-11-12: the same runtime and programs on
core 0 of the RP2040, a Cortex-M0+ (ARMv6-M), with no SDK in the image.

- **The core.** `spinel-bare-full runtime --cpu m0plus` builds the runtime for
  `thumbv6m-none-eabi`, against picolibc and compiler-rt's builtins built for
  the Cortex-M0+ (each installation record has a section for it). The runtime
  directory names its core, and `build` refuses a runtime made for another
  core than the board's. The reset entry skips `msplim`, which ARMv6-M does
  not have.
- **Atomics.** ARMv6-M has no exclusive loads and stores, so clang calls
  `__atomic_<op>_<size>`, which neither picolibc nor the builtins define.
  `platform/common/atomic-v6m.c` defines them with interrupts masked: atomic
  only on one core, which is how the program runs.
- **boot2.** The boot ROM copies the first 256 bytes of flash to SRAM, checks
  a CRC-32 of the first 252 against the last 4 and runs them. `boot2.S` is
  pico-sdk 2.3.1's generic 03h-read boot2 ([provenance](../provenance.md));
  the driver pads it and appends the checksum. The ROM's check, read from its
  own code (the CRC loop at `0x25b4`, called with 252 bytes and a start of
  `0xffffffff`), is CRC-32 with polynomial `0x04c11db7`, most significant bit
  first, from `0xffffffff`, with no final xor. A first build that started
  from 0 was refused by the ROM, which fell back to USB boot.
- **Clock and console.** The board starts the 12 MHz crystal oscillator and
  runs clk_ref, clk_sys and clk_peri from it, so the console's divisor is
  exact for a known rate (IBRD 6, FBRD 33: about 115,108 baud). The console is
  UART0 on GP0 and GP1, 115200 8N1, and a `BAREFULL\tCLOCK` line prints
  `CLK_REF_SELECTED`, read after the switch.
- **RAM.** 264 KB at `0x20000000`, the stack 32 KB at its top.

Each image was written with OpenOCD 0.12.0 through a second Pico running
debugprobe v2.3.1 (`debugprobe_on_pico`, CMSIS-DAP over SWD; `program ... verify
reset`, "Verified OK"), and its console read through the probe's UART bridge
from that reset. Built on Debian 13 with the sources of this stage.

| Program | Image (text / data / bss) | Console |
|---|---|---|
| `basics.rb` | 249,452 / 1,180 / 45,448 B | its `.out` exactly, `GC 0`, `EXIT 0` |
| `float.rb` | 193,392 / 772 / 33,336 B | its `.out` exactly, `GC 0`, `EXIT 0` |
| `gc.rb` | 204,856 / 1,100 / 70,848 B | its `.out` exactly, `GC 43`, `EXIT 0` |
| `oom.rb`, `--heap-kb 64` | 174,904 / 772 / 43,824 B | `unhandled exception: out of memory`, `GC 3`, `EXIT 1` |

Text includes boot2's 256 bytes. `gc.rb`'s heap on the Pico is 165,632 B, and
it collected the same 43 times as on QEMU and the FRDM board. The clock line
was `CLK_REF_SELECTED=0x00000004` (clk_ref from the crystal) in all four.

## Later fixes, 2026-11-23

Two defects reported from a Pico driver built on `--board rp2040-pico`, and
one found while checking them. The limits above are kept as written at the
time; these change them.

- **`<<` on a boxed value did not link.** `sp_poly_shl` keeps the runtime's
  IO and `Queue` arms reachable, so even an Integer shift on a boxed value
  needed `send`, `getsockopt`, `fcntl`, `poll` and `nanosleep`. `posix.c`
  now defines the first four, failing with `ENOSYS`, and `nanosleep`, which
  waits on the clock. `Marshal` and `Array#index` on such a value link and
  run as a result. `tests/bare-full/programs/poly.rb` checks the shift and a
  250 ms `sleep`.
- **The Pico's clock followed clk_sys.** `clock_gettime` counted SysTick at
  the 12 MHz `bf_core_hz` gives, so a program that raised clk_sys ran its
  clock fast (10.4 times at 125 MHz, measured by the reporter). A board may
  now define `bf_board_us`, a microsecond count that does not follow the core
  clock; `clock_gettime` then returns it instead of SysTick. The Pico's is
  the RP2040 TIMER, ticked once per microsecond by the watchdog's tick
  generator from clk_ref (the crystal). The TIMER is taken out of reset at
  start-up and its count is never reset.
- **The SysTick clock started one wrap ahead.** The first read set the
  counter to 0 and read that 0 as a whole wrap elapsed, so a later read could
  be earlier than the first (a 250 ms `sleep` measured -420 ms on
  mps2-an521). A read of 0 is now taken again.
- **The Pico's start-up resets follow pico-sdk's runtime_init** (asked for
  by the same driver's author, so that code written against the SDK's
  start-up state runs unchanged). Every block but the flash's pads and IO
  bank, the PLLs, USBCTRL and SYSCFG is put into reset; before the clocks,
  every block but those on clk_peri, clk_adc, clk_rtc and clk_usb is taken
  out of it (DMA, PIO0/1, PWM, I2C0/1, TIMER, BUSCTRL, JTAG, SYSINFO, TBMAN
  among them); after the clocks, SPI0/1 and UART0/1, on clk_peri. ADC and RTC
  stay in reset, since their clocks are not started here; USBCTRL, never put
  into reset, stays as it was (out of reset after the boot ROM). On the
  Pico, RESET read 0x8001 (ADC and RTC) after start-up, run by the
  driver's author. Until
  now only IO_BANK0, PADS_BANK0, UART0 and TIMER left reset. The TIMER's
  count now starts at 0 at each start-up.
- **Layout: chip family and board values (2026-11-23).** `platform/<board>/`
  is divided into `chip/<family>/` (the code, the link script, the core's
  name and, for the RP2040, `boot2/generic_03h.S`, which this record calls
  `boot2.S`) and `board/<name>.yaml` (values only: the crystal, the console's
  instance and pins, the flash, and the policy values, which are the stack
  size and the collector's two settings that `posix.c` returned as
  literals). The driver writes the values into a generated header that the
  base, the chip family, boot2 and the link script are compiled with; no
  value is a linker `--defsym`. The link order is now the same on every
  board, the base before the chip family; this moved the four board
  functions in the an521 image (1,140 of 192,756 bytes differ for a small
  program, the same functions at other addresses). The frdm-mcxn947 and
  rp2040-pico flash images did not change by a byte through the whole
  change, measured with a small program on both and with a 662,852-byte
  program on the RP2040. Each link script also defines `__image_end`, one
  past the last byte of the image in flash. `tools/bare-full/README.md` has
  the layout.
- **The build lives in spinel-modular (2026-11-23).** `tools/bare-full` and
  `tests/bare-full`'s programs were moved to spinel-modular and removed from
  this repository, which pins that repository as the submodule
  `vendor/spinel-modular`. `tests/bare-full/run.sh` here runs its lane with this
  repository's Spinel, and `tests/zephyr-full` reads its programs from the
  submodule. The paths this record names are now under
  `vendor/spinel-modular/`.
- **The RP2040 family is a port outside the build's repository
  (2026-11-23).** At the spinel-modular pin `f36772c` the bare-metal build
  finds chip families and boards in its own tree and in the port directories
  `BAREMETAL_PORT_PATH` names. Its tree holds `an521` and `frdm-mcxn947`; the
  RP2040 family and the `rp2040-pico` board this record describes are no
  longer in it. No lane of this repository builds for the Pico.
