# tools/realtime -- the allocation-freedom prover

Ported from spinel-llvm `463d49dd` (E056, E169); see
[provenance](../../docs/provenance.md). `spinel-rtcheck` proves, for each entry
method, that no path from it reaches an allocator: it compiles the Ruby program
with the pinned Spinel to C, the C to LLVM IR, links the runtime's bitcode,
and walks the call graph against the allocation vocabulary in
`alloc_vocabulary.tsv` (the one source the native build and the freestanding
undef gate both read).

The product is native: `tools/realtime/spinel-rtcheck` only execs
`tools/mlir/native/build/bin/spinel-rtcheck`, which `tools/mlir/native/build.sh`
builds (`lib/Realtime`, `tools/spinel-rtcheck`).

## Before the first run

The runtime's bitcode is built once, from the pinned `vendor/spinel/lib`:

```sh
LLVM=/opt/llvm-23.1.1 bash tools/llvm/build_rt_bc.sh
# -> tools/llvm/build/libspinel_rt_lto.a and libspinel_rt_mt_lto.a
```

`build_rt_bc.sh` is the one file taken from spinel-llvm's `tools/llvm`; the
rest of that backend is not imported. `BC_DIR` names another location.

## Use

```sh
export LLVM_PREFIX=/opt/llvm-23.1.1
tools/realtime/spinel-rtcheck app.rb --entry 'Game#tick' --int-overflow wrap -o out
tools/realtime/spinel-rtcheck kern.ll --entry spinel_add --allow-abort
```

The output is `verdict<TAB>entry<TAB>cause<TAB>detail`, and the exit status is
non-zero when any entry is not proved. The main options: `--entry SPEC` (a
Ruby spelling or a raw symbol, repeatable), `--entries FILE`, `--all-ruby`,
`--allow-abort` (ignore allocations on paths that cannot reach `ret`),
`--indirect {conservative,address-taken}`, `--int-overflow
{raise,wrap,promote}` (passed to Spinel; it changes verdicts), `--link-bc
FILE`, `-o DIR`, `--print-region`, `-q`, `-v`, `--keep`.

It is function-grained (an in-bounds `a[i] = v` shares a runtime function with
the growing path, so `ary_set` is refused), most runtime error paths allocate,
it sees FFI shims only if they are passed as bitcode, and it says nothing
about time.

## Checks

```sh
bash tools/realtime/test/run.sh    # the prover's own verdict table: 22 rows, 11 accepted, 11 refused
```

`ab/` (`run_e169.sh`, `test_e169.rb`) compares this native tool byte for byte
with the frozen Python it replaced. It is an oracle, kept as files, and runs
only on the user's instruction.

## Local change

The pinned compiler emits a top-level method whose plain name could collide
with a runtime symbol as `sp_rb_<name>` (`str_build`, `raise_guard`,
`loop_break` in the test cases); the predecessor's pin did not. The entry
spelling tries `sp_<name>` first and `sp_rb_<name>` second.
