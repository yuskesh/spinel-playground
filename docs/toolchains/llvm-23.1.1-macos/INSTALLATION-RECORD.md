# LLVM 23.1.1 installation record

Installed on 2026-09-10 for macOS arm64.

- Prefix: `$HOME/.local/opt/llvm-23.1.1`
- Alias: `$HOME/.local/opt/llvm-23` -> `llvm-23.1.1`
- Release: https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.1
- Archive: `LLVM-23.1.1-macOS-ARM64.tar.zst`
- SHA-256: `2c4a0fdd1ec6a32d4fd57ff32aa714ec8b3c71bf02a24ec38608a4f23f8aca89`
- LLVM commit: `6dfe1677ab8dffbc6ec13d53a1e0215d75147689`
- Verification: archive SHA-256 matched the release asset digest; GitHub
  attestation verification exited 0 with repository `llvm/llvm-project` and
  signer workflow `llvm/llvm-project/.github/workflows/release-binaries.yml`.
  The verified SLSA statement identifies the `llvmorg-23.1.1` tag.

## Local SDK configuration

The unconfigured official Clang could not find `stdio.h`. Added only
`bin/arm64-apple-darwin25.6.0.cfg`, selecting this existing Xcode SDK:

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`

The configuration uses `-isysroot` and is loaded for the native target by both
Clang drivers. A BPF-target version query confirmed that the native configuration
is not loaded for that target. If Xcode is moved or the host target triple
changes after an OS upgrade, regenerate the config from `xcrun --show-sdk-path`
and this Clang's `-dumpmachine`. No release binaries were modified.

## Verification

- clang, clang++, opt, llc, llvm-config, mlir-opt, mlir-translate, ld.lld and
  wasm-ld all report 23.1.1.
- C compile, link and execution: output `42`, exit 0.
- MLIR arith/func lowering, LLVM IR translation, Clang linking to a C harness
  and native execution: output `42`, exit 0.
- A CMake C++ application linked to MLIRIR, constructed an MLIRContext, and
  executed: output `42`, exit 0. Its RTTI setting follows LLVM_ENABLE_RTTI.
- Header and CMake packages for LLVM and MLIR are present.
- Homebrew LLVM 22.1.8 and the system Apple Clang were retained. No shell startup
  files, global PATH, Homebrew links or project configuration were modified.
- These are installation checks, not Spinel's acceptance or regression suite.

Verification logs and smoke inputs were retained locally; they are not repository
build dependencies. This document records the completed installation checks.

## Use

```sh
export LLVM_PREFIX="$HOME/.local/opt/llvm-23.1.1"
"$LLVM_PREFIX/bin/clang" --version
```

Pass LLVM_PREFIX to project build scripts that support it. For CMake, select
CMAKE_C_COMPILER, CMAKE_CXX_COMPILER, LLVM_DIR and MLIR_DIR from this prefix.

This prefix is the only C toolchain selected for this repository on macOS.
Apple Clang is not used for any build or test artifact; see the toolchain
paragraph in `docs/building.md`.
