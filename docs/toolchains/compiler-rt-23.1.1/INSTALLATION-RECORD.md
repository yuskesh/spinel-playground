# compiler-rt 23.1.1 builtins (Cortex-M33) — installation record

The `bm040` freestanding lane links E040's kernel with no RTOS, so nothing
supplies the compiler runtime the kernel needs (`__aeabi_ldivmod`, for i64
division). This is that runtime: compiler-rt's `builtins` only, built for
Cortex-M33 from the official LLVM 23.1.1 sources with the official LLVM 23.1.1
clang. It is a third-party dependency, built user-local and pinned. Nothing
shared is changed, and nothing in this repository names its location: the lane
takes it as `BAREMETAL_BUILTINS`. Decision 0017 records why this runtime rather
than another.

## The pin

| | |
|---|---|
| version | compiler-rt from the `llvmorg-23.1.1` release |
| source | <https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.1/llvm-project-23.1.1.src.tar.xz> |
| source sha256 | `ebe9be46fe8756d58c5b198ffad0fa2a766257add81a4dc52179bfacc7888ee6` (179,168,672 bytes) |
| signature | `llvm-project-23.1.1.src.tar.xz.sig`, beside it on the release |
| built with | the official LLVM 23.1.1 (`docs/building.md`) |
| target | `thumbv8m.main-none-eabi`, `-mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb` |

The release publishes the whole `llvm-project` source as one archive; there is
no separate compiler-rt archive for 23.1.1. The sha256 above equals the digest
GitHub's release API records for the asset. The signature verified as a good
signature by key `D574BD5D1D0E98895E3BF90044F2485E45D59042` (Tobias Hieta),
imported from <https://releases.llvm.org/release-keys.asc> (sha256
`f38bd19b7f2d22cafa755841e6ce9375b9a2e6d41f7b974e4953d6b084839001`) into a
temporary keyring; the user's keyring was not touched. GnuPG reports the key as
not certified by a trusted signature, which is the usual state for a key
fetched this way.

## Debian 13 (x86_64), 2026-10-19

```sh
D=~/toolchains/compiler-rt-23.1.1
mkdir -p $D/dl && cd $D/dl
curl -fsSLO https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.1/llvm-project-23.1.1.src.tar.xz
curl -fsSLO https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.1/llvm-project-23.1.1.src.tar.xz.sig
cd $D
tar -xJf dl/llvm-project-23.1.1.src.tar.xz llvm-project-23.1.1.src/compiler-rt \
    llvm-project-23.1.1.src/cmake llvm-project-23.1.1.src/llvm/cmake \
    llvm-project-23.1.1.src/llvm/utils/llvm-lit
mv llvm-project-23.1.1.src src
L=/opt/llvm-23.1.1/bin
F="-mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -ffile-prefix-map=$D/src=compiler-rt-23.1.1"
T=thumbv8m.main-none-eabi
cmake -G Ninja -S $D/src/compiler-rt -B $D/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$L/clang -DCMAKE_CXX_COMPILER=$L/clang++ -DCMAKE_ASM_COMPILER=$L/clang \
  -DCMAKE_AR=$L/llvm-ar -DCMAKE_NM=$L/llvm-nm -DCMAKE_RANLIB=$L/llvm-ranlib \
  -DCMAKE_C_COMPILER_TARGET=$T -DCMAKE_CXX_COMPILER_TARGET=$T -DCMAKE_ASM_COMPILER_TARGET=$T \
  -DCMAKE_C_FLAGS="$F" -DCMAKE_CXX_FLAGS="$F" -DCMAKE_ASM_FLAGS="$F" \
  -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCOMPILER_RT_BAREMETAL_BUILD=ON -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF \
  -DCOMPILER_RT_BUILD_BUILTINS=ON -DCOMPILER_RT_BUILD_CRT=OFF -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF \
  -DLLVM_CMAKE_DIR=/opt/llvm-23.1.1/lib/cmake/llvm
ninja -C $D/build -j4
export BAREMETAL_BUILTINS=$D/build/lib/generic/libclang_rt.builtins-armv8m.main.a
```

The same configure and build are in `~/toolchains/compiler-rt-23.1.1/build-builtins.sh`.

- The build took 9 s wall on 4 jobs: 176 steps, 0 errors. CMake detected
  `armv8m.main` as the only builtins architecture.
- The archive, `libclang_rt.builtins-armv8m.main.a`: 152,170 bytes,
  175 members, sha256
  `6ea8324b64975c42b6097188f7657d2227d0b1c7989507aeb869709836f386fc`.
- `-ffile-prefix-map` makes the archive independent of where the sources
  are. Twelve members (`absvdi2`, `addvsi3`, `mulvdi3` and others) keep
  `__FILE__` as a string through `compilerrt_abort()`; without the flag that
  was the source's absolute path, and the same build gave different archives
  on Debian (`ce967677...`) and on the Mac (`1c3ff144...`). With it, the string
  is `compiler-rt-23.1.1/compiler-rt/lib/builtins/<file>`, and `strings` finds no
  `/home` or `toolchains` in the archive. Member times and uids are 0 either
  way.
- Its objects carry `Tag_CPU_name` `cortex-m33` and `Tag_CPU_arch` v8-M
  Mainline, and no `Tag_FP_arch`: no floating-point hardware is assumed.
- `COMPILER_RT_BUILTINS_ENABLE_PIC=OFF`: by default the builtins are compiled
  `-fPIC`, which a static image does not need. A first build without the flag
  was discarded.
- CMake warns that `LLVMTestingSupport` is not among the LLVM release's
  libraries. Only compiler-rt's tests use it, and they are not built.
- The user CMake package registry (`~/.cmake/packages`) was compared before and
  after: unchanged.
- No `sudo`, and nothing installed outside `~/toolchains/compiler-rt-23.1.1`.

## macOS (arm64), 2026-10-19

macOS 27.0.1, CMake 4.2.1, Ninja 1.13.2. The download, the extraction and the
configure are the Debian ones, with the LLVM release at
`~/.local/opt/llvm-23.1.1`:

```sh
L=$HOME/.local/opt/llvm-23.1.1/bin
# ... the cmake line above, ending in
  -DLLVM_CMAKE_DIR=$HOME/.local/opt/llvm-23.1.1/lib/cmake/llvm
ninja -C $D/build -j4
export BAREMETAL_BUILTINS=$D/build/lib/generic/libclang_rt.builtins-armv8m.main.a
```

The same configure and build are in `~/toolchains/compiler-rt-23.1.1/build-builtins.sh`.

- The tarball's sha256 and size and the release keys' sha256 are the ones
  above. The signature verified with the same key and the same uncertified-key
  warning, in a temporary keyring; the user's keyring was not touched.
- The build took 9 s wall on 4 jobs: 176 steps, 0 errors, `armv8m.main` the
  only builtins architecture, and the same `LLVMTestingSupport` warning.
- The archive is byte-identical to Debian's: 152,170 bytes, 175 members, sha256
  `6ea8324b64975c42b6097188f7657d2227d0b1c7989507aeb869709836f386fc`.
  `strings` finds no `/Users` or `toolchains` in it. The same tags: `cortex-m33`,
  v8-M Mainline, no `Tag_FP_arch`.
- `~/.cmake/packages` was compared before and after by the sha256 of each of
  its 16 files: unchanged.
- No `sudo`, and nothing installed outside `~/toolchains/compiler-rt-23.1.1`.

## Cortex-M0+ (RP2040), Debian 13, 2026-11-12

The configure and build above, into `$D/build-m0plus`, with
`F="-mcpu=cortex-m0plus -mfloat-abi=soft -mthumb -ffile-prefix-map=$D/src=compiler-rt-23.1.1"`
and `T=thumbv6m-none-eabi`. CMake detected `armv6m` as the only builtins
architecture; 150 steps, 9 s wall.

- `BAREMETAL_BUILTINS=$D/build-m0plus/lib/generic/libclang_rt.builtins-armv6m.a`,
  for spinel-modular's `tools/bare-full` on a Cortex-M0+ board.
- The archive: 157,860 bytes, 149 members, sha256
  `019b22f6d5931406d07b508f121c65d2f7f177e3a7da1f897f06e1df0988537a`;
  `strings` finds no `/home` or `toolchains` in it.
- It has no `__atomic_*` functions; spinel-modular's `tools/bare-full` supplies them for
  ARMv6-M (`platform/common/atomic-v6m.c`).
