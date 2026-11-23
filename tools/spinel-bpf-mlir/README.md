# spinel-bpf-mlir

**Status: being imported.** The tree is spinel-bpf-mlir v0.7.0 updated to
main `4b936d5`, then to v0.8.0 (`1ffc979`), then to main `9b914a8` (E160 and E161, with E161's
addendum), then to main `cf77cec` (E161's addendum 2), then to main `8b20ffa` (its addendum 3), then to main `7af1fd4` (E162 and E163, English documents and messages), then to main `e14acc0` (E164: bml `d879745`), then to `c56a4915`, the source of the public release v0.9.0 (with bml `41ec56f1`, the source of bpf-mlir-loader v0.1.0), and then to `0e83966a`, the source of v0.9.1 (E172: the version and its go.sum correction), with the local changes listed below. Both are Apache-2.0 WITH LLVM-exception (`LICENSE`, `NOTICE`; bml's are in `third_party/bpf-mlir-loader/`). The owner's route is
the BPF side through spinel_facts v2 and spinel-mlir's consumer
([`tools/spinel-mlir`](../spinel-mlir/README.md)): `spinelbpf build --seam-emit E
--seam-inspect I x.rb` takes the consumer's outputs and skips the Go
frontend. The driver's own frontend path still checks for Spinel `086d514d`
and refuses this repository's pin. `tests/spinel-bpf-mlir/run.sh` runs the ported Go tests that need no
privilege and no oracle; `tests/spinel-bpf-mlir/tests.tsv` gives every test's
class, and those still tied to Spinel `086d514d` are `pending`.

spinel-bpf-mlir v0.7.0 puts the user-space side and the eBPF side of a
program in one Ruby (Spinel) source and builds one executable:

- the eBPF side goes through its Go frontend to bpf-mlir's `ebpf` dialect, a
  schema and a maps description;
- bpf-mlir's `ebpf-compile` turns those into a BTF-carrying BPF ELF;
- the user-space side is compiled by Spinel against the Ruby library
  `ruby/lib/`, and linked with the C loader bml.

`examples/bcc/` holds 35 bcc tools written this way (28 at v0.7.0, and the
third wave's seven at v0.8.0), from spinel-ebpf
`23fa4b0`'s `tools/<tool>.rb` (here in `tools/ebpf/tools/`). Where it came
from, and what was left out, is in [provenance](../../docs/provenance.md#spinel-bpf-mlir-v070-and-its-loader-bml-the-bcc-tools-2026-10-26).

## Layout

The source's own layout, under this directory:

| Path | What |
|---|---|
| `cmd/spinelbpf/` | the driver (`spinelbpf build`), and most tests |
| `internal/` | the Go frontend, the toolchain checks, the version string |
| `ruby/lib/` | the Ruby library a program requires (`bpf`, `spinelbpf`) |
| `examples/` | 14 examples, `examples/bcc/` among them (sources only) |
| `scripts/` | spinel-bpf-mlir's scripts |
| `packaging/needed.allow` | the shared libraries a built executable may need |
| `third_party/bpf-mlir-loader/` | bml `41ec56f1` (bpf-mlir-loader v0.1.0's source), as source |
| `third_party/PINS` | the bpf-mlir commits both sources pin (local, below) |

## Toolchain

All user-local; see the
[installation record](../../docs/toolchains/spinel-bpf-mlir-deps/INSTALLATION-RECORD.md).
The driver checks that `ebpf-compile` was built from the bpf-mlir commit
that `internal/toolchain` pins. The source has two build shapes:
- **The development shape** is what this repository builds and tests. It pins
  bpf-mlir's development tree at `41b188568` (E166), and its Go packages come from the module
  at that commit.
- **The public shape** pins the public bpf-mlir v1.21.0, whose source is the
  same commit `41b188568`. Its Go packages come from go-bpf-mlir v0.19.0.

Set `BPF_MLIR_SRC` to that bpf-mlir source and `BPF_MLIR_BUILD` to its
build. The driver takes its tools from the environment:

```sh
export GO=$HOME/toolchains/go-1.27.3/bin/go GOTOOLCHAIN=local GOFLAGS=-mod=readonly
export EBPF_COMPILE=$BPF_MLIR_BUILD/bin/ebpf-compile
export SPINEL=$PWD/vendor/spinel/bin/spinel   # from the repository root
```

bml's five archives (`libbml_spinel.a`, `libbml.a`, `libbpf.a`, `libelf.a`,
`libz.a`) are built into `tools/spinel-bpf-mlir/build/bml/lib`, the driver's
default, from the user-local sources. As spinel-bpf-mlir's `setup.sh` does,
the build runs from zlib's directory. `taskset` keeps the script's
`$(nproc)` jobs at four:

```sh
R=$PWD/tools/spinel-bpf-mlir   # from the repository root
(cd ~/toolchains/zlib-1.3.2 && \
  BML_ZLIB_DIR=$HOME/toolchains/zlib-1.3.2 \
  BML_ELFUTILS_DIR=$HOME/toolchains/elfutils-0.196 \
  BML_LIBBPF_DIR=$HOME/toolchains/libbpf-1.7.0 \
  taskset -c 0-3 bash "$R/third_party/bpf-mlir-loader/scripts/build-libs.sh" "$R/build/bml")
```

The output directory is any path; the driver reads `SPINELBPF_LOADER_LIBS`
when it is not the default. The tests also need bml's test-caps archive in
`build/bml-test`, built after the five:

```sh
BML_LIBBPF_DIR=$HOME/toolchains/libbpf-1.7.0 BML_ZLIB_DIR=$HOME/toolchains/zlib-1.3.2 \
  taskset -c 0-3 bash tools/spinel-bpf-mlir/scripts/build-bml-test.sh
```

The ported Go tests run through `tests/spinel-bpf-mlir/run.sh`, which holds
them to `tests/spinel-bpf-mlir/tests.tsv` and refuses sudo.

## Local changes

- **`cmd/spinelbpf/e133_test.go`, `TestBccProvenance`.**
  - The blob column of `examples/bcc/PROVENANCE.md` is checked against this repository's `tools/ebpf/<path>`, through `git hash-object`.
  - spinel-bpf-mlir read a sibling spinel-ebpf checkout and skipped the check without one.
  - A copy with one byte added to `tools/ebpf/tools/runqlat.rb` fails it by name.
- **`cmd/spinelbpf/bml.go`, `cmd/spinelbpf/seam_pin_dev.go` and `third_party/PINS`.**
  - The check that the frontend's and the loader's bpf-mlir agree read two gitlinks: spinel-bpf-mlir's `third_party/bpf-mlir` and bml's. Neither exists here.
  - It now reads both commits from `third_party/PINS`, which records those gitlinks as the sources have them.
  - The development shape's seam fallback, used when there is no `ebpf-compile`, read the first gitlink too. It now reads the same row.
  - `PINS` also records the public shape's source commit, which `tests/spinel-bpf-mlir/run.sh` compares with a release's `SOURCE_VERSION`.
  - The judgement version and the format maximum still come from the Go module and bml's C headers. `TestBMLVersionsMatch` and `TestBMLVersionMismatchStops` pass.
- **`third_party/bpf-mlir-loader/scripts/build-libs.sh`.** zlib, elfutils and libbpf are named by `BML_ZLIB_DIR`, `BML_ELFUTILS_DIR` and `BML_LIBBPF_DIR`. They default to the submodule paths, which do not exist here.
- **`scripts/build-bml-test.sh`.** libbpf and zlib are named by `BML_LIBBPF_DIR` and `BML_ZLIB_DIR`, as for bml's `build-libs.sh`.
- **`internal/frontend/helpers_test.go`.** The frontend tests take Spinel from `SPINEL`, as the driver does, in place of `third_party/spinel/bin/spinel`.
- **`cmd/spinelbpf/e165_test.go`, `TestNoOtherSudoPath`.** Its `git grep` for the real sudo path leaves out `third_party/bpf-mlir-loader`. bml is a submodule upstream, which `git grep` does not enter; here it is imported as source, and its `test/oracle/internal/p152` names that path.
- **Call-signs replaced by roles.** In 29 files, comments that named an agent by call-sign name its role instead, and `cmd/spinelbpf/e168_test.go` builds its planted call-sign at run time. The files are listed in `docs/provenance.md`.
- **bml's oracle scripts gated.** Eighteen differential scripts and bml's own commit gate call `tools/oracle/gate` and run only with `ALLOW_ORACLE=1` (`tests/ORACLES.tsv`).
  - Five more from bml `41ec56f1` call it too: `scripts/{reader-unit,target-rows-unit,unknown-probes,p152-unit,p152-preroot}.sh`.
  - `scripts/srcs.sh` writes `"$HERE"/test/oracle` for `"$HERE/test/oracle"`, which is the same path. It was changed only because `tests/oracle/check.sh` reads `/oracle"` there as a mention of another tree's `oracle.rb`. `scripts/gen-uprobe-offset-copy.sh` (from bml `a6da571`) and `scripts/check-mutation-inventory.sh` (from `41ec56f1`) have the same change.
- **`third_party/bpf-mlir-loader/scripts/{mojo,spinel}-oracle.sh`.** These defaulted to sibling checkouts of mojo-bpf-mlir and spinel-bpf-mlir. They now require `MOJO_REPO` or `SPINEL_REPO` and stop at once without them. They are oracles, and are not run here.

## Not run

- **The VM tests.** They boot kernel images under `$HOME/kernel-build/`, and run only with `SPINELBPF_VM=1`, so by default they skip. They are kept as files and not run here: spinel-bpf-mlir's owner limited that project to the host kernel, and this repository has no such images.
  - `e005_test.go` `TestDifferential`
  - `e011_test.go` `TestTableThreeTargets`
  - `e015_test.go` `TestPacketRunVM`
  - `e017_test.go` `TestEthertypeSelftestVM`, `TestPacketTableVM`
  - `e023_test.go` `TestLastseenSelftestVM`, `TestRecordTableVM`
  - `e029_test.go` `TestPktlogSelftestVM`, `TestRingTableVM`
  - `e036_test.go` `TestFlowcountSelftestVM`, `TestHashTableVM`
  - `e040_test.go` `TestPercpuTableVM`, `TestProtostatSelftestVM`
- **Scripts that need the absent submodules or another project.** These are spinel-bpf-mlir's `scripts/setup.sh`, `clone-check.sh` and `gate.sh`, and bml's oracle and differential scripts (`scripts/{mojo,spinel}-oracle.sh`, `diff-*.sh` and others). They are kept as files and are not part of this import's checks.
- **The VM and root scripts of `c56a4915` and bml `41ec56f1`.** spinel-bpf-mlir's `scripts/gate-vm*.sh`, `scripts/lib/guest-only.sh` and the root-test lists `cmd/spinelbpf/testdata/root_{tests,skips}.txt`, and bml's `scripts/p152-*`, `gate-vm*.sh`, `gate-mode.sh` and the `virtme-run` wrappers are kept as files and not run. The Go tests that check their guards with a fake sudo and no VM (`e165_test.go`) are routine.
