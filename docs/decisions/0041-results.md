# 0041: results, stage by stage

The record [decision 0041](0041-goose-ideas-for-core.md) keeps beside it. Each
stage's predictions are committed before its implementation starts, and its
results are added below them when its checks have run. A prediction that turns
out wrong stays as written, and the result says so.

Since [decision 0045](0045-buffer-classes.md) a buffer is written
`Core::Buffer` / `Core::Table`, and the Array spelling shown here is refused.
This record keeps its text.

## Stage 1: literal blocks on iterator calls

### Observed before the predictions (2026-11-14)

One probe, with the contract reader built from the pinned Spinel
`c23d82a7c` (`tools/contract/build/spinel-typedump`), on a method that calls
`n.times do |i| t = i * 2; s += t end` and `1.upto(n) { |j| s += j }`:

- The AST face has a `BlockNode` under each `CallNode`, with
  `BlockParametersNode`, `ParametersNode` and `RequiredParameterNode` below it.
- The locals face lists the block parameters `i` and `j` and the block's own
  local `t` in the method's scope, typed `int`, not cells, not nullable.

So the analysis already types what stage 1 needs for `times` and `upto`,
and a block's locals reach the lowering as the method's own locals.

### Predictions (2026-11-14, before any implementation)

1. **Where the change lands.** The lowering
   (`tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp`), the importer's
   closed sets (`Importer.cpp`), the freestanding subset walk and the refusal
   table (`FreestandingSubset.cpp`, `Core/SubsetRefusals.cpp`), the CORE
   checker (`Core/Eligibility.cpp`) and the loop bounds
   (`Core/LoopBounds.cpp`), with their documents and tests. Nothing in
   `vendor/`, and nothing in the contract reader.
2. **One lowering for every route.** `spinel-fs-emit` (`freestanding_def`)
   and `spinel-core-kernel` (0007 contracts and 0014 applications) both lower
   through `MlirGen`, so one lowering serves both; the two checkers each
   admit the forms separately.
3. **The loop's shape.** A block call lowers to a head that tests a hidden
   counter, a body that binds the block parameter to it, and a latch that
   steps it. `next` goes to the latch, not the head. `upto` and `downto`
   leave through an equality test in the latch before stepping, so a loop
   to the body's largest or smallest Integer ends without `ARITHMETIC`. The
   receiver and arguments are evaluated once, before the loop, as Ruby does.
4. **The block's locals.** Because the locals face puts a block's own locals
   in the method's scope, a read of `t` after the block is not a local read
   at all to Prism: it parses as a method call `t`, which the checkers
   already refuse as an unresolved call. No new rule is needed for it.
5. **`buf.each`'s element type.** For an Integer buffer the block parameter
   is typed `int`. For a Float buffer it is typed `float` on a straight read;
   if the analysis gives it either class instead, Float buffers are refused
   by name in stage 1 and the result says so.
6. **Loop bounds.** The report lists block loops in the same per-method
   sequence as `while` loops, by source order, so a method's `id`s count both.
   Existing reports keep their ids, because no admitted program had a block
   loop. New headers render as `times (lvar n)`, `upto (lvar a) (lvar b)`,
   `downto ...`, `each (lvar buf)` and `each_with_index (lvar buf)`; `while`
   rendering does not change, so `digest_version` stays `1`.
   - Bounds: `max(0, n)` for `times`, `max(0, b - a + 1)` for `upto`,
     `max(0, a - b + 1)` for `downto`, and the buffer's count for `each` and
     `each_with_index`, all `static_proof` when the receiver and arguments
     are expressible at the loop's entry.
   - The receiver is read once, so reassigning `n` inside its own block does
     not make the bound vary. The decision's check "a `times` whose receiver
     the loop changes is not `static_proof`" is wrong as worded; what is not
     `static_proof` is a receiver that varies with an enclosing loop, which
     gets `bound-not-expressible` with `enclosing-varying:` or
     `enclosing-induction:` as a nested `while` does.
   - The step rules (2 to 6) cannot fail for a block loop: the counter is
     hidden, and assigning the block parameter does not step it.
7. **Refusals.** `yield`, `&block`, `proc`, `lambda`, `Proc.new`, `&:sym`,
   `map` and `select`, `break` with a value, `redo`, `retry`, numbered and
   `it` parameters, more block parameters than the call yields, and a block
   call whose value is used are each refused with their own reason, at their
   line and column. `times`, `each`, `BlockNode` and `upto` leave the
   refusal table as unconditional rows; the forms above stay in it.
8. **Nothing else moves.** The suites `affected.rb` selects pass with the
   same counts apart from the new cases. `fiber-core` is unchanged, since
   0035's rewrite still turns a fiber body's loops into `while` before CORE
   reads it. DOOM's entries still admit and build.

### Checks

As 0041 lists them for stage 1, with prediction 6's correction: a receiver
reassigned in its own block stays `static_proof`, and a receiver that varies
with an enclosing loop does not.

### Results (2026-11-14)

Implemented on `feat/0041-literal-blocks` (`6ebbc05e`, with `50c96307` and
`e79877de`). Each prediction, as it
turned out:

1. **Where the change lands: held, with additions.**
   - The files named changed, and so did one new module,
     `Core/BlockLoops.{h,cpp}`, which classifies a call as an admitted loop
     or gives its refusal. The importer, the freestanding walk, the checker,
     the loop bounds and the lowering all ask it.
   - Two additions were not predicted. The report schemas' `header` pattern,
     which was `^while `, now also allows the five call names (both schema
     versions). And the new suite is registered in `tools/test/` with the
     manifest's pins renewed.
   - Nothing in `vendor/` and nothing in the contract reader changed.
2. **One lowering for every route: held.** `spinel-fs-emit` and
   `spinel-core-kernel` both lower through `MlirGen`'s `blockLoopStmt`.
3. **The loop's shape: held.**
   - `next` goes to the latch.
   - `upto` to `INT64_MAX` and `downto` to `INT64_MIN` each run 3 times
     with status OK, and so does `upto` to `INT32_MAX` on the freestanding
     route.
   - The receiver and the argument are read once: assigning the receiver
     in the block leaves the count at 3 (`tests/core-blocks`, `hidden`).
4. **The block's locals: partly wrong.**
   - They reach the lowering as the method's locals, but not always under
     their written names. When the same name is used anywhere outside the
     block, the pinned Spinel gives the block's name a slot of its own,
     `name__bp<block>`, while the AST keeps the written name. The lowering
     and the checker resolve the slot through `blockSlotName`.
   - A block's own local starts afresh on every iteration, so one read
     before it is assigned on some path is refused. The freestanding route
     says so by name. The status lane refuses it as `type-evidence` (`local
     t is conflicting`), indirectly.
   - The read of `t` after the block was not checked by a fixture.
5. **`each`'s element type: held.**
   - An Integer buffer gives `int`.
   - An `f64` buffer gives a Float on the freestanding route:
     `g.each { |x| s = s + x }` over 1.5, 2.25 and 4.0 gives 7.75.
   - `s += x` on a Float accumulator is refused, with a `while` as well
     ("the target of `s +=` is a boolean"). That refusal and its wording
     were there before this stage.
6. **Loop bounds: held.**
   - Block loops share the method's ordinal sequence, and `digest_version`
     stays 1.
   - The bounds are as predicted, including the corrected case: a receiver
     reassigned in its own block stays `static_proof`, and a receiver that is
     an enclosing loop's induction variable gives `bound-not-expressible`,
     `enclosing-induction`.
   - Not predicted: in a helper, a buffer's count is written `size(buf)`,
     and each call's term replaces it with the caller's count.
   - A `while` whose step is inside a block loop is `step-conditional`.
7. **Refusals: held for the forms tested, with two corrections.**
   - Each of these is refused with its own words, on both routes: a used
     value (`loop-value`), `map`, `&:sym`, numbered and `it` parameters,
     too many parameters, the wrong argument count, a shadowing name, `each`
     on a non-buffer, `break` with a value (`loop-control-value`) and
     `yield`.
   - Optional and destructured parameters are refused earlier, by the
     contract reader (`dangling-reference`).
   - Not tested one by one: `select` (an "other call with a block", like
     `map`), `lambda`, `proc`, `Proc.new`, `redo` and `retry`. Their table
     rows did not change.
   - Correction: the `BlockNode`, `times` and `each` rows stay in the table
     with new words, and apply to what is not an admitted loop. `upto` was
     never a row.
   - A word intrinsic (decision 0022) with a block keeps its own refusal
     (`unsupported-node`), as before this stage.
   - Correction: `break` and `next` are refused on the freestanding route,
     as they are in a `while` there. The status lane admits them.
8. **Nothing else moves:** see "Suites" below.
   - Four existing fixtures moved, as a consequence of the change:
     - the E040 rejection row `a07_block` uses `n.tap { |i| i }`, a block
       that stays refused;
     - the E084 rejection row `n3_block` is now an accepted row. Its body
       uses `s = s + g[i]`, for the Float reason in 5;
     - the subset fixtures for `call each` and `call times` use the
       blockless call;
     - the closure table's `each_block` row is admitted, and a new
       `map_block` row is refused.
   - DOOM's entries were not rebuilt. Their lane, `doom-loop-reports`, is a
     long check, kept for the end of the effort.

Found on the way, and not changed by this stage:

- **Writing a renamed block parameter.** A block that assigns its own
  parameter, when the pinned Spinel has renamed it, makes the contract reader
  refuse the whole file: `dangling-reference`, then `unanalysable-root`. It
  is refused, not miscompiled. The status-lane fixture does not assign one.
  The owner recorded this as a known limit of stage 1 on 2026-11-14.
- **A method-level local read before it is assigned** is admitted as 0 on
  the freestanding route. This was so before this stage. A block's own
  local is refused instead (4).
- **32 bits.** A 32-bit body width was not exercised. The freestanding
  checks use `i32` parameters on the x86_64 host profile.

### Checks run

- `tests/core-blocks/run.sh` (new): 44 passed, 0 failed, 0 skipped.
- `tests/core-report/run.sh`: 741 passed, 0 failed, 1 skipped (the baseline
  kernel comparison, which needs `BASELINE_KERNEL`). Its oracle section is
  not run.
- `tests/core-boundary/closure.sh`: 33 checked, 33 pass, 28 constructs.

### Suites

The suites `ruby tools/test/affected.rb --base origin/main` selected, 30 of
them, run once on Debian x86_64 with LLVM 23.1.1.

| suite | result | wall |
|---|---|---|
| `tests/affected/run.sh` | 67 checked, 67 pass | 3 s |
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 skipped | 13 s |
| `tests/core-blocks/run.sh` (new) | 44 passed, 0 failed, 0 skipped | 2 s |
| `tests/core-boundary/run.sh` | 12 lanes, 12 passed | 50 s |
| `tests/core-eligibility/run.rb` | 52 passed, 0 failed | 2 s |
| `tests/core-boundary/intrinsics.sh` | 50 checked, 50 pass | 3 s |
| `tests/core-report/run.sh` | 741 passed, 0 failed, 1 skipped | 82 s |
| `tests/core/run.sh` | 33 passed, 0 failed | 0 s |
| `tests/core-stack/run.sh` | 31 checked, 31 pass, 1 skipped | 3 s |
| `tests/dist/run.sh` | 104 checked, 104 pass | 14 s |
| `tests/dist/export.sh` | 1 checked, 1 pass | 35 s |
| `git diff --check origin/main -- docs` | clean | 0 s |
| `tests/doom-core/borrowed-calls.sh` | 51 checked, 51 pass | 1 s |
| `tests/doom-core/control-flow.sh` | 55 checked, 55 pass | 1 s |
| `tests/fiber/core.sh` | 43 passed, 0 failed, 0 skipped | 71 s |
| `tests/freestanding/run.sh` | every lane passed; the two board lanes NOT RUN (no `FRDM_HOST`) | 248 s |
| `tests/imports/run.sh` | 10 checked, 10 pass | 2 s |
| `tests/lowering/duplicate.sh` | 3 checked, 3 pass | 0 s |
| `tests/lowering/locations.sh` | 9 checked, 9 pass | 0 s |
| `tests/lowering/reopened.sh` | 11 checked, 11 pass | 1 s |
| `tests/lowering/split.sh` | 6 checked, 6 pass | 0 s |
| `tests/native-core/arith.sh` | 50 passed, 0 failed, 1 pending | 15 s |
| `tests/native-core/driver.sh` | 44 passed, 0 failed | 7 s |
| `tests/native-core/ledger.sh` | 23 passed, 0 failed | 0 s |
| `tests/native-core/run.sh` | 8 passed, 0 failed | 3 s |
| `tests/oracle/check.sh` | 0 failures | 6 s |
| `tests/source-stamp/run.sh` | 12 checked, 12 pass | 0 s |
| `tests/subset/map.sh` | 13 checked, 13 pass | 1 s |
| `tests/subset/reasons.sh` | 42 checked, 42 pass | 3 s |
| `tests/subset-tables/run.sh` | 12 checked, 12 pass | 0 s |

The skips and pendings are each suite's own named ones, which do not change
with this stage: `BASELINE_KERNEL` in core-report, the pending `rescue`
fixture in native-core arith, and the board lanes in freestanding. No oracle
section ran. The long `doom-loop-reports` lane waits for the end of the
effort.

How the run went: the first full run, at `50c96307`, failed four suites.
- `tests/core-boundary/intrinsics.sh`, on an earlier build: a word intrinsic
  with a block was refused as `unsupported-block`, not by the intrinsic's own
  rule. Fixed in `50c96307`, after which this run took place.
- `tests/freestanding/run.sh`:
  - e040's `a07_block` asserted that `n.times { |i| i }` is refused, which
    stage 1 admits. It now uses `n.tap { |i| i }`.
  - e084's host leg lacked this worktree's runtime bitcode and pass plugin,
    which were then built.
- `tests/subset-tables/run.sh`: the reasons digest moved with the reworded
  rows, and the pin was renewed.
- `tests/dist/export.sh`: `docs/imports.tsv`'s rewrite pins moved, and were
  renewed.

These are committed in `e79877de`. The four suites passed when they were run
again on that commit, with the timings above. That commit changes only those
suites' inputs, so the other 26 rows are from the first run.

### The owner's review (2026-11-14, relayed by the bpf-mlir coordinator)

Stage 1 was approved for main as it is. The owner accepted:

- the report schemas' widened `header` pattern;
- the existing fixtures this stage moved (E040 `a07_block`, E084
  `n3_block`, the subset fixtures for `each` and `times`, and the closure
  table's `each_block` and `map_block`).

The owner recorded the block-parameter assignment as a known limit: it is
refused as `dangling-reference`, not miscompiled.

## Stage 1 follow-up: the independent review

The reviewer reviewed stage 1 at `5217686a` and confirmed two defects
(2026-11-14). These predictions were written before any fix.

### The defects, as found

1. **The reported bound counts a side effect twice.** In
   `tools/mlir/native/lib/Core/LoopBounds.cpp`, `blockLoop` evaluates the
   receiver and the limit, then passes the environment *after* both to
   `classifyBlock`. `classifyBlock` evaluates the same expressions again in
   that environment. A receiver or limit that assigns a local has its
   assignment applied twice. The receiver is also read after the limit has
   run.
   - `(a -= 1).times` runs `a - 1` times, but its bound was reported as
     `max(0, a - 2)`.
   - `a.upto(a = 0)` with `a = -2` runs 3 times, but its bound was reported
     as `1`.

   The loop property is `observe`, so this wrote a false bound into the
   report. It disabled no check.
2. **An exit taken on every iteration fails code generation.** Take
   `a.times { |i| return 9 }` or `a.times { |i| break }`. The block's body
   always leaves the loop, so nothing branches to the loop's step block
   (the latch). The block is still filled in, and the conversion to LLVM IR
   then fails on its constant (`translate-failed`, kernel exit 3). That
   input should compile. The stage 1 fixtures exit only under a condition,
   so they always reach the latch and missed this.

### Predictions

1. **One evaluation, in Ruby's order.** The receiver's bound is its value in
   the environment at the loop's entry. The limit's bound is its value in
   the environment the receiver's evaluation leaves. These are new rows in
   `tests/core-report/fixtures/loops.rb`, each counting its iterations in
   `cnt`:

   | entry | body | reported bound |
   |---|---|---|
   | `lb_times_effect` | `(n -= 1).times` | `max(0, n - 1)` |
   | `lb_upto_effect` | `a.upto((b -= 1))` | `max(0, b - 1 - a + 1)` |
   | `lb_downto_effect` | `a.downto((b += 1))` | `max(0, a - (b + 1) + 1)` |
   | `lb_upto_reassign` | `a.upto(a = 0)` | `max(0, 0 - a + 1)` |

   I have not run the renderer on these, so a reported bound may differ in
   form, for example in its parentheses or with `+ 1` folded. If it does,
   the row holds the reported text, and these results say so. Their values
   at the reviewer's inputs are 3, 3, 4 and 3.
2. **Every existing row stays as it is.** That covers `expect.tsv`, the
   goldens, and the loop digests. The fix changes only the environment the
   bound is read in, and that environment is the same whenever neither
   expression assigns a local.
3. **An exit on every iteration compiles and runs.** The latch is discarded
   when nothing branches to it, as `ifStmt` already discards an unreached
   join. These are new entries in `tests/core-blocks/src/ok.rb`, through the
   status lane:
   - `bl_return_all`, which is `a.times { |i| return 9 }` then `-1`, gives
     9 at `a = 3` and -1 at `a = 0`;
   - `bl_break_all`, which is `a.times { |i| break }` then `7`, gives 7 at
     `a = 3`;
   - `bl_return_upto`, which is `a.upto(b) { |i| return i }` then `-1`,
     gives 2 at `a = 2, b = 5` and -1 at `a = 5, b = 2`.
4. **The freestanding route.** It shares this code. If it admits `return`
   in a block, the same unconditional return compiles there too. If it
   refuses it, the refusal is unchanged. I have not checked which.
5. **Nothing else moves.** The suites `affected.rb --base origin/main`
   selects pass.

### Results (2026-11-14)

The fix is `13ae4db9`, and the fixtures are `955b4e93`. They were run on
Debian x86_64 with LLVM 23.1.1, at the pin `c23d82a7c`.

1. **Prediction 1 held, in the exact text predicted.** The four new rows
   report `max(0, n - 1)`, `max(0, b - 1 - a + 1)`,
   `max(0, a - (b + 1) + 1)` and `max(0, 0 - a + 1)`, and `core-report`
   checks them against the rows written before the fix.
2. **Prediction 2 held.** Every existing `core-report` row, golden and
   digest is unchanged: 785 passed, 0 failed. Before the new rows were
   added, the suite passed 741.
3. **Prediction 3 held.** `bl_return_all` gives 9 and -1,
   `bl_break_all` gives 7, and `bl_return_upto` gives 2 and -1.
4. **Prediction 4: the freestanding route admits it.**
   `n.times { |i| return 9 }` in a `freestanding_def` now compiles. It
   gives 9 at `n = 3` and -1 at `n = 0`, through `fs/k.rb` and
   `fs/drive.c`. I did not run the build from before the fix to see it
   fail there, because that would be a comparison of the old build with the
   new.
5. **Prediction 5 held.** All 25 selected suites pass (below).

### Suites

`ruby tools/test/affected.rb --base origin/main` selected 25 suites, run
once in 871 s:

| suite | result |
|---|---|
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 skipped |
| `tests/core-blocks/run.sh` | 47 passed, 0 failed, 0 skipped |
| `tests/core-boundary/run.sh` | 12 lanes, 12 passed |
| `tests/core-eligibility/run.rb` | 52 passed, 0 failed |
| `tests/core-boundary/intrinsics.sh` | 50 checked, 50 pass |
| `tests/core-report/run.sh` | 785 passed, 0 failed, 1 skipped |
| `tests/core/run.sh` | 33 passed, 0 failed |
| `tests/core-stack/run.sh` | 31 checked, 31 pass, 1 skipped |
| `git diff --check origin/main -- docs` | clean |
| `tests/doom-core/borrowed-calls.sh` | 51 checked, 51 pass |
| `tests/doom-core/control-flow.sh` | 55 checked, 55 pass |
| `tests/fiber/core.sh` | 43 passed, 0 failed, 0 skipped |
| `tests/freestanding/run.sh` | every lane passed (282 s, rerun); the two board lanes NOT RUN (no `FRDM_HOST`) |
| `tests/imports/run.sh` | 10 checked, 10 pass |
| `tests/lowering/duplicate.sh` | 3 checked, 3 pass |
| `tests/lowering/locations.sh` | 9 checked, 9 pass |
| `tests/lowering/reopened.sh` | 11 checked, 11 pass |
| `tests/lowering/split.sh` | 6 checked, 6 pass |
| `tests/native-core/arith.sh` | 50 passed, 0 failed, 1 pending |
| `tests/native-core/driver.sh` | 44 passed, 0 failed |
| `tests/native-core/ledger.sh` | 23 passed, 0 failed |
| `tests/native-core/run.sh` | 8 passed, 0 failed |
| `tests/oracle/check.sh` | 0 failures |
| `tests/source-stamp/run.sh` | 12 checked, 12 pass |
| `tests/subset/reasons.sh` | 42 checked, 42 pass |

- **The freestanding rerun.** In the first run, the freestanding suite's
  e084 host leg failed because this new worktree had no pass plugin
  (`tools/llvm/passes`): 101 pass and the host leg not run. That is a
  setup step, the same one stage 1's worktree needed. After building it,
  only that suite was run again: e084 104 pass, 0 fail.
- **No oracle section ran.** `doom-loop-reports` waits for the end of the
  effort.

## Stage 3: a declared slot pool

The owner started stage 3 on 2026-11-14 (relayed by the bpf-mlir coordinator), in parallel
with 0042 stage 4. Stage 2 is not started. The owner answered the question on
misuse the same day (relayed by the bpf-mlir coordinator): option 2, an occupancy bit per
slot. A double free and a free of a slot never allocated fail with `BOUNDS`.
A stale index to a reused slot reads the new contents and is not detected;
that is a known limit. Generation handles (option 3) are not taken.

### Predictions (2026-11-14, before any implementation)

1. **Where the change lands.** The CORE rewrite
   `tools/fiber/spinel-fiber-core` reads `pool_def` beside `fiber_def` and
   `enum_def`, and writes its states and helpers. The host reference
   `tools/app/lib/spinel/core.rb` gains `pool_def`. The application reader
   (`tools/app/lib/core_app/declarations.rb`) admits it as a top-level
   declaration. The hook in `tools/app/bin/spinel-core-app` runs the rewrite
   for it too. The fixtures, the refusal table and the suite are in
   `tests/fiber/`, and `docs/core/applications.md` describes it. Nothing in
   `vendor/`, `tools/mlir/`, or `tools/contract/`: no kernel change, as the
   record predicts.
2. **What the rewrite writes**, for `pool_def :node, max: N`:
   - three `state` buffers, all `:i32`: `spl_node_live` (N elements, 1 when
     the slot is allocated), `spl_node_free` (N elements, a stack of freed
     slot numbers) and `spl_node_top` (2 elements: the freed slots on that
     stack, and the slots handed out at least once). Zeroed states are an
     empty pool, so no start-up code is needed. The build prints one line,
     `pool_def :node: N slot(s), (2N + 2) x 4 bytes of state`.
   - three helpers, called in place of `Node.alloc`, `Node.free(i)` and
     `Node.live?(i)`, and the frame-style state parameters on every
     definition that reaches one, as 0035 does for frames.
3. **Order of reuse.** `alloc` answers the most recently freed slot first
   (a stack), and otherwise the lowest slot never handed out. With every
   slot live it fails with `CAPACITY` (status 4) through
   `core_fail(:capacity)`. The host reference keeps the same order, so the
   host and the target answer the same slot numbers.
4. **Misuse is `BOUNDS`** (status 3), through a checked access `max` past
   the slot, as 0035's helpers do: `free` of a slot that is not allocated
   (a double free, or a slot never handed out), and `free` or `live?` of a
   slot outside `0...max`. A stale index to a reused slot reads the new
   occupant and is not detected (the known limit above).
5. **Refusals**, each one diagnostic at its line and column, nothing
   written: a pool reached from two contexts ("a pool has one owning
   context"), a `pool_def` without `max:` or with a non-literal one, a pool
   whose name is also a `fiber_def` or `enum_def`, a module method other than
   `alloc`, `free` and `live?`, and a wrong argument count.
6. **Checks** (added to `tests/fiber/core.sh`): an accept fixture that
   allocates, frees and reuses, whose payloads decode to a hand-written
   `expect.txt` on the host and, with Zephyr, under QEMU on `mps2_an521`;
   an exhaustion at `max + 1` declared as `expect_failure` with status 4 at
   the same release on every run; a double free and a free of a slot never
   allocated, each status 3; the refusals of 5.
7. **Nothing else moves.** The suites `tools/test/affected.rb --base
   origin/main` selects pass with the same counts apart from the new cases;
   `fiber-core` gains them. For the files of 1, `affected.tsv` selects
   `app-board`, `app-contract`, `app-effects`, `app-host`, `app-build`,
   `app-reserves`, `app-cross`, `app-udp`, `app-core-channel`, `doom-board`,
   `doom-profile`, `doom-play-board`, `fiber`, `fiber-core` and `docs-check`.
   The record's expected set also names `core-report` and `core-run`, which
   `affected.tsv` does not select when the kernel does not change; they are
   run once anyway, as the record asks. DOOM's entries do not use `pool_def`
   and still admit.

### Results (2026-11-14)

The implementation is `19ca14ef`. `25fac0a4` re-pins the export manifest
(see 7).

1. **Where the change lands:** as predicted, with two more files. Editing
   `fiber-core`'s line in `tools/test/tests.tsv` required re-pinning both of
   that file's hashes in `tools/dist/manifest.json`, the input in
   `19ca14ef` and the output in `25fac0a4`. The prediction did not name
   either file. Nothing changed in `vendor/`, `tools/mlir/` or
   `tools/contract/`.
2. **What the rewrite writes:** as predicted. The helpers are
   `spl_node_alloc`, `spl_node_release` and `spl_node_used`. The build's
   line prints the computed size, not the formula:
   `pool_def :node: 3 slot(s), 32 bytes of state`. The linked image for
   `mps2_an521` has the three `.bss` states, 32 bytes in all.
3. **Order of reuse:** as predicted. `pool`'s five values,
   `1 1 2 10 23`, are the same on the host and under QEMU. `poolfull` fails
   with `CAPACITY` (status 4) at release 3 on the host, and under QEMU the
   first failure site is `tick`'s, with status 4.
4. **Misuse is `BOUNDS`:** as predicted for the double free (`pooltwice`,
   on the host and under QEMU) and for a slot never handed out
   (`poolnever`, on the host only). At `19ca14ef` no fixture checked `free`
   or `live?` of a slot outside `0...max`. Four were added at the coordinator's
   request in `d1189565`: `poolfreehi`, `poolfreeneg`, `poollivehi` and
   `poolliveneg`. Each is `BOUNDS` on the host, with no run on the target.
   An entry stops at its first failure, so each fixture holds one misuse.
5. **Refusals:** as predicted, plus one the prediction did not list. A
   `fiber_def` or `enum_def` body that uses a pool is refused
   (`pool_body.rb`), because the body's helpers take only their frames.
   Each of the six refusals is one diagnostic at its line and column, and
   nothing is written.
6. **Checks:** as predicted. `tests/fiber/core.sh` went from 43 passed
   (stage 1 and 0042 stage 3) to 62 passed, 0 failed, 0 skipped. The 19 new
   checks are:
   - 6 refusals;
   - 8 admission and host checks;
   - 5 under QEMU: the size line, the linked size, `pool`'s frames, and
     the `CAPACITY` and `BOUNDS` sites.
7. **Nothing else moves:** as predicted for the suites' counts; every
   suite that also ran in 0042 stage 3 has the same count. The selection
   was wider than predicted:
   - Because of the `tests.tsv` and manifest edits, `affected.rb` also
     selected `affected-controls`, `imports`, `oracle-check`,
     `dist-controls` and `dist-export`.
   - `doom-board` and `doom-play-board` are its board checks (the RT1186).
     They were not run.
   - The export check failed twice before it passed:
     - At `19ca14ef` it stopped on the stale output hash of the rewritten
       `tests.tsv`, which `25fac0a4` re-pins.
     - At `25fac0a4` I set `DIST_PROVISIONAL` to the 27-row list of
       2026-11-01. That was a runner error: the list was superseded at the
       public bml import (2026-11-11). The current list has no rows, so the
       export runs without `DIST_PROVISIONAL`. The run stopped on that
       list's rows for
       `docs/toolchains/spinel-bpf-mlir-deps/INSTALLATION-RECORD.md`, a
       file this branch does not touch.
     - Run in the current form, without a provisional list, it passed.

### Suites (2026-11-14)

`ruby tools/test/affected.rb --base origin/main` selected 18 commands. The
two board checks were not run. The other 16 were run once on Debian x86_64
with LLVM 23.1.1, at `19ca14ef`, with `core-report` and `core-run` added
from the record's expected set. The four suites the manifest selects were
run again at `25fac0a4`.

**An input, not a result.** `doom-profile` needs DEMO1's session image.
tests.tsv's own command points `SESSION_IMAGE` at the suite's empty
directory, and only a board run of `rt1186.sh` makes the image. The input
was the DEMO1 image of the 2026-11-01 gc-none run, copied unchanged, and
its own `image.sha256` accepted it (`sha256sum -c`). The sha256 of each
file:
- `image.sha256`: `3998a105897bf42f73ff016819e116df64a1873fbe56570d811f3a0637e2535b`
- `image.tsv`: `a8f179058dd1627b59751fc2ccc2bf29e213e247ebbfd4e456afcd4a093f3265`
- `resources.bin`: `3075802823c7d38b3ccd2d0afa288cd23087855b6e8522b6d928976d8f97a112`
- `writable.bin`: `3dfeb3f91cb3561d92dd2c8c37e5f1b246620c3eb54fb667901011fe36e513f7`

| suite | result | wall |
|---|---|---|
| `tests/fiber/core.sh` | 62 passed, 0 failed, 0 skipped | 108 s |
| `tests/fiber/run.sh` | 60 passed, 0 failed, 1 skipped (no wasmtime) | 21 s |
| `tests/app/host.sh` | 58 checked, 58 pass | 15 s |
| `tests/app/contract.sh` | 68 checked, 68 pass | 2 s |
| `tests/app/board.sh` | 102 checked, 102 pass | 7 s |
| `tests/app/build.sh` | 113 checked, 113 pass, 0 skipped | 639 s |
| `tests/app/core-channel.sh` | 57 checked, 57 pass | 0 s |
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 skipped | 13 s |
| `tests/app/effects.sh` | 23 checked, 23 pass | 11 s |
| `tests/app/reserves.sh` | 43 checked, 43 pass, 0 skipped | 80 s |
| `tests/app/udp.sh` | 46 checked, 46 pass, 0 skip | 7 s |
| `tests/core-report/run.sh` | 785 passed, 0 failed, 1 skipped (`BASELINE_KERNEL`) | 84 s |
| `tests/core/run.sh` | 33 passed, 0 failed | 1 s |
| `tests/doom-core/profile.sh` | 13 checked, 13 pass | 3 s |
| `tests/affected/run.sh` | 67 checked, 67 pass | 2 s |
| `git diff --check c2e4eac8 -- docs` | clean | 0 s |
| `tests/imports/run.sh` (at `25fac0a4`) | 10 checked, 10 pass | 2 s |
| `tests/oracle/check.sh` (at `25fac0a4`) | 0 failures | 5 s |
| `tests/dist/run.sh` (at `25fac0a4`) | 104 checked, 104 pass | 11 s |
| `tests/dist/export.sh` (at `25fac0a4`, no provisional list) | 1 checked, 1 pass | 33 s |

No oracle section ran.

## Stage 3 review (the reviewer, 2026-11-14)

The reviewer reviewed `035d6a9f` and `d1189565` independently and found one
Medium defect and nothing else.

### The finding

`tools/fiber/spinel-fiber-core` built each module call's replacement from
its arguments' original source. It queued the outer and the inner call's
replacements over overlapping ranges and applied both at the original
offsets. `Node.free(Node.alloc)` was rewritten as

```
spl_node_release(Node.alloc, spl_node_live, spl_node_free, spl_node_top)loc(spl_node_live, spl_node_free, spl_node_top))
```

The rewrite exited 0, but its output is not valid Ruby. 0035's calls take
the same path: `Reader.resume(0, Reader.start(1, 3))` failed the same way
at origin/main. A receiver-less helper used as an argument
(`Node.free(pick)`) had the same overlap. Here the overlapping edit is the
insertion of the pool's states into the helper's call.

### The fix (`3c110a92`)

The rewrite now composes the calls instead of dropping one:
- module calls are replaced last, innermost first;
- an argument's text is its source with every edit inside it applied (a
  nested call, or the states a helper gains);
- an outer replacement stands for everything inside its range.

Each call still appears once in the output, so each is evaluated once. No
contract changed, and no refusal was added.

### Its checks

- **`poolnest`, a new fixture.** It covers every form named in the
  review:
  - `Node.free(Node.alloc)`;
  - `Node.live?` of a helper that allocates;
  - `Node.free(Node.free(0) + 1)`;
  - two allocs in one expression;
  - `Node.live?(Node.free(Node.alloc))`, nested two deep;
  - `Keeper.resume(0, Keeper.start(0, 7))`.
- **The rewrite check.** `tests/fiber/core.sh` checks that `poolnest`'s
  rewrite parses (`ruby -c`) and that its `tick` is the hand-written
  `poolnest/rewrite.txt`.
- **Control.** The rewriter as of `d1189565` writes output that `ruby -c`
  rejects.
- **Values on the host and under QEMU.** Both are `110 1 70 10 12`, as
  written by hand. The first value is the review's control: after
  `Node.free(Node.alloc)`, the count of allocated slots is back to 1 and
  the next `alloc` answers the freed slot.
- **`tests/fiber/core.sh`:** 75 passed, 0 failed, 0 skipped, in 123 s. That
  is the 62 of the first run, plus 8 range checks at `d1189565`, plus 5 for
  `poolnest`:
  - the rewrite parses, and its text matches;
  - admission;
  - the host values;
  - the QEMU frames.
- **The other suites the fix selects** (`affected.rb --base d1189565`), run
  at `3c110a92`:

| suite | result | wall |
|---|---|---|
| `tests/fiber/run.sh` | 60 passed, 0 failed, 1 skipped (no wasmtime) | 22 s |
| `tests/imports/run.sh` | 10 checked, 10 pass | 2 s |
| `tests/oracle/check.sh` | 0 failures | 5 s |

### The re-review (the reviewer, at `7cdcd12c`)

The reviewer found the same class of defect still open in one form: a
receiver-less helper whose last argument is a module call,
`Node.live?(pick(Node.alloc))`. `3c110a92` placed the states a helper
gains by offset, and here that offset is the end of `Node.alloc`'s range.
The inner replacement swallowed the insertion, and `pick` lost its three
state arguments. The output parsed, but CORE refused it as an arity
mismatch.

**The second fix (`687afc03`).**
- Each insertion now carries the range of the call it belongs to, and
  composition goes by that range rather than by the insertion's offset.
- A helper call written without parentheses that takes arguments now
  gains parentheses. Without them, the outer call would take the states
  as its own arguments.

**Its checks.**
- `poolnest`'s release 1 adds `Node.live?(swap(Node.alloc))` and
  `(swap Node.alloc) * 10`. `swap` frees its slot and allocates again.
- The release's value is `1123` on the host and under QEMU. Each `alloc`
  runs once: a second evaluation would fail with `CAPACITY` there.
- `poolnest/rewrite.txt` gains the two lines.
- Control: the rewriter as of `3c110a92` writes source that parses but
  differs from `rewrite.txt` on those two lines (no state arguments).
- `tests/fiber/core.sh`: 75 passed, 0 failed, 0 skipped, in 131 s. The
  values are `110 1123 70 10 12` on the host and under QEMU.
- The other suites `affected.rb --base 3c110a92` selects, at `687afc03`:
  - `tests/fiber/run.sh`: 60 passed, 0 failed, 1 skipped (no wasmtime);
  - `tests/imports/run.sh`: 10 checked, 10 pass;
  - `tests/oracle/check.sh`: 0 failures.

### The second re-review (the reviewer, at `c4a1a29d`), High

The reviewer found a wrong-code case. It has two pools, and helpers called
without parentheses and nested: `x = outer inner A.alloc`, where `inner`
uses pool A and `outer` uses pool B. Both calls close at one offset, and
`687afc03` ordered the two insertions there by offset only. As a result:
- `inner` received B's states and `outer` A's;
- the program compiled and ran with status 0, but the result was wrong;
- A slot 1 was allocated when it should not have been.

**The third fix (`d6ce92c5`).** This was the third defect in the offset
edits, so the coordinator asked for the edits to be replaced rather than patched
again:
- Every definition other than a `fiber_def` or `enum_def` body is now
  written anew from its tree.
- A call's arguments are rendered first, then the call itself, with its
  own states.
- The tree, not an offset, decides which call gains which states.
- The top-level edits that remain do not overlap: the declarations, the
  fiber helpers and whole definitions.

A `fiber_def` or `enum_def` body that calls a definition gaining states is
now refused by name (`pool_body_helper.rb`). Such a body is not rendered
this way, and before this fix the rewrite wrote invalid Ruby for it.

**Its checks.**
- **`poolmix`, a new fixture.** It has two pools. `inner` and `outer` are
  defined in one order, `outer2` and `inner2` in the other.
  - The values are `12 123 1 0 1` on the host and under QEMU, written by
    hand.
  - The first two values encode the slot returned and both pools' counts
    of allocated slots.
  - Its `tick` is the hand-written `poolmix/rewrite.txt`.
- **Controls.** The rewriter as of `687afc03` binds the states the wrong
  way round on two lines of `poolmix`, and writes invalid Ruby for
  `pool_body_helper.rb`.
- **`poolnest/rewrite.txt`.** It lost one space in `(swap(` because the
  rendering no longer copies the source's spacing inside a rewritten call.
- **`tests/fiber/core.sh`:** 81 passed, 0 failed, 0 skipped, in 139 s. That
  is the 75 before, plus 1 refusal and 5 for `poolmix`:
  - the rewrite parses, and its text matches;
  - admission;
  - the host values;
  - the QEMU frames.
- **The other suites `affected.rb --base 687afc03` selects**, at
  `d6ce92c5`:
  - `tests/fiber/run.sh`: 60 passed, 0 failed, 1 skipped (no wasmtime);
  - `tests/imports/run.sh`: 10 checked, 10 pass;
  - `tests/oracle/check.sh`: 0 failures.

## Stage 2: one bounded data stack, for arrays that stay in their method

The owner started stage 2 on 2026-11-14 (relayed by the bpf-mlir coordinator), after
stage 3's merge (`28587dce`). The CRuby comparison the record names (0010's
second obligation) is an oracle and does not run.
The owner chose, the same day, how the kernel object reaches a context's
region (relayed by the bpf-mlir coordinator). It is option A:
- the entries that make arrays take one hidden pointer argument;
- the region's first word is the bump offset;
- the glue passes a static `.bss` `spc_scratch_<context>`, as it passes a
  `state`;
- the contract gains a `scratch <bytes>` row;
- helpers receive the region by the existing buffer passing;
- the core object gains no undefined symbol.

### Observed before the predictions (2026-11-14)

One probe, with the contract reader built from the pinned Spinel
`baddd25a9`, on a method `work(n)` that makes `a = Array.new(n, 0)`,
writes `a[0]` and `a[1] += 2`, passes `a` to `fill(b, k)` (a `while` over
`b.size`) and to `sum2(b)` (a `b.each` block), and answers `sum2(a) +
a.size`:

- The methods face types `work`'s `a` as `int_array`. It also types `fill`'s
  and `sum2`'s `b` as `int_array`. That is the record's prediction 1.
- The kernel refuses the same program today. `Array.new` is an
  `unresolved-call` ("no scalar effect contract for new"), `Array` is an
  `unresolved-constant`, and the local `a` is "conflicting"
  (`Core/Eligibility.cpp`).

### Predictions (2026-11-14, before any implementation)

1. **Where the change lands.**
   - The application tool:
     - `declarations.rb` and `app_model.rb` read `scratch`;
     - `contracts.rb` writes a `scratch <bytes>` line into the contract of
       each entry whose context makes arrays;
     - `main.c.erb` emits one `.bss` region per context and passes it;
     - `pipeline.rb` puts the region in the resource report.
   - The kernel:
     - the contract reader (`Core/Boundary.cpp`);
     - the CORE checker (`Core/Eligibility.cpp`): admission and every
       escape refusal;
     - the lowering (`Frontend/Scalar/MlirGen.cpp`): allocation, checked
       access, `size`, `each`, the borrow into a callee, and the restore
       on every `func.return`;
     - the loop bounds (`Core/LoopBounds.cpp`): the fill as `n`
       iterations, `size(a) = n`, and the composed total;
     - the report (`Core/Report.cpp`).
   - Nothing in `vendor/` or `tools/contract/`.
   - The subset tables keep `new`, `ArrayNode`, `push` and `<<` as refusals
     outside the 0014 route, so `tests/subset-tables/pin.tsv` does not
     change.
2. **The region.** Each context that makes an array gets one region of the
   declared bytes in `.bss`. Its first word is the bump offset; the
   elements follow. An entry whose context makes arrays takes the region as
   one more trailing argument (option A). A helper that makes or borrows an
   array receives it the way it receives a buffer today.
3. **Allocation.** `Array.new(n, v)`:
   - reads the offset;
   - fails with `CAPACITY` (status 4) when `n` elements do not fit, before
     it writes anything;
   - otherwise fills `n` elements with `v` and moves the offset.
   A negative `n` is `BOUNDS`, not an empty array. The elements have the
   body's integer width (0019): 8 bytes, or 4 on a 32-bit target.
4. **Freeing.** Every function that makes an array saves the offset on
   entry and stores it back before each `func.return`. That covers the
   value returns, every cold status block, `core_fail`, and a callee's
   status passed up. This is one store per return site, not per
   allocation; the record's "one store per method" holds per path.
   - An entry is such a function too, so a release after a failure starts
     with the region as the previous release found it: free.
   - An entry does not reset the offset to 0. An entry preempted by another
     of the same context would lose its arrays if it did. Save and restore
     are last in, first out under preemption.
5. **Access.**
   - `a[i]`, `a[i] = x`, `a[i] op= x`, `a.size` and stage 1's `each` and
     `each_with_index` lower as on a borrowed buffer, with the count `n`.
   - A negative index is `BOUNDS`.
   - Passing `a` to a direct callee makes the callee's parameter a borrow.
     The checker treats it as a lent buffer of the caller's, and stage 1's
     rules apply.
6. **Refusals**, each at its location with its own text:
   - returning the array;
   - storing it in a `state`, an instance variable, a global or another
     array's element;
   - assigning it to a second local, or reassigning its local;
   - passing it to an extern or to a `fiber_def` body;
   - `Array.new` inside a loop (`while`, `until`, or a stage 1 block);
   - `push`, `<<` and every other method on it;
   - an array literal;
   - `Array.new` with a non-literal or non-Integer fill;
   - a context that makes arrays and declares no `scratch`;
   - two `scratch` declarations for one context.
7. **The report.**
   - The resource report lists each context's region beside the states and
     the fiber frames.
   - When every `Array.new` size on every path from an entry is a
     constant, the kernel's report states the worst path's total bytes
     against the declared size as `static_proof`, composed over call edges
     as loop bounds are. Otherwise the evidence is `runtime_guard`.
   - A constant total larger than the region is refused at build time,
     naming the entry and both sizes.
8. **Checks**, the record's list:
   - accept fixtures: an array in a method, one passed down two calls, and
     one in each of two contexts at once;
   - a refusal fixture per escape;
   - a planted `scratch` one element too small, which fails with `CAPACITY`
     at the same allocation on every run, with the bytes after the region
     unchanged;
   - the release after a `CAPACITY` starts with the region free;
   - on QEMU, an interrupt entry that makes an array between two of the
     thread entry's writes leaves the thread's array intact;
   - the report's region line, and `static_proof` for constant sizes.
   Values are hand-written, never compared with CRuby.
9. **Nothing else moves.** Programs without `Array.new` lower as before.
   DOOM's entries still admit and build. The suites `affected.rb` selects
   pass with their counts, apart from the new cases.

### Clarified before implementation (2026-11-14)

The coordinator asked which failure channel a short region uses on the `--core`
route, whose failures go through the hook `spc_core_fail` with a
`CoreFailKind` (decision 0015). Status 4 (`CAPACITY`) and `CoreFailKind` 4
(`Intrinsic`, 0042 stage 4) are separate numberings.

- A region reaches the kernel only through a version 2 contract's
  `scratch <bytes>` row. The kernel admits `Array.new` only in the status
  mode, for an entry whose contract has that row.
- On `--core`, and in the trap mode, there is no region, and `Array.new` is
  refused as it is today. No `CoreFailKind` is added, and `spc_core_fail`
  never reports a short region.
- One more refusal fixture checks that `--core` still refuses `Array.new`.

### Results (2026-11-14)

The implementation is three commits:
- `576b1136`: the kernel;
- `957289cc`: the application tool and the fiber rewrite;
- `c6c2cb64`: `tests/scratch` and its registration.

`4d94e685` documents the declaration in `docs/core/applications.md`.

1. **Where the change lands:** as predicted, with these differences.
   - `tools/fiber/spinel-fiber-core` refuses `Array.new` in a `fiber_def` or
     `enum_def` body (see 6).
   - `tools/app/bin/spinel-core-app` drops a leading `: ` that the detail of
     a kernel `not-eligible:` summary kept. Every such refusal had printed
     `entry tick: : ...`.
   - `lib/Frontend/Scalar/Importer.cpp` and `Scalar/Importer.h` admit
     `Array.new` and an array's `size` when the contract has a region. The
     prediction did not name them.
   - Registering the suite edits `tools/test/tests.tsv`,
     `tools/test/affected.tsv` and `docs/imports.tsv`. That re-pins all
     three in `tools/dist/manifest.json`.
   - As predicted, nothing changed in `vendor/` or `tools/contract/`, and
     `tests/subset-tables/pin.tsv` did not change.
2. **The region:** as predicted. The glue emits
   `static uint8_t spc_scratch_<context>[N] __attribute__((aligned(8)))`. The
   entries of that context take it as their last argument.
   - The wrapper refuses a null region with `ARGUMENT`.
   - It passes the region on only to a body that makes or lends an array.
     These are the makers and every caller up to the entry.
   - A thumbv8m object of an entry that makes arrays has no undefined
     symbol.
   - In `pair`'s image for `mps2_an521`, `.bss.spc_scratch_thread` and
     `.bss.spc_scratch_interrupt` are 64 bytes each, as declared.
3. **Allocation:** as predicted. `kernel/host.c` drives one 256-byte region
   on the host: an 8-byte word and 31 i64 elements. Within it:
   - 31 elements fit;
   - 32 elements are `CAPACITY`;
   - a size of −1 is `BOUNDS`;
   - in each case the 64 bytes after the region stay `0xA5`.

   Under QEMU, `capfull`'s first failure site is `tick`'s, with status 4.
4. **Freeing:** as predicted. After every call in `host.c` the offset word
   is 0, the failures included. After them, a release makes `work(4)`
   again and answers 23. The restore runs before every `func.return`. The
   pass that adds it runs after the cold failure blocks join the function;
   an earlier version missed them.
5. **Access:** as predicted. `array` passes its array down two calls (a
   `while` over `b.size`, then `each_with_index`). It answers
   `1702 2603 3804` on the host and under QEMU.
6. **Refusals.** Each is at its location: the kernel's with line and
   column, the application tool's with the line. Every prediction-6 case
   is refused, with these differences:
   - **Narrower than predicted:** `Array.new` is admitted only as
     `local = Array.new(n, v)`, a statement of its method's own body. It is
     refused inside a loop or block, and also inside a branch or an
     expression (`array-position`).
     - The reason: freeing is per method, so an array made in a branch would
       live on until the method returns.
     - `pair` therefore makes its array in a helper called from the branch.
   - **A fill must be an Integer literal** (`array-fill`). This includes a
     local holding a literal.
   - **Instance variables and globals** are refused by the existing
     `runtime-state` rule. That rule is not specific to arrays.
   - **An array literal** stays `heap-operation`, as before.
   - **An extern** is refused with `array-escape` before its argument's
     type is checked, so a u8 channel's `put` names the escape, not the
     domain.
   - **Passing an array to `Reader.start`** is `array-escape`, raised from
     the rewritten store into the frame. The text names the rewritten
     local and the rewritten file, as every refusal in a fiber application
     does.
   - **`Array.new` in a fiber body** is refused by `spinel-fiber-core` at
     its position, because the body returns at every suspension. The
     prediction listed only passing an array to a body.
   - **Declarations:** two for one context, bytes outside 16 to 2147483647,
     an unknown keyword, and an unknown context are each `declaration`.
   - **No region:** `Array.new` in a context without one is
     `scratch-missing`.
   - **Version 1 contracts (the trap mode)** refuse `Array.new` as before,
     with `unresolved-call`. The `--core` route's compiler is not changed by
     this branch, so the suite does not run it. The clarification named one
     more refusal fixture for it; that fixture is not added.
7. **The report:** as predicted.
   - `kernel/outer.rb` reports `static_proof` with `worst_bytes` 72 against
     256: outer's 6 elements under inner's 3, at 8 bytes each. Against 72
     bytes it is refused with `scratch-capacity`, naming 72 and 64.
   - `tick2` and `array` report `runtime_guard`.
   - `pair` reports `static_proof` with 12 bytes for both entries.
     `build.json` lists both regions with that evidence.
8. **Checks:** as predicted.
   - `pair` checks the interrupt case. Its thread entry makes `[0, 0, 0]`,
     writes `a[0]`, spins until an interrupt release has made its own array
     of nines, then writes `a[1]`. Both frames are 1120 under QEMU.
   - The first digit, 1, says the interrupt landed between the two writes.
     The last, 0, says the thread's array kept its zero.
   - `pair` does not run on the host, which runs one entry at a time.
   - `sh tests/scratch/run.sh`: 43 passed, 0 failed, 0 skipped, in 40 s.
   - Values are written by hand. Nothing is compared with CRuby.
9. **Nothing else moves:** every selected suite passed, with skips in two.
   - `ruby tools/test/affected.rb --base origin/main` selected 41 suites to
     run, the board-free parts of 3 board suites, and the long
     `doom-core/loop-reports.sh`. The long one waits for the end of the
     effort, as the owner set on 2026-10-20.
   - The 44 others ran one at a time at `4d94e685`. 42 exited 0 and 2
     exited 2, with a total of 2645 s.
   - `fiber` skips its wasmtime runner: there is no wasmtime on the
     runner's path. Its count is 60 passed, 1 skipped.
   - `doom-play-board` did not run. It reads the directory of a finished
     `rt1186.sh` DEMO1 run, and the runner gave it none. `doom-board` ran
     its board-free part: 52 checked, 52 passed, board part skipped.
   - `freestanding` stopped twice before it passed. Its `e084` lane needs
     two build products this worktree did not have: the runtime bitcode
     (`tools/llvm/build_rt_bc.sh`) and the GC-roots pass plugin
     (`tools/llvm/passes`). Both are named in the suite's header. With
     both built, it passed.
   - DOOM's entries still admit and build: `doom-source-pack`,
     `doom-profile` and `doom-board`'s image checks pass.
   - No suite's count is compared here with an earlier run.

The host runner models the data stack as the 32-bit target lays it out:
a 4-byte word and i32 elements. `Array.new` from the application's own
files takes from it, and each method gives back what it took when it
returns (a `TracePoint` on `:call` and `:return`). The runner's own
`Array.new` calls are Ruby's.

### The review (the reviewer, at `a69c90de`)

The reviewer confirmed four findings, each with its own probe, and reported none
beyond them. No oracle was run.

The reviewer also inspected three things and found them consistent:
- the restore runs before every `func.return`, the cold blocks included;
- the closure of `scratchMethods`;
- the wrapper's routing of the region.

The reviewer reran `kernel/host.c` against freshly built objects: 9 of 9
passed.

1. **High: a size the caller chooses was read as the capacity, exactly.**
   - What happened: for `Array.new(n, v)` with a size that is not a
     constant, the loop bounds used the region's element count (31 for 256
     bytes at 8 bytes) as the fill's bound. They then stored that number as
     the value of `a.size`.
   - That is a valid upper bound for the fill's iterations. It is not the
     size. A count that falls as the size grows was bounded from the wrong
     end.
   - The reviewer's probe: `i = a.size; while i < 32` around 100 inner steps,
     with the size taken from `out[0]`. It reported `pass` with work 132
     (outer loop: 1). With `out[0] = 1` the entry runs the outer loop 31
     times, 3132 steps in all.
2. **Medium: the worst-bytes sum of constant sizes overflowed int64.**
   - `Array.new(2^60, 0)` at 8 bytes wrapped to −2^63.
   - The entry was admitted, its object written, and the report said
     `static_proof`.
   - The runtime `CAPACITY` check still kept the region's storage safe, but
     the build-time refusal the record promises (prediction 7) was
     bypassed.
3. **Medium: the host model freed an array early on a name collision.**
   - The TracePoint that frees arrays matched methods by name alone. An
     application method named `make`, even one never called, made the
     model's own `Scratch#make` give each array back as soon as it was
     made.
   - The reviewer's probe was a 16-byte region with 3 elements then 1 more. It
     ran without its declared `CAPACITY`; with the method renamed, the
     `CAPACITY` came back.
4. **Medium: the host model's width.**
   - The model used 4-byte words and i32 elements whatever the body.
   - An application that declares `# spinel: int64` and is listed in
     decision 0019's table is built with a 64-bit body: `Boundary.cpp`
     takes 64 for a declared source, and `pipeline.rb` derives the table
     that lists the packed root.
   - The reviewer's probe stores 2^40 in one element of a 32-byte region. The
     target runs it with status 0; the model reported `ARITHMETIC`.
   - An `:i64` state alone does not widen the body. The first fix here
     (`bc2b8cd2`) assumed every body was 32 bits and missed this case.

### The fix (`fdd5eb04`, `bc2b8cd2`, `ef10112b`)

1. **An array's size is now a symbol of its own**, `size(@<method>:<local>)`,
   unless it is an exact constant within the region.
   - Substitution carries the symbol unchanged through every call, up to
     the entry's totals.
   - There it lies in [0, the region's elements], because a longer array
     fails with `CAPACITY` before anything reads its size. Each work term
     and extern count is resolved separately:
     - a count that never falls as the symbol grows takes it at the
       element count;
     - one that never rises takes it at 0;
     - one that does both, or whose direction cannot be told, is unknown
       (`array-size`), and the work bound is unknown with it.
   - A product moves one way with the symbol only when both factors are
     never negative. Loop bounds are `max(0, …)`, so that holds for nested
     loops.
   - The fill's own iteration count is still the capacity. It is used only
     as a count, where an upper bound is sound.
2. **The worst-bytes sums and products now saturate** at the int64
   maximum. That is past every region, so the total is refused with
   `scratch-capacity`, which says "more than 2^63 - 1".
3. **The host model frees only the application's own methods** (`bc2b8cd2`):
   top-level definitions, on `Object`, in the application's own files.
4. **The host model's data stack has the body's width, as the build has
   it** (`ef10112b`).
   - `CoreApp.int64_listing` is the build's check of decision 0019's table,
     moved out of `Pipeline#int64_allow_table`, which now calls it.
   - `CoreApp.body_bits` gives:
     - 32, what every kernel call passes as `--int-width`;
     - 64 for a listed `# spinel: int64` source.
   - An unlisted declaration is refused by name
     (`int-width-int64-refused`) before any release, as the kernel refuses
     it.
   - `run-host` reads the tree's table, or the one `--mutate-int64-allow`
     names, as `build` does.

### Its checks (`6e83067d`, `37e18304`, `b29741f8`)

Five kernel controls join `tests/scratch/run.sh`:
- `size.rb` (the reviewer's probe) is `pass` with work 3263: the fill 31, the
  outer loop 32 (from a size of 0), and 3200 inside. That is above the 3132
  it runs with `out[0] = 1`.
- `sizeany.rb` bounds a loop by `s * (40 - s)`, which rises and then falls
  over [0, 31]. It is `unknown`, and its term names `array-size`.
- `huge.rb` (2^60 elements) is refused with `scratch-capacity`.
- `room.rb` makes 31 elements, which fill a 256-byte region exactly. It is
  `static_proof` with 248 bytes.
- `room32.rb` makes 32 elements and is refused, 256 against 248.

Four application fixtures run on the host:
- `samename` (the reviewer's probe, with the unused `make`) fails with its
  declared `CAPACITY` at release 1. Before the fix it failed at release 2.
- `wide` has an `:i64` state and no declaration. Its report has 3
  elements in 16 bytes; on the host its 3 elements fit and `out[0]` is 21.
- `int64` (the reviewer's probe) declares a 64-bit body:
  - listed in a table of the suite's own, it runs with status 0, and
    `out[0]` is 2^40;
  - under this tree's table, `run-host` refuses it by name before any
    release.
- `narrow`, the same program with a 32-bit body, fails with `ARITHMETIC` at
  release 1.

The suite went from 43 to 56 passed, 0 failed, 0 skipped.

The 44 suites `affected.rb` selects (the same ids as before) ran once more,
one at a time, at `b29741f8`, in 2510 s.
- 42 exited 0 and 2 exited 2, as at `4d94e685`:
  - `fiber` skips its wasmtime runner;
  - `doom-play-board` was not given a finished `rt1186.sh` run.
- `scratch` passed 56 of 56. `doom-board`'s board-free part passed 52 of
  52. `freestanding` passed every lane.
- `app-build` passed. It builds `divides`, the listed `# spinel: int64`
  application, through the moved table check.
- The export check passed on the export of `b29741f8`.
- A rerun begun after `6e83067d` was stopped and its results discarded:
  the third and fourth fixes were made in the worktree while it ran.

### The re-review (the reviewer, at `f02c9c6d`)

All four findings are closed, and there are no new ones. The reviewer ran each
probe again against copies of this tree's kernel and contract reader:
- `size.rb`: `pass` with work 3263, where the report had said 132. The C
  run with `out[0] = 1` returns status 0, 3100 steps and offset 0, so its
  3132 iterations are within the bound.
- `huge.rb`: refused with `scratch-capacity` ("more than 2^63 - 1"), and no
  object is written.
- The application with the unused `make`: `CAPACITY` at release 1, as its
  stimulus declares.
- The `# spinel: int64` application:
  - with a table that lists it, status 0 and 2^40 in the state;
  - with this tree's table, `int-width-int64-refused` before any trace.

The reviewer added a control of its own: the same int64 application with 16
bytes and `n = out[0] + 2`. It fails with `CAPACITY` at release 1, which
shows 8-byte words as well as 8-byte elements.

`sh tests/scratch/run.sh` gave 51 passed, 0 failed, 1 skipped. The skip is
QEMU, for want of the Zephyr environment. No oracle was run.
