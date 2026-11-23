# spinel-mlir's consumer

spinel-mlir's consumer reads a spinel_facts v2 module and produces the eBPF
side of a program. A module is what this repository's Spinel writes with
`--emit-mlir` and `--analysis-root` (the contract is
[`third_party/spinel-mlir/spinel_facts.md`](../../third_party/spinel-mlir/spinel_facts.md)).
Its outputs are:

- bpf-mlir's `ebpf` dialect, a schema and a maps description (`--emit-dir`);
- the inspection outputs, the domain graph and a manifest (`--inspect-dir`).

`bpf-mlir`'s `ebpf-compile` turns the first set into a BPF ELF.

It is the route the owner chose on 2026-10-26 for the bcc tools of
[`tools/spinel-bpf-mlir`](../spinel-bpf-mlir/README.md). That driver takes
them with `spinelbpf build --seam-emit E --seam-inspect I` (spinel-bpf-mlir
E152, imported at `4b936d5`, now at v0.9.1). This tree is spinel-mlir main
`f96ac6d`, with E082's neutral fixture paths (`c86ce1ae`) and E084's port to
bpf-mlir v1.21.0, whose pin `41b188568` it takes (`a8abbdc3`). Where this came from is in
[provenance](../../docs/provenance.md#spinel-mlirs-consumer-the-bpf-side-from-spinel_facts-v2-2026-10-26).

## Building

LLVM / MLIR 23.1.1, and the source and build of bpf-mlir v1.21.0 (public tag
`e5e439a0`, from the source commit `41b188568`: the pin spinel-mlir took in E084, and
spinel-bpf-mlir's development pin), user-local
([installation record](../../docs/toolchains/spinel-bpf-mlir-deps/INSTALLATION-RECORD.md)).
From the repository root:

```sh
L=/opt/llvm-23.1.1
cmake -G Ninja -S tools/spinel-mlir -B tools/spinel-mlir/build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$L/bin/clang -DCMAKE_CXX_COMPILER=$L/bin/clang++ \
  -DMLIR_DIR=$L/lib/cmake/mlir -DLLVM_DIR=$L/lib/cmake/llvm \
  -DBPF_MLIR_SOURCE=$HOME/toolchains/bpf-mlir-v1.21.0 \
  -DBPF_MLIR_BUILD=$HOME/toolchains/bpf-mlir-v1.21.0-build \
  -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON
cmake --build tools/spinel-mlir/build --parallel 4
```

The build takes about 4½ minutes at `-j4`, for 623 steps. `build/bin/spinel-mlir` is the consumer:

```sh
spinel-mlir --verify-only FACTS.mlir
spinel-mlir --emit-dir E [--inspect-dir I] FACTS.mlir
```

## Tests

`tests/spinel-mlir/run.sh` runs them, as `tests/spinel-mlir/tests.tsv` classes them:

- ctest's entries;
- the RUN lines of `test/*.test`, which the runner reads itself, because lit is Python.

The routine class runs. These do not:

- **oracle-records:** comparisons with the Go frontend's output that spinel-mlir recorded under its `docs/experiments`, which was not imported;
- **oracle-committed:** comparisons with the Go frontend's output committed here, in `test/Oracle`, `test/Inputs/*.stderr` and the tables generated from Go;
- **absent:** tests that read archived facts supplies.

`tools/bcc-facts/emit-facts.rb --consumer tools/spinel-mlir/build/bin/spinel-mlir`
checks the 28 bcc tools' modules from this repository's Spinel through it.

## Local changes

- **`cmake/BpfMLIR.cmake`.** `BPF_MLIR_SOURCE` is a cache variable, so it can name the user-local bpf-mlir. spinel-mlir set it to its `third_party/bpf-mlir` submodule.
- **`CMakeLists.txt` and `bpf-mlir-commit.cmake`, the bpf-mlir commit** ([decision 0047](../../docs/decisions/0047-bpf-mlir-commit-from-source-version.md)). The build records bpf-mlir's commit from `BPF_MLIR_SOURCE`'s `SOURCE_VERSION` (`format=1`, `source_commit=`) when there is one: a source release, or a clone of a public release. In a checkout, SOURCE_VERSION must be tracked and unchanged, and the work tree free of tracked changes. Without SOURCE_VERSION, a checkout is read with `git rev-parse HEAD`. Any other source stops the configure. `bpf-mlir-commit.cmake` is written here.
- **`scripts/batch-compare.rb` and `scripts/build-consumer-sanitizers.sh`.** Their bpf-mlir pin is main `a8abbdc3`'s (E084), `41b188568`. The rest of each is `f96ac6d`'s.
- **`CMakeLists.txt`.** It no longer requires a lit runner (`LLVM_EXTERNAL_LIT`) and no longer configures `test/lit.site.cfg.py`. `check-spinel-mlir` only builds the test programs. lit is Python, and its two files were not imported.
- **Expected but not run.** spinel-mlir's `build.sh` builds bpf-mlir into `build/bpf-mlir`, and the tests look for its tools there. `tests/spinel-mlir/run.sh` links `build/bpf-mlir` to `BPF_MLIR_BUILD`, inside the ignored build directory.
