# Compiler patch review for CORE DOOM

Status: design input, 2026-09-12; no new compiler patch or pin change is claimed.
The owner requested this review as part of Stage 2. Execution belongs to
[0008's plan](../decisions/0008-doom-core-migration-plan.md).

## Fixed comparison points

- Extended integration base: `5ee37630663d3ad66a9b45f43bf84a09e42132b7`.
- Extended compiler: `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`, from
  `yuskesh/spinel`, including the process arena, selected-root seam and ledger.
- Predecessor application: `f8ad13c6d9dc990b116ba1c842c7881232f29585`.
- Predecessor compiler: `ecbd0f2a7cd134d5affc2bd705f0f0e83aa82101`,
  branch [`spinel-fork/c-emit-ir`](https://github.com/yuskesh/spinel/tree/spinel-fork/c-emit-ir) of `yuskesh/spinel`, a mirror of
  the predecessor's spinel-fork.

The fork default branch was confirmed at that compiler revision via GitHub on
2026-09-12. The initial classification below uses commit/source inspection and
the historical [compatibility checkpoint](../doom/task1-checkpoint.md), not
fresh reproducer runs. Stage 2 must rerun its selected fixtures under the
documented toolchain. No checked-in recipe may read a sibling repository.

**The rerun has happened.** The section [Measured at the pin](#measured-at-the-pin)
below carries it. The initial classification in this section is kept as it was
written, because it is the record of what was believed before the measurement;
where the two differ, the measurement is what holds.

## Bug-fix batches

| batch / source commit | subject | existing evidence at Extended pin | initial action |
|---|---|---|---|
| 1 / `99a5fc49` | six GC-soundness fixes | `$0` and cross-variant Hash merge defects identified; other rows differ in coverage; MatchData builder root absent | separate all six; prioritize required Full paths, prepare minimal candidates for reproduced cases |
| 2 / `61ffe24e` | loop-source rooting | not reproduced under checkpoint conditions | rerun relevant fixtures; inspect root placement, do not infer upstream resolution |
| 3 / `8154ec0c` | folding/scope merge | two listed cases did not reproduce | rerun against refactored hosted control flow |
| 4 / `c02ca2cf` | builtin exception poly dispatch | reproduced truncated execution | keep outside CORE; test any new Full error path before using it |
| 5 / `7d8a6408` | builtin pre-arm unboxing | reproduced generated-C type error | same; a clean unrelated game build is not coverage |
| 6 / `da2d009d` | poly result widening | extended fixture reproduced compile error | same; preserve the distinguishing builtin arm in the control |
| 7 / `8648d478` | widened binary string writes | IO append truncated; fixture write/syswrite paths matched | validate the exact output operation and receiver variant used by the new bridge |
| 8 / `cec1ec4d` | print/puts binary length | NUL truncation reproduced; `sp_File_puts` still uses strlen | binary bridge uses explicit lengths; prepare fix if a required Full path cannot avoid the defect |
| 9 / `883957dd`, `bd2d276a` | included ivars; return rederivation | listed cases not reproduced | inspect/retest if the new hosted wrapper needs these forms |
| 10 / `f8512260` | empty FloatArray nil | listed case not reproduced | no float dependency in CORE; retain an explicit Full-only disposition |
| 11 / `ecbd0f2a` | nil Float display | reproduced NaN display for nil; real NaN control matched | no float dependency in CORE; retain the known compiler defect |

Priority is not an absence claim. CORE cannot reach GC/runtime helpers, but its
Full caller can. The initial audit covers every row, including rows deferred
from the implementation's critical path. A patch's unrelated historical
experiment archive is not imported; only necessary executable fixtures and
attribution are carried over.

## Opt-in patches and analysis instruments

Read the complete `SPINEL_LLVM_PATCHES.md` and `SPINEL_EBPF_PATCHES.md` at the
fixed fork revision. These are source provenance identifiers, not local build
dependencies. Enumerate their individual entries rather than treating the
eleven bug-fix batches as the whole fork.

| patch/instrument | Stage 2 disposition to verify |
|---|---|
| `SPINEL_EXTERN_METHODS` | current selected-root seam and explicit adapter already supply linkage; do not replace them with the older gate |
| `SP_UNMASKED_SETJMP` | optional Full optimization with a signal-mask boundary; no CORE need, defer performance change |
| `SP_STRLEN_DEDUP` | optional Full string optimization; no CORE runtime string access, defer pending measurement |
| `SP_INT64` | native hosts already have 64-bit pointers; CORE has explicit i64 independently; reassess only for a separately selected 32-bit target |
| `SP_TU_NO_BIGINT` | CORE zero-runtime gate already requires no bigint dependency; do not remove bigint from general Full programs |
| `SP_REQUEST_ARENA` and driver variants | compare with the implemented Extended process arena; no duplicate import, no use as a substitute for CORE |
| L1 `SPINEL_LLVM_SHL_DEFER` | inference behavior, not just tracing; reproduce before considering it |
| L2 node IDs; L3/L4 codegen facts; L5 widening logs | current reader supplies source facts; import only a demonstrated missing analysis capability |
| L7 range facts/assertions | current checked operations are authoritative; optional evidence never grants unchecked access |
| L8 GC tracing | Full instrumentation only; consider if needed for end-to-end measurements |

Patch 3 was intentionally not implemented in the predecessor; do not create a
missing-patch task for its number. New entries found in the fixed patch ledgers
must receive their own disposition before the audit is called complete.

## Executable audit record and adoption rule

Create `tests/doom-core/fork/ledger.tsv` with columns `id`, `fork_commit`,
`fixture`, `domain`, `source_status`, `run_status`, `decision`, `reason`.
Domain is CORE, Full, analysis or instrumentation. Source status is
present-verified, absent-verified or not-inspected. Run status is reproduced,
not-reproduced, not-applicable or not-run. Decision is reuse-current,
prepare-fix or defer. Every not-applicable/not-run/defer row requires a reason;
none counts as a passing execution. Batch 1 has six defect IDs, not one.

A required reproduced blocker cannot be deferred to get a green milestone.
Before changing a pin, provide the exact patch, positive/negative controls,
old/new output comparison, compiler corpus results, changed behavior and
candidate SHA. Use an isolated branch of `yuskesh/spinel`; keep the predecessor
fork untouched. Preserve both-host acceptance and the ordinary hosted/arena/
selected-core routes. Optional optimizations do not travel with correctness
fixes merely because they share a predecessor branch.

## Measured at the pin

Run on Debian 13 x86_64 with the compiler this repository pins
(`cad0ad148af00b98a3de8a384c18a3cabe15bc1a`) built with official LLVM 23.1.1,
and the generated C compiled by the same clang, named explicitly:

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/doom-core/fork-compat.sh
LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/doom-core/fork-compat-controls.sh
```

`tests/doom-core/fork/ledger.tsv` carries all 29 rows — sixteen defects
(B1–B16), two later batches with no reproducer of their own, seven opt-in
patches and five analysis instruments. Batch 1 is six rows, not one. Eleven
reproducers were imported verbatim from the fork at `ecbd0f2a`, with their
digests in the ledger and their licence in
`tests/doom-core/fork/fixtures/NOTICE.md`; nothing in this repository reads the
predecessor checkout.

Each row's `run_status` is a pinned measurement: the harness runs every row
that names a fixture five times and fails if what it measures disagrees with
what the ledger says, so the table below cannot go stale quietly.

**Executed 12, all agreeing with the ledger. Not executed 7. Source 10.**

### Still present at this pin (6)

| id | batch | defect | evidence | decision |
|---|---|---|---|---|
| B2 | `99a5fc49` | both operands of `Hash#merge` are unrooted | 0/5 runs return the expected bytes at the default threshold | defer — DOOM uses `Hash#merge` nowhere (measured: 0 occurrences under `examples/doom`) |
| B10 | `c02ca2cf` | the poly dispatch cannot answer a builtin exception's `message`/`backtrace`/`cause`/`full_message` | the program exits 1, 0/5 | defer — poly exception dispatch stays outside CORE, and no Full path here raises through a poly receiver |
| B11 | `7d8a6408` | the poly dispatch builtin pre-arm unboxes into a slot it does not fit | the reproducer does not compile | defer — same boundary as B10 |
| B12 | `da2d009d` | a poly call whose arms disagree leaves its result slot unboxed | the same reproducer does not compile | defer — same boundary; the fork notes this batch changes generated C for programs that already worked, so adopting it is not additive |
| B13 | `8648d478` | the `IO#write` family measures a widened String with `strlen` | 0/5 runs return the expected bytes | defer — DOOM's one binary write is `DemoWriter#save` at `examples/doom/lib/doom/record.rb:77`, and the defect needs an inferred `TY_POLY` String; measured, the reader types that argument `string` |
| B14 | `cec1ec4d` | the output family measures a String with `strlen`, and `puts` reads the wrong byte for the trailing newline | 0/5 runs return the expected bytes | defer — DOOM's `print`/`puts` carry interpolated diagnostics and TSV rows, never binary |

B14 confirms this review's earlier reading that `sp_File_puts` still uses
`strlen` at the pin. B2 also agreed 5/5 under `SPINEL_GC_FULL_INTERVAL=1`,
which is not a contradiction: forcing a collection that often moves it out of
the window the defect needs. The default-threshold run is the one that counts.

### Already fixed at this pin (6)

| id | batch | defect | evidence |
|---|---|---|---|
| B1 | `99a5fc49` | an inlined yielding `initialize` leaves the instance under construction unrooted | 5/5, and 5/5 under forced collection |
| B7 | `61ffe24e` | a loop leaves the source array or receiver it is walking unrooted | 5/5, and 5/5 under forced collection |
| B8 | `8154ec0c` | a generated writer is not counted, so `if @x` folds to constant false | 5/5 |
| B9 | `8154ec0c` | two same-named rescue bindings merge into one slot | 5/5 |
| B15 | `883957dd` | an included module's ivar slot falls to `TY_POLY` and boxes the includer | 5/5 |
| B16 | `bd2d276a` | the post-fixpoint re-narrow does not re-derive a return type | 5/5 |

B8, B15 and B16 are the three whose domain is CORE rather than Full: an ivar
guard folded constant-false, the ivar slots of an included module, and
return-type inference all decide the code a CORE entry is compiled from. DOOM
includes six modules into `Game` and the closure audit measures 150 per-class
instantiations of their methods, so B15 in particular is not hypothetical. All
three come back clean.

### Not executed (7)

B3, B4, B5 and B6 are the four batch-1 rows the fork found under stress and
never gave a fixture; `$0`, Rational and MatchData are runtime types no CORE
entry can hold and DOOM's Full caller does not use. Batches 10 and 11 changed
`lib/sp_array.h` and codegen with no test, and are float defects in a program
that is fixed-point throughout. L1 (`SPINEL_LLVM_SHL_DEFER`) is inference
behaviour with no reproducer in the fork, so it would have to be reproduced
before being considered.

None of these is counted as a pass. The harness prints them under their own
heading and the controls check that they never appear as a measurement.

### No pin change is proposed

Every reproduced defect is deferred with a measured reason, so nothing here
asks for a compiler candidate. If one of these later turns out to block a
required path, the rule above still applies: exact patch, positive and negative
controls, old and new output, compiler corpus results, changed behaviour and a
candidate SHA, on an isolated branch of `yuskesh/spinel`, with the predecessor
fork untouched.
