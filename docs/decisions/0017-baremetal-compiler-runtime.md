# 0017: The compiler runtime of the bare-metal Cortex-M33 lane

- Date: 2026-10-19
- Status: Accepted (owner, 2026-10-19)
- Scope: what supplies the compiler runtime (`__aeabi_ldivmod` and the like)
  when a freestanding kernel is linked with no RTOS, in `tests/freestanding/bm040`.
  The Zephyr lanes are unchanged.

## Context

The `bm040` lane runs E040's kernel on QEMU's `mps2-an521` Cortex-M33 without
Zephyr, to show directly that `kern.o` depends on no RTOS. The kernel needs a
few compiler runtime routines, i64 division above all (decision D-1 of the
freestanding design). Under Zephyr they come from the SDK's GCC `libgcc`. With
no RTOS, the lane has to name its own, and the final image is checked to hold
nothing but the lane's driver, `kern.o` and that runtime. The LLVM 23.1.1
release ships no compiler-rt for bare-metal Arm.

## Options

- **compiler-rt's builtins, built here** from the LLVM 23.1.1 release sources
  with the LLVM 23.1.1 clang the kernel is compiled with. One compiler version
  end to end, no GCC runtime, and the library is only the builtins, with no C
  library. It is a local build that has to be repeated when the LLVM pin moves,
  and once per target configuration.
- **Arm Toolchain for Embedded**: a prebuilt LLVM distribution with
  compiler-rt and picolibc for many Arm variants. No build, but a second LLVM
  version beside the pinned one, a larger download, and a C library the lane
  must take care not to link.
- **GNU `libgcc`** from the Zephyr SDK, as the Zephyr lanes link it. Already
  installed, but it is GCC's runtime under a clang-built image, and it ties a
  lane meant to be Zephyr-independent to the Zephyr SDK.

## Decision

Build compiler-rt's builtins from the `llvmorg-23.1.1` sources for
`thumbv8m.main-none-eabi`, `-mcpu=cortex-m33+nodsp -mfloat-abi=soft`, user-local
under `~/toolchains/compiler-rt-23.1.1`
(`docs/toolchains/compiler-rt-23.1.1/INSTALLATION-RECORD.md`). The lane takes the
archive as `BAREMETAL_BUILTINS` and stops with exit 2 when it is not set or not
a file.

## Validation

`tests/freestanding/bm040` on Debian: every case runs to `END`, the seven
trapping cases trap with their codes, the panic image stops in its loop, both
images have no undefined symbol, and every input and every foreign symbol of
the images is the driver, `kern.o` or a member of this archive, with a control
image each of those checks refuses. Its rows equal `e040`'s Zephyr run of the
byte-identical `kern.o`.

## Consequences

- The archive is rebuilt when the LLVM pin moves; its record names the source
  digest and the configure arguments.
- Only Cortex-M33 (soft float, no DSP) is built. Another bare-metal target
  needs its own build of the same sources.
- macOS has no record yet.
