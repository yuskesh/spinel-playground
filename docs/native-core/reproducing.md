# Building a native core executable

The pinned Spinel revision is the commit `vendor/spinel` records
(`git ls-tree HEAD vendor/spinel`), at this writing
`ad4bb8c4238ddeaa801dc434b84f0b5cfd865af1`. It includes the selected-root
linkage seam and the input ledger. No predecessor or independent compiler
checkout is required.

## Build from the repository root

Select LLVM 23.1.1 and a CRuby interpreter on PATH. On Debian, the measured LLVM
prefix is `/opt/llvm-23.1.1`. On macOS, use the installation described in the
[installation record](../toolchains/llvm-23.1.1-macos/INSTALLATION-RECORD.md),
for example `$HOME/.local/opt/llvm-23.1.1`, and install Xcode's macOS SDK.

```sh
export LLVM_PREFIX=/opt/llvm-23.1.1  # use your installation prefix on macOS
export CLANG="$LLVM_PREFIX/bin/clang"
export CC="$CLANG"
export NM="$LLVM_PREFIX/bin/llvm-nm"
umask 022
git submodule update --init --recursive
make -C vendor/spinel deps
make -C vendor/spinel -j8 CC="$CC"
tools/contract/build.sh
tools/mlir/native/build.sh
mkdir -p build
tools/core/spinel-core-build --source tests/native-core/fixtures/lower.rb \
  --core lower -o build/lower.bin
./build/lower.bin
```

Expected output: `3`. `SPINEL_CORE_VERBOSE=1` prints the six build stages.
The native build produces all four core/freestanding tools. On macOS it uses
SDK libc++ headers with the system libc++ runtime, while compiling against
LLVM/MLIR 23.1.1. Use a fresh `BUILD_DIR` when changing toolchains; set
`SPINEL_CORE_BUILD` to that same directory for the driver and tests.

The driver defaults to `vendor/spinel`. `SPINEL_SEAM` and `SPINEL_TYPEDUMP` are
optional development overrides, not dependencies on local checkouts.

## Checks

On macOS, `LLVM_PREFIX` (or `NM`) and `CLANG` are REQUIRED for these checks,
not conveniences. `tools/core/core-artifact-gate` reads the Mach-O symbol table
through `NM`, defaulting to `$LLVM_PREFIX/bin/llvm-nm`, and refuses to start
with `set LLVM_PREFIX or NM` if neither is set; every gate check in
`tests/native-core/driver.sh` then fails for that reason alone.
`tests/native-core/ledger.sh` defaults `--clang` to `/opt/llvm-23.1.1/bin/clang`,
a Debian path that does not exist on macOS. The export block above sets all of
them; measured at `20e6b79` on macOS arm64, the driver is 43 passed 0 failed
and the ledger 23 passed 0 failed with them set, and 39/4 and 22/1 with
`LLVM_PREFIX`, `CLANG` and `NM` unset on the same build.

```sh
tests/native-core/driver.sh
tests/native-core/ledger.sh
ruby tests/core-eligibility/run.rb
```

On Debian, run `tests/native-core/run.sh` and `tests/core/run.sh` for the
ELF fixture and declared freestanding checks. Neither applies to macOS:
`tests/native-core/run.sh` links `-lcrypt` and compares exported symbols
without normalising the Mach-O leading underscore, and `tests/core/run.sh`
selects the x86_64-linux freestanding profile, of which there is no arm64
counterpart. On macOS arm64, run
`ruby tests/native-core/macos-probe.rb` for the Mach-O fixture checks.
The shared product-driver suite exercises the actual artifact gate on both
hosts, including unexpected exports, undefined dependencies, non-code exports,
and a failing symbol reader. `RUBY` selects the CRuby the Mac probe's
gated section compares with (`ALLOW_ORACLE=1`); the shell suites use `ruby`
on PATH.

## Scope

The executable contains the normal hosted runtime. Only the core object is
checked for runtime independence. The initial envelope is one source file and
one selected top-level root, with inferred integer literals, comparisons,
selection and local binding. Arithmetic, unknown input domains and dependent
loads are refused. See [supported envelope](supported-envelope.md).

Native builds on Debian x86_64 and macOS arm64 are measured separately. This
is not a cross compiler or a hermetic build: the system toolchain, SDK and C
library headers remain environmental inputs. The driver records the selected
SDK path and deployment-target setting; it does not hash SDK contents.

## Pinned Debian integration check

The Debian collaborator reproduced a fresh pinned build and an out-of-tree
native build at `1435713`, then corrected the empty-SDK header-check regression
in `589848c`. That candidate recorded native core 18/0, product driver 43/0,
input ledger 23/0, eligibility 50, and declared core acceptance 33/0 with
LLVM/Clang 23.1.1. The fix is included in the integration. The final Mac build
also executes the acceptance program after this fix with a relative build path.
Upstream and arena corpus results below were retained at their measured
revisions; they were not rerun for the platform-script change.

## Earlier Debian evidence

The table below preserves the revisions of earlier executions; pinning does
not turn them into fresh executions on a different host. Current Mac evidence
is in [macOS validation](macos-validation.md).

## What each result covers

Results are recorded against the revision, host and scope they were produced
under. They are not interchangeable.

| result | revision under test | host | scope |
|---|---|---|---|
| `make test` 3543 pass / 0 fail / 0 error | fork `core/input-ledger` `cad0ad14` | Debian, LLVM/Clang 23.1.1 | the upstream suite, default configuration, with no `--core` and no `--inputs-out` |
| generated C, 3493 compared / 0 differing | `cad0ad14` vs a worktree of `00218233` | Debian | `test/*.rb` with `--no-line-map -S`, no `--inputs-out`: the vendor change is inert when unused |
| core seam 28 / 0 | fork `core/selected-root-seam` `00218233` | Debian | the `--core` symbol, body omission and link behaviour |
| arena guards 5 / 0, arena gate 267 declared | `00218233` | Debian | unchanged from the arena work; re-run to confirm the seam did not disturb it |
| native core 18 / 0 | Extended `621476a` with seam `00218233` | Debian | the acceptance program and its fixtures, end to end |
| core driver 43 / 0 | Extended `621476a` | Debian | the build driver and its refusals |
| input ledger 23 / 0 | Extended `621476a` with fork `cad0ad14` | Debian | the dependency boundary at the tools |
| eligibility 50, core acceptance 33 / 0 | Extended `621476a` | Debian | source checks; no artifact claim |

`make test` and the arena gate were measured on **`cad0ad14`** and **`00218233`**
respectively, which are different revisions. They are listed separately for that
reason rather than summed into one figure.
