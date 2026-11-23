# Building and testing

## Checking core source eligibility

After building the pinned compiler and contract reader using the commands below,
the native build also produces `spinel-core-check`:

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 tools/mlir/native/build.sh
tools/mlir/native/build/bin/spinel-core-check app.rb --method pick
ruby tests/core-eligibility/run.rb
```

This checks an ordinary Ruby method and its reachable direct callees. It does
not require `freestanding_def` or select a foreign ABI, and it does not emit an
object. See [Core source eligibility](../tools/core/README.md) for a complete
example, exact primitive rules, reports and limitations. The executable reuses
the contract model without linking the MLIR IR libraries; the existing native
build configuration still requires an LLVM installation with MLIR.


For ordinary Ruby methods selected for native core compilation, use the
[pinned native executable build](native-core/reproducing.md). The commands
below also describe the independent hosted and declared freestanding paths.

## Requirements

Use Git, a C compiler and platform development headers, GNU Make, curl, tar, and Ruby for reference tests. Dependency download requires network access.

`tests/core-boundary/closure.sh` needs a Ruby that can `require "prism"`, which
means 3.3 or later, or the gem installed; it says so and stops rather than
failing partway. The other lanes need only a Ruby that runs their oracles.

Debian 13 (trixie) x86_64 with Ruby 3.3.8 is the primary environment: the full upstream suite is run there. macOS arm64 is an auxiliary compatibility environment and is not the reference for suite results. Put your selected Ruby on PATH before testing; macOS system Ruby 2.6 is not a selected reference.

Set `umask 022` before running the tests. `vendor/spinel/test/implicit_conversion_protocol.rb` opens a file with a `nil` permission argument, so the resulting mode depends on the umask, and its recorded expectation is `644`. Under a group-writable default such as `umask 002` that one test reports `664` and the suite fails. This is a property of the environment, not of the compiler under test. Recorded results are in [provenance](provenance.md).

The [macOS LLVM 23.1.1 installation record](toolchains/llvm-23.1.1-macos/INSTALLATION-RECORD.md)
records the official archive, verification, native SDK configuration and installation
checks. Its user-local prefix can be selected through `LLVM_PREFIX`; those checks
do not establish Spinel acceptance on that toolchain.

**Selected C toolchain on both hosts: the official LLVM 23.1.1 release, and
not Apple Clang.** On macOS `/usr/bin/clang` and `cc` are Apple Clang and are on
`PATH`, but they are not used to build `vendor/spinel`, the contract reader, the
native tools or any test artifact, and this holds until a recorded decision
changes it. Pass `CC="$LLVM_PREFIX/bin/clang"` on every `make -C vendor/spinel`
line and export `LLVM_PREFIX`, `CLANG`, `CC` and `NM` before running the test
suites. A `make` without `CC=` silently builds with Apple Clang, because the
Makefile defaults to `cc`; that happened on 2026-09-12 and is recorded in
[provenance](provenance.md). `CC_KIND` only tells clang from gcc, so it does not
catch the substitution. To check an existing build, compile one runtime source
with `$LLVM_PREFIX/bin/clang` and the Makefile flags and compare it byte for byte
with the object under `vendor/spinel/build/`; an Apple Clang object differs in
size. A build made with the wrong compiler is rebuilt from `make -C vendor/spinel
clean`, not reused.

## Oracles run only with `ALLOW_ORACLE=1`

An oracle is a check against another implementation's behaviour: CRuby, a
reference C build, doomgeneric, a JAX or IREE reference, a replay under CRuby, a
byte comparison with another implementation's recorded output. It runs only on
the owner's instruction, and the instruction is `ALLOW_ORACLE=1` in the
environment. Without it every oracle section in `tests/` and `tools/` prints

```text
NOT RUN (oracle): <file> <section>: <what it compares with>
```

and is skipped: its checks are not counted, and the suite goes on and is not
failed by the skip. A bundled runner (`tests/*/run.sh`) therefore runs no
oracle unless `ALLOW_ORACLE=1` reaches it. Every oracle, and every file that
looks like one and is not, is a row of [`tests/ORACLES.tsv`](../tests/ORACLES.tsv),
with the owner's classification; a section marked `confirm` is gated until the
owner classifies it. The sections ask
[`tools/oracle/gate`](../tools/oracle/gate) (or `tools/oracle/gate.rb` in
Ruby), and `sh tests/oracle/run.sh` holds the list to the tree: a gate call
without its row, a row without its call, or a file the oracle patterns find
without a row fails it. [Decision 0020](decisions/0020-oracle-gate.md) records
the contract, the owner's classification and the check's limits.

`SPINEL_ORACLE=1` is an older switch, read at run time by the compiled examples
under `examples/tensor` and `examples/image` and by `tests/grad/e076/demoA`;
no runner sets it.

## Checkout and build

From the repository root:

```sh
git submodule update --init --recursive
make -C vendor/spinel deps
make -C vendor/spinel -j8
```

The submodule pins a commit, not a moving branch. Do not use `git submodule update --remote` for normal builds. `make deps` downloads Prism 1.9.0 and RBS 4.0.1 using the upstream recipe. The recipe pins versions but does not verify archive checksums; this is not yet a fully hermetic dependency bootstrap.

The compiler is `vendor/spinel/bin/spinel`, also reachable through the `vendor/spinel/spinel` symlink that points at it. The project tool is `vendor/spinel/bin/spin`.

## Compile and run

From the repository root:

```sh
mkdir -p build
printf 'puts 6 * 7\n' > build/hello.rb
vendor/spinel/spinel build/hello.rb -o build/hello
./build/hello
```

Expected output: `42`. Compilation and execution are separate commands.

## Writing Spinel's facts as MLIR

The pinned compiler can also write what it learned about a program as an
MLIR module of the `spinel_facts` dialect: the parsed and analyzed AST, the
inferred types and the codegen evidence. Its contract is
[`third_party/spinel-mlir/spinel_facts.md`](../third_party/spinel-mlir/spinel_facts.md),
and how it came here is in [provenance](provenance.md#patch-2-spinel-mlir-m1m3-the-spinel_facts-contract-v2-2026-10-25)
and [Patch 3](provenance.md#patch-3-spinel-mlir-m4-the-typing-probe-2026-10-27).

```sh
vendor/spinel/spinel build/hello.rb --emit-mlir=build/hello.mlir
```

- `--emit-mlir=<path>` is a mode of its own: it writes the module and no C,
  prints nothing on stdout, and refuses `-S`, `-c`, `-o`, `-E` and the other
  emit modes (exit 2). A program Spinel refuses gives a module with
  `status = "rejected"` and only diagnostics, and exit 1.
- `--analysis-root=METHOD:TYPE[,TYPE...]`, with `--emit-mlir` only, seeds the
  analysis with a top-level method and its argument types, and the module
  becomes version 2. The types are `int`, `float`, `string`, `bool`,
  `symbol` or `obj_<Class>`; the flag may be given up to 16 times.
- Node positions are in the original files. A node that spans two files has
  no position, and a node whose line does not match its file is refused,
  `MLIR M3 unrecoverable span … reason=content`, exit 1.
- `--emit-typing-probe`, with `--emit-mlir` and at least one
  `--analysis-root` only (exit 2 otherwise), adds the dictionary
  `spinel_facts.typing_probe`: the types of a second analysis without the
  roots, beside the module's own. Spinel runs that analysis in a forked
  child before parsing. spinel-mlir's consumer needs it for a tool that
  embeds a kernel struct.

Without these flags the compiler's output is unchanged. The bcc tools' facts
script and spinel-mlir's consumer read the module (next section).

## The bcc tools' BPF side: spinel-bpf-mlir and spinel-mlir's consumer

On 2026-10-26 the owner chose this route for the bcc tools of
[`tools/spinel-bpf-mlir`](../tools/spinel-bpf-mlir/README.md): the BPF side
comes from this Spinel's facts (above), through spinel-mlir's consumer in
[`tools/spinel-mlir`](../tools/spinel-mlir/README.md). spinel-bpf-mlir's
driver takes the consumer's outputs with `spinelbpf build --seam-emit E
--seam-inspect I`, and the owner accepted the 28 tools built that way on
2026-10-27 ([below](#the-acceptance-2026-10-27)). The 35 tools of v0.8.0
met the same criterion on one run of the oracle the same day
([below](#v080-35-tools-2026-10-27)). Linux x86_64 only.

**Tools, all user-local, without sudo.** They are:
- Go 1.27.3;
- the build and source of the public bpf-mlir v1.21.0, whose `source_commit`
  (`41b188568`) is the `public/bpf-mlir` row of
  `tools/spinel-bpf-mlir/third_party/PINS`;
- the libbpf, zlib and elfutils sources that the loader bml builds from.

All are recorded in
[the installation record](toolchains/spinel-bpf-mlir-deps/INSTALLATION-RECORD.md).
None of them uses Python:

- bpf-mlir is configured with `-DLLVM_EXTERNAL_LIT=/bin/false`, because its
  lit tests are not run here;
- spinel-mlir's lit files are read by `tests/spinel-mlir/run.sh`, not by lit.

```sh
export GO=$HOME/toolchains/go-1.27.3/bin/go GOTOOLCHAIN=local GOFLAGS=-mod=readonly
export BPF_MLIR_SRC=$HOME/toolchains/bpf-mlir-1.21.0 BPF_MLIR_BUILD=$HOME/toolchains/bpf-mlir-1.21.0-build
export EBPF_COMPILE=$BPF_MLIR_BUILD/bin/ebpf-compile
```

The development tree builds the same compiler source from bpf-mlir's
development repository instead (the `bpf-mlir` row of
`tools/spinel-bpf-mlir/third_party/PINS`: the development tree's `41b188568`,
the source of the public bpf-mlir v1.21.0, and the development pin of spinel-bpf-mlir `0e83966a`, the source of v0.9.1) and needs a `GOPRIVATE` setting
for its Go module, which the published tree does not use. spinel-mlir's
consumer pins the same `41b188568` since E084.

**bml's archives.** They are built from the user-local sources, which
`BML_ZLIB_DIR`, `BML_ELFUTILS_DIR` and `BML_LIBBPF_DIR` name. The build runs
from zlib's directory, so that no checkout path lands in the archives.
`taskset` keeps the scripts' `$(nproc)` jobs at four:

```sh
R=$PWD/tools/spinel-bpf-mlir
export BML_ZLIB_DIR=$HOME/toolchains/zlib-1.3.2 BML_ELFUTILS_DIR=$HOME/toolchains/elfutils-0.196 BML_LIBBPF_DIR=$HOME/toolchains/libbpf-1.7.0
(cd "$BML_ZLIB_DIR" && taskset -c 0-3 bash "$R/third_party/bpf-mlir-loader/scripts/build-libs.sh" "$R/build/bml")
taskset -c 0-3 bash "$R/scripts/build-bml-test.sh"
```

**The consumer.** Build it with CMake into `tools/spinel-mlir/build`, as
[its README](../tools/spinel-mlir/README.md#building) shows; that takes about
4½ minutes at `-j4`.

**The checks.** Each takes a fresh directory outside the checkout:

```sh
sh tests/spinel-bpf-mlir/run.sh DIR   # spinel-bpf-mlir's routine Go tests
sh tests/spinel-mlir/run.sh DIR       # the consumer's routine ctest entries and lit files
CONSUMER=$PWD/tools/spinel-mlir/build/bin/spinel-mlir \
  EBPF_OPT=$BPF_MLIR_BUILD/bin/ebpf-opt sh tests/bcc-facts/run.sh DIR
```

- `tests/spinel-bpf-mlir/tests.tsv` and `tests/spinel-mlir/tests.tsv` class
  every ported test. Only the routine class runs. Oracles stay gated
  ([above](#oracles-run-only-with-allow_oracle1)), among them the six
  spinel-mlir unit tests whose expectations come from the Go frontend
  (`confirm`, which the owner named oracles on 2026-10-27). Tests that need
  a load as root, a VM or files that were not imported are not run.
- **sudo is refused.** On the development host sudo asks for no password,
  and a plain `go test` of spinel-bpf-mlir would load programs as root. So
  both runners put a `sudo` on `PATH` that records the call and fails, and
  a recorded call fails the suite.
- `tests/bcc-facts/run.sh` checks the 35 tools' facts modules
  (`tools/bcc-facts/emit-facts.rb`) against the contract. tcpretrans, which
  embeds a kernel struct, is asked for the typing probe
  ([Patch 3](provenance.md#patch-3-spinel-mlir-m4-the-typing-probe-2026-10-27)).
  With `CONSUMER`, it also checks the consumer's seam outputs (`--emit-dir`,
  `--inspect-dir`) for each tool. With `EBPF_OPT` too, it checks the
  acceptance oracle's generic comparison on the consumer's own output, with
  planted controls.

### The acceptance (2026-10-27)

The owner accepted the 28 tools on 2026-10-27, on one run of the oracle
`tests/bcc-facts/acceptance.rb` (commit `a59e556`, 2026-10-26, run once as
the owner approved). It compared the 224 files the 28 tools generate here,
end to end through the consumer, with those spinel-bpf-mlir v0.7.0 committed
(`examples/bcc/artefacts.sha256`; every reference file matched that list
first).

**The criterion.** The plan said: "byte for byte, but the `.mlir` file's
version line". The owner corrected it on 2026-10-27, keeping that sentence
as the record of what was planned:

- the `.bpf.o`, `_embed.S`, `_embed.o`, `.schema.json`, `.maps.json`,
  `.domain.json` and `.compile_warnings.txt` files are equal byte for byte;
- the `.mlir` files are equal in bpf-mlir's `ebpf-opt --mlir-print-op-generic`
  form: the IR and its Ruby source locations, which is how spinel-mlir's E074
  compared them. Their text cannot be equal byte for byte. The consumer prints
  through MLIR's own printer and spinel-bpf-mlir through Go's: SSA names,
  location aliases, the `module {}` wrapper and the header comments differ.

**The result.**

| Files (28 each) | Criterion | Met |
|---|---|---|
| `.bpf.o`, `_embed.S`, `_embed.o` | bytes | 84 of 84 |
| `.schema.json`, `.maps.json`, `.domain.json` | bytes | 84 of 84 |
| `.compile_warnings.txt` | bytes | 28 of 28 |
| `.mlir` | the generic form, IR and source locations | 28 of 28 (0 of 28 by bytes) |

196 of the 224 files are byte-identical. The other 28 are the `.mlir` files.
The script itself classes them `ast` (different beyond the version line) and
exits 1. Their generic-form comparison was made from that run's outputs, read
back with `ebpf-opt`, without a second run:

- without locations, the IR is equal in 28 of 28;
- every Ruby source location (`<tool>.rb:L:C`) is equal;
- the only other locations that differ are the ones the parser gives block
  arguments that Go's text leaves without a location, where the consumer
  writes `loc(unknown)`.

#### v0.8.0: 35 tools (2026-10-27)

The owner approved one run of the oracle against spinel-bpf-mlir v0.8.0
(`1ffc9791e0a5`), under the same criterion. The script now checks that
criterion itself (commit `96c2a89`): the `generic` class is the `.mlir`
comparison above, made by `ebpf-opt` inside the run. The run used:

- OURS: the 35 tools built end to end here through the consumer
  (`spinel-mlir` at `f96ac6d`), with tcpretrans given the typing probe;
- REF: v0.8.0's `examples/bcc`, from `git archive` of the tag, outside the
  checkout. All 280 files matched its `artefacts.sha256` first;
- `EBPF_OPT`: bpf-mlir go/v1.18.0's `ebpf-opt`.

```sh
ALLOW_ORACLE=1 EBPF_OPT=$BPF_MLIR_BUILD/bin/ebpf-opt \
  ruby tests/bcc-facts/acceptance.rb OURS REF OUT
```

It exited 0 in under a second.

| Files (35 each) | Criterion | Met |
|---|---|---|
| `.bpf.o`, `_embed.S`, `_embed.o` | bytes | 105 of 105 |
| `.schema.json`, `.maps.json`, `.domain.json` | bytes | 105 of 105 |
| `.compile_warnings.txt` | bytes | 35 of 35 |
| `.mlir` | the generic form, IR and source locations | 35 of 35 (`generic`; 0 by bytes) |

245 of the 280 files are byte-identical. No file is `missing`, `ast`,
`json-escape`, `json-value` or `bytes`.

The comparison is an oracle: it runs only with `ALLOW_ORACLE=1`
([above](#oracles-run-only-with-allow_oracle1)), and only on the owner's
instruction.

## Recording the collector's events

Decision [0036](decisions/0036-gc-event-record.md). An opt-in runtime archive
records every slab slot's allocation, promotion and sweep, the same for the
blocks malloc'd outside the slab, and each collection's roots. It is not
built by default:

```sh
make -C vendor/spinel events-runtime CC="$CC"
tools/gcviz/gcviz-build tools/gcviz/example.rb /path/to/example
SPINEL_GC_THRESHOLD_KB=16 SPINEL_GC_OBJ_BUDGET=fixed \
  SPINEL_GC_EVENTS=events.bin /path/to/example
ruby tools/gcviz/gcviz-events.rb summary events.bin
ruby tools/gcviz/gcviz-events.rb check events.bin
LLVM_SYMBOLIZER="$LLVM_PREFIX/bin/llvm-symbolizer" \
  ruby tools/gcviz/gcviz-events.rb json events.bin /path/to/example > events.json
```

The small fixed budget makes a short program collect often enough to watch
(21 collections for the example). The JSON names, for each slot, the lines
of the Ruby source that allocated it, and for each collection the line whose
allocation started it; `gcviz-build` compiles with `-g` for that.
`SPINEL_GC_EVENTS_MAX` caps the records
(default 2^20). `SPINEL_GC_SLAB=0` records the same program with the slab
off, its objects malloc'd and kept on lists (add `SPINEL_GC_AGE=1` for
aging). Single-threaded programs only. `sh tests/gcviz/run.sh` checks
the record by replaying it.

## Upstream tests

```sh
umask 022
make -C vendor/spinel -j8 test
```

The upstream test target clears previous result stamps and runs its feature, package, and auxiliary checks. Inspect the summary and exit status. This is the upstream baseline, not validation of Extended tier separation. Benchmark, optcarrot, and other non-test targets are separate and are not implied by a successful `make test`.

## Selecting a specific C toolchain

Three things decide which compiler actually runs. Point all of them at the toolchain you intend to measure, or the run mixes compilers.

1. The Makefile's `CC`. It builds the compiler itself, compiles every generated translation unit in the main suite, runs the OpenSSL probe, and compiles the host C of `ext-test` and `rbs-seed-test`. A `CC=` assignment on the make command line overrides the default, and a command-line assignment wins over the environment.
2. The `cc` that the Spinel compiler executes for itself. At the pinned revision `vendor/spinel/src/main.c` hardcodes the command name `cc` and reads no `CC` environment variable; only its `--cc=` option overrides the choice, and the Makefile's rules do not pass that option. The auxiliary checks that link a program through `bin/spinel` compile through this path: `backtrace-test`, the `gc-*` checks, `byref-capture-test`, and `re-lit-test`.
3. A compiler cache. `vendor/spinel/common.mk` prepends `sccache` or `ccache` to `CC` with `override` when either is on `PATH`, so even a command-line `CC=` is wrapped. Pass `NO_CCACHE=1` to invoke the compiler directly. Remember that a cache hit replays a stored object instead of recompiling, so a cache shared with earlier runs weakens the claim that this toolchain produced these artifacts; point `CCACHE_DIR` at an empty directory when that matters.

Covering the second path requires `cc` to resolve to the intended compiler on `PATH`. An LLVM release tree installs `clang`, not `cc`, so add a shim directory. The following selects LLVM 23.1.1 from `/opt/llvm-23.1.1` for one shell and changes nothing outside it:

```sh
umask 022
LLVM_PREFIX=/opt/llvm-23.1.1
SHIM_DIR=$(mktemp -d)
ln -s "$LLVM_PREFIX/bin/clang" "$SHIM_DIR/cc"
ln -s "$LLVM_PREFIX/bin/clang++" "$SHIM_DIR/c++"
PATH="$SHIM_DIR:$LLVM_PREFIX/bin:$PATH"
export PATH

make -C vendor/spinel clean
make -C vendor/spinel deps
make -C vendor/spinel -j8 CC="$LLVM_PREFIX/bin/clang"
make -C vendor/spinel -j8 test CC="$LLVM_PREFIX/bin/clang"
rm -rf "$SHIM_DIR"
```

The `clean` is required, not tidiness. Object files under `vendor/spinel/build/` do not depend on `CC`, and no stamp records which compiler produced them, so building over a tree left by another compiler relinks a mixed executable without any diagnostic. The `c++` link is defensive; nothing in the pinned tree was observed to invoke it.

Keep the shim out of a login profile and out of the system `PATH`. Making `cc` resolve to a different compiler for every process would change unrelated builds.

Confirm the selection took effect rather than assuming it:

- `command -v cc` resolves inside the shim directory, and `cc --version` reports the intended compiler.
- `make -C vendor/spinel -p -n CC="$LLVM_PREFIX/bin/clang" | grep '^CC_KIND'` prints `CC_KIND := clang`. Note that `-n` suppresses only recipe execution: the Makefile still evaluates its parse-time `$(shell)` calls, so this query compiles and links an OpenSSL probe into `/tmp/sp_ossl_probe`.
- The Makefile writes precompiled headers under `vendor/spinel/build/pch/`, in a directory whose name starts with the detected compiler kind, for example `clangO2` for Clang at `-O2`.
- Read the `.comment` section of a translation unit that is not regenerated on every run, such as `vendor/spinel/build/csrc/codegen.o`:
  `"$LLVM_PREFIX/bin/llvm-readelf" --string-dump=.comment vendor/spinel/build/csrc/codegen.o`.
  Do not sample `build/csrc/main.o` for this: it depends on a header rebuilt through a `FORCE` rule, so it always names the current `CC` even when the rest of the tree is stale. A fully linked executable also names GCC, because Clang links GCC's `crtbeginS.o` and `crtendS.o` on this platform; that string alone does not mean Spinel's own translation units were built with GCC.

## Building and checking the core slice

The commands above build the hosted upstream compiler. The core slice is a
separate build that produces the drivers `spinel-fs-emit` and
`spinel-fs-check`, and it is what turns a declared function into a standalone
object. `spinel-fs-emit` stops at LLVM IR and runs `spinel-fs-codegen`, from
the same `bin` directory unless `--codegen` names another, for the object. It is imported from the predecessor project; see
[provenance](provenance.md).

Requirements beyond the hosted path: CMake 3.20 or newer, Ninja, and an LLVM
installation that includes MLIR. The recorded runs use LLVM 23.1.1 at
`/opt/llvm-23.1.1`; set `LLVM_PREFIX` to use another one. The official LLVM
release archive is enough. It does not ship `lit`, `FileCheck`, `count` or
`not`, and this slice needs none of them.

From the repository root, in this order:

```sh
git submodule update --init --recursive
make -C vendor/spinel deps
tools/contract/build.sh
tools/mlir/native/build.sh
```

`make deps` comes before `tools/contract/build.sh` because the contract reader
links the vendor compiler objects, and those objects cannot be built until
Prism and RBS are present. `build.sh` writes `tools/contract/build/spinel-typedump`
and `tools/mlir/native/build/bin/`. The native build needs them too: since
[decision 0045](decisions/0045-buffer-classes.md) the CORE reader parses
`Core::Buffer` calls with the vendored Prism. So `tools/mlir/native/build.sh`
links `vendor/spinel/build/libprism.a` with the headers under
`vendor/spinel/vendor/prism/include`, and it stops with a message when
`make -C vendor/spinel deps`, and the vendor objects that
`tools/contract/build.sh` makes, have not run first.

Each of the two build scripts also writes `source-stamp.tsv` beside what it
built: a digest of every source input it compiled, and for the reader the vendor
sources it linked. The kernel's stamp also has the vendor `Makefile`, which names
the Prism version, and a digest of the Prism sources and headers it was built
with. Every test lane that takes the kernel, a tool of the native
build or the reader compares the stamp with its own tree before it uses one
(`tools/test/source-stamp.sh`, `tools/test/source-stamp.rb`), and refuses a
binary built from other source, naming the inputs that differ.
`tools/core/spinel-core-build` itself does not check, so that it needs no Ruby. A binary copied for a long run must be copied
with its stamp (`cp -a` of the directory keeps it). Ruby is needed to write it.

Then run the acceptance checks:

```sh
SPINEL_CORE_BUILD=tools/mlir/native/build tests/core/run.sh
```

It prints one line per check and a final count, and exits non-zero if any check
fails. On this Debian baseline it is 33 passed, 0 failed.

The decision 0007 CORE boundary has its own nine suites and a runner over all
of them, which need only the native build and a C compiler — `adapter.sh` also
needs the pinned compiler:

```sh
tests/core-boundary/schema.sh      # the contract file and its generated header
tests/core-boundary/arithmetic.sh  # the checked scalar kernel, built and run
tests/core-boundary/buffers.sh     # the checked buffer boundary, built and run
tests/core-boundary/adapter.sh     # the Full adapter, the Ruby module, packaging
tests/core-boundary/capabilities.sh # the extracted DOOM helpers
tests/core-boundary/framebuffer.sh # the extracted DOOM framebuffer kernels
tests/core-boundary/slots.sh       # the extracted DOOM slot and link state
tests/core-boundary/artifacts.sh   # every capability through the adapter too
tests/core-boundary/closure.sh     # what a whole-DOOM closure would still need
tests/core-boundary/run.sh         # all nine, with their counts and statuses
```

What the suite is offered as, and what it is not, is in
[the stage-1 capability](core/stage1-capability.md).

`run.sh` reports THREE outcomes, not two. A lane that passed and a lane that
could not run are different answers, and a summary folding them together would
report a clean sweep on a machine where part of it never executed. That is not
hypothetical: on macOS with the default Ruby 2.6 the closure lane met a
`LoadError` for Prism in the middle of its census and reported 30 of 33, which
reads as a disagreement about the tree rather than a missing dependency. The
lane now states that requirement before it starts, and `run.sh` counts it as
`NOT RUN` with the reason. `REQUIRE_ALL=1` makes a lane that could not run a
failure. The lanes' own summary lines are printed verbatim rather than
reformatted, because they do not measure a common thing.

`adapter.sh` is the only suite that uses the pinned compiler. It looks for it
in this checkout's `vendor/spinel/bin` and, failing that, in the main
checkout's — a git worktree does not carry the submodule — and never on `PATH`.
`SPINEL=<pinned binary>` overrides it.

On this Debian baseline, with clang 23.1.1 and ruby 3.3.8: schema 73 passed,
arithmetic 171 passed with 66 of 66 cases executed, buffers 115 passed with 53
of 53 executed and both the `address` and `undefined` sanitisers run. `arithmetic.sh` builds a
kernel per case with `spinel-core-kernel`, calls it from a generated C harness,
and needs `ruby` for its language oracle. `BOUNDARY`, `KERNEL`, `CORE_CHECK`
and `CC` override the tool paths; `LLVM_PREFIX` supplies the default compiler.
See [the CORE buffer boundary](core/buffer-boundary.md) for what those three
establish, for the contract-file route through `spinel-core-kernel`, and for the
generated Full adapter the Ruby caller uses.

`capabilities.sh` and `framebuffer.sh` are the decision 0007 task 5
extractions. Neither writes an expected answer down. `capabilities.sh` loads
`examples/doom/lib/doom/fixed.rb` unmodified and asks it; `framebuffer.sh`
drives `Doom::JobExecutor`'s own `exec_wall`, `exec_span` and `exec_masked`
over a schedule and keeps the screen they draw. The extracted Ruby has to
agree, and then the CORE objects, called from C, have to agree with what the
original drew -- all 3072 bytes of it, including the bytes no job should have
touched. The C harness draws nothing of its own, so no C reference stands
between Full and CORE. Both lanes need `ruby`; `KERNEL` and `CC` override the
tool paths. On the same baseline: capabilities 49 passed, and framebuffer 22
passed with 15 jobs, 24 status-ABI cases and 10 mutation controls; adapter 62
passed with 45 of 45 executed. The hardening of 2026-09-12 added one
original-digest check to each of capabilities, framebuffer and slots, so those
lanes now count 50, 23 and 25; see [provenance](provenance.md).

`slots.sh` is the third, and it is the one that needs a reference model rather
than only the original. The thinker list and the mobj allocator are pointer
surgery, so a second spelling of the same surgery agreeing with the first would
show the transcription was faithful and nothing more -- a transposition would
be copied across and agree. `fixtures/slots/model.rb` keeps an ordered Array
and a stack and DERIVES what the link fields must contain, never assigning one
from another, and all three worlds must agree on the status, the result and
every cell after every operation. It earned its place twice while being
written: a slot swept off the live list keeps its stale `th_next`, and a mobj
taken off the free list keeps its stale `thing_next`, because neither Z_Free
nor the allocator clears the field it read. Measured here: 24 passed, with 48
operations -- 34 over 258 thinker cells and 14 over 66 mobj cells -- 39
status-ABI cases, exhaustion at the original's own 4095 thinkers and 4096
mobjs followed by a sweep of the full list, and 11 mutation controls, two of
which break the model itself.

`artifacts.sh` asks the other half of the question the three capability lanes
ask. Each of those holds a capability to the original Full code through a C
harness that calls the CORE entry directly; this one runs the same capability
again through the FULL ADAPTER -- the registry, an allocation per buffer, an
`invoke` over ids, a `load` per cell -- and requires the same answer. It is the
same harness either way: each fixture's `harness.c` compiles twice, once
plainly and once with `-DSPINEL_VIA_ADAPTER`, so the parsing and the comparison
are one source and a difference in the answer is a difference in the boundary.
That the adapter build really is a second path is itself checked: the same
source and the same define, linked WITHOUT the adapter sources, has to fail --
a build needing nothing from the registry is not going through it, and a
mis-spelled define would otherwise compile a second copy of the direct build
and compare it with itself.

It also reads each object's undefined symbols out of the symbol table, with
nothing exempt: there are none at all, because these entries answer with a
status rather than trapping, so not even the trap hook is wanted. A control
compiles an object that does need the host and requires the same reader to
report it. Every one of the thirteen entries generates the same registry source
and header, compared entry by entry rather than once per capability, and each
capability packages and verifies while a sibling entry's object in its place is
refused. Measured here: 30 passed over 13 entries.

The two paths do not share everything, and the difference is checked rather
than assumed. A refused `invoke` POISONS the mutable participants, so a Full
caller cannot read a half-written buffer at all where a direct C caller reads
whatever the kernel wrote before the access that failed. That also means a Full
caller who exhausts a fixed capacity loses access to the arrays, where the
hosted game raises and carries on with the list intact; `slots.sh`'s exhaustion
is ordered so that everything checkable on both paths happens before the
refusal that poisons.

`closure.sh` is task 5's last bullet, which asks for the remaining whole-DOOM
gaps to be recorded as stage-2 design input. A record of that kind rots
quietly, so the record in `docs/core/doom-closure-gaps.md` is written from two
things this lane measures and is required to agree with them: a probe per
construct, asking the checker what it does with each and requiring the answer
the record states (for what is ADMITTED as well as for what is refused), and a
census of every `def` in `examples/doom/lib/doom/` counted by which refused
constructs appear in its body or parameters. Every count has to be on its own
category's row of the record, not merely somewhere in a file full of numbers,
and the record's calibration methods have to be filed on the side the census
put them. Measured at `57bcc74` and recorded in [provenance](provenance.md):
32 passed over 27 constructs, with 571 `def`s and a further 381 accessor
methods over 33 files, and 72 of the `def`s holding nothing the subset
refuses.

The lane builds its probes and runs nothing, which is stated in the record: the
admitted ones are known to compile and no more, except the ternary, which
`capabilities.sh` exercises against the original for thirty cases.

Full and CORE part company in three places here and each is pinned by a pair
of cases rather than left to be discovered. An index off the end of an array
is `SPINEL_CORE_BOUNDS` where a Ruby Array grows or reads nil. An index BELOW
it is the direction where the original is not merely different but wrong:
`remove_thinker(-1)` counts from the end in Ruby and silently marks the last
slot, which the next sweep then frees. And a `func` or `data` outside what an
i32 cell holds is `SPINEL_CORE_ARITHMETIC` where CRuby stores it without
comment. The sweep also carries the one adaptation in task 5 that is not a
spelling change: it is bounded, so a `th_next` chain that closes on itself
answers `SPINEL_CORE_CAPACITY` instead of walking forever as the original and
vanilla do.

`framebuffer.sh` carries one Full/CORE divergence deliberately, because it is
real rather than avoidable. CRuby integers are arbitrary precision, so the
original draws for every `texmid`; the kernel computes in i64 and answers
`SPINEL_CORE_ARITHMETIC` once `texmid + (yl - centery) * iscale` overflows.
Two of the status-ABI cases pin where that starts. The kernels also address
the screen as one linear buffer, which is what the contract declares, so the
boundary they enforce is that buffer's end rather than the right-hand edge of
the picture; keeping `x` below the width stays the caller's obligation, as it
is in `R_DrawColumn`.

`CLANG` selects the C compiler used for the host program, and **defaults to the
clang the build directory was configured with**, read back from its CMake
cache -- not to whatever `clang` is on `PATH` -- so the host program and the
object come from one LLVM. `spinel-fs-emit` runs no clang: `spinel-fs-codegen`,
built against the same LLVM, writes the object. A `CLANG` that does not match
is refused before any check runs, with both versions named. `SPINEL_TYPEDUMP` overrides the contract reader path,
and `NM` overrides the symbol reader.

What the checks establish: a declaration is emitted to an object and a header;
the object's only undefined symbol is the declared trap hook, confirmed both by
the gate's verdict and by reading the symbol table directly; an ordinary C
program links it and gets the expected values at and inside the boundary; a
return outside the declared width traps; an internal arithmetic overflow traps
through a different path on a separate kernel; and array indexing, string
literals and undeclared calls are refused while a conforming kernel still
emits.

These freestanding checks do not exercise the hosted-to-core connection. That
path has its own [native executable checks](native-core/reproducing.md).

## Word intrinsics (decision 0022)

A checked CORE closure behind the status boundary can call the 32-bit word
intrinsics:
- `core_w32_add`, `core_w32_sub`, `core_w32_mul` and `core_w32_neg` wrap;
- `core_u32_lt`, `_le`, `_gt` and `_ge` compare as unsigned words;
- `core_u32_shr` shifts right logically;
- `core_fixed_mul` and `core_fixed_div` are DOOM's fixed-point operations.

Every operand must be an i32, or the call is ARITHMETIC. Ordinary arithmetic
stays checked. The table is `tools/mlir/native/include/spinel-mlir/Core/Intrinsics.h`.
Plain Ruby gets the same answers from `tools/core/intrinsics.rb`, which the
session host loads and which is never packed. `tests/core-boundary/intrinsics.sh`
runs the decision's table on the host as int64 bodies, the refusals, the
prelude and the Thumb lowering. `tests/core-boundary/intrinsics-board.sh`
runs the 32-bit cases on the FRDM-IMXRT1186, since a 32-bit body needs a
32-bit target.

## Finding where a CORE entry failed

A failed call answers a status, ARGUMENT, ARITHMETIC, BOUNDS or CAPACITY,
and nothing about where it failed. To find the place, build the entry with
`--failure-sites FILE`. This is a debugging aid and is off by default. Without
the option the object has no site symbol and no site store, and
`tests/core-boundary/failure-sites.sh` checks that.

- **What it changes.** With the option, every place a failure starts stores
  its site's id in `spinel_core_<entry>_failure_site`, an exported `int32_t`,
  before the status returns. These are the checked operations, the bounds and
  narrowing checks, the extern guards and `core_fail(:capacity)`.
  - A callee's failure passed up by its caller stores nothing, so the global
    holds the innermost site.
  - The wrapper writes 0 on entry, so a site read after a failed call belongs
    to that call. 0 after a failure means the wrapper's own argument checks
    refused it.
- **What it does not change.** The status ABI and the result are unchanged.
- **The table.** `FILE` lists each site: id, file, line, column, status and
  operation.

```sh
tools/mlir/native/build/bin/spinel-core-kernel k.contract --root DIR -o k.o \
  --header k.h --clang "$CLANG" --failure-sites sites.tsv
```

A C caller declares `extern int32_t spinel_core_<entry>_failure_site;` and
reads it after a failed call.

**For DOOM's entries on the host**, `DC_FAILURE_SITES=1` builds
`tests/doom-core/harness/artifacts.sh`'s entries this way, and builds their
adapters with `spinel-core-adapter --failure-sites`.

- A failed call through `bound` or the other host programs then prints
  `spinel-core: <entry> answered <status> at failure site <id>`.
- `ruby tools/doom/failure-site.rb --build DIR` reads those lines. Through
  the entry's `sites.tsv` and pack map it names the CORE unit, the line and
  the operation.

## The CORE build report

Decision 0010 step 1 gives `spinel-core-kernel` a per-entry build report:
every loop in the entry's closure with its derived bound or the reason it has
none, and the entry's work bound, under profile `hosted-stage2` in observe
mode. Step 2 adds the stack budget: every function's frame size, the worst
path through the final call graph, and `kernel_stack`.
[The CORE build report](core/core-report.md) describes both.

```sh
spinel-core-kernel app.contract --root DIR -o app.o --clang "$CLANG" \
  --report app.report.json --profile hosted-stage2
```

The report refuses nothing and changes no object. Three runs check it:

- **`tests/core-report/run.sh`.** It covers:
  - the report flags;
  - byte identity of the object, header and MLIR with and without the report;
  - every fixture's loop bounds and reasons against
    `tests/core-report/expect.tsv`;
  - schema validation, with a validator self-test;
  - the canonical JSON the goldens are written in, byte for byte against
    `tests/core-report/fixtures/canonical.json`, so a change in Ruby's json
    library fails there and not in a golden on the other host;
  - a CRuby oracle that runs the fixtures and compares the iterations they
    count with the reported bounds;
  - the golden reports;
  - digest stability.
- **`tests/doom-core/loop-reports.sh OUTDIR`.** It builds all 27 kernel-built
  DOOM entries three times each, checks the same identity, validates every
  report, and writes the unknown-loop catalogue and a summary into `OUTDIR`.
  `OUTDIR` must be outside the checkout, because DOOM reports are regenerated
  evidence and are not tracked.
- **`tests/core-stack/run.sh`.** Decision 0010's step 2 proof-of-concept
  acceptance and nothing else: the frame-size diagnostic against ELF
  `.llvm_stack_sizes` per function, a painted-stack run that stays within the
  static `kernel_stack`, a large frame and a deep acyclic chain reported
  correctly, and a dynamic `alloca` refused under `realtime`. `REAL_IR`, a
  directory of `.bc` files left by `--emit-optimised-ir`, adds the first item
  over real entries; without it that part skips.

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 REQUIRE_ALL=1 sh tests/core-report/run.sh
LLVM_PREFIX=/opt/llvm-23.1.1 REQUIRE_ALL=1 sh tests/core-stack/run.sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/doom-core/loop-reports.sh /path/outside/loop-reports
```

Both take `KERNEL`, `SPINEL_TYPEDUMP`, `CLANG` (or `LLVM_PREFIX`) and `RUBY`
from the environment.

- **`BASELINE_KERNEL`.** Set it to a kernel built without the report change,
  for example from the branch's starting revision. Every plain object must
  then also equal the one that kernel builds, which is what establishes that
  observation did not change the artifact.
  - **A gate sets it.** A gate runs with `REQUIRE_ALL=1`, which makes any
    check that did not run a failure, so a green gate run has zero skips and
    has made that comparison. A bare local run without it reports one skip and
    is still useful, which keeps the cheap run cheap.
  - When `REQUIRE_ALL=1` fails for this reason, build the baseline kernel.
    Unsetting `REQUIRE_ALL` turns the missing check back into a silent skip.
- **`UPDATE_GOLDEN=1`.** It rewrites the golden reports and the canonical JSON
  fixture instead of comparing them, and counts those comparisons as skipped.
  It is **refused together with `REQUIRE_ALL=1`**, because a run that rewrites
  the files it compares would compare each with itself.

## Verifying DOOM's three CORE entries

`tests/doom-core/verify.sh` checks decision 0008's three entries,
`doom_core_input`, `doom_core_step` and `doom_core_render`. They are generated
by `tools/doom/core-entries.rb`. The script runs these parts:

- `tests/doom-core/entries.sh`: the entries are what the generator writes, and
  the field map holds against the generated layout.
- `tests/doom-core/input-diff.rb`: the input entry against the original input
  step.
- `tests/doom-core/content-scan.rb`: the ledger's claims that the shipped IWAD,
  or any content, never runs a definition or a branch of one. Each is checked
  against the pinned IWAD and the original library, with planted inputs that
  must be refused.
- `tests/doom-core/refusals.rb`: every "not implemented" raise of the original,
  and what shows that the port stops where the original does
  (`tools/doom/core-refusals.tsv`).
- The kernel build of all three entries, from
  `examples/doom/core/entries/units.tsv`, with the link rule applied to each
  object.
- `tests/doom-core/step-diff.rb` and `tests/doom-core/render-diff.rb`, over every
  tic of DEMO1, DEMO2 and DEMO3, in job mode 1.
- A render run at `--scale 2`, which covers the status bar's shadow path.
- `step-diff.rb` over the synthesised starts in `tests/doom-core/scenarios.rb`:
  the definitions the shipped IWAD reaches and no demo does. Each scenario must
  enter its targets. Six are witnesses that the port stops where the original's
  "not implemented" raises stop it: at the same tic, in the named port
  definition.
- `tests/doom-core/step-coverage.rb`: the step lines those runs executed, which
  is the denominator of their zeros.
- Full's job-mode-1 route (`examples/doom/core/full/route.rb`): the built
  entries through their generated adapter, driven over every tic of each demo
  by `tests/doom-core/route-demo.rb`. It checks two things:
  - the route's screens against the original's recordings
    (`tests/doom-core/fixtures/screens`);
  - its state at checkpoints against the original's, run in job mode 1 by
    `tests/doom-core/route-reference.rb`. Three named cells are compared at
    session open only (`tests/doom-core/route-lane.rb`).

  Planted controls cover the mode assertion, the rebirth refusal, both
  comparisons and those cells. `tests/doom-core/graph-guard.rb` checks that a
  reference reads the program's own objects.
- `tests/doom-core/native-scenario-diff.sh`: the same 19 scenarios, run against
  the COMPILED step entry over the library the route part linked. The demos
  cover E1M5, E1M3 and E1M7, so without this the definitions only the scenarios
  reach were compared in CORE-source execution alone (decision 0009's
  clarification of 2026-09-18). Each scenario's two sides evolve independently
  from one prepared start; scalars are compared after every tic and all of the
  state after the first tic and after the last. A scenario that stops must stop
  in the same tic on both sides, in two runs. Two controls plant a difference
  into the compiled side's live state: a scalar, caught in its own tic, and a
  cell of an array nothing reads, which only the full comparison can catch.
- `tests/doom-core/native.sh`: the playable program itself.
  - `examples/doom/bin/doom.rb -core` is built by the pinned compiler with the
    entries (`examples/doom/build.sh CORE_DIR=...`) and plays DEMO1-3. Every
    frame must match the recording.
  - The session it opens must equal the route's at session open. This checks
    transport, not value: both sides read the same objects.
  - Its catalog must equal `Resources.catalog`'s, count for count.
  - A build without the entries must refuse `-core` and still play the old
    paths.
  - Controls are planted on live paths: a call into the sealed original game, a
    mode cell that is not 1, a pending rebirth, and a generated read that stores
    a wrong value.

`tests/doom-core/bound-resources.sh` covers decision 0021's resources at an
address the boundary did not allocate. `verify.sh` runs it after `native.sh`,
passing its own kernel build as `CORE_BUILD`. Run alone, the lane takes
`CORE_BUILD`, a kernel build of the three entries in `verify.sh`'s layout
(`DIR/build`), because building one takes about eight minutes. It generates the
adapter itself, and does the following:

- it plays DEMO1 over allocated storage;
- it writes the session image with `tools/doom/session-image.rb`;
- it maps the image's resource part with `PROT_READ` and binds every resource
  to it;
- it requires every frame to equal the allocated run's and the recording;
- it requires a write to a bound resource, and four bad binds, to be refused by
  message;
- its control, an image with an inverted colormap, must play other frames.

```sh
CORE_BUILD=/path/to/verify-dir/build WAD=/path/to/doom1.wad LLVM_PREFIX=/path/to/llvm \
  READER=/path/to/spinel-typedump sh tests/doom-core/bound-resources.sh DIR
```

Measured on Debian: 162 s.

`tests/doom-core/rt1186.sh` is decision 0021's board lane: DOOM's three entries
on FRDM-IMXRT1186, one demo per NOR write. For each demo it:

- builds the entries for thumbv8m.main (or, with `RT1186_CORE=cm7`, for the
  board's Cortex-M7, thumbv7em: decision 0023) with their reports, recording
  the runtime helpers they call;
- writes the demo's session image (`tools/doom/session-image.rb --demo`);
- builds `examples/doom/core/board/app.rb` with that image;
- assembles the NOR image of program and session
  (`tools/doom/nor-image.rb`).

It also runs `tests/app/session.sh` over DEMO1's image.

With a board (`RT1186_HOST`, the ssh destination of a Linux host with
LinkServer and the board's MCU-Link; `tests/doom-core/harness/rt1186-host.sh`),
and only when every check before the board part passed, it then writes each
image and reads the console from the lane's own reset. A write that fails, or
whose log does not say it finished, is a failure, and that demo's console is
not read: the board then holds an earlier image.
The console length just before that reset is recorded. The run is read from
the first boot after it, so the earlier run that the write's reset started is
not read. `tools/doom/board-frames.rb` decodes the loop's lines from 0014's
transport frames (0xA5, channel, length, payload). Each frame is
`F <tic> <view fnv> <full fnv> <cycles>`: the board computes no SHA-256
(0021, the owner's decision of 2026-10-21). It refuses a broken frame, a
second boot, a fault or a refused session. It requires the run to print
`SPC_SESSION_ID <id>` once, before its first frame, with the id of the build
the lane wrote (`build.json`'s `session.id`, a digest of the application,
the board, the image and the entries' objects), so a console from earlier
firmware is never judged as this build's. It requires every frame to be the
recorded one, in order, and the demo to end; the per-tic time is
reported as information. With `TICS=N` it reads the console until the N-th
frame and checks only the first N, without waiting for the demo to end:
`DEMOS=DEMO1 TICS=500` is about 14 s of DEMO1 and 80 s on the board, the
check the 32-bit work and `tools/test/affected.rb` use. Planted consoles
check each refusal without a board, and `tests/doom-core/board-controls.sh`
(which the lane runs) drives the board part itself with a planted write and
console: a failed write is not read, and a wrong frame or another build's
console fails the lane's own check, with `TICS` and without. Without a board the board part is a
named skip. The board loop is **not a realtime claim**, and the summary line
says so.

```sh
WAD=/path/to/doom1.wad LLVM_PREFIX=/path/to/llvm ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... \
  [CORE_BUILD=/path/to/verify-dir/build] [THUMB_BUILD=DIR/thumb] [RT1186_CORE=cm33|cm7] [RT1186_HOST=user@host] \
  sh tests/doom-core/rt1186.sh DIR
```

With `RT1186_CORE=cm7` (decision 0023) the application is built for
`frdm_imxrt1186_cm7`, with the M33 launcher, and the NOR image holds the
launcher, the M7's program at 0x100000 and the session. On the Mac, with
`DEMOS=DEMO1 TICS=500`, the lane took 719 s without a board (thumbv7em entries
165 s, the host kernel 278 s), and 342 s with the board, reusing that run's
`THUMB_BUILD` and `CORE_BUILD`. That run's per-tic median was 38.2 ms
(2026-10-21; information).

Measured on Debian without a board, with `CORE_BUILD` given: 491 s, 16 checks.
Building the thumbv8m entries took 265 s of that; without `CORE_BUILD` the host
kernel build adds about eight minutes. The NOR images are 16,226,325,
16,255,101 and 16,245,541 bytes for DEMO1-3.

**Stage times on the board (a measurement, not the acceptance).**
`examples/doom/core/board/profile.rb` is `app.rb`'s loop with `Clock.cycles`
read between the stages:
- the stages are input (the command decode), step, cells, render and the
  FNV digests;
- every tenth tic it writes a `T` line after its `F` line, with each stage's
  cycles, the F line's total, the line's formatting and its `Console.put`,
  and the wall time since the previous tic.

The time a line spends on the UART is not measured: the transport thread
writes it while the loop sleeps. `tests/doom-core/rt1186-profile.sh LANE_DIR
DIR` builds the variant with a finished `rt1186.sh` run's entries and image
and writes it to the board. `tools/doom/board-profile.rb` then judges its
frames with `board-frames.rb` and writes `stages.tsv` and `summary.txt`
(min, median, p90 and max per stage, in ms at the build's
`CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC`: 240 MHz on the M33, 792 MHz on the M7). It needs the same
environment as `rt1186.sh`, with `RT1186_HOST`, and takes `RT1186_CORE` as it
does. On the M7, the PC sampler's record is read through `--core cm7`
(`RT1186_GDB_CORE`). `tests/doom-core/profile.sh
DIR`, with `SESSION_IMAGE` set to DEMO1's image, checks the variant and the
reader without a board.

**The board's frames on a host (decision 0024).** `tools/doom/net-viewer.rb`
receives the frames the board sends over UDP, shows them, and checks each
one's view and full FNV-1a 64 against the board's own `F` line for its tic.
The board side is 0014's `udp:` transport and the application's frame
channel: `examples/doom/core/board/app.rb` sends its frames through the M33,
and the viewer takes them live from the port or from a recording. On the
board, the frames were recorded on the Mac as they arrived and checked with
`--replay --console`: all 260 that arrived of DEMO1's first 500 tics matched
the console ([0024's validation](decisions/0024-doom-frames-over-the-network.md#clarification-2026-10-22-validation-measured)),
and the owner's play gave 7,119 complete frames, none incomplete, late,
duplicated or backwards ([0025's validation](decisions/0025-doom-play-over-the-network.md#clarification-2026-10-23-validation-measured)).
The wire is version 3 (decision 0025 point 15): one datagram per channel
message, each opening with its kind, the version and the boot id. A message
of any kind with another version, version 2 included, is bad.
- `P`: the palette, 768 RGB bytes, at boot and every second.
- `C`: the tic, the piece's index and count, the tic's input (the
  controller's session id, the sequence number it used and its state: none,
  held or released by the time-out), then 1,280 bytes of the 8-bit screen.
  A frame is 50 pieces, and all 50 carry the same input; a frame whose
  pieces disagree is incomplete.
- `S`: the M7's counts since boot, every second.

The M33 sends no report of its own, so a `T` (0x54) is a bad datagram of an
unknown kind.

Boots are never combined. The console's `B` line names the boot that is
judged.

```sh
ruby tools/doom/net-viewer.rb [--port 5029] [--record run.rec] \
  [--console console.log] [--show ffplay] [--aspect 1:1|4:3|fill] [--scale 2]
ruby tools/doom/net-viewer.rb --replay run.rec --console console.log --log frames.tsv
```

- **Receiving.** A child process only receives and appends each datagram to
  the recording, and the viewer reads behind it.
- **The summary counts:**
  - per boot: complete frames (and those before the palette), incomplete
    and absent frames, late, duplicate and backwards pieces, the latest
    `S`, and the complete frames by their input's state, with the frames
    whose pieces disagree on it;
  - bad datagrams, by reason;
  - with `--console`, the frames that match or differ from their `F` lines;
  - the frames missing against the board's `N <frames dropped> <messages
    dropped> <frames not sent>` line, so the rest is what the network lost.
- **Exit status 1** when a datagram is bad, when a boot's tics go backwards
  (two boots sharing an id) or an `S` does not add up; and, with `--console`,
  when it has no `B` line or two, when its boot sent nothing, when a
  frame differs, when no frame matched (nothing received is no evidence), or
  when the network lost more frames than `--max-loss` (0 unless given;
  judged only when the console has an `N` line).
- **Speed.** The viewer kept up with 500 frames sent at 19 ms each over
  loopback (Debian, 2026-10-22).

`tests/doom-core/net-viewer.sh DIR` checks it in about a second. It feeds
planted datagrams and a planted console, whose digests come from
`examples/doom/core/board/frame_digests.c` compiled for the host. Its failing
controls include a changed `F` line, a flipped screen byte, bad datagrams
(boot id 0, version 1, an unknown kind, a `T`), a run in version 2, pieces
whose input fields contradict each other, a tic going backwards, an `S` that
does not add up and the `B` line's faults. Two boots interleaved, a viewer
that starts before the palette, and a frame whose pieces disagree on the
input (incomplete, its `--log` row `mismatch`) are admitted.

**The SDL2 viewer.** `examples/doom/net_view/net_view.rb` shows the same
frames in a window. It is Ruby compiled by Spinel, as `bin/doom.rb` is.
- **Showing.** It passes the palette and the 8-bit screen to `Doom::Video`
  (`examples/doom/native/sp_sdl_shim.c`) as they are.
- **Receiving.** The socket is `sp_udp_shim.c`, beside it. It reads version 3
  of the wire (decision 0025 point 15).
- **Boots.** Boots are never combined, and the window shows the newest boot.
  A board that restarts is followed to its new boot, and the frames of any
  other boot are counted as not shown. The summary has a line per boot, with
  its latest `S`. A `T` (0x54) is a bad datagram, as in `net-viewer.rb`.
- **Judging.** It judges nothing; its `--record` file is the form
  `net-viewer.rb --replay` reads.
- **Frames shown.** It shows the newest complete frame. A frame a newer one
  replaced before it could be shown is counted as not shown. `--fps` limits
  the rate only when given, since the board already sends at most 35 a
  second.
- **Keys (decision 0025).** Only live, and only with `--keys ADDR:PORT`
  (the board's address and its inbound port) or `--keys PORT`. With a port
  alone the keys go to the source address of the first datagram of the boot
  shown, so a board on DHCP need not be known. A new boot is followed to its
  own source; a datagram of the same boot from another address changes
  nothing. The viewer prints `keys to ADDR:PORT for boot ID` when the
  destination is set. The viewer chooses a
  controller session id at start, and sends nothing until it knows the boot
  it shows. It then sends a 17-byte `K` message from its receiving socket at
  35 a second and on every change of the 18 `WATCHED_KEYS`. The keys are read
  after each pump, as `bin/doom.rb` reads them. Each send advances the sequence
  number by 1, modulo 2^32. Without the keyboard's focus every key is sent
  released, and at the end one all-released message is sent, best effort.
  `--script FILE` takes the keys from a key script in place of the keyboard.
  The keyboard's focus is read by `sp_focus_shim.c`, beside it.
- **Latency.** With `--keys`, a complete frame of this session's held input
  is matched on (boot, session, sequence) to the time that message's keys
  were sampled, once at receipt and once at the call of `present`. The summary
  gives each span's count, minimum, median and maximum in microseconds.
  Neither is when the frame appeared on the screen.

```sh
LLVM_PREFIX=/path/to/llvm sh examples/doom/net_view/build.sh build/net_view
build/net_view [--port 5029] [--bind ADDR] [--record run.rec] [--scale 3] \
  [--keys [BOARD_ADDR:]5030 [--script keys.txt] [--first-seq N]]
build/net_view --replay run.rec [--fps 35] [--hold]
```

`tests/doom-core/net-view.sh DIR` builds it and runs it on SDL's dummy video
driver in about thirty seconds. It replays planted datagrams, receives them
over loopback UDP, compares the BMP of the frame shown with the palette's
colours, and reads the recording with `net-viewer.rb`. It also checks two
boots kept apart, each in its own palette, and a palette that arrives late or
changes. Against a planted board over loopback it checks the `K` messages
(their shape, session and boot, the sequence numbers wrapping past 2^32 − 1, a
scripted key, the release at the end) and the latency matching. With
`--keys PORT` it puts the board on 127.0.0.2 and checks that the keys reach
the boot's source and follow a new boot to 127.0.0.3. Those checks are skipped,
named, where 127.0.0.2 cannot be bound; macOS has only 127.0.0.1 on loopback
unless an alias is added. Its failing controls are:
- a missing piece;
- bad datagrams (boot id 0, version 1, an unknown kind);
- a run in version 2, all bad;
- a piece that disagrees with its frame on the input;
- frames carrying another session's input, input released by the time-out,
  no input, or a sequence never sent, none of them matched;
- half of each frame's pieces sent from another address, which must not
  move the keys' destination;
- `--keys` with `--replay`, `--script` without `--keys`, and a malformed
  `--keys`, each a usage error;
- a `T`, counted as bad with the boot's counts unchanged;
- a tic going backwards;
- a changed screen byte;
- a cut recording;
- an unknown option.

```sh
WAD=/path/to/doom1.wad LLVM_PREFIX=/path/to/llvm \
  SPINEL_TYPEDUMP=/path/to/spinel-typedump \
  ADAPTER=/path/to/spinel-core-adapter REQUIRE_ALL=1 \
  sh tests/doom-core/verify.sh
```

`ADAPTER` defaults to `tools/mlir/native/build/bin/spinel-core-adapter`.
`SPINEL` and `SPINEL_LIB` select the pinned compiler and its runtime for the
native part. They default to `vendor/spinel/bin/spinel` and
`vendor/spinel/lib`.

**Those defaults do not resolve in a git worktree.** A worktree does not get the
`vendor/spinel` submodule — the directory is there and empty — so
`$ROOT/vendor/spinel/bin/spinel` does not exist and `native.sh` skips its lane
for a missing compiler. Under `REQUIRE_ALL=1` that skip becomes a failure, so it
presents as the playable program failing rather than as an absent file:

```
FAIL the playable program, through the entries (native.sh) (got 'rc=1|0', want 'rc=0|1')
  SKIP the playable program's lane: it needs CORE_DIR, ROUTE_DIR, the IWAD,
       LLVM_PREFIX and the pinned compiler
```

This is the normal invocation on macOS, not an edge case: the main checkout is
usually held by another agent, and switching its branch is not done, so the lane
runs from a worktree. `native.sh` takes both variables for exactly this —
`SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}` and
`SPINEL_LIB=${SPINEL_LIB:-$ROOT/vendor/spinel/lib}` (lines 32-33 at the time of
writing) — so point them at a checkout that has the built submodule:

```sh
export SPINEL=/path/to/main-checkout/vendor/spinel/bin/spinel
export SPINEL_LIB=/path/to/main-checkout/vendor/spinel/lib
```

**Those two are what `native.sh` reads, and nothing else reads them.** Name the
variable each consumer looks at rather than carrying a list, because in a
worktree the wrong one fails as a refusal about the tree:

| the consumer | the variable it reads | default when unset |
| --- | --- | --- |
| `tests/doom-core/native.sh` | `SPINEL`, `SPINEL_LIB` | `$ROOT/vendor/spinel/{bin/spinel,lib}` |
| `tools/core/spinel-core-build` | **`SPINEL_SEAM`** (a checkout, not a binary) | `$ROOT/vendor/spinel` |
| the kernel-building suites, through that script | **`SPINEL_SEAM`** | as above |

Every suite that compiles a core object goes through `spinel-core-build`, which
reads `SPINEL_SEAM` and **ignores `SPINEL` and `SPINEL_LIB` entirely**
(`tools/core/spinel-core-build`, the `SEAM=` line). So in a worktree, exporting
only the first two leaves `source-pack.sh` failing seven checks with

```
spinel-core-build: missing or not executable: <worktree>/vendor/spinel/bin/spinel
```

which reads as the packer refusing the tree rather than as an absent submodule.
Setting `SPINEL_SEAM` took that suite from 73 checked / 64 pass / 9 fail to
74 / 72 / 2 with no other change, so add it whenever the lane is not just
`native.sh`:

```sh
export SPINEL_SEAM=/path/to/main-checkout/vendor/spinel
```

Two more variables belong to the same family, for the same reason. `NM` selects
the symbol reader, and is read by `spinel-core-build`, `tools/core/core-artifact-gate`,
`harness/build-artifacts.sh`, `harness/run.rb`, `state.sh` and `borrowed-calls.sh`;
`SPINEL_TYPEDUMP` selects the contract reader and defaults to
`$ROOT/tools/contract/build/spinel-typedump`, which a worktree also does not
build. Export both alongside `SPINEL_SEAM` for any lane wider than `native.sh`.

**What makes that valid is two facts, and check the second rather than assuming
it.** The first is that the submodule pin is identical at both revisions, so the
compiler is built from the same source the worktree names; `git ls-tree <rev>
vendor/spinel` on each settles it. The second is that the binary you point at
was actually built from that pin, with the required compiler — which is a
property of the artifact, not of the pin. Three records can be made to agree:

- the binary names its own source revision: `spinel --version` prints it, and it
  must equal the pin;
- `provenance.md` records which tree was built with which compiler, and
  distinguishes a worktree's bare-`make` Apple-clang build from the main
  checkout's LLVM 23 one;
- the byte discriminator settles the compiler independently of both. Recompiling
  one runtime source and comparing sizes is the documented method above;
  for the current pin, `vendor/spinel/build/sp_str.o` is 142600 bytes for the
  LLVM 23.1.1 build and 150872 for Apple clang 21 (measured on macOS arm64,
  2026-09-18). These figures are pin-specific; `provenance.md` is where they
  move when the pin does.

**`spinel --version`'s bracketed compiler is not the one that built it.** It
names the C compiler `spinel` will *invoke*, resolved from `cc` on `PATH`, so on
macOS a bare `PATH` prints `[Apple clang version 21.0.0 ...]` for a binary built
entirely with LLVM 23.1.1. Changing `cc` changes the bracket, which is how to
establish what the string means. `native.sh` shims it — `ln -sf
"$LLVM_PREFIX/bin/clang" "$SHIM/cc"` — so the compiler it invokes under the lane
is the required one regardless of what a bare `--version` reports. Read the
bracket as a question about the environment, and the revision beside it as the
provenance claim.

The route part runs after the build, in the background beside the demo runs.

`tests/doom-core/state.sh` and `tests/doom-core/tick.sh` report what they
covered, not only what passed. Each lane they skip is named in the summary,
with its reason and the variable that would enable it. A pass count alone
depends on the environment: without a compiler, `state.sh` checks 251 and
with one it checks 270. With `REQUIRE_ALL=1`, any skipped lane fails the
run.

The build and the demo runs go side by side, and each part prints its wall
time. One run on Debian x86_64 (2026-09-18, nothing else on the host) took
3032 s for 96 checks, and its parts took:

- the kernel build: 642 s;
- step-diff: 523, 415 and 269 s for DEMO1, DEMO2 and DEMO3;
- render-diff: 1990, 1526 and 864 s;
- the scaled run: 152 s;
- the 19 scenarios with their controls, in CORE-source execution: 136 s;
- the build and the demo runs together, side by side: 2053 s;
- the route's adapter generation and link, after the build: 275 s;
- the route: 484, 384 and 250 s;
- the playable program: 338 s;
- the same 19 scenarios through the compiled step entry: 240 s;
- the capacity contract: 952 s.

Before that lane existed, the two-host gate at `02f7375` ran 94 checks in one
invocation on each host: 2955 s here and 3755 s on macOS arm64.

render-diff over DEMO1 sets the total. The step lines were last reported as
6642 of 8023 (82.8%), on 2026-09-18, with 13 definitions entered by the
scenarios and by no demo. The kernel runs each pass of its contract
reader under a fixed 30 s limit, and one pass over the packed entries takes
about 17 s. A heavily loaded host can therefore fail the build with no change
in the tree. This is an open item; until it is settled, run this lane with
nothing else on the host.

**On macOS "nothing else on the host" is not available, and reading your own run
as clean because you started nothing is the mistake that precondition invites.**
The machine does its own work: `mediaanalysisd` and Spotlight's
`mdworker_shared` were measured between 18 and 68 per cent of a core while a
lane was being set up on 2026-09-18, and the one-minute load average has been
seen above 200 with nothing of the operator's running. So:

- **Sample the load through the run and report the distribution, never two
  endpoints.** A start and an end reading once produced "started at load 210"
  for a run whose median was 24.8 — the 210 was the operator's own linkers
  decaying out of the one-minute average, which two samples cannot show and
  twenty-two can. One `uptime` every 120 s alongside the lane is enough.
- **Keep Spotlight out of the build.** An empty `.metadata_never_index` at the
  root of the worktree stops the indexer walking the build tree, needs no
  privileges, and is the difference between competing with the indexer and not.
  A throwaway worktree leaves it behind as an untracked file, which nothing in
  the lane asserts on.
- **Check for stray work of your own before timing anything**, including
  background loops left by an earlier run: `ps aux | sort -rnk 3 | head` names
  the consumers, and their `TIME` column says whether a long-lived process has
  actually cost anything or has merely been alive.

`DEMOS` narrows the demo set and
reports the rest as skipped. `SCALED_FRAMES` sets the length of the scaled run
(default 200).

## Selecting the tests a change reaches

`tools/test/affected.rb --base REV` reads the change from `REV` to the
working tree, untracked files included. It prints the test commands that
change reaches, each with the reason that selected it: which file, and for
CORE source which definition and which entry.

- **Tables.** A file maps to tests through `tools/test/affected.tsv`, where
  the first row that matches applies. The tests and their commands are in
  `tools/test/tests.tsv`.
- **CORE source.** A change under `examples/doom/core/src` is placed in the
  definitions it touches, from Prism's line ranges. It reaches an entry
  through `tools/doom/core-migrated.tsv` and the audit's closure, given
  with `--closure` or run here with `SPINEL_TYPEDUMP`.
- **Excluded.** Comparisons with CRuby or its recordings are named under
  `excluded` and never selected to run, and so are the oracle sections of
  the tests it does select (`tests/ORACLES.tsv`).
- **Unmapped files.** A changed file no row matches is listed as
  `unmapped`, and the run exits 1.
- **Known failures.** `tools/test/known.tsv` lists failures a test already
  had without the change, with the revision that showed it, and the reason.
  The preprocessor prints each one under its test.
- **Pinned files.** A changed file `tests/doom/manifest.tsv` pins by digest
  also selects `tools/doom/verify-sources.sh`.
- **Coverage.** `--scope PATH...` lists the tracked files under those paths
  that no row matches. The trees of the 32-bit work (`tools/mlir/native`,
  `tools/app`, `examples/doom/core`, `tests/doom-core`, `tests/app`) are all
  covered.

`tests/affected/run.sh DIR` holds the preprocessor to planted changes, and
holds those trees to the table.

## Running every doom-core suite at once

`tests/doom-core/run.sh` runs the suites `tests/doom-core/lanes.tsv` enumerates,
and its first check is that the table and the directory are the same set in both
directions. Before it runs anything it prints each lane's role — five are run by
`verify.sh` itself, one is a subject another suite runs against copied trees —
and then the preconditions each lane names, with the absences:

```sh
REQUIRE_ALL=1 sh tests/doom-core/run.sh /path/outside/the/checkout/run-1
```

`SELECT="audit source-pack"` narrows it and is refused together with
`REQUIRE_ALL=1`, because a narrowed run is not the gate.

**What a fully green run needs, measured on 2026-09-18/19 and not all of it
documented before.** Every suite takes its tools from the environment, and the
lanes do not want the same ones:

| lane | beyond `SPINEL_TYPEDUMP`, `KERNEL`, `LLVM_PREFIX` |
| --- | --- |
| `source-pack.sh` | `SPINEL` **and** `SPINEL_SEAM` — four compiler-shaped variables in all. `tools/core/spinel-core-build` reads `SPINEL_SEAM`, not `SPINEL`; in a worktree without it, seven checks fail on the absent `vendor/spinel` rather than skipping |
| `screens.sh` | **six** `HARNESS_*` directories — `ONE_CLOSURE`, `AUDIT_DIR`, `ADAPTER_LIB`, `SOURCE_LIB`, `SESSION_DIR`, `SESSION_ROOT` — all produced by one run of `harness/build-artifacts.sh` |
| `loop-reports.sh` | a kernel at or after `f65b5a8`, which added the `--report` and `--profile` options it is built on. Against an older one it reports itself dormant and exits 3 |
| `verify.sh`, `tick.sh`, `native.sh` | `ADAPTER`, `WAD`, and for `verify`/`native` also `SPINEL` and `SPINEL_LIB` |

Measured runs, all on Debian x86_64 with nothing else on the host:

- the whole runner, with the shared `e2f5676` tools and no harness directories:
  **6331 s**, 13 of 15 — `screens` red on one skip under `REQUIRE_ALL`,
  `loop-reports` dormant;
- `harness/build-artifacts.sh` once: **10714 s**, about three hours, which is
  where the six directories come from;
- `screens.sh` with them: **23 checked, 23 pass, 0 fail, 0 skipped**, 190 s —
  it checks four more things than without them;
- `loop-reports.sh` against a kernel built from the tree
  (`tools/mlir/native/build.sh` into a build directory of its own, 9 s with a
  warm ccache): **102 passed, 0 failed**, 11804 s.

**The fully green combination has not been executed.** Each half above has —
`screens` green with its directories, `loop-reports` green against a current
kernel — but no single `REQUIRE_ALL=1` run has had both. End to end that is
`build-artifacts.sh` plus the runner with `loop-reports` live, about six and a
half hours, and its value is not the green: it would be the first run of
`state`, `tick`, `verify`, `borrowed-calls`, `control-flow` and `source-pack`
against a kernel built from the tree rather than the shared `e2f5676` build.

## Running the DOOM frame lane's cases

**Retired.** These cases are frozen at `0af8ba0` (decision 0009, clarification of
2026-09-17). They are superseded by `tests/doom-core/verify.sh` on the three real
entries (the section above). `run.rb` now prints
a `RETIRED` line and exits unless `STAGE1_LANES=run` is set. To reproduce the
recorded evidence, check out `0af8ba0`. The rest of this section describes the
runner as it was at that revision.

The frame lane's checks are declared as data and run by
`tests/doom-core/harness/run.rb`, which selects cases from
`tests/doom-core/cases/frame.tsv`, runs each as one `source-port.rb` process
that writes a JSON result record, judges that record against
`tests/doom-core/expect/frame.tsv`, and writes a summary as JSON and JUnit XML.
It builds nothing: everything a route loads is named through the environment.

```sh
HARNESS_RUN=/path/outside/the/checkout/run-1 \
  ruby tests/doom-core/harness/run.rb --tier commit --route ruby
```

| Variable | What it names |
|---|---|
| `HARNESS_RUN` | required by every run, though not by `--list`; the run's own directory, which receives `records/`, `text/`, `fixtures/`, `trees/`, `summary.json` and `junit.xml` |
| `WAD` | the IWAD; without it the cases that need one skip and say so |
| `HARNESS_SOURCE_LIB` | the shared object linking the kernel's objects for the source contracts, which the compiled and session routes load |
| `HARNESS_ADAPTER_LIB` | the shared object linking the adapter and those objects, which the adapter route loads |
| `HARNESS_SESSION_DIR` | the generated session layout, the directory holding `buffers.tsv` and `slots.tsv` |
| `REQUIRE_ALL=1` | turns every skip into a failure |
| `RUBY` | the interpreter for the child runs, defaulting to the one running the runner |

Selection takes any column of the matrix -- `--tier`, `--route`, `--control`,
`--case`, `--variant` and the rest -- repeated or comma-separated; values of
one flag are a union and different flags intersect. `--list` prints the
selected ids and stops, and needs no `HARNESS_RUN`. **A selection that matches
no case is an error**, not an empty pass. `--jobs N` caps concurrency, which is
a budget for one process: full-suite runs are serialized outside it. A bad
`--jobs`, `--matrix`, `--expect` or `--driver` value is refused with a message
and exit 2.

Two tiers are held apart from the rest, under every selection and under
`--list`:

- a row tiered **`retired`** is never selected and never listed. It is not a
  case: it records that a pinned check was deliberately not migrated, and its
  `origin` carries the reason. `--tier retired` is refused rather than answered
  with an empty selection.
- a row tiered **`selftest`** is selected only where `--tier selftest` names
  it, never by a route, control or lane selection alone. These are the
  harness's own tests, and several of them are meant to end as fail or error.

Every case ends as pass, fail, error or skip. A failure prints the differing
keys one per line with the rule, the expected value and what the record held.
An error is a missing record, a run that ended as anything but a clean finish
or its own refusal, or an expectation naming something the record does not
carry -- so a killed run is never reported as a pass or a failure. A skip
names the prerequisite that is missing.

**A mutation case inverts that.** A selftest row whose variant begins
`mutate=` deletes a named piece of the CORE source in a private copy of the
tree, under `trees/` in the run directory, and runs the copy; the worktree is
never written. It is judged against the nominal it perturbs, and it requires
detection, so its verdict is the other way round: the nominal's expectation
failing means the deletion was seen and the case **passes**, and that
expectation still holding means nothing noticed and the case **fails**, which
is the vacuous comparison such a case exists to catch. A mutation whose edit
matched nothing in the source is an error, never a pass.

**Two selftests are designed to end in something other than pass**, and the
runner declares which verdict each must reach, so reaching it is that case
passing: `frame.ruby.none.599` must **fail** (a nominal one frame short must
not pass the 600-frame expectation on a subset) and `frame.ruby.none.600.kill`
must **error** (a run killed by a signal is never a pass or a failure). A
`--tier selftest` run therefore exits 0 when every selftest did what it is
designed to do, and 1 when one of them did not; the reason text says which way
round each is being read, and `summary.json` carries `expected_verdict` and
`as_designed` beside the verdict. `run.rb --help` lists them.

### The expectations, and a row that still says `TBD`

`tests/doom-core/expect/frame.tsv` is generated, not written. Every value it
can take from the frozen `tick.sh` pins it takes mechanically, so a migrated
check asserts what the check it replaces asserted; a value no pin holds is
written `TBD` and waits for a run. **A `TBD` row fails its case** -- no record
holds the string `TBD` -- so an expectation is not finished until none are
left, and `expect.rb` prints how many remain and names them.

A `TBD` is filled from a **record**, through the tracked file
`tests/doom-core/expect/frame-fills.tsv` (`case_id`, `key`, `value`, `from`,
where `from` names the run directory and record the value was read out of).
Nothing in that path is typed: `harness/fills.rb` writes the fills file from a
run's records, and `expect.rb --fills` substitutes each row's value for that
key's `TBD`. A fills row that names a key which is not `TBD`, a key the case
does not assert, or the same case and key twice is refused rather than applied.
The steps, where `PINS.tsv` and `UNFILLED.tsv` are scratch files outside the
checkout and `RUNDIR` is the `HARNESS_RUN` of the run whose records hold the
values:

```sh
ruby tests/doom-core/harness/pins.rb --out PINS.tsv
ruby tests/doom-core/harness/expect.rb --pins PINS.tsv --out UNFILLED.tsv
ruby tests/doom-core/harness/fills.rb --expect UNFILLED.tsv \
  --records RUNDIR --out tests/doom-core/expect/frame-fills.tsv
ruby tests/doom-core/harness/expect.rb --pins PINS.tsv \
  --fills tests/doom-core/expect/frame-fills.tsv \
  --out tests/doom-core/expect/frame.tsv
```

The middle step needs the expectation as it is generated **without** `--fills`,
because that is the file that still holds the `TBD` rows; pointing it at the
tracked one is refused with that sentence. Regenerating is idempotent: the same
pins and the same fills file produce a byte-identical `frame.tsv`.

### A value the port legitimately moved: overrides

A value taken from a frozen pin is otherwise fixed forever. When a capability
changes what the port counts -- the renderer's plane walk pushing the sky
columns inside the walk, so the port's own push no longer counts them -- the
pinned count is simply wrong, and neither way out is allowed: the pins are the
record of what the old checks asserted and are not edited, and `frame.tsv` is
generated and is not hand-patched.

`tests/doom-core/expect/frame-overrides.tsv` is the third tracked input, and
0009 item 3's reviewed update in the shape the rest of this layer already uses:
a file whose **diff** is what a review reads. Its columns are `case_id`, `key`,
`value`, `revision` -- the commit that moved the value -- and `reason`, which
names the port change in words. `revision` is an abbreviated or full hex id
matching `/\A[0-9a-f]{7,40}\z/` that names a commit the repository holds;
**both are checked when the expectation is generated**, not when it is run,
because `run@REVISION` is evidence only if the revision can be looked up, and a
branch, a tag or `HEAD` names something that moves. `expect.rb --overrides`
substitutes the value
and writes the row's origin as `run@REVISION`, so the expectation itself says
the value no longer stands on its pin; the generated header lists every
override with the value it replaced and the reason, so a reader of the
expectations sees them without opening this file. It holds no rows while every
value still stands, and **an empty one changes nothing**: `frame.tsv` is
byte-identical generated with it and without it.

```sh
ruby tests/doom-core/harness/expect.rb --pins PINS.tsv \
  --fills tests/doom-core/expect/frame-fills.tsv \
  --overrides tests/doom-core/expect/frame-overrides.tsv \
  --out tests/doom-core/expect/frame.tsv
```

**Generating an expectation needs a git checkout; running one does not.** The
revision check looks the commit up, so `expect.rb` must run where the
repository's history is. `run.rb` needs none of that: it judges a result record
against the tracked `tests/doom-core/expect/frame.tsv`, where the revision is
only a label in the `origin` column. A verification line working from an
archive can therefore run every case; it just cannot regenerate the
expectations there.

**An override moves a measured value and never a declared one.** A declared
invariant never comes from a run, so a run that broke one must never be able to
write its own result in as the expectation. The two classes, in full:

- **(a) declared, and refused.** The case's own declaration fixes the value.
  On a **nominal** case: `rc`, `run.frames`, every `faults.<kind>` equal to 0,
  `session.other_slots_changed` and `session.readonly_changed`. On a **refusal**
  case and on a **control** case: `outcome` and `rc`. On **every adapter case**,
  nominal or not: `adapter.second_release`, which is the harness declaring what
  the registry must do with an id -- a run that answers otherwise has *failed*,
  and is not evidence about the expectation.
- **(b) measured, and allowed** with a revision and a reason, because a run
  produces the value rather than the declaration: coverage counts; the measured
  route counts `adapter.ids_allocated` and `adapter.ids_released_once`; a
  control's first-failure text, `adapter.session_failed` among them -- it names
  *where* a session was refused, which is the same kind of fact, and that site
  can move for a legitimate reason -- and its raised-kind set; and a refusal
  case's `ended` message, while that same case's `outcome` and `rc` stay
  declared and refused.

Each row of `frame.tsv` carries its class, set in `expect.rb` where the row is
made, by the code that knows where the value came from. A row made without one
is refused rather than allowed, so a key added later cannot become overridable
by nobody having decided which class it is in.

These are refused by name as well:

- a row with no `revision`, a `revision` that is not a hex commit id, a
  `revision` that names no commit in this repository, no `reason`, or a reason
  that is only whitespace: it would be a bare number nobody can review. So is a
  key the named case does not assert, the same case and key twice, and a value
  equal to the one it replaces, which moves nothing.
- **a `gt0` row**, which compares no value, so it has none to move; and a row
  still `TBD`, whose first value comes from a run through `--fills`.
- **a fault kind's `eq 0` row**, the sharpest case of class (a) and refused
  wherever it appears, not only on a nominal: a case that raises a kind it
  asserts stays at 0 has *failed*, and overriding the row would write the fault
  the run raised in as the expectation, which is the vacuity this layer exists
  to prevent.
- **a movable count that is not a base-10 integer, or one below zero.** Both
  kinds of count are checked with the one strict form -- the coverage counts,
  and the measured route counts `adapter.ids_allocated` and
  `adapter.ids_released_once` -- because `Integer()` would take `1_0` and ` 5`,
  which no record can ever equal, and no run reports fewer than none of
  anything.
- **a coverage value equal to `0`** -- `0`, `00` and ` 0` alike, refused by the
  number the value parses to rather than by how it is spelled. A coverage count
  must be strictly above zero, while a measured route count need only be at
  least zero: zero released once is a legitimate measurement, and zero coverage
  is the constant nothing can move. A count the new code never increments
  becomes an exactly-asserted constant no regression can ever move: it is the
  vacuous comparison 0009's context records at `44a7d4b`, arrived at from the
  other direction. Such a count is **dropped**, not overridden -- taken out of
  `COVERAGE` in `harness/expect.rb`, in a diff whose comment says why the port
  stopped producing it, and replaced by the counts the new code does produce.
  The refusal says so.

Every one of these refusals quotes both classes in full, so a reader who meets
one of them reads the whole rule and not just the clause they tripped over.

### The artifacts the compiled, session and adapter cases need

Stage 1 has no artifact cache, so the two shared objects and the session layout
are built as `tests/doom-core/tick.sh` builds them. `run.rb` builds nothing, so
without them its compiled, session and adapter cases can only skip.
`tests/doom-core/harness/build-artifacts.sh DIR` builds the three into `DIR`
and prints the three assignments the runner reads -- and nothing else on
stdout, so they are taken through `eval`:

```sh
export HARNESS_RUN=/path/outside/the/checkout/run-1
out=$(sh tests/doom-core/harness/build-artifacts.sh "$HARNESS_RUN") || exit 1
eval "$out"
REQUIRE_ALL=1 ruby tests/doom-core/harness/run.rb --tier commit
```

**Catch the build's exit status in its own command**, as above.
`eval "$(...)"` returns the status of `eval`, not of the build: under `dash` a
failed build leaves the three variables unset, the `eval` succeeds, and the
runner then *skips* every compiled, session and adapter case -- a run that
reports green having tested four cases out of twenty-eight. `REQUIRE_ALL=1`
turns a skip into a failure, which catches exactly that, so gate a tier run
with it.

It takes its tools from the environment under the names `tick.sh` already
uses -- `KERNEL`, `ADAPTER`, `SPINEL_TYPEDUMP`, `CLANG` or `LLVM_PREFIX`, `WAD`
and `RUBY` -- and refuses with a message naming the one that is missing. It
runs the audit step the session layout is derived from, so it is not cheap;
build once per run directory and reuse the three assignments.

## Choosing between the collected heap and no collector

An ordinary Ruby program can be built two ways. The default links the collector.
With upstream's `--gc=none` (also `--no-gc`) the program has no collector:
allocation still works, nothing is reclaimed while the program runs, and the
process exit reclaims everything at once. Nothing about the language changes --
the same source, the same integer types, the same method dispatch, the same FFI.

```sh
vendor/spinel/spinel prog.rb --gc=none --cc=/opt/llvm-23.1.1/bin/clang -o prog
```

There is no separate runtime archive. The generated C defines the collector
pointer `sp_gc_collect_fn` as `NULL`, the runtime's weak definition gives way,
and `--gc-sections` drops the collector from the link. The allocation triggers
are lifted the first time one fires. `GC.start` is a no-op. The process-lifetime
arena that this replaced, with its archive, its limit and its refusals, was
removed from the pin on 2026-11-01; see
[provenance](provenance.md#the-arena-replaced-by-upstream---gcnone-2026-11-01).

What upstream accepts and this repository has not verified. The driver refuses
none of the following under `--gc=none`: upstream accepts each, and it is not
verified in this repository unless a check is named.

- Threads (`Thread`, `Mutex`, `Queue`). `tests/gc-arena/run.sh` builds and runs
  one Thread program both ways; nothing beyond that program is claimed.
- C extensions.
- `--target=wasm32-wasi`. The Extended WASM tool's `--request-arena` build is
  `--gc=none` and is checked by `tests/edge/arena.sh`; upstream's own wasm32
  target is not.
- `--exceptions=abort`.
- `SPINEL_MAX_HEAP_MB` is not checked under `--gc=none`: the limit is enforced
  only after a collection, and none runs. There is no limit, and memory grows
  until the host refuses it.

Run the acceptance checks with:

```sh
CLANG=/opt/llvm-23.1.1/bin/clang sh tests/gc-arena/run.sh
```

It builds each fixture on the collector and with `--gc=none`, and compares the
two: output and exit status, retained values, explicit release and exit
processing, `GC.start`, a Thread, a 200 MB retained allocation, and
`sp_gc_collect` absent from the `--gc=none` artifact, with its presence in the
default one as the control. `CLANG` selects the C compiler and `NM` the symbol
reader. The comparison of each fixture with a reference interpreter
(`REF_RUBY`) is an oracle and runs only with `ALLOW_ORACLE=1`
([tests/ORACLES.tsv](../tests/ORACLES.tsv)). There, where the compiler's answer
differs from the reference interpreter in *both* configurations, the exact diff
is pinned under `tests/gc-arena/expected/`, so a new shared difference fails
instead of being absorbed as another note. The fork's own check is
`make -C vendor/spinel gc-none-test`, one program. The upstream corpus is not
run under `--gc=none` here.

What is not reclaimed, and what still is. No finalizer runs, so a file or
directory handle that nobody closes is not closed for you, and a container's
storage is not freed when the container is dropped. Explicit release is
untouched: `File#close`, the block forms, `at_exit` and `END` all behave as they
do on the collector, because none of them goes through a finalizer.

See [decision 0003](decisions/0003-gc-and-arena-build-modes.md) for why the
switch is the collector rather than the allocator, and its 2026-11-01 revision.

## Writing a declared freestanding function

A boundary is declared next to the method, using the declaration surface in
`tools/freestanding/spinel/freestanding.rb`:

```rb
require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
```

The declaration is not decoration. Inference establishes that the method
computes on `Integer`; it cannot establish whether the foreign C side wants
`int32_t` or `int64_t`, so the declaration states it and the generator emits
the adapter. Bodies compute at the target's pointer width (decision 0019), and
the declared width applies at the boundary, where a value that does not fit
traps rather than being truncated.

Failure behavior is fixed: trap by default, `overflow: :wrap` per declaration,
and `raise` refused, because raising needs a heap and a setjmp stack that a
core object does not have. The trap hook is the one symbol a core object
expects the platform to supply.

## Running freestanding kernels on targets

A declared function builds for more than the host. With a cross profile from
`tools/freestanding/profiles/`, `spinel-fs-emit` writes an object for QEMU
Cortex-M33, QEMU RISC-V 32 or wasm32:

```sh
tools/mlir/native/build/bin/spinel-fs-emit kern.rb --freestanding \
  --profile tools/freestanding/profiles/riscv32-zephyr.yaml \
  -o kern.o --emit-header spinel_freestanding.h
```

`tests/freestanding/run.sh` links such objects into Zephyr images and wasm
modules and runs them under QEMU, node and workerd. It needs Zephyr v4.4.2 with
SDK 1.0.1, wasm32 builtins and a WASI sysroot beyond the core slice's
requirements. [The target lanes](../tests/freestanding/README.md) give the
settings, what each lane checks, and what is kept as an oracle and not run.

## Running full on a Cortex-M33 with no RTOS

Decision [0037](decisions/0037-bare-metal-full.md). The build lives in
spinel-modular, which this repository pins as the submodule
`vendor/spinel-modular` (`git submodule update --init vendor/spinel-modular`); it was
`tools/bare-full` here until 2026-11-23. Its `tools/bare-full` links a
program with the hosted runtime and its collector into an image for QEMU's
`mps2-an521`, with picolibc 1.8.12 built with LLVM 23.1.1
([installation record](toolchains/picolibc-1.8.12/INSTALLATION-RECORD.md)) and
compiler-rt's builtins:

```sh
export LLVM_PREFIX=/opt/llvm-23.1.1
export BAREMETAL_PICOLIBC=~/toolchains/picolibc-1.8.12-llvm23/install
export BAREMETAL_BUILTINS=~/toolchains/compiler-rt-23.1.1/build/lib/generic/libclang_rt.builtins-armv8m.main.a
export SPINEL_DIR=$PWD/vendor/spinel
vendor/spinel-modular/tools/bare-full/spinel-bare-full runtime /path/to/rt
vendor/spinel-modular/tools/bare-full/spinel-bare-full build --runtime /path/to/rt/libspinel_rt_bare.a app.rb app.elf
sh tests/bare-full/run.sh
```

The boards in the pinned spinel-modular are `an521` and `frdm-mcxn947`. A
chip family or board outside it is found through `BAREMETAL_PORT_PATH`, a list
of port directories; the RP2040's family, which was here, is such a port now.
For a Cortex-M0+ board, build the runtime with `runtime --cpu m0plus` and
point the two variables at picolibc and the builtins built for that core
(each record has a Cortex-M0+ section).

`SPINEL_DIR` names this repository's Spinel, so that one checkout of it is
built; `tests/bare-full/run.sh` sets it and runs spinel-modular's lane. The
suite skips with exit 2 without those variables or `qemu-system-arm`, when
the submodule is not checked out, and when the two repositories pin different
Spinel commits. The tool's guide, `vendor/spinel-modular/tools/bare-full/README.md`,
gives the console protocol, the chip and board files and the limits.

## Running full on Zephyr's POSIX layer

Decision [0038](decisions/0038-zephyr-posix-full.md). `tools/zephyr-full` builds
a program with the hosted runtime and its collector into a Zephyr v4.4.2
application for the FRDM-MCXN947, on Zephyr's POSIX layer and network stack,
so that `TCPSocket`, `sleep` and `Marshal` link. It uses the pinned Zephyr and
SDK as in the section below:

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
export PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE="$ROOT/workspace/zephyr" \
  ZEPHYR_SDK_INSTALL_DIR="$HOME/zephyr-sdk-1.0.1"
tools/zephyr-full/spinel-zephyr-full build app.rb out/
sh tests/zephyr-full/run.sh
```

The suite builds seven programs and checks the images, about 1 m 35 s on
Debian 13; it skips with exit 2 without those variables or `west`. Board runs
are by hand, compared with `tests/zephyr-full/check-log.rb`.
[The tool's guide](../tools/zephyr-full/README.md) gives the options, the
console protocol, the board procedure and the limits.

## Keeping 64 bits on a 32-bit target

On a target whose pointers are 32 bits, a first-line `# spinel: int64` on a
freestanding kernel, a CORE application or a CORE entry unit is refused
unless `tools/core/int64-allow.tsv` lists the source ([decision
0019](decisions/0019-target-integer-width.md), revised 2026-10-21). A listed
source builds at 64 bits as before. On a 64-bit target the declaration
changes nothing.

- **Who reads the table.** The kernel (so also `spinel-core-app`),
  `spinel-fs-emit` and `spinel-fs-grad` read it before analysis.
  `--int64-allow FILE` reads another table, whose paths are relative to the
  directory two levels above it.
- **A row.** A row is a repository-relative path and a reason, separated by a
  tab. The reason says why the 64 bits do not matter for performance, and why
  rewriting the source at 32 bits would lose what it tests.
- **Who adds rows.** Listing is the owner's policy, and is typically a test
  whose subject is 64-bit arithmetic or a 64-bit platform value. DOOM's CORE
  entries and its board application are never listed; code that runs on the
  board for real computes at 32 bits.
- **Matching.** A source is listed when its bytes are a listed file's current
  bytes. A lane may compile a copy; an edited copy is not listed.
- **Checks.** Every read checks the whole table. A malformed row, a path
  listed twice, a missing file, or a listed file without the declaration
  refuses every source, as `int64-allow-table: <table>:<row>: ...`.
- **The refusal.** An unlisted source is refused as
  `<file>:1: int-width-int64-refused`, naming the table. `spinel-core-app`
  names the application's own file and line, not the packed root.
- **The controls** are `ruby tests/freestanding/int-width/run.rb` and
  `sh tests/app/int-width.sh`. A planted table's listed source builds at 64
  bits, an unlisted one is refused, and a row naming a missing file refuses
  every source. The first also checks the repository's table.

## Compiling Ruby to wasm32 for the edge

`tools/wasm/spinel-wasm` compiles a whole Ruby program to a `wasm32-wasip1`
module with the pinned compiler, and writes projects that run on Cloudflare
Workers (`--emit-worker`) or Fastly Compute (`--emit-fastly`). It needs
`LLVM_PREFIX`, a WASI sysroot (`WASI_SYSROOT`) and the wasm32 builtins
(`WASI_BUILTINS`); [its README](../tools/wasm/README.md) lists the options and
the differences from spinel-llvm, including that Integer is 32-bit on this
target.
[Cloudflare Workers limits](edge/workers-limits.md) records the Workers Free
and Paid limits, what our modules measured against them, and why Workers
modules should use the arena build.

```sh
tools/wasm/spinel-wasm examples/hello-http/app.rb --emit-worker dist
(cd dist && npx wrangler dev --local)
```

The checks are local, with nothing deployed:

```sh
ruby tests/edge/capcheck_rc.rb   # the capability checker's 46-case table
sh tests/edge/run.sh             # the six edge examples, served and checked
```

`tests/edge/run.sh` needs, beyond the above, `ZEPHYR_BASE` and
`ZEPHYR_SDK_INSTALL_DIR` for edge-twin's device, and wrangler, node, west and
Viceroy (`VICEROY` may name it) on `PATH`. It builds and serves each example
and checks the contract the example documents.

## Running tensor kernels on the CPU and the Apple GPU

The tensor lane compiles `tensor_def` kernels, `assign!` fusion and
`tensor_extern` models through IREE into `.vmfb` modules that one Spinel binary
carries and runs on the CPU or the Apple GPU. It needs IREE 3.11.0, compiler and
runtime from the same commit, installed as its
[installation record](toolchains/iree-3.11.0/INSTALLATION-RECORD.md) describes,
and the native importer (`tools/mlir/native/build.sh` builds
`spinel-tensor-import`).

```sh
export IREE_SRC=... IREE_BUILD=... IREE_COMPILE=...
sh tests/tensor/run.sh       # builds and runs the five examples on both devices
```

[tools/tensor](../tools/tensor/README.md) describes the surface. The examples'
comparisons with a second implementation run only with `SPINEL_ORACLE=1`.

## Drawing DOOM on the GPU

`RASTER_GPU=1 examples/doom/build.sh` links DOOM with the GPU raster path
(`tools/raster`, through IREE 3.11.0 and Metal). With a Job IR dump turned into
kernels by `spinel-rastergen` and `iree-compile`, `doom -gpu -jobs -gpuvmfb ...`
draws the 3D view on the GPU. [tools/raster](../tools/raster/README.md) has the
steps; `sh tests/raster/run.sh` (with `IREE_SRC`, `IREE_BUILD`, `IREE_COMPILE`
and the IWAD) builds everything and plays the three demos to their end on the
GPU at five resolutions, 320x200 to 1920x1200.

## Watching allocation and the GC

[tools/gcmon](../tools/gcmon/README.md) counts allocations and collections:
`spinel-gcmon ab` compares two runs, and a section probe, through vendor Patch 1
(`SPINEL_EXTERN_METHODS`), measures part of a program without allocating.
`sh tests/gcmon/run.sh` checks the tools and runs the DOOM gate, which plays
DEMO1 to tic 500 and to tic 5026 and requires every allocation count to be
equal. The malloc counter is DYLD interposition, so the suite needs macOS;
elsewhere it skips those parts and exits 2.

## Ruby shaders on the GPU

[tools/shader](../tools/shader/README.md) compiles Ruby methods declared with
`shader_def` to SPIR-V, and through naga to WGSL and MSL. `draw_metal.m` draws
with the MSL on Metal, and `draw.c` with the WGSL through wgpu-native. The
[installation record](toolchains/shader-tools/INSTALLATION-RECORD.md) lists the
tools; with them:

```sh
export PATH="$HOME/.cargo/bin:$PATH" WGPU_NATIVE=$HOME/toolchains/wgpu-native-v29.0.1.1
sh tests/shader/run.sh
```

## Through clang with ThinLTO

[tools/llvm](../tools/llvm/README.md) builds a Spinel program with the LLVM
release's clang instead of `cc`, and with ThinLTO across the program and a
bitcode build of the runtime:

```sh
tools/llvm/build_rt_bc.sh
tools/llvm/spinel-llvm app.rb -o app          # --mode thinlto | clang-O2 | ir
sh tests/llvm/run.sh
```

## Examples: spinel-vi and mvc-blog

`examples/spinel-vi` is a small vi (`bash tests/spinel-vi/run.sh`; its PTY legs
need perl and `script`). `examples/mvc-blog` is a Rails-style blog that runs
natively and on Workers (`bash tests/mvc-blog/run.sh`, which needs what
`tests/edge/run.sh` needs for its Workers half).

## Dependency changes

Make compiler patches on a branch in the Spinel fork, validate them, and push that commit before updating the parent gitlink. Keep the submodule source clean for baseline validation. Record each adopted revision and local changes in [provenance](provenance.md). Preserve upstream and bundled dependency notices.

## Zephyr, for CORE applications (decision 0014)

The pinned Zephyr v4.4.2 and SDK 1.0.1 live outside the repository; the
[installation record](toolchains/zephyr-v4.4.2/INSTALLATION-RECORD.md) has the
release, the commands and what they established. Every command that runs
`west` puts the installation's venv first on `PATH` and passes `ZEPHYR_BASE`
and `ZEPHYR_SDK_INSTALL_DIR` explicitly; nothing registers a package in
`~/.cmake/packages`, and the scripts confirm the tree and SDK used from the
CMake log, because `ZEPHYR_SDK_INSTALL_DIR` alone does not select the SDK.

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
env PATH="$ROOT/.venv/bin:$PATH" \
    ZEPHYR_BASE="$ROOT/workspace/zephyr" \
    ZEPHYR_SDK_INSTALL_DIR="$HOME/zephyr-sdk-1.0.1" \
    sh tests/app/platform-facts.sh
```

`platform-facts.sh` builds `hello_world` and a timer probe for
`mps2/an521/cpu0`, runs both under the SDK's QEMU, configures
`frdm_mcxn947/mcxn947/cpu0`, `frdm_imxrt1186/mimxrt1186/cm33` and
`frdm_imxrt1186/mimxrt1186/cm7`, and prints
each fact with the command that produced it; about 30 s on Debian (28 s
measured with the RT1186 block). It fails when a required fact does not
hold, and it carries its own controls: the probe without the 64-bit cycle
count, a nonexistent SDK path, and an empty `ZEPHYR_BASE`. `OUT` keeps the
build directories somewhere of your choosing.

The kernel cross-builds for Cortex-M33 with its own clang; `tests/app/cross.sh`
is the check, and the target flags it uses are the ones the plan fixes
(`--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os`,
with `--layout ptr32-i64-32long`, which the kernel now requires for a cross
target and checks against the triple). With `ZEPHYR_BASE` and
`ZEPHYR_SDK_INSTALL_DIR` it also compiles an adapter against Zephyr's headers
and compares the build attributes with a Zephyr object; without them that lane
skips. `tests/app/doom-admission.sh --baseline-kernel K0 --kernel K1` builds
`col`, `renderall`, `lindex` and `fplane` with a kernel from `7a7f453` and the
tree's kernel and requires identical objects and reports (1011 s measured on
Debian on 2026-09-22, `renderall` 439 s of it; `--mid-course` is the subset
used between tasks, 413 s). `tools/core/core-artifact-gate` takes
`--extern <symbol>` for each undefined symbol an object may reference, by
exact name, and decides the Mach-O underscore from the object's format.

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/cross.sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/doom-admission.sh \
    --baseline-kernel /path/to/7a7f453/spinel-core-kernel \
    --kernel tools/mlir/native/build/bin/spinel-core-kernel
```

The application contract (`core-contract 2`, decision 0014) is read by the
same kernel. `spinel-core-kernel <contract> --root <dir> --admit-only --clang
... --typedump ...` runs admission alone -- the checker with the contract's
facts, the extern rules of 0014 §6 and the derived-bound rule -- and writes
nothing; `tests/app/contract.sh` runs every fixture under
`tests/app/fixtures/contract` through it against `expect.tsv` (about 2 s).
The kernel's snapshot of an application holds no `core_extern` declarations;
the contract carries them.

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/contract.sh
```

An application entry's report is version 2 (`core-report-v2.schema.json`):
version 1 plus an `application` object with the context, the buffers and
whether each is written, and each extern's derived call count, guards and the
stack and effects its bound evidence attests. `--config-binding
<dts>:<config>:<flags>` names the configuration the evidence must be bound to,
and `--admit-only --report` writes the report before the entry is lowered,
with `object` null. `tests/app/effects.sh` checks the write set, the call
counts, the evidence binding and the schema (about 8 s).

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/effects.sh
```

A version 2 entry lowers to `int32_t <entry>(<elem> *p1, ...)`: the state
buffers alone, no counts and no result pointer. Its externs become `llvm.call
@symbol` with the C ABI of the plan (a buffer is a pointer and a `uint32_t`
count), guarded before the call; string literals are private constant bytes;
the cross buffers, and every buffer of a helper reached with one, are accessed
atomically. `--extern-header <out.h>` writes the prototypes a provider includes.
`tests/app/lowering.sh` checks the IR, the thumbv8m object (gate, disassembly,
relocations), a native harness against C providers, and the final D1 probe
(about 3 s).

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/lowering.sh
```

### The application tool and the host runner (Task 6)

`tools/app/bin/spinel-core-app` reads an application's declarations with
Prism (`state`, `every_us`/`every_ms`, `channel`, `core_extern` in a module,
one top-level `def` per trigger), generates the channel package (the ring's
C, its host simulator and its declarations), writes one `core-contract 2`
per entry, and packs the root the contracts name: the application with its
`require` lines turned into comments, `spinel/net.rb`, and one module per
board and channel module holding that module's integer constants
(`Led::COUNT`, 0014 D5), with a line map and the pack's sha256 beside it. The board comes from a board package -- `board.rb` (declarations),
`board_host.rb` (CRuby simulators) and `board.tsv` (one row per instance,
ownership by `node_path`). `spinel-core-app board` generates one from a
devicetree ([Task 7](#the-board-package-task-7)); the commands below use the
synthetic package under `tests/app/fixtures/synthetic-board/`.

```sh
ruby tools/app/bin/spinel-core-app package --app app.rb \
     --board tests/app/fixtures/synthetic-board/board.rb --out build/app
ruby tools/app/bin/spinel-core-app admit --app app.rb \
     --board tests/app/fixtures/synthetic-board/board.rb \
     --board-tsv tests/app/fixtures/synthetic-board/board.tsv --out build/app \
     --kernel tools/mlir/native/build/bin/spinel-core-kernel \
     --clang /opt/llvm-23.1.1/bin/clang --typedump tools/contract/build/spinel-typedump
ruby tools/app/bin/spinel-core-app run-host --app app.rb \
     --board tests/app/fixtures/synthetic-board/board.rb \
     --board-host tests/app/fixtures/synthetic-board/board_host.rb \
     --stimulus stimulus.tsv --trace build/app.trace
```

`admit` runs the kernel on every entry (admission only, with a report) and
then the cross-entry checks of `CoreApp::AppChecks` over the reports:
`shared-writer`, `device-owner` (a device is a `board.tsv` row; the instance
index of each call site comes from the report's `const_args`, and a computed
index reaches every instance of the module), `channel-end`, `channel-buffer`
(the kernel's static requirement, carried under its code), `unknown-member`,
`member-effect` (`isr_ok` in interrupt context, and a blocking or
unknown-blocking instance anywhere) and `declaration`. Each diagnostic is
printed as `file:line: code: detail`.

`run-host` is the CRuby reference of 0014 §10: the same application file
under the checked-domain discipline of the arithmetic reference
(`CoreApp::Checked`, a copy of `tests/core-boundary/oracle.rb`'s mechanism,
plus the state buffers with their element domains), released on a virtual
microsecond clock with the scheduling of §4 -- selection from one clock
reading, skips never caught up, interrupt entries preempting a thread
invocation's cost window -- and the channels of §5 with both inbound drop
reasons. The stimulus script gives the horizon, the drain bound, `adc`,
`gpio` and `inbound` items, `cost` lines (virtual execution time, simulation
input and not an estimate) and `expect_failure` lines; the run fails when
the failures observed differ from those declared, or when an inbound message
is left unconsumed by a context that did not stop. The trace is the plan's
record kinds as text (`seq kind context entry field=value...`); the byte
encoding is Task 11's. `tests/app/host.sh` runs the fixtures under
`tests/app/fixtures/apps/` -- one per diagnostic code, the scheduling cases,
the channel drops, the idle-time run -- and its controls (about 15 s). The
tool needs a Ruby that can `require "prism"` (3.3 and later, or the gem);
the lane says so and stops otherwise:

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/host.sh
```

Every check added from Task 6 on that reads symbol names from an object goes
through `tools/core/object-symbols`, which reads the object's format with
`llvm-readobj` and removes its ABI prefix (one underscore on Mach-O, none on
ELF; any other format is refused by name). `core-artifact-gate` and
`tests/app/contract.sh` call it. Older lanes (`tests/app/lowering.sh` and
`cross.sh`, `tests/native-core/run.sh`, `tests/doom-core/borrowed-calls.sh`
and `verify.sh`, `tests/gc-arena/run.sh`) still parse `nm` output themselves;
moving them is separate work. A new check that parses `nm` itself repeats a
defect that has bitten three times on macOS.

### The board package (Task 7)

`spinel-core-app board` generates the board package from the final
`zephyr.dts` and `.config` of a configured build, the release's effect table
(`tools/app/zephyr/<release>/effects.tsv`) and the adapters
(`tools/app/adapters/<class>/`: `class.tsv`, `adapter.c`, `adapter.h`,
`sim.rb`):

```sh
ruby tools/app/bin/spinel-core-app board --dts build/zephyr/zephyr.dts \
     --config build/zephyr/.config --board mps2_an521 --out build/board
```

It writes `board.rb` (the declarations: one module per class and effect
group, with `core_extern` per member and the D2 index guard), `board_host.rb`
(the CRuby simulators from each class's `sim.rb`), `board_port.c` (the
`DT_PATH` tables and the `spc_board_<module>_<fn>` functions over the
adapters), `board.tsv` (one row per instance: module, index, name, device as
`<controller path>:<channel>`, compatible, bus, `isr_ok`, blocking, evidence)
and `provenance.json` (release, DTS, `.config`, flags and effect-table
digests). Instances come from the devicetree alone: the enabled children of
`gpio-leds`, `gpio-keys` and `pwm-leds`, the `io-channels` of `zephyr,user`,
and the system timer. Each module carries its own constants
(`Led::COUNT`, `Led::LED0` from the alias, `Led::USERLED0` from the label,
`Led::LED_0` from the node name), which is what the checked boundary resolves
since 0014 D5 -- one level, `Mod::NAME`, a module of the packed root and an
integer literal in its body -- and what CRuby resolves natively. A generated
name that would collide inside a module is refused by name; no prefix is
invented to separate two of them. Effects follow
the instance: the effect row of the controller's compatible on its bus whose
`applies_when` holds in `.config`; an instance with no row is not `isr_ok`
and not proven non-blocking, and a class whose instances differ in effect is
split (`Led` keeps the attested memory-mapped ones, `LedI2c` an expander's,
`LedUnattested` an unknown driver's). Nothing generated is tracked.

`spinel-core-app screen --object x.o [--entry sym]...` reads an adapter or
provider object's undefined symbols through `tools/core/object-symbols` and
refuses a listed allocating, blocking or interrupt-configuring primitive
(`tools/app/zephyr/<release>/screen.tsv`) or a call back into a CORE entry.
Direct calls only; passing is evidence, not proof.

`tests/app/board.sh` generates from the recorded devicetrees of both real
boards and from three synthetic ones, parses the generated C and the
adapters against stand-in headers, checks the screen's refusals and its pass
case, resolution across boards, provider evidence binding, and re-runs Task
6's host fixtures against the generated packages (about 6 s):

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/app/board.sh
```

It does not compile the adapters' C against Zephyr, which needs a configured
build's generated headers (Task 10); the stand-in headers under
`tests/app/fixtures/boards/zephyr-stubs/` establish well-formed C only.

### Channels, the transport and the byte helpers (Task 8)

The channel package is rendered from `tools/app/templates/`: per channel a
header, the storage (`channel_<name>_ring.c`), and `spc_channel_<name>_put`
and `_get` each alone in its own translation unit, `noinline`, with global
assembler labels `spc_ring_<name>_<put|get>_<copy|pub>_<begin|end>` around
the copy and the publication (C11 atomics, release on publish, acquire on
read); the copy is the ring's own inlined byte loop, so a ring unit depends
on nothing but its storage. `transport_uart.c` drains every `:out` ring to
the UART and fills the `:in` rings from it, one pass per
`spc_transport_step()`, with the framing and the two drop reasons the plan
fixes. `spinel-core-app package` writes them under `channels/`;
`spinel-core-app labels --object <image> --channel <name>...` checks a linked
image's labels (each once, begin before end, inside the operation's
function) through `tools/core/object-symbols --addresses`.

`tests/app/channel.sh` compiles every unit natively and for thumbv8m, runs
the ring and the transport harnesses on the host (including the kept
failing input, a copy of the generated transport mutated to drop with room),
compares the byte helpers' output from the kernel's native build with
CRuby's, and checks the labels on the host-linked harness, with a control
that swaps a put's publication above its copy. With `ZEPHYR_BASE`,
`ZEPHYR_SDK_INSTALL_DIR` and `west` on the PATH it also runs the thumbv8m
build of the helpers under QEMU and links the two-channel fixture with the
SDK's GNU ld (24 checks, about 8 s; 20 checks and 4 skipped in about 1.5 s
without; `REQUIRE_ALL=1` makes a skip a failure). With the installation
record's layout:

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
env PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE=$ROOT/workspace/zephyr \
    ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1 LLVM_PREFIX=/opt/llvm-23.1.1 \
    REQUIRE_ALL=1 sh tests/app/channel.sh
```

### Attested reserves and driver rows (Task 9)

`tools/app/zephyr/v4.4.2/reserves.tsv` holds the stack reserves of decision
0014 §9 for both boards -- `thread_switch`, `thread_kernel_calls`,
`isr_entry_exit`, `pendsv`, `timer_dispatch`, `uart_calls`, `guard_area` and
one `isr_<driver>` per driver interrupt handler -- each an attestation whose
bytes are the sum of the frames along a path traced by hand from the pinned
source (`reserve-harness/paths/<board>/<item>.tsv`: GCC `.su` frames of a
`CONFIG_STACK_USAGE=y` build, an assembly handler's pushes, the hardware
exception frame), never an observed high-water mark. `irq-rows.tsv` says,
per driver compatible, which interrupts it connects, where the priority
comes from and what changes after initialisation; `vector-classes.tsv`
names the reset, terminal and default handlers of the pinned release.
`CoreApp::Reserves` reads them, decides applicability (`applies_when`:
`CONFIG_X=value`, `=n` for not set, `board=<name>`; no applicable row is
`unknown`, never a default) and recomputes a path's sum from a build's `.su`
files.

`tests/app/reserves.sh` checks the tables and the applicability logic with
their controls (about 1 s), and with `ZEPHYR_BASE`, `ZEPHYR_SDK_INSTALL_DIR`
and `west` on the PATH builds the reserve harness (`reserve-harness/`, a
non-deliverable Zephyr application) for both boards under both fragments,
recomputes every applicable reserve whose path has `.su` steps from the
fresh `.su` files (the literal-only rows are named), and runs the harness
under QEMU on `mps2/an521`: it paints its stacks, drives the SysTick
dispatch and the scheduler thread's kernel-call chain, and reports whether
any high-water mark exceeds its reserve (a held run is falsification
evidence, not the reserve; the README says which rows the run cannot
refute); two controls lower `timer_dispatch` below its path, which must be
refuted, and turn time slicing off, which must drop the interrupt-stack
mark below the sliced run's (33 checks, about 46 s; 12 and 22 skipped without):

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
env PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE=$ROOT/workspace/zephyr \
    ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1 LLVM_PREFIX=/opt/llvm-23.1.1 \
    REQUIRE_ALL=1 sh tests/app/reserves.sh
```

### The build pipeline, the glue, the stacks and the inventory (Task 10)

`spinel-core-app build` runs the eleven steps of decision 0014 §8 for one
application on one board:

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
env PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE=$ROOT/workspace/zephyr \
    ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1 LLVM_PREFIX=/opt/llvm-23.1.1 \
    KERNEL=tools/mlir/native/build/bin/spinel-core-kernel \
    SPINEL_TYPEDUMP=tools/contract/build/spinel-typedump \
    ruby tools/app/bin/spinel-core-app build --app tests/app/fixtures/build/sample/app.rb \
         --board mps2_an521 --board-overlay tests/app/fixtures/build/mps2_an521.overlay \
         --out build/sample
```

Everything before step 11 lives under `<out>/.staging`; a refusal at any
step names it, removes the staging (`--keep-staging` keeps it for
diagnosis) and leaves no firmware. When step 10 passes, `<out>/firmware/`
holds `zephyr.elf`, `zephyr.map`, `link.log`, the final `zephyr.dts` and
`config`, the evidence with the measured `objects/` it names, one
`report_<entry>.json` per entry, the board package, the rendered `main.c`
and `build.json` -- the stack verdicts with every term and its evidence
kind, the interrupt inventory, the vector-slot classes and the memory
figures. The steps: the declarations (a period the 100 us tick cannot
represent is refused); the skeleton (`CMakeLists.txt`, `prj.conf` enabling
only the driver subsystems of the classes the application refers to, and
`app.overlay`: the board table's overlays and `--board-overlay` passed
through; in a pair's build, also derived from the declarations: an image
whose application declares no `uart:` channel takes the table's
`pair_no_console` overlay and fragment (decision 0027), and one with a
`wake:` entry takes the doorbell's, which disables the free MUs and sets
`CONFIG_MBOX=y` (decision 0028); 0027's cacheable control adds its own);
`west build --cmake-only` plus the generated headers, with the
DTS, `.config` and translated compile flags digested; the board package;
the providers, compiled by the kernel's clang against Zephyr's headers,
screened (0014 §6), measured with `-fstack-usage` and bound as evidence --
the transport thread and the Adc sampler are glue, compiled, measured and
screened for everything but the block set (the sampler's own thread stack
is a literal the build lists as unbudgeted in `build.json` until its
driver path is attested); the interrupt inventory (an interrupting node with no irq
row is `unknown` and refuses the build); the kernel per entry under
`realtime` with `--config-binding`; the glue (`main.c` from
`tools/app/templates/main.c.erb`: storage, entry wrappers, the scheduler
thread, timer dispatch and the failure handler) with `CoreApp::Stack.check`
deciding R for each thread and the interrupt inequality from the
inventory's worst nesting chain, the nested-entry hardware frame carried
explicitly; the link through west with the objects handed over
(`-DSPC_OBJECTS`), an orphan-section warning refused; the artifact checks
(digests unchanged, the stack objects and the recorded size words against
R, each used extern's evidence bound and its symbol defined by the measured
object in the map, every vector slot after word 0 classified, the image
against the board's RAM); publication.

`tests/app/build.sh` builds the acceptance sample for `mps2/an521` and
boots it under QEMU, builds it for FRDM-MCXN947, builds an application with
a provider of its own, and runs the fifteen controls, each with its own
build and each refused at the step the plan names (40 checks, about 141 s
on Debian; all 40 skipped, named, without the Zephyr environment):

```sh
env PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE=$ROOT/workspace/zephyr \
    ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1 LLVM_PREFIX=/opt/llvm-23.1.1 \
    KERNEL=tools/mlir/native/build/bin/spinel-core-kernel \
    SPINEL_TYPEDUMP=tools/contract/build/spinel-typedump \
    REQUIRE_ALL=1 sh tests/app/build.sh
```

The FRDM-MCXN947 build of the sample needs its overlay
(`--board-overlay tests/app/fixtures/build/frdm_mcxn947.overlay`), which
declares the two `zephyr,user` ADC channels the board's devicetree does not;
without it step 4 refuses the build with `unknown-member: Adc.latest`, as
`tests/app/build.sh` never sees because it always passes the overlay.

`frdm_imxrt1186` (decision 0021) has no `zephyr,user` ADC channels and no
`pwm-leds`, so `build.sh` builds a small application of its own for it
(`tests/app/fixtures/build/rt1186/app.rb`). Its image boots from FlexSPI NOR:
the boot header comes first in `rom_start`, and step 10 reads the vector
table at `_vector_table`. The board's reserve rows, the RGPIO effect row and
the interrupt rows of its SoC are in `tools/app/zephyr/v4.4.2/`, recomputed by
`tests/app/reserves.sh` like the other boards'.

`frdm_imxrt1186_cm7` (decision 0023) is the same board's Cortex-M7
(`frdm_imxrt1186/mimxrt1186/cm7`). Its units are compiled for
`thumbv7em-none-eabi`. Armv7-M has no PSPLIM, so the stock configuration's
`HW_STACK_PROTECTION` is an MPU stack guard, and step 10 checks each thread
stack object as `K_KERNEL_STACK_LEN`: R rounded to 8, plus the 64-byte guard
below the buffer, rounded to 64, at a 64-byte boundary. PendSV's reserve is
the guard's re-programming chain, 64 bytes. `build.sh` builds the RT1186
application for it as well (section 2c).

The M7 runs only when the M33 releases it, so its build is a sysbuild of two
images. The board table (`tools/app/zephyr/v4.4.2/boards/frdm_imxrt1186_cm7.tsv`)
names three things: the overlays and the Kconfig fragment the tool applies,
the launcher, and the NOR offsets.
- **The launcher** (`tools/app/launcher`) is the M33 image at NOR 0, with the
  boot header and the XMCD. It opens the TRDC and releases the M7
  (`CONFIG_SECOND_CORE_MCUX`, `CONFIG_CM7_BOOT_FROM_FLASH`). Its own RAM is its
  DTCM, and it has no console.
- **The application** runs in place from the NOR's `m7_code_partition` at
  0x100000 (`boards/frdm_imxrt1186_nor.overlay`). Its RAM is the HyperRAM
  (0x2800_0000 in the M7's view), and its console is LPUART1, the board's
  VCOM (`boards/frdm_imxrt1186_cm7.overlay`).
- **The session image** stays at 0x720000. Its base is the M7's NOR window,
  0x0400_0000, plus that offset.

The firmware directory holds `launcher.bin` and `launcher.elf`, and
`build.json`'s `launcher` records the launcher's board, offset and sha256.
`tools/doom/nor-image.rb` writes the launcher at its offset and the
application at `CONFIG_FLASH_LOAD_OFFSET`. The session id covers the
launcher's inputs, which are under `tools/app`.

**A Spinel application on the M33 as well** (decision 0027). With
`--companion APP`, the M33 image is that CORE application instead of the
launcher:

```sh
spinel-core-app build --app examples/doom/core/board/pair.rb --board frdm_imxrt1186_cm7 \
  --companion examples/doom/core/board/companion.rb \
  --session-image DIR --session-objects DIR --out OUT
```

- **Its table.** The M7's table names the companion's, `companion_board
  frdm_imxrt1186_cm33_amp`. That table builds `frdm_imxrt1186/mimxrt1186/cm33`
  with the launcher's memories: its RAM is its own DTCM (128 KB), it releases
  the M7 (`CONFIG_SECOND_CORE_MCUX`), and it has no console, since LPUART1 is
  the M7's. Its `reserves_board frdm_imxrt1186` reads the M33's traced reserve
  rows, each against the companion's own `.config`.
- **One sysbuild.** The companion's steps run between the M7's. Step 3
  configures both images with one west call, and step 9 links both with
  another, each image with its own objects. Both go through every step's
  checks, and a refusal of either leaves no firmware of either.
- **Its firmware.** It is published under `OUT/companion/firmware`. Its
  `zephyr.bin` is also the firmware's `launcher.bin`, so `nor-image.rb` writes
  it where the launcher goes.
- **The ids.** Each image has its own id: the session id for the M7, and for
  the companion the same digest less the session's parts. The pair id is a
  digest of the two. `build.json`'s `pair` records all three.
  - Before it releases the M7, the companion writes the pair id and its own id
    into line 11 of the OCRAM ring's header (`tools/app/ring/ring_abi.h`).
  - The M7 prints them at boot as `SPC_PAIR_ID` and `SPC_COMPANION_ID`. If the
    pair id is not its own, it prints `SPC_PAIR_REFUSED`. Either way it then
    clears the words, so a later boot with another M33 image never reads them.
  - Step 10 refuses either image if any of its sections lies in the ring's
    128 KB.
- **Refused together.** Neither application may have a `udp:` channel. Those
  need the M33's network firmware, which a build with a Spinel companion does
  not have (owner, 2026-10-26).
- **The lane.** `RT1186_PAIR=1 sh tests/doom-core/rt1186.sh DIR` builds
  `pair.rb` with `companion.rb`. The board part also requires the two ids
  `build.json` records, before the first frame (`board-frames.rb --pair`).

**Helper files.** An application's `require_relative "name"` names a file
beside it, or below it, that holds top-level definitions only. The build packs
it after the application, its definitions become the application's helpers,
and its digest is part of the id. `app.rb` and `pair.rb` share their tic this
way, through `examples/doom/core/board/demo_tic.rb`. The tool refuses:
- a helper's own requires, declarations, modules or constants;
- a helper named twice;
- a definition made twice.

**A channel between the pair's cores** (decision 0027 stage 2). Both
applications of a pair name one contract file, relative to each application:

```ruby
channel :console, contract: "channels/console.channel"
```

```text
core-channel 1
channel console
from cm7
to cm33
depth 16
field tic u32
field len u8
field text u8 count 119
```

- **The file.** It holds the fields in order, each at its natural alignment,
  little-endian, with no padding the file does not name. The types are `u8`
  `i8` `u16` `i16` `u32` `i32`, and `count` makes an array.
  `tools/app/lib/core_app/core_channel.rb` reads it and names every refusal:
  `i64` and `u64`, floating point, pointers, `offset` fields, unnamed padding,
  and a depth that is not a power of two up to 1024.
- **Direction.** The board table's `core` fact (`cm7`, `cm33`) says which end
  each build is. The producer's module has `put`, with each scalar field an
  argument and each array a buffer. The consumer's has `get`, with every
  field a buffer it fills. A narrow scalar is passed as `u32` or `i32` with a
  domain guard. An `i8`, `u16` or `i16` array is refused, since the tool has
  no such state.
- **Refused for the pair.** A contract channel without `--companion`, a
  channel only one application names, two different files under one name,
  both applications declaring a `uart:` channel, and channels that do not fit
  the 128 KB region.
- **The region.** The channels are laid out in name order after the header
  of `tools/app/ring/ring_abi.h` (version 5: six lines a channel, 704 bytes for
  one channel; decision 0028 and its follow-ups).
  - The companion writes the table at `PRE_KERNEL_1`, after checking that its
    MPU makes the region non-cacheable.
  - The M7 checks its MPU, the magic, the pair words, the table and each
    descriptor, and records the outcome in its own header line. A channel
    the check did not accept answers 0.
  - The pair id also covers each contract's sha256, and `build.json`'s `pair`
    lists the channels.
- **The console.** In a pair, the UART belongs to the core whose application
  declares a `uart:` channel. An image of the pair that declares none gets
  its table's `pair_no_console` overlay and fragment. When the M33 has the
  console, its `main.c` prints the M7's lines before the first relayed one:
  the M7's `SPC_SESSION_ID` from its header line, `SPC_PAIR_ID`,
  `SPC_COMPANION_ID`, `SPC_M33_SESSION_ID`, and `SPC_CHANNEL_REFUSED` when
  either core refused. It then prints `SPC_M7_FATAL` when the M7's generated
  `k_sys_fatal_error_handler` records a fatal error.
  `examples/doom/core/board/companion.rb` relays `pair.rb`'s console this way.
- **The wait from put to get** (decision 0027, the owner's of 2026-10-26).
  - Each put stamps its slot with the core's DWT cycle counter. Each get on
    the companion maps the stamp to its own counter and counts the wait in
    the channel's line M and in `spc_channel_<name>_wait_hist`. The unit
    reads the counter itself, so it still calls nothing.
  - The companion aligns the two counters at start, in 16 round trips with
    the M7, and renews the reference every 10 ms. Once a second it measures
    the drift (`tools/app/ring/wait_map.h`, `cycles.h`).
  - The lane's `pair-counts.rb` reports the figures in microseconds at the
    companion's `CYCLES_PER_SECOND`, as a measurement and not a verdict.
    Both counters run from RC24M. Since ABI version 4 the companion also
    keeps its drift rounds in the channel's line E, and `pair-counts.rb`
    prints the drift's estimate, each departure with its half round trip,
    beside the lower bound (decision 0028 Q5).
  - Since version 5 (0028's follow-ups, the owner's of 2026-10-29):
    - line C names the message whose wait was the longest
      (`lat_max_at`), and `pair-counts.rb` prints its number, 0 being the
      first put;
    - the M7 answers the drift rounds from `main` at priority 0, above the
      scheduler, so that they are not left to the lowest priority;
    - line F, which the M33 alone writes, keeps the rounds that timed out
      and each kept round's g: the time from the companion's read before
      the one that saw the answer to t1. The M7 stamps, a barrier, and
      stores `s7_seq` with its interrupts locked, and the companion loads
      `s7_seq`, a barrier, then reads t1. So the departure measured from
      t1 is a one-sided bound, in [dev - trip/2, dev - trip/2 + g], and
      `pair-counts.rb` prints it beside the midpoint's.
    - `pair-counts.rb` reads version 5 only: another version, or line F's
      spare words 4 to 7 not 0, exits 2, named.
- **The doorbell** (decision 0028, the owner's of 2026-10-27). An entry of
  the consumer's application declared `every_ms 10, :relay, wake: :console`
  is also released when the producer puts into `console`.
  - `wake:` names a contract channel this core consumes, on a thread entry.
    Anything else is refused at step 1, as is `wake:` in a verification
    build for now.
  - The MU and its interrupts are board facts (`doorbell` in each table):
    MU1, GIR0 from the M7 to the M33 and GIR1 back. MU2 stays free
    (`doorbell_free`), and the consumer's image disables it.
  - The descriptor's `notify` names the doorbell (0x01: MU1, GIR0). The
    consumer's get, finding the ring empty, stores `waiting = 1` and reads
    `head` again. The producer's put, after publishing `head`, reads
    `waiting` and, when it is 1 and GIR0 is 0, writes GIR0 of its own
    side's GCR and counts `rung`. The put still calls nothing.
  - The consumer's glue takes the interrupt through Zephyr's MU driver
    (`CONFIG_MBOX=y`). Its callback counts the wake-up in line C
    (`woken`), marks the entry due, and gives the semaphore the scheduler
    thread waits on in place of its sleep. The period stays, as the time-out
    of a doorbell that never comes.
  - The MU's interrupt has its own reserve row, `isr_mbox_nxp_imx_mu`, and
    step 10 charges the callback's measured frame to it.
  - The build's controls for the board: `--mutate-doorbell-unrung CHANNEL`,
    `--mutate-doorbell-unenabled` and `--mutate-doorbell-notify CORE`.
  - `examples/doom/core/board/companion.rb` is woken this way.
- `tests/app/core-channel.sh` holds the reader, the declaration, the host
  simulator and the doorbell's generated put and get to planted inputs.
  `tests/app/build.sh` 2f builds a contract pair and its controls, and 2g a
  pair with a doorbell and its controls.

The board table's `session_itcm_entries` names session entries whose code
runs from the instruction TCM rather than in place from the NOR. On
`frdm_imxrt1186_cm7` that is the render entry: 111,118 B of the 256 KB ITCM,
measured at −2.27 ms per tic on DEMO1's first 500 tics (2026-10-21).
- **Copy.** At step 5 the entry's object is linked from a copy whose `.text`
  and `.text.<name>` sections are renamed to `.itcm`. Zephyr's linker script
  puts `.itcm*` in the ITCM with its load address in the NOR, and
  `z_data_copy` copies it at boot.
- **Capacity.** Step 4 refuses entries whose code does not fit the
  `zephyr,itcm` node. The step entry's 226,592 B does not fit beside render's.
- **Checks.** Step 10 checks that the entry's symbol lies in the ITCM.
- **Records.** `build.json`'s `session.itcm` and the session id record the
  placement.

A board whose table names no entries, such as the M33's, keeps the code in
place. `--mutate-itcm-entries LIST` replaces the board's list, for the
controls of `tests/app/session.sh`.
The M7's console transport is interrupt-driven: its board conf sets
`CONFIG_UART_INTERRUPT_DRIVEN`.
- **Transmit.** The transport thread puts each frame into a 1 KB transmit
  ring. The LPUART's interrupt drains the ring into its FIFO
  (`transport_uart.c.erb`), so a line goes out while the scheduler runs. With
  polling, the lowest-priority transport thread sent it only between tics,
  which added its wire time, about 6 ms at 115200 baud, to every tic. The
  framing and the bytes are unchanged.
- **Stack accounting.** The console LPUART is an interrupt source of the
  inventory, with the board's `isr_lpuart` reserve: the driver's handler and
  the deepest driver call the callback makes. The stack check adds the
  transport's callback frame to it and leaves it off the transport thread.
  The thread's `uart_calls` reserve is the interrupt-driven one: `poll_in`
  for the inbound bytes and the transmit-interrupt enable.
- **Elsewhere.** A board without the option, the M33 among them, keeps the
  polled transport.

### The verification build, the trace and the checks (Task 11)

`spinel-core-app verify` is decision 0014 §10 (a) end to end: a
verification build (`build --verify --stimulus <script>`: every unit the
pipeline compiles with `-DSPC_VERIFY` (Zephyr's own are west's), the recorder, the stimulus thread from the script, the
nesting source when the script asks for it, the kernel's `--record-cross`
lowering so each cross-context access -- integer elements, the only kind
an application has -- is performed and recorded inside one PRIMASK section), the run under the SDK's QEMU until the `SPC_END` line
(`-icount shift=5`, 32 ns per instruction -- the board's default shift 7
starves the recorded build's transport thread), the console demultiplexed
into text lines, the application's frames and the trace frames (channel
0xFE), the trace decoded by `tools/app/lib/core_app/trace_schema.tsv`, and
the four checks and the replay of `tools/app/lib/core_app/verify.rb`. The
report goes to `<out>/verify/report.json` beside `trace.txt` and
`console.bin`: the verdict, every failure by record and rule, the releases
by class, the channels' figures, the cross loads, the replayed invocations,
the painted stacks' marks against their static values, and the D3
instruction figures with their method.

**A trace is compared within a host, never across one.** Two runs of the same
tip on one host gave an identical trace, epoch and clock readings included
(measured once, on macOS, at Task 11's tip; the property is not asserted by
any check).
Two hosts do not: the record count, the kind multiset, the invocation count,
the painted marks and the D3 figures agree, and the ORDER differs at a few
positions where a transport drain interleaves differently against a
timer-driven invocation. Nothing here depends on the stronger property -- a
run is checked against its own trace, and the decoder fixtures are compared
with the checked-in file on whichever host runs them -- so a live trace is
never diffed against `tests/app/fixtures/trace/sample-run/trace.txt`, and a
difference there is not a defect. The two hosts' SDK QEMU binaries are
different builds of 10.0.2; which input causes the interleaving is not
established.

```sh
env PATH="$ROOT/.venv/bin:$PATH" ZEPHYR_BASE=$ROOT/workspace/zephyr \
    ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1 LLVM_PREFIX=/opt/llvm-23.1.1 \
    KERNEL=tools/mlir/native/build/bin/spinel-core-kernel \
    SPINEL_TYPEDUMP=tools/contract/build/spinel-typedump \
    ruby tools/app/bin/spinel-core-app verify --app tests/app/fixtures/build/sample/app.rb \
         --board mps2_an521 --board-overlay tests/app/fixtures/build/mps2_an521.overlay \
         --stimulus tests/app/fixtures/stimulus/sample.tsv --out build/verify-sample
```

`--console FILE` verifies a captured console instead of running QEMU;
`--trace-text FILE` verifies a text trace (the mutation controls of
`tests/app/mutate.rb`), with `--board-dir` naming the board package to
load. `tests/app/verify.sh` runs the decoder fixtures, the seventeen
mutations over the checked-in trace of the sample's run, and, with the
Zephyr environment, the sample's run and the `divides` run (36 checks,
about 30 s; 24 and 12 skipped without the environment).

`tests/app/run.sh` runs the `tests/app` suites and prints each one's count
line and wall time; its suite list plus the excluded ones and the files on
disk must agree both ways, and `REQUIRE_ALL=1` reaches every suite it runs.
It excludes `doom-admission.sh`, which needs two kernels and is an oracle (a
baseline-kernel comparison) run only on the owner's instruction. The user guide is
[CORE applications on Zephyr](core/applications.md).

`tests/app/stress.sh` is Task 12: the production primitives under preemption.
It builds `tests/app/stress/app.rb` as production with the build's sampling
source (`--stress PERIOD_US[,REPORT_AT]`, CMSDK timer 1 of `mps2/an521`), runs
it under QEMU at icount shift 5 with UART input for the inbound channel, and
requires a hit in each span of the preemptible side, no content failure (off
the wire and at the consumer), a live consumer, the IR's atomics on the cross
state, and a negative control (`--mutate-ring-early-publish`) refused both by
the label check and by the run (12 checks, about 67 s on Debian; 11 skipped
without the Zephyr environment).

A thread an adapter's glue creates (the Adc sampler, `adapters/adc/sampler.c`)
has a requirement of its own since the sampler item of Task 10's list: the
class's `thread` row names its unit, stack macro, object, entry, the init
that runs on the main thread and its reserve items (`drv_adc_read`, the
driver's attested blocking read path per board; `thread_kernel_calls`);
the build derives R, recompiles the unit with `-D<macro>=R`, reads the
object and the size word back at step 10, and `build.json`'s
`adapter_threads` lists it; `--mutate-adapter-stack -1` is its R − 1
control. A verification run prints and checks its mark with the others.
The named reserves are alternative blocking paths, not one sequence: they
are summed, which bounds whichever path the thread is in, and each term
in `build.json` says so. The init is excluded from the sum because it runs
on Zephyr's main thread, whose stack no inequality bounds; its frame is
published under `adapter_threads.excluded` rather than dropped. Both the
entry and the init must be functions of the named unit, or step 8 refuses
the row -- which is also what catches a shifted or mistyped field.
`threads_unbudgeted` is then empty for a production build; a verification
build lists the stimulus thread, whose literal stack is the verification
glue's own and outside the inequalities.
