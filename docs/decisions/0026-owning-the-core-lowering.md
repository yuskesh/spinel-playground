# 0026: Owning the CORE lowering, and the shared facts it reads

- Date: 2026-10-23
- Status: Accepted (owner, 2026-10-23), with the before/after comparison in
  Validation and the acceptance criteria as written. Implemented: all five
  steps are on main by `dbcf88d`; see "Validation, measured".
- Scope:
  - the ownership of `tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp`,
    `Importer.cpp` and `SubsetTables.cpp`, which every CORE route shares;
  - three facts that consumers of the admitted closure now derive in more
    than one place: resolved internal call edges, source-level allocation
    legality, and the integer, pointer and buffer-element widths;
  - revises item 3 of [0013](0013-semantic-layer-followup-and-core-ir-triggers.md)
    and corrects one of its figures.

## Context

Four tools lower Ruby to MLIR through the same library, `SpinelMLIRScalar`:
`spinel-core-kernel` (the board's DOOM entries and the CORE boundary),
`spinel-core-emit` (the native core route), `spinel-fs-emit` (freestanding)
and `spinel-fs-grad` (gradients). Full does not use MLIR; it stays on
Spinel's C path, and nothing here changes that.

0013 recorded that this library is a transliteration of a predecessor's
Python generator that is not in this repository, and proposed conditions under
which the question of a Core IR reopens. A re-measurement on main `6e23735`
(the coordinator, cross-checked independently by the reviewer) found:

- `MlirGen.cpp` grew from 3365 to 4252 lines; 94 lines still name the frozen
  generator.
- Trigger B is met: a second target axis acts inside the generator.
  `integerBits` ([0019](0019-target-integer-width.md)) and `freestandingTypes`
  are read in the same functions (`typeOf`, `needNumeric`, the binary
  operators).
- Trigger C is met: three source consumers (native CORE, freestanding, the
  [0014](0014-core-applications-on-zephyr.md) applications) while allocation
  legality still has two source-level owners, `Eligibility` and the
  freestanding tables.
- Signal 6 is non-empty: `SubsetTables.cpp`, which says it is generated and
  must not be hand-edited, was hand-edited in `60a67f1` (a reason string; the
  key set did not change). Its generator is not in the tree, so its own
  instruction cannot be followed.
- Triggers A and E are not met; D is met only by an optional Rust stage of the
  eBPF route, which carries no Ruby semantics.
- The two "is this a call into the closure" predicates still differ
  (`Eligibility.cpp:2031` `isInferenceCall`, `LoopBounds.cpp:511`
  `callsClosure`), and `Effects.cpp` added a third reading of receiverless
  calls.

**Correction to 0013.** 0013 counted "36 node entries and 46 call entries" in
`SubsetTables.cpp`. The table has 36 node entries and 10 call entries, 46 in
all, both at 0013's revision `d19957c` and now.

The finding agrees with 0013's conclusion: what breaks first is the ownership
of the lowering, not the expressiveness of its intermediate form. A
universal Ruby IR would not fix it.

## Options

- **(a) Widen the `spinel` dialect** (today three ops: checked add, subtract,
  multiply) so CORE contracts survive as ops that MLIR verifiers check.
  Deferred: it needs the lowering it would grow inside to be owned first, and
  a concrete second consumer of the same normalized meaning.
- **(b) Own the lowering and its tables, and give each shared fact one
  owner.** Chosen. It addresses the maintenance risk that exists today and
  needs no new IR.
- **(c) A Ruby-level dialect shared by all routes.** Rejected for now: it would
  need a new contract for types, calls, exceptions, GC, borrowing and effects,
  would move every emitter, and would put the independent object gates behind
  one generator. Tensor, raster, shader and SpBPF already enter upstream or
  their own dialects directly.
- **Importing spinel-mlir's `spinel_facts` transport** (bpf-mlir's ongoing
  project) is a later, separate decision: it depends on patches to Spinel,
  which are a vendor approval boundary here, and that project is not complete.

## Decision

Proposed, in five steps. Each step lands on its own branch with its own
evidence. No step changes what any route accepts, refuses or emits, except
where a step says so.

1. **`SubsetTables.cpp` becomes a hand-maintained table.** Its header says so
   and records where its entries came from; the instruction to regenerate
   from the absent Python is removed. A check pins the key sets (36 node
   kinds, 10 call names) and a digest of the reason strings. Changing either
   without changing the pin fails the check.
2. **Each table entry is tied to evidence.** A tracked map lists every entry
   with the test that shows its refusal, or marks it
   `unverified-inherited`. A check fails if an entry has no row. Entries
   marked unverified stay in force; they are named, not removed.
3. **The inputs the lowering reads are checked against Spinel's known
   pitfalls**: decisions that exist only in Spinel's C codegen (callees,
   dispatch), methods Spinel never lowers because nothing calls them, line
   shifts from Spinel's own `require` splicing, Spinel's renames (`__redefN`,
   `A__Ctx`), and nodes that span two files. Each is recorded as not reached,
   reached and harmless (with the reason), or a defect; a defect becomes its
   own fix.
4. **Resolved internal call edges become a fact of the eligibility report.**
   Eligibility resolves each admitted call once; `LoopBounds`, `Effects` and
   the lowering read the edges instead of re-testing call nodes. `callsClosure`
   is removed. The report's other fields and `kLoopDigestVersion` do not
   change.
5. **Allocation legality gets one source-level owner, and widths become three
   settings.**
   - "Does this construct allocate" moves into `Eligibility` for the entries
     step 2 covers. "Is allocation allowed here" stays target policy in
     `FreestandingProfile`. Entries that step 2 left unverified stay in the
     table, which becomes the explicit list of inherited refusals.
   - The lowering's options separate the Ruby integer width (0019), the
     pointer width, and the buffer element widths
     ([0018](0018-narrow-buffer-elements.md)). Equal bit counts are not
     treated as the same setting.

Not in scope: new `spinel` dialect ops, `spinel_facts`, Full's C path, the
object gates (`UndefGate`, the artifact gates, `StackBudget`, `Realtime`),
which stay independent of the analysis they check.

## Validation

- **Steps 1 and 2.** Each new check carries a planted control: a changed key, a
  changed reason string, and a table entry with no row each fail by name.
- **Step 3.** A written finding per pitfall, with file and line, saying what
  was observed and what was inferred.
- **Steps 4 and 5: output is unchanged.** The owner authorized a before/after
  comparison for this work on 2026-10-23. For every route's fixtures (native
  core, the CORE boundary and DOOM entries for host and Cortex-M7,
  freestanding lanes, gradients), compare the old and the new tool's output:
  the generic-printed MLIR with implicit file locations stripped and explicit
  Ruby locations kept, and the object bytes. Both arms must exit 0 with
  non-empty output, and a 1-byte test-only change must be refused by name.
  Refusal diagnostics are compared as full text.
- **Every step:** the tests `tools/test/affected.rb` picks, and the merge check
  (`tools/doom/verify-sources.sh`, `tests/affected/run.sh`).
- **At the end of all five steps, once:** the long checks, including the
  RT1186 board lanes.

## Consequences

- The tables and the generator are edited as this project's code, with their
  origin kept in [provenance](../provenance.md).
- 0013 item 3 is superseded by steps 1, 2 and 5. 0013 itself stays Proposed;
  its triggers remain the test for reopening a Core IR.
- When a new contract is added later, re-count: how many places decide the
  same source fact, how many places a width or failure-ABI change touches, and
  whether two transformations need the same normalized meaning. The last is
  what would justify option (a).

## Clarification (2026-10-23): step 4 resolves CORE calls once, and freestanding keeps the selector

Step 4 gives the CORE routes one resolver. `Eligibility` records each call into
the closure as an edge (caller, callee, call node) in `EligibilityReport`;
`spinel-core-kernel` and `spinel-core-emit` hand those edges to the importer's
selector, and `LoopBounds`, `Effects` and the lowering read them.

`spinel-fs-emit` and `spinel-fs-grad` run no eligibility check, so for them the
selector still resolves call names, and the lowering reads the edges it
resolved (`ScalarProgram::calls()`). "Eligibility resolves each admitted call
once" therefore holds for the CORE routes only: the freestanding routes keep a
second resolver, and no selector edge enters `EligibilityReport`. Giving them
one resolver would need the eligibility check on those routes, which step 4
does not do.

## Clarification (2026-10-23): step 5 owns the subset refusal table, and CORE's allocation is its heap-operation column

Step 5 says "does this construct allocate" moves into `Eligibility`. What
the CORE and freestanding routes share is narrower than that phrase. The
owned fact is the freestanding subset refusal table
(`tools/mlir/native/lib/Core/SubsetRefusals.cpp`): the 30 node kinds and 10
call names that step 2 ties to a fixture, each with the reason its refusal
gives, and a CORE column. The column marks the 7 node kinds the CORE checker
refuses as heap operations (Array, Hash, String, interpolated String,
Regexp, Range and lambda literals). Only those 7 are what CORE calls
allocation; the other node rows are refusals for other reasons (runtime
state such as `self` and constants, `nil`, `case`, a nested `def`), which is
why the table is named for refusal, not allocation. The CORE checker reads
the column instead of listing the kinds itself, with the same set and
the same words; its other rules are unchanged.

The table is data in a library of its own that depends on nothing but the
standard library. `spinel-fs-emit` and `spinel-fs-grad` link it through the
lowering library without linking the checker, so they still run no
eligibility check. The 6 entries step 2 left `unverified-inherited` stay in
`SubsetTables.cpp`, the explicit inherited list; the freestanding walk reads
the owned table, then that list. `tests/subset/coverage.tsv` decides which
file holds a key, and `tests/subset-tables/check.rb` pins both files
together.

Of the widths, the lowering's options now carry `pointerBits` beside
`integerBits`. The width of a buffer's count and hidden bound follows the
Integer width today, as it did, through `ScalarImportOptions::countBits()`.
No site of the lowering reads `pointerBits` yet; two that name "a 32-bit
target" read the Integer width, recorded in
[the lowering's inputs](../core/lowering-inputs.md) section 6 for the owner.

## Clarification (2026-10-24): Validation, measured

All five steps landed on main, each on its own branch:

- step 1, the hand-maintained table and its pin: `aa257b8`;
- steps 2 and 3, the evidence map and the input findings: `86927c7`;
- step 3's four defects, each its own fix: `c80ab9f` (file locations),
  `cc22891` (a reopened builtin), `5469f8d` (a method split across files) and
  `5869b11` (the duplicate-method message);
- step 4, the call edges: `c7affd5`;
- step 5, the refusal table and the widths: `3866a93`.

The before/after comparison is `tools/core/compare-lowering`, an oracle the
owner authorized for steps 4 and 5 only (`tests/ORACLES.tsv`). It wraps the
lowering tools of two frozen builds and runs the route suites through them.

- **The first comparisons left five tools out.** At step 4's merge, the
  harness wrapped the kernel, `spinel-core-emit`, `spinel-fs-emit` and
  `spinel-fs-grad` (695 calls), but suites took `spinel-core-check`,
  `-boundary`, `-adapter`, `-package` and `-stack` from the tree's own
  build. Step 5 found this when three core-boundary lanes could not run
  against a stale tree build and the run still said "no difference".
  Step 5's harness (`24138f9`) wraps all nine tools, and a run fails by name
  when a lane could not run, a skip is unnamed or a count differs from
  `tests/compare-lowering/counts.tsv`.
- **Step 4**, `8c38624` against `c7affd5`, re-run with that harness after
  step 5's merge: 944 calls, 637 identical outputs, 307 identical refusals,
  0 differences, no lane that could not run. The five tools added: check 71
  calls, boundary 118, adapter 36, package 16, stack 8. An identity run of
  `c7affd5` against a second copy of its build gave the same figures.
- **Step 5**, `c7affd5` against `b4f3bf3`: 944 calls, 637 identical, 307
  identical refusals, 0 differences, counts equal to the baseline; the
  identity run likewise.
- **Controls**, at each tree: a 1-byte change to an object, to the generic
  MLIR or to a refusal text is reported as a difference by name. Without
  `ALLOW_ORACLE=1` the harness runs nothing. A stale tree build and a changed
  baseline count each fail by name.
- The run records and their summaries are kept outside the repository; the
  figures above were read from them on the day.

The long checks ran once, at the end, at `dbcf88d`, each alone, from frozen
copies of the kernel and the reader:

- `tests/core-boundary/intrinsics-board.sh` on the RT1186: 44 of 44 passed,
  0 skipped.
- `tests/doom-core/rt1186.sh` (DEMO1, 500 tics): 57 of 57 passed, 0 lanes
  skipped. An earlier run without `RT1186_GDB` failed only the M33 count
  check for that reason and is void.
- `tests/doom-core/loop-reports.sh`: 102 of 102 passed in 5337 s, 0 skipped.
  Its baseline-kernel comparison is an oracle and did not run.

One defect surfaced on the way and is fixed outside this decision
(`dbcf88d`): the adapter registry sized its table from id 1. The
core-boundary adapter lane's ceiling case starts ids at 2^31 - 2, so it
touched 57 to 60 GB to issue one id. The table now starts at the configured
first id; with the default first id, 1, the generated code places every entry
as before.

Recorded for the owner, not changed: two refusals that name "a 32-bit target"
read the Integer width ([the lowering's inputs](../core/lowering-inputs.md)
section 6).
