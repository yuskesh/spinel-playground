# macOS arm64 native core validation

> **HISTORICAL. These numbers were measured on 2026-09-11, at commit
> `1435713`, against Xcode's SDK 26.5 and the LLVM 23.1.1 installation of that
> day. They are kept as that run's record and are not a statement of current
> behaviour.** The page is historical because its results are tied to that
> revision and toolchain, not because anything in it was found to be wrong: the
> 43-passed product driver and 23-passed input ledger recorded here reproduce
> at `20e6b79` from a clean checkout.
>
> An earlier note here said this record no longer reproduced and blamed an
> unnamed external change. That was a misreading and is withdrawn. The
> 2026-09-12 runs that disagreed had not exported `LLVM_PREFIX`/`NM` and
> `CLANG`, which macOS requires — the artifact gate refuses to start without a
> symbol reader, and `tests/native-core/ledger.sh` otherwise falls back to a
> Debian clang path — and the `vendor/spinel` they used had been built with
> Apple clang rather than the LLVM 23.1.1 clang `docs/building.md` requires.
> `tests/native-core/run.sh` was also compared against this page's "nine
> fixtures match CRuby", which is the Mach-O probe's line, not that suite's.
> At those revisions, `tests/native-core/run.sh` was ELF-only. Subsequent review
> hardening added Darwin support, and it now passes 18/0 on macOS under the
> documented toolchain.
> `docs/provenance.md` carries the re-measurement, its commands and its
> compiler evidence.
>
> Nothing below has been edited. It is left as it was written so that what was
> claimed, and when, stays readable.

Measured on 2026-09-11. The original stage-by-stage probe used Extended
`9cacfd4` and an independent compiler at `cad0ad14`. The integration validation
below uses the pinned submodule at
`cad0ad148af00b98a3de8a384c18a3cabe15bc1a`, without that checkout override.

## Pinned product validation

A newly initialized `vendor/spinel` was built with LLVM 23.1.1; the contract
reader was rebuilt against it. `tools/mlir/native/build.sh` was then run with
a fresh `BUILD_DIR=build/native-core-final`, producing all four native tools.
The suites selected that directory with `SPINEL_CORE_BUILD`. The commands are
in [Reproducing](reproducing.md); no `SPINEL_SEAM` was set.

- Product driver: 43 passed, 0 failed. The actual Mach-O gate accepted the
  correct object and refused an extra core export, an undefined dependency,
  a data-only export and a failing symbol reader. Failed builds preserve prior
  output; the accepted executable agrees with CRuby and ordinary Spinel.
- Input ledger: 23 passed, 0 failed. Expected paths are canonicalized because
  macOS resolves `/var` through `/private/var`; byte comparison and NUL
  termination are preserved.
- Source eligibility: 50 tests, exit 0.
- Native Mach-O probe: nine fixtures match CRuby, with export/undefined checks,
  a 999 stub-routing control, missing-body link refusal and sentinel refusal.

The product driver uses `shasum -a256`, LLVM nm, and native libraries (`-lm`,
without Linux's `-lcrypt`). It selects the Xcode SDK and records the SDK path
and deployment-target setting. System SDK contents are not snapshotted.
The artifact gate normalizes Mach-O's one leading ABI underscore before
comparing the mapping and checks all symbol-reader exit statuses.

The following sections preserve the original probe's configuration and
observations. They are not additional independent test counts.

## Toolchain and build configuration

LLVM/Clang/MLIR 23.1.1, release commit
`6dfe1677ab8dffbc6ec13d53a1e0215d75147689`, was used for compiler objects,
the contract reader, native tools and final hosted linking.

- Compiler default target: `arm64-apple-darwin25.6.0`.
- Emitted LLVM target: `arm64-apple-macosx26.0.0`.
- Data layout: `e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32`.
- SDK reported in the emitted metadata and executable: 26.5.
- Executable `LC_BUILD_VERSION`: macOS, minimum 26.0, SDK 26.5.
- SDK selection: `xcrun --show-sdk-path`; the installation's native Clang
  configuration selects the installed Xcode SDK.

The initial native-tool build failed: LLVM 23 libc++ headers referenced
`std::__bad_variant_access_with_msg`, unavailable from the SDK runtime.
Explicitly linking the archive's libc++ and libc++abi linked the tools but
aborted before source analysis with a typed-operator-new initialization error.
These failed attempts are not successful core tests. The successful configuration
uses the SDK's C++ headers together with the system C++ runtime, while retaining
LLVM 23.1.1 as the compiler and LLVM/MLIR implementation.

The following commands assume an independent compiler checkout containing both
reviewed changes. They do not move the project's gitlink:

```sh
export LLVM_PREFIX="$HOME/.local/opt/llvm-23.1.1"
export SPINEL_SEAM=/path/to/spinel-at-cad0ad14
export SPINEL_CORE_BUILD="$PWD/tools/mlir/native/build"
SDK_PATH=$(xcrun --show-sdk-path)

make -C "$SPINEL_SEAM" deps
make -C "$SPINEL_SEAM" -j8 CC="$LLVM_PREFIX/bin/clang"
SPINEL_DIR="$SPINEL_SEAM" CC="$LLVM_PREFIX/bin/clang" tools/contract/build.sh

cmake -G Ninja -S tools/mlir/native -B "$SPINEL_CORE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
  -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
  -DMLIR_DIR="$LLVM_PREFIX/lib/cmake/mlir" \
  -DLLVM_DIR="$LLVM_PREFIX/lib/cmake/llvm" \
  -DCMAKE_EXE_LINKER_FLAGS= \
  -DCMAKE_CXX_FLAGS="-nostdinc++ -isystem $SDK_PATH/usr/include/c++/v1"
ninja -C "$SPINEL_CORE_BUILD" spinel-core-check spinel-core-emit
python3 tests/core-eligibility/run.py
python3 tests/native-core/macos-probe.py
```

Use a fresh build directory when changing toolchains. `RUBY` can select the
CRuby oracle for the native probe. The measured oracle was Homebrew CRuby;
its exact executable is selected explicitly rather than using system Ruby.
The native `build.sh` at this revision does not build `spinel-core-emit`, so
that target is explicitly requested above.

## Results

- Source eligibility suite: 50 tests, exit 0, using the newly built Mac tools.
- Native probe: nine fixtures agree with CRuby: lower, reversed/equal/negative
  arguments, two call sites, upper/lower admitted signed boundaries, the full
  admitted signed span, and a helper closure.
- Every fixture's core object has exactly one external definition: the mapped
  root with Mach-O's leading underscore. `llvm-nm -u` reports no undefined
  symbols. Private helper/section symbols are not counted as public entries.
- `llvm-objdump -dr` identifies Mach-O arm64. The smallest comparison object
  contains `cmp`, `csel`, `ret`; that observed body has no external relocation.
- Linking a stub implementation returning 999 changes execution to 999.
  Omitting the core implementation fails to link. These are routing controls.
- The reserved minimum integer literal is refused by emission.
- The generated executable is Mach-O arm64 and prints `3` for the acceptance
  program. The whole executable still includes the hosted Spinel runtime.

All final commands above completed successfully in the isolated work area.
Existing runtime header comments produce three `-Wcomment` warnings during
hosted compilation; no warning-free claim is made.

An exploratory executable named `lower.app` was killed with signal 9 locally,
while a copied executable with a different name ran. The cause was not
established. The repeatable probe uses ordinary `.bin` executable names in a
fresh temporary directory and passed; it does not create macOS application
bundles or claim to resolve that exploratory failure.

## Limits of the original probe

The original probe did not exercise product snapshot/publication behavior.
The pinned product validation above now covers that path on macOS. No full
upstream or arena suite was rerun on Mac for this integration; Debian's
revision-scoped results remain separate. The executable still includes the
hosted runtime, and none of these checks establish general Ruby support.
