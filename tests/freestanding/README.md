# Freestanding kernels on targets

These lanes build `freestanding_def` kernels for targets other than the host and
run them: QEMU Cortex-M33 (`mps2/an521`), QEMU RISC-V 32 (`qemu_riscv32`), and
wasm32 under node and workerd. They are ported from spinel-llvm `463d49dd`, where
they were experiments E040, E063, E077, E081 and E083. The compiler side was
already here, byte-identical to spinel-llvm's: `spinel-fs-emit`, `spinel-fs-check`
and `lib/Freestanding`. Since then the object is written by `spinel-fs-codegen`
where spinel-llvm ran clang; `spinel-fs-emit` and `spinel-fs-grad` run it from
their own `bin` directory. The port adds the target profiles, the platform ledger,
and these lanes. The gradient lanes (E079, E083's target runs, E084) came with
the differentiation tools: `spinel-fs-grad` and Enzyme
([tools/grad](../../tools/grad/README.md)). `bm040` is written here: E040's kernel on
the same Cortex-M33 machine with no RTOS, so that what `kern.o` needs is visible
in the final image. [Provenance](../../docs/provenance.md) records each import.

## What runs where

| Lane | Capability | Cortex-M33 | RV32 | wasm32 |
|---|---|---|---|---|
| `e040` | the first kernel: integer boundaries, traps, the panic platform | QEMU; FRDM-MCXN947 board (`run_frdm.sh`) | QEMU | - |
| `e063` | the wasm32 profile, with E040's kernel unchanged | - | - | node, workerd |
| `e077` | Float values and pointer+length buffers across the boundary | QEMU | QEMU | node |
| `e081` | platform externs declared by the profile (uptime, sleep, print, GPIO) | QEMU | QEMU | node |
| `e079` | a kernel and its Enzyme gradient in one object; SGD on the edge, the weights shipped to a device | QEMU | QEMU | node |
| `e083` | the optimiser loop inside the kernel, calling the adjoint as a buffer platform extern | QEMU | QEMU | node |
| `e084` | Newton-CG inside the kernel, with the Hessian-vector product as a second extern | QEMU | QEMU | node |
| `bm040` | E040's kernel with no RTOS: the lane's own startup, UART console and setjmp, and compiler-rt's builtins | QEMU, no Zephyr | - | - |
| `bm040-frdm` | `bm040` on the MCX N947: its own startup, memory map and LPUART console, bm040's driver, setjmp and builtins | FRDM-MCXN947 board, no Zephyr or SDK | - | - |
| `profiles` | every shipped profile is read; each platform-first one emits | object | object | object |

The checks the lanes run are the compiler's own refusals and accept/reject
tests, plus properties of the runs themselves:

- emission for each target, through the emitter's undefined-symbol gate;
- `.mlir` determinism;
- the ABI table (`spinel-fs-check --abi`);
- the export map;
- the undef-gate and extern-check control tables;
- the reject tables and their controls;
- on each target, every case running to its `END` marker without a `FATAL` line;
- the trap probes, and the panic image stopping at the trap;
- the device property rows (uptime, sleep, GPIO, print);
- the wasm import shape;
- the strict link without builtins being refused;
- the workerd results agreeing with node's for the same module;
- in the gradient lanes, which also run a host leg: every leg's stream
  byte-identical to the host leg's (one generator, fast-math off), the loop and
  trap rows, the extern surface, G5 on the kernel and the adjoint, and the
  Hessian's symmetry from the printed bits;
- in `bm040`, which is written here rather than ported: the trap code of each
  of E040's seven trapping cases, no undefined symbol in either image, and that
  the images hold nothing but the driver, `kern.o` and members of the builtins
  archive, checked by input and by symbol, with a control image each check has
  to refuse; and that its rows and its `kern.o` equal `e040`'s Zephyr run of
  the same kernel (one compiler, two platforms of this repository);
- in `e040/run_frdm.sh`, also written here: the same `kern.o`, linked by Zephyr
  for `frdm_mcxn947/mcxn947/cpu0` and run on the board, runs every case to
  `END`, the panic image stops at its trap, and both consoles equal the QEMU
  run's line for line, `BEGIN` aside; each image arrives on the host intact,
  is written, and is the one that printed (its `BEGIN` names the board);
- in `bm040-frdm`, also written here: bm040's checks on the board -- every
  case to `END`, the seven trap codes, the panic image stopping at its trap,
  no undefined symbol, and nothing in either image but the driver, `kern.o`
  and builtins members, each with its control -- with the panic core's halted
  PC on the trap hook's final self-branch where bm040 asks QEMU whether it is
  still running; `kern.o` byte-identical to bm040's and every row equal to
  bm040's QEMU run; and the build refusing a driver that is not bm040's.

## Running

```sh
export LLVM_PREFIX=/path/to/llvm-23.1.1
export ENZYME=/path/to/LLVMEnzyme-23.so   # docs/toolchains/enzyme-0.0.290
export ZEPHYR_BASE=/path/to/zephyr-v4.4.2/zephyr
export ZEPHYR_SDK_INSTALL_DIR=/path/to/zephyr-sdk-1.0.1
export WASI_BUILTINS=/path/to/wasm32-unknown-wasip1/libclang_rt.builtins.a
export WASI_SYSROOT=/path/to/wasi-sysroot
export BAREMETAL_BUILTINS=/path/to/libclang_rt.builtins-armv8m.main.a  # docs/toolchains/compiler-rt-23.1.1
export QEMU_ARM=/path/to/qemu-system-arm  # bm040; default: on PATH, with mps2-an521
# optional: FRDM_HOST and the rest for the FRDM-MCXN947 board (see below)
# west (from the Zephyr venv), node and wrangler on PATH
tools/contract/build.sh                   # spinel-typedump
tools/mlir/native/build.sh
# e084's host leg runs tools/grad/spinel-gradgen, which also needs these
tools/llvm/build_rt_bc.sh                 # the runtime bitcode spinel-rtcheck links
cmake -G Ninja -S tools/llvm/passes -B tools/llvm/passes/build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=$LLVM_PREFIX/bin/clang -DCMAKE_CXX_COMPILER=$LLVM_PREFIX/bin/clang++
ninja -C tools/llvm/passes/build          # libSpinelGCRoots.so
sh tests/freestanding/run.sh
```

These are the dependencies [tools/grad](../../tools/grad/README.md) lists. A
lane that needs one of them and finds it missing names it and exits 2.

Each lane can also run on its own, in the order `run.sh` uses. For example,
`bash tests/freestanding/e081/build_all.sh`, then `run_extern_check.sh`,
`run_gates.sh` and `run_reject.sh`. Output goes under `$FS_WORK`, which defaults
to `$TMPDIR/spinel-freestanding`. Nothing is written into the source tree.
Each lane writes under `$FS_WORK/<lane>` and takes no other location from the
environment; in particular an exported `OUT` or `W` is ignored. The scripts that
start from an empty directory (`build_all.sh`, `e063/build.sh`, and the
`reject`, `rej` and `host` directories under the lane) remove it only if
`tests/freestanding/workdir.sh` created it, which leaves a
`.spinel-freestanding-workdir` marker inside, and otherwise stop with exit 2. A
lane directory left by a run before this check has no marker; remove it once.

`ZEPHYR_SDK_INSTALL_DIR` is only a hint to Zephyr's CMake, which falls back to
its own search when the value is wrong. So every `west build` prints the
toolchain Zephyr actually found. Compare that line with the path you meant.

On the Mac that verified this port, these tools were already installed and were
used as they were:

- the official LLVM 23.1.1, which includes `wasm-ld`;
- Zephyr v4.4.2 with SDK 1.0.1, whose own QEMU (`qemu-system-arm` and
  `qemu-system-riscv32`, 10.0.2) the `run` targets use;
- Homebrew's `wasi-runtimes` 22.1.8 for `WASI_BUILTINS`;
- Homebrew's `wasi-libc` for `WASI_SYSROOT`;
- node 24.12.0 and wrangler 4.61.1.

`bm040` ran on the Mac on 2026-10-19 with Homebrew's `qemu-system-arm` 10.0.0 as
`QEMU_ARM` and the compiler-rt builtins built there
(`docs/toolchains/compiler-rt-23.1.1/INSTALLATION-RECORD.md`): 46 passed, 0 failed.

On Debian 13 (x86_64), 2026-09-23, installed user-local under
`~/toolchains` (nothing system-wide):

- the official LLVM 23.1.1, whose `lld` (so `wasm-ld`) is linked against ICU
  70, which Debian 13 does not ship (it has ICU 76): the three `libicu*.so.70`
  were taken from Ubuntu 22.04's `libicu70_70.1-2_amd64.deb` (sha256
  `58a154f6307289813da2276f900498ef536ae7c0522d2cf31a3c3c5cf62dfd9a`) into
  `~/toolchains/icu-70/lib`, which `LD_LIBRARY_PATH` names;
- Zephyr v4.4.2 with SDK 1.0.1, as installed for decision 0014;
- wasi-sdk 34: `wasi-sysroot-34.0.tar.gz` (sha256
  `9d813544eeebe38b7b8f2244ed591de46b6db812c6dd1a257ff9f0d2a905a2be`) for
  `WASI_SYSROOT`, and `libclang_rt-34.0.tar.gz` (sha256
  `eee3e634dcf71aa22b1333391623cf5c9965a637dc428a27b1a858c026c587f1`), whose
  `wasm32-unknown-wasip1/libclang_rt.builtins.a` is `WASI_BUILTINS`;
- node 24.20.0 (Debian's) and wrangler 4.61.1 from npm in its own prefix,
  which brings workerd 2026-01-28;
- for `bm040`, compiler-rt 23.1.1's builtins, built from the release sources
  (docs/toolchains/compiler-rt-23.1.1), and Debian's `qemu-system-arm`
  10.0.13, which `bm040` runs instead of the Zephyr SDK's QEMU.

Measured there: 335 pass and 4 not ported, in 64 s -- the Mac's figures.

The LLVM release ships no wasm32 builtins. The kernels need `__multi3` from
them, and `e063` checks that a link without them is refused.

### The FRDM-MCXN947 board

Two lanes run on the board: `e040/run_frdm.sh`, after `e040`'s `build_all.sh`
and `run_gates.sh`, and `bm040-frdm`, after `bm040`. They need hardware, so
they are the lanes that can be **NOT RUN**: without a prerequisite they say
which is missing and exit 3, and `run.sh` prints the reason and goes on.
`bm040-frdm`'s image checks need no board, so they run and are counted
either way. With `REQUIRE_ALL=1` a lane that could not run is a failure, in
the scripts and in `run.sh`. Both drive the board's host through
`tests/freestanding/frdm-host.sh`.

```sh
export FRDM_HOST=user@host          # ssh destination; unset, the lane is NOT RUN
export FRDM_LINKSERVER=/path/to/LinkServer  # on that host; default /usr/local/LinkServer/LinkServer
export FRDM_TTY=/dev/ttyACM0        # the MCU-Link VCOM on that host (the default)
# FRDM_PROBE ('#1') and FRDM_TIMEOUT (60 s per console) are optional
sh tests/freestanding/e040/run_frdm.sh
bash tests/freestanding/bm040-frdm/build_all.sh   # after bm040
bash tests/freestanding/bm040-frdm/run_gates.sh
bash tests/freestanding/bm040-frdm/run_join.sh
```

What it needs:

- **a Linux host with NXP LinkServer**, which the board's MCU-Link (J17) is
  plugged into with a data cable, and which accepts `ssh` with a key and no
  prompt (`BatchMode`). The console is read there with GNU `stty` and
  `timeout`. Verified with LinkServer 26.3.123 for Linux aarch64 and the
  MCU-Link's CMSIS-DAP firmware 3.172. A charge-only USB cable leaves the host
  seeing nothing, which reads as no probe.
- **not macOS arm64 as that host.** There LinkServer 26.6.137 and 26.9.130
  (macOS 27.0.1) list the MCU-Link and then fail every command with
  `Error: Probe not open`; `west flash -r linkserver` ends in `Flash operation
  exited with code 1`. The lane checks that LinkServer's probe list names the
  device and board, which an unopened probe leaves blank, and reports such a
  host as NOT RUN.
- the board out of ISP mode, and nothing else using the probe.

The images are built on this machine and copied to the host; the
host's files go in one `mktemp -d` directory per run, removed when the run
ends. LinkServer resets the target before it writes, so the image already in
flash boots once; the console is therefore opened after the write, and a reset
on the probe's wire (`probe wiretimedreset`) starts the new image. The run
LinkServer starts after the write can still be printing then, so the wait for
a console's terminator, and the checks, read it from its last `BEGIN` on. For
`e040` the board's Zephyr configuration
leaves `CONFIG_FPU` unset, so its objects use the soft-float ABI, as the
`cortex-m33-zephyr` profile's `kern.o` does; only DSP differs (`+nodsp`), and
the link reports nothing.

`bm040-frdm` takes nothing from Zephyr or NXP's SDK into the image. Its
`src/` holds what is the chip's, each value with its source in a comment:

- **memory**: code at 0x10000000, the 2 MB flash in CPU0's secure alias, and
  RAM in RAMA, the first 32 KB block of SRAM at 0x30000000 (Zephyr's DTS);
- **startup**: the boot ROM takes the initial SP and reset vector from the
  start of flash. The entry masks interrupts, clears MSPLIM, sets MSP and
  points VTOR at its own table before any C runs, because what the ROM leaves
  in them is not documented here. Words 0x20-0x2b of the table are ARMv8-M
  reserved and stay zero, as in Zephyr's image for the board: written by
  LinkServer, an image in that shape boots from a pin reset, with nothing in
  the image-length or image-type words. A power-on boot was not tried;
- **console**: LP_FLEXCOMM4 as an LPUART on P1_8/P1_9, which the board wires
  to the MCU-Link VCOM (UM12018), clocked from FRO_12M through SYSCON, with
  the registers of NXP's device headers as Zephyr's `hal_nxp` ships them;
  115200 baud is OSR 26, SBR 4 (+0.16%).

The driver half of `src/main.c` is bm040's, with only the `BEGIN` line's
platform name changed, and `build_all.sh` stops if it is not. The PC is read
with LinkServer's script language (`probe runscript`: connect, halt, read
r15), which leaves the core halted.

## Oracles: kept as files, not run

Every comparison with another implementation's behaviour stays out of the
runnable path and runs only on the user's instruction:

- the host oracle each lane built from the same Ruby through `bin/spinel`'s C
  back end;
- the joins of every target's values against that build (`compare.py`,
  `e063_gates.rb`, E040's gates join);
- `run_nonreg.sh`;
- the byte comparisons with spinel-llvm's recorded tables (`reject_compare.rb`,
  E063's "E040 regression");
- in the gradient lanes: E079's `model.py`, an independent reimplementation
  (Python, not imported); E083's trajectory compared with E079's stored results;
  E084's `analytic_check.c`, the closed-form Hessian written by hand; and E084's
  `host_mirror.c` comparison of the host pipeline with the freestanding one, with
  its FMA attribution (`unfuse_fmuladd.py`, not imported) and the check that the
  two take the same number of steps.

The original runners are under each lane's `oracle/`. `compare.py` and the other
Python helpers were not imported, because this repository admits no Python, so
the value joins cannot run as they stand. Every expected value in those tables
is relative to the host build (`same` / `diverge`), so none of them was
convertible to an ordinary check.

In place of the joins, each lane checks only that every case ran. That is a
count of printed rows per target, and it says nothing about the values.
The gradient lanes compare each target with this repository's own host leg,
built by the same generator from the same IR; no other implementation is involved.

## Not ported, and why

- **E083's and E084's extern-check rows.** spinel-llvm checked the profile's
  declaration of the adjoint against the C shim its retired `spinel-gradfs`
  wrote. `spinel-fs-grad` builds the shim in IR and writes no C, and
  `spinel-fs-check --extern` needs a C definition. The rows are `NOT-PORTED`.
- **E040 undef rows e05–e07.** They build a host-mode object through
  spinel-llvm's hosted MLIR importer (`spinel-mlirgen -m … --int-overflow raise`),
  which this repository does not have. The runner prints them as `NOT-PORTED`.
- **E077 control e11.** It uses `--types-from emit-types`, spinel-llvm's retired
  Python typing path. The native emitter accepts only `contract`. The row is
  `NOT-PORTED`.
- **Records written by Python.** These are E040's `checkcost.tsv`, E077's
  `position_ambiguity.txt`, and the per-function size tables. They are
  measurements, not checks.
- **E066 and E067 (the gatekeeper and edge-twin examples)**, the capability
  checker `spinel-capcheck` and its E168 goldens. They are separate
  capabilities, and E168's goldens are an oracle.

## Local changes worth knowing

- **Refusal wording.** spinel-llvm wrote the reject tables against its retired
  Python generator. Nine refusal patterns (E081 p1, k1, k3, k4, k6; E083 r3, r4,
  r5, r7) are updated to the native emitter's wording, and each runner's comment
  records the old text. Two of them record defects, not rewordings:
  - E081 k6 is refused as `unsupported: 'gpio_set'`, which no longer says that
    the name collides with a top-level method.
  - E083 r7 is refused for the right kernel under the wrong reason. The emitter
    says "buffer element :f64 is outside the freestanding subset", but the fault
    is a buffer with no `:len`.
- **QEMU is stopped at the console's terminator** in every lane, as spinel-llvm's
  later runners did, rather than after a fixed `timeout 180`.
- **The gradient lanes call `spinel-fs-grad`** (with `--enzyme`) where
  spinel-llvm called its retired `spinel-gradfs`, with the same arguments.
- **Their host leg is this machine's.** spinel-llvm's was macOS arm64. On x86-64
  Linux, each lane uses an `x86_64-host*.yaml` profile: the arm64 one with this
  host's triple and data layout, and with one spelling per symbol (ELF adds no
  underscore).
- **Checks spinel-llvm computed in inline Python** are in Ruby: E084's
  Hessian symmetry and its host Newton gate. The wasm import list is read
  with node, because the LLVM release ships no `obj2yaml`.
