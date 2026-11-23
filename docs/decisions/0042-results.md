# 0042: results, stage by stage

The record [decision 0042](0042-core-bit-and-power-operators.md) keeps beside
it. Each stage's predictions are committed before its implementation starts,
and its results are added below them when its checks have run. A prediction
that turns out wrong stays as written, and the result says so.

## Stage 1: `&`, `|`, `^` and `~` on `--core` and freestanding

### Observed before the predictions (2026-11-14)

Probes against the native build, the contract reader and the pinned compiler
of `5217686a`, built in this worktree:

- **Native `--core`** (`tools/core/spinel-core-build --core calculate`): `a & b`,
  `~a`, `r & 0xffff_ffff` and `(a < b) & (b < a)` are each refused as
  `unresolved-call`, `no scalar effect contract for &` (or `~`). The checker
  runs in its unchecked scalar mode on this route, and admits the four only in
  the checked mode (`Core/Eligibility.cpp`).
- **Freestanding** (`spinel-fs-emit`, x86_64 host profile): `a & b` and `~a` are
  refused as `unsupported: CallNode`, by the importer's closed operator set
  (`Importer.cpp`, `isSupportedOperator`), which admits the four only for the
  status ABI. `x &= 0xff` is refused as
  `unsupported: 'opw': LocalVariableOperatorWriteNode`, by the lowering's own
  operator list for `op=` (`MlirGen.cpp`).
- **The lowering** (`MlirGen.cpp`, `binop` and the unary arm) has the four for
  the status mode only. `--core` lowers in the `Abort` overflow mode, and
  freestanding in `Trap` or `Wrap` with typed values.
- **What stays refused in stage 1:** `a >> 4` is `unsupported: CallNode` on
  freestanding, and `a << 4` is refused by the subset table ("`<<` on an Array
  or String appends to a heap object..."). On `--core` both are
  `unproved-arithmetic`.
- **A Float operand on freestanding** is refused before any operator rule:
  `x & 1` on an `:f64` parameter makes whole-program inference type the method
  `poly`, and the declaration check refuses it ("whole-program inference says
  `fand` returns `poly`").
- **A wide literal at 32 bits:** on the wasm32 profile, `a + 0xffff_ffff` is
  refused because inference types the method `bigint`.

### Predictions (2026-11-14, before any implementation)

1. **Where the change lands.**
   - `Core/Eligibility.cpp`: the unchecked scalar mode (the `--core` route)
     admits `&`, `|`, `^` and `~` under the rule the checked mode already
     applies: proven `int` operands and an `int` result, else `type-evidence`.
   - `Frontend/Scalar/Importer.cpp`: the closed operator set admits the four
     for freestanding and for the `--core` route, through one new selection
     option that `Core/Emit.cpp` sets. The hosted lanes (`Raise`, `Wrap` and
     `None` without freestanding types) keep their refusal.
   - `Frontend/Scalar/MlirGen.cpp`: `binop` and the unary arm lower the four
     for the status, `Abort` and freestanding modes, as the bare `arith.andi`,
     `arith.ori` and `arith.xori` the status mode already emits. On
     freestanding, `x &= m`, `x |= m` and `x ^= m` are admitted too, as
     `x = x op m`.
   - Nothing in `vendor/`, the contract reader, the subset refusal table or
     its pin.
2. **No failure path.** None of the four can fail, so a `--core` object whose
   method uses only them has no undefined symbol: `spc_core_fail` is not
   referenced. A method that also uses `/`, `*` or `+` keeps it.
3. **Values, 64-bit, hand-derived.** On `--core` and on the x86_64
   freestanding profile:
   - `7 & 2` is 2, `12 & 10` is 8, `-12 & 255` is 244, `MIN & -1` is `MIN`;
   - `12 | 3` is 15, `-16 | 5` is -11;
   - `12 ^ 10` is 6, `-1 ^ 5` is -6, `MIN ^ -1` is `MAX`;
   - `~5` is -6, `~MAX` is `MIN`, `~MIN` is `MAX`;
   - `-1 & 0xffff_ffff` is 4294967295;
   - field extraction `(r & 0xf0) / 16 * 100 + (r & 0xf)` with `r = 0xa7` is
     1007; set and clear `(r | 0x80) & ~0x01` with `r = 0x41` is 192;
   - on freestanding only, `x = 0x1234; x &= 0xff; x |= 0x100; x ^= 1` is 309.

   `MIN` and `MAX` are the Integer bounds at the body width.
4. **Values, 32-bit.** On the wasm32 profile under node, with `i32`
   parameters: the same rows where they fit, with `MIN` and `MAX` at 32 bits,
   and `-1 & 0x7fff_ffff` is 2147483647 in place of the 32-bit mask. This is
   the only 32-bit execution in stage 1.
5. **Refusals.**
   - `--core`: `(a < b) & (b < a)` is refused as `type-evidence`; the
     operands are booleans.
   - Freestanding: the same boolean expression is refused by the lowering,
     "left operand of & is a boolean; only Integer values are in the subset".
     A Float operand stays refused by the declaration check (`returns poly`),
     before the operator.
   - Stage 2's operators stay refused, each with today's words: `>>` and `<<`
     on both routes.
6. **Where the checks go.**
   - `tests/native-core/arith.sh` gains the `--core` value cases. The fixture
     `reject_bitwise` (`7 & 2`) moves from a refusal row to an admitted case,
     `and_ok`. Each case also states the core object's undefined symbols. Its
     count goes from 50 passed and 1 pending to 78 passed and 1 pending: 14
     cases of two checks each, one refusal row fewer, and one more for the
     boolean operands.
   - A new suite, `tests/core-bitwise`, holds the freestanding route: the
     x86_64 values, the wasm32 values under node, the refusals, and two
     controls with planted inputs. It is registered in `tools/test/tests.tsv`
     and `tools/test/affected.tsv`, and the manifest's pins for those two
     files are renewed.
   - The documents that list the `--core` envelope move with it: `README.md`,
     `docs/native-core/supported-envelope.md`, `docs/roadmap.md` and
     `tests/native-core/arith.md`.
7. **Nothing else moves.** The suites `ruby tools/test/affected.rb --base
   origin/main` selects pass, with the counts 0041 stage 1 reported for the
   same suites, apart from `native-core-arith` (6) and the new suite. No
   existing fixture outside `tests/native-core` asserts a refusal of the four:
   a grep of the e040 and e084 reject tables, `tests/subset` and the
   subset-table pin finds none. `doom-loop-reports` is a long check and waits
   for the end of the plan.

### Checks

As 0042 lists them for stage 1, with one change: the field extraction is
written with a mask and a division, since `>>` is stage 2's. The decision's
`(r >> 4) & 0xf` is checked as still refused.

### Results so far (2026-11-14), before the pin move

Implemented on `feat/0042-bitwise` (`0516712f`), on `5217686a`. The final
suite run waits for the pin move to `bd53f5938`'s backport and a rebase onto
it; the run below is kept for reference only.

1. **Where the change lands: held.** Two additions. The new selection option
   is named `exactBitwise`, and the lowering asks one helper of the same
   name. A Float operand of `~` is refused by name, as `&` on a Float
   already was.
2. **No failure path: wrong in one case.** A core that uses only the four
   has no undefined symbol, as predicted. But `field`,
   `(a & 0xf0) / 16 * 100 + (a & 0xf)`, which also divides, multiplies and
   adds, has none either.
   - Observed: the core MLIR that `spinel-core-emit --emit-mlir` writes for
     `field` has four calls to `spc_core_fail`: the zero divisor, and the
     overflow of `/`, `*` and `+`. The object has no undefined symbol.
   - The mask bounds every value, so after the MLIR the failure arms are
     gone. Which pass removes them was not looked at.
   - This is correct behaviour, not a defect. `field` now expects no
     symbol. A new fixture, `field_var` (`(a & 0xf0) / b`), keeps
     `spc_core_fail`.
3. **Values at 64 bits: held,** on both routes, for every row listed.
4. **Values at 32 bits: held,** on wasm32 under node.
5. **Refusals: held.** The boolean operands are refused with the predicted
   words on both routes. The Float operand is refused by the declaration
   check (`returns poly`). `>>` and `<<` keep their words.
6. **Where the checks go: held, with one addition.** `arith.sh` gives 80
   passed, 0 failed, 1 pending, not 78: `field_var` adds two checks.
   `tests/core-bitwise` gives 10 passed, 0 failed, 0 skipped.
7. **Nothing else moves: wrong twice.** In the run before the pin move, 27
   of the 29 selected suites passed with 0041 stage 1's counts. Two failed:
   - `tests/core-boundary/arithmetic.sh` asserted that the `--core` checker
     refuses `band.rb` (`a & b`) as `unresolved-call`, the refusal this
     stage lifts. The prediction's grep looked for the message text and
     missed this row. Run on its own, the lane showed the refusal is now
     `type-evidence`, `parameter a is poly`, since the fixture has no
     caller. The row now expects that, and the lane passes 164 of 164.
   - `tests/imports/run.sh` found the 11 new `tests/core-bitwise` files
     under no row of `docs/imports.tsv`. The row is added, the table is
     re-pinned in the manifest, and the suite passes 10 of 10.

### Suites, the final run (2026-11-14)

After the pin move to `baddd25a9` (main `5d45f62f`), the four commits of
this stage were rebased onto main, vendor and the tools rebuilt, and the
suites `ruby tools/test/affected.rb --base origin/main` selected, 29 of them,
run once on Debian x86_64 with LLVM 23.1.1. The selection is the same 29 as
before the pin move. Every suite passed; the total wall time was 482 s.

| suite | result | wall |
|---|---|---|
| `tests/affected/run.sh` | 67 checked, 67 pass | 2 s |
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 skipped | 14 s |
| `tests/core-bitwise/run.sh` (new) | 10 passed, 0 failed, 0 skipped | 1 s |
| `tests/core-blocks/run.sh` | 47 passed, 0 failed, 0 skipped | 1 s |
| `tests/core-boundary/run.sh` | 12 lanes, 12 passed | 36 s |
| `tests/core-eligibility/run.rb` | 52 passed, 0 failed | 2 s |
| `tests/core-boundary/intrinsics.sh` | 50 checked, 50 pass | 2 s |
| `tests/core-report/run.sh` | 785 passed, 0 failed, 1 skipped | 80 s |
| `tests/core/run.sh` | 33 passed, 0 failed | 1 s |
| `tests/core-stack/run.sh` | 31 checked, 31 pass, 1 skipped | 3 s |
| `tests/dist/run.sh` | 104 checked, 104 pass | 10 s |
| `tests/dist/export.sh` | 1 checked, 1 pass | 33 s |
| `git diff --check origin/main -- docs` | clean | 0 s |
| `tests/doom-core/borrowed-calls.sh` | 51 checked, 51 pass | 1 s |
| `tests/doom-core/control-flow.sh` | 55 checked, 55 pass | 1 s |
| `tests/fiber/core.sh` | 43 passed, 0 failed, 0 skipped | 81 s |
| `tests/freestanding/run.sh` | every lane passed; the two board lanes NOT RUN (no `FRDM_HOST`) | 172 s |
| `tests/imports/run.sh` | 10 checked, 10 pass | 2 s |
| `tests/lowering/duplicate.sh` | 3 checked, 3 pass | 0 s |
| `tests/lowering/locations.sh` | 9 checked, 9 pass | 1 s |
| `tests/lowering/reopened.sh` | 11 checked, 11 pass | 0 s |
| `tests/lowering/split.sh` | 6 checked, 6 pass | 0 s |
| `tests/native-core/arith.sh` | 80 passed, 0 failed, 1 pending | 22 s |
| `tests/native-core/driver.sh` | 44 passed, 0 failed | 5 s |
| `tests/native-core/ledger.sh` | 23 passed, 0 failed | 1 s |
| `tests/native-core/run.sh` | 8 passed, 0 failed | 4 s |
| `tests/oracle/check.sh` | 0 failures | 4 s |
| `tests/source-stamp/run.sh` | 12 checked, 12 pass | 1 s |
| `tests/subset/reasons.sh` | 42 checked, 42 pass | 2 s |

- `core-blocks` (47, not 44) and `core-report` (785, not 741) have more
  checks than 0041 stage 1 reported. The added fixtures came to main with
  the 0041 review (`955b4e93`); this branch changes neither suite.
- The skips and the pending one are each suite's own named ones:
  `BASELINE_KERNEL` in core-report, the pending `abort_hooks` fixture in
  native-core arith, `REAL_IR` unset in core-stack (A == B checked on the
  fixtures only), and the board lanes in freestanding.
- No oracle section ran. The long `doom-loop-reports` lane and the board
  suites (`intrinsics-board`, `rt1186`) wait for the end of the plan.

## Stage 2: `<<` and `>>` on every route (S1)

### Observed before the predictions (2026-11-14)

Probes against the native build, the contract reader and the pinned compiler
of main `d5b54a7f`, built in this worktree. `w` is the body width.

- **Status lane** (`spinel-core-kernel`). `shiftOp` in `MlirGen.cpp` is
  0007's rule: a count outside `0..w-1` is `ARITHMETIC` before the shift, and
  a `<<` that does not shift back to its operand is `ARITHMETIC`. Built for
  wasm32 with `--layout ptr32-i64-32long --int-width=32` and run under node,
  the 32-bit `shl` kernel gives `3 << 4` 48, `1 << 30` 1073741824, `-1 << 31`
  `MIN`, and status 2 (`ARITHMETIC`) with the result untouched for `1 << 31`,
  `0 << 32`, `1 << -1` and `5 << 32`. So a 32-bit status kernel can run on
  this host without a board.
- **Native `--core`** (`tools/core/spinel-core-build --core calculate`):
  - `a << b` and `a >> b` are refused as `unproved-arithmetic`.
  - `x <<= b` is refused as `unsupported-node`, as every `op=` is in the
    unchecked mode.
  - `x = [a]; x << b` is refused as `heap-operation` (the `ArrayNode`), with
    `type-evidence` rows beside it, and `unproved-arithmetic` for the `<<`.
  - A reopened `Integer#<<` is refused as `binding-environment`.
- **Freestanding** (`spinel-fs-emit`, x86_64 host profile):
  - `x << 1` on an `i64` parameter and `b << 1` on an `[:i64_buf, :inout]`
    parameter are both refused by the subset table's `<<` row, which reads
    no type.
  - In the stage 2 source, with the synthetic driver appended, the reader
    types `x` and the `<<` call as `int`, and `b` and its `<<` call as
    `int_array`. So the walk can tell the two apart by the receiver's type.
  - A reopened `Integer` is refused by its own words ("`class Integer`
    changes the builtin class Integer at the top level"), before any
    operator.
- **Status lane refusals**: a kernel whose method does `x = [a]; x << b` is
  refused as `heap-operation` (with `type-evidence`); one with a reopened
  `Integer#<<` as `binding-environment`.
- **The pinned Spinel** (`lib/spinel_rt.h`, `sp_int_shl`, `sp_int_shr`, read,
  not run), in wrap mode:
  - `a << n` with `n >= w` is 0, and otherwise keeps the low bits;
  - `a << -n` is `a >> n`, the sign fill when `n >= w`;
  - `a >> -n` is a left shift with no check (the defect 0042 records). In
    wrap mode it keeps the low bits, and gives 0 when `n >= w`.

### Predictions (2026-11-14, before any implementation)

1. **One rule, one helper.** `shiftOp` in `MlirGen.cpp` is rewritten to S1 for
   every mode, and the status, `Abort`, `Trap`, `Wrap` and `None` modes all
   lower `<<` and `>>` through it. Branch-free:
   - the count's direction and magnitude are computed first;
   - a magnitude of `w` or more (including `n = MIN`) selects the sign fill
     for a right shift;
   - a left shift loses bits when it does not shift back, or when the
     magnitude is `w` or more and the operand is not 0.

   Only the failure delivery differs by mode:
   - status: `ARITHMETIC`;
   - `Abort`: `spc_core_fail(OVERFLOW, SHL)`, a new op code 7, which the shim
     maps to `integer overflow in <<` (also for `a >> -n`);
   - `Trap`: the profile's hook with code 1, the overflow code `/` uses for
     `MIN / -1`;
   - `Wrap` and `None`: no failure. The low bits are kept, and a left shift
     by `w` or more is 0.
2. **Where else the change lands.**
   - `Core/Eligibility.cpp`: the unchecked mode admits `<<` and `>>` under the
     same type rule as `& | ^`.
   - `Importer.cpp`: the closed operator set admits `<<` and `>>` for
     freestanding and `--core`. The stage 1 option `exactBitwise` is renamed
     `bitOperators`, since a shift is not exact.
   - `MlirGen.cpp`: the `op=` list admits `<<=` and `>>=` on freestanding.
   - `FreestandingSubset.cpp`: the `<<` row is applied only when the
     receiver's type is not `int`.
   - `SubsetRefusals.cpp`: the `<<` reason drops "the freestanding subset has
     no shift yet", since that is no longer true.
   - `Core/Emit.cpp`: the header and the shim gain `SPC_CORE_OP_SHL`.
   - Nothing in `vendor/` or in the contract reader.
3. **Values.** One hand-written table, `tests/core-bitwise/shifts.tsv`, gives
   for each width (64 and 32) and each row `op a n` the checked answer (a
   value, or `fail`) and the wrapped answer. It has the counts `-w-1`, `-w`,
   `-w+1`, -1, 0, 1, `w-2`, `w-1`, `w`, `w+1`, `MIN` and `MAX`, with:
   - `-1 << (w-1)` is `MIN`, and `1 << (w-1)` fails;
   - `3 << (w-2)` and `-3 << (w-2)` fail;
   - `0 << w`, `0 << MAX` and `0 >> MIN` are 0;
   - `a >> -1` past the width fails (`MAX >> -1`), and `1 >> -(w-1)` fails;
   - `-1 >> -(w-1)` is `MIN`.

   Each route gives the table's answers on every row:
   - the status lane at 64 bits natively, and at 32 bits on wasm32 under
     node. A failed row has status `ARITHMETIC` with the result untouched;
   - freestanding `trap` at 64 bits (x86_64 host) and at 32 bits (wasm32),
     where a failed row is the hook with code 1;
   - freestanding `wrap` at both widths, matching the wrap column;
   - `--core` at 64 bits. A failed row prints `integer overflow in <<
     (RangeError)` on stderr with exit status 1, as the hosted
     `--int-overflow=raise` build does. Its object keeps `spc_core_fail` as
     its one undefined symbol.
4. **A field read with a constant shift has no hook.**
   `((r >> 4) & 0xf) * 100 + (r & 0xf)` with `r = 0xa7` is 1007 on `--core`,
   and its object has no undefined symbol: a constant count in range cannot
   fail, and the mask bounds the rest (stage 1's `field`). `(a << 8) | b` with
   `0x12` and `0x34` is 4660, and keeps the hook.
5. **Refusals.**
   - `--core`: the Array `<<` stays `heap-operation`; the reopened
     `Integer#<<` stays `binding-environment`.
   - Status lane: the same two, with the same categories.
   - Freestanding:
     - `b << 1` on a buffer parameter is refused by the `<<` row's new
       words;
     - the reopened `Integer` keeps its own words;
     - a Float operand of `>>` is refused before the operator, as `returns
       poly` (stage 1's `float_and`).
6. **Fixtures and documents that move,** and no others:
   - `tests/native-core/arith.sh`: `reject_shift` (`7 << 2`) becomes the
     admitted case `shl_ok` (28). The refusal row `shift` is replaced by the
     two in 5. Nine cases are added: `shl_ok`, `shl_values`, `shr_values`,
     `shl_overflow`, `shl_count`, `shr_neg_count`, `shr_min_count`,
     `field_shift` and `pack`. The suite goes from 80 passed and 1 pending
     to 99 passed and 1 pending (9 cases of two checks, one refusal row
     fewer, two more).
   - `tests/core-boundary/fixtures/arithmetic/cases.tsv`: S1 changes three
     rows. `shl-count-64` (`0 << 64`) becomes `ok 0`, `shr-count-64`
     (`-1 >> 64`) `ok -1`, and `shl-count-neg` (`1 << -1`) `ok 0`.
     - `oracle.rb`'s `<<` and `>>` follow S1. It is edited, not run: it is a
       gated oracle.
     - The mutation control "an unchecked shift count", which planted `ok`
       on `shl-count-64`, would now change no cell. It is replaced by "the
       0007 count rule", which plants `arithmetic`/`shift-range` on
       `shr-count-64`.
     - The unchecked-slice pair `shl.rb:shl:unproved-arithmetic` becomes
       `type-evidence` with the poly-parameter words, as `band.rb` did in
       stage 1.
   - `tests/core-bitwise`:
     - the `shift_left` and `shift_right` refusals are removed (their
       functions are admitted now);
     - the suite gains the shift table's runs on the four builds, the
       refusals in 5, and a control that plants a wrong table row;
     - `fs/k.rb` and `fs32/k.rb` gain an `op=` function
       (`x <<= 4; x >>= 2`).

     From 10 to 22 checks:
     - freestanding at 64 bits: 4 (compile, the bitwise lines, trap shifts,
       wrap shifts), and 4 at 32 bits;
     - the status lane: 2 at 64 bits and 2 at 32 bits;
     - refusals: 7 (5 freestanding, 2 status);
     - controls: 3.
   - `tests/subset/fixtures/call-shl.rb` puts its `<<` on a buffer parameter.
     `tests/subset-tables/pin.tsv` takes the new reasons digest.
   - `docs/core/buffer-boundary.md`'s shift count rule, `README.md`,
     `docs/native-core/supported-envelope.md`, `docs/roadmap.md` and
     `tests/native-core/arith.md`.
7. **Nothing else moves.** The suites `affected.rb --base origin/main`
   selects pass with stage 1's counts, apart from the ones in 6. In
   particular, no DOOM kernel's status-lane result changes: every shift in
   them has a count in `0..w-1`, where S1 and 0007 agree. The board suites
   and `doom-loop-reports` wait for the end of the plan.

### Results (2026-11-14)

The implementation is `d890b574` (code, with the subset pin and the subset
fixture) and `9d05a2b6` (tests and documents). `d890b574` also carries the
removal of core-bitwise's two shift refusal fixtures and the rename of
`reject_shift.rb`, which belonged to the tests commit, so `core-bitwise` and
`native-core-arith` run from `9d05a2b6` on. The two misses below are fixed in
`c35fb424`.

1. **One rule, one helper:** as predicted. `shiftOp` is S1 for every mode,
   and only the failure delivery differs.
2. **Where else the change lands:** as predicted, including the rename to
   `bitOperators` and `SPC_CORE_OP_SHL` (7). Nothing in `vendor/` or in the
   contract reader changed.
3. **Values:** as predicted. `tests/core-bitwise/shifts.tsv` has 43 rows per
   width, and every row matched on:
   - freestanding `trap` and `wrap` at 64 bits (x86_64 host) and at 32 bits
     (wasm32 under node);
   - the status lane at 64 bits on this host and at 32 bits on wasm32 under
     node, where each failed row was `ARITHMETIC` with the result word
     untouched.

   On `--core`, `shl_overflow`, `shl_count`, `shr_neg_count` and
   `shr_min_count` print `integer overflow in << (RangeError)` with exit
   status 1.
4. **A field read with a constant shift has no hook:** as predicted.
   `field_shift` is 1007 with no undefined symbol, and `pack` is 4660 with
   `spc_core_fail`.
5. **Refusals:** as predicted, on all three routes.
6. **Fixtures and documents that move: two misses.** The listed ones moved
   as predicted: `native-core-arith` 99 passed and 1 pending, `core-bitwise`
   22. But two more checks asserted a shift refusal, and both failed in the
   run below:
   - `tests/native-core/driver.sh`, the eligibility refusal (42 passed,
     2 failed);
   - `tests/native-core/run.sh`, the emitter refusal (7 passed, 1 failed).

   Both write their input with `printf` inside the script, so a grep of
   `.rb` fixtures for shifts does not find them. A check of the checker
   found that, after this stage, no operator outside decision 0042 still
   reaches `unproved-arithmetic` on the `--core` route: `**` is the last
   one, and stage 3 admits it. So both checks now refuse a String literal,
   which allocates and which no decision plans to admit in core. The printed
   reason is `heap-operation`, `StringNode requires heap semantics`, and it
   is the only one. Rerun alone after the fix: `driver.sh` 44 passed,
   0 failed (5 s), and `run.sh` 8 passed, 0 failed (4 s).
7. **Nothing else moves:** as predicted. Every other selected suite passed
   with stage 1's counts where stage 1 ran it. `subset-map` and
   `subset-tables` are selected in this stage (the subset table changed),
   and `affected`, `dist` and `export` are not (no `tools/test` table
   changed).

### Suites (2026-11-14)

The suites `ruby tools/test/affected.rb --base origin/main` selected at
`9d05a2b6`, 28 of them, run once on Debian x86_64 with LLVM 23.1.1: 26
passed and 2 failed (the misses of prediction 6), in 439 s in all. The two
were rerun alone after `c35fb424`.

| suite | result | wall |
|---|---|---|
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 skipped | 15 s |
| `tests/core-bitwise/run.sh` | 22 passed, 0 failed, 0 skipped | 0 s |
| `tests/core-blocks/run.sh` | 47 passed, 0 failed, 0 skipped | 2 s |
| `tests/core-boundary/run.sh` | 12 lanes, 12 passed | 35 s |
| `tests/core-eligibility/run.rb` | 52 passed, 0 failed | 3 s |
| `tests/core-boundary/intrinsics.sh` | 50 checked, 50 pass | 2 s |
| `tests/core-report/run.sh` | 785 passed, 0 failed, 1 skipped | 80 s |
| `tests/core/run.sh` | 33 passed, 0 failed | 1 s |
| `tests/core-stack/run.sh` | 31 checked, 31 pass, 1 skipped | 2 s |
| `git diff --check origin/main -- docs` | clean | 0 s |
| `tests/doom-core/borrowed-calls.sh` | 51 checked, 51 pass | 1 s |
| `tests/doom-core/control-flow.sh` | 55 checked, 55 pass | 1 s |
| `tests/fiber/core.sh` | 43 passed, 0 failed, 0 skipped | 80 s |
| `tests/freestanding/run.sh` | every lane passed; the two board lanes NOT RUN (no `FRDM_HOST`) | 169 s |
| `tests/imports/run.sh` | 10 checked, 10 pass | 2 s |
| `tests/lowering/duplicate.sh` | 3 checked, 3 pass | 0 s |
| `tests/lowering/locations.sh` | 9 checked, 9 pass | 1 s |
| `tests/lowering/reopened.sh` | 11 checked, 11 pass | 0 s |
| `tests/lowering/split.sh` | 6 checked, 6 pass | 0 s |
| `tests/native-core/arith.sh` | 99 passed, 0 failed, 1 pending | 27 s |
| `tests/native-core/driver.sh` | 42 passed, 2 failed; after `c35fb424`, 44 passed, 0 failed | 6 s; 5 s |
| `tests/native-core/ledger.sh` | 23 passed, 0 failed | 0 s |
| `tests/native-core/run.sh` | 7 passed, 1 failed; after `c35fb424`, 8 passed, 0 failed | 4 s; 4 s |
| `tests/oracle/check.sh` | 0 failures | 4 s |
| `tests/source-stamp/run.sh` | 12 checked, 12 pass | 1 s |
| `tests/subset/map.sh` | 13 checked, 13 pass | 0 s |
| `tests/subset/reasons.sh` | 42 checked, 42 pass | 3 s |
| `tests/subset-tables/run.sh` | 12 checked, 12 pass | 0 s |

- The skips and the pending case are each suite's own named ones, as in
  stage 1.
- No oracle section ran. `oracle.rb` in core-boundary was edited to S1 and
  is not run here. The long `doom-loop-reports` lane and the board suites
  (`intrinsics-board`, `rt1186`) wait for the end of the plan; the DOOM
  kernels' shifts, all with counts in `0..w-1`, meet the changed status
  lowering only there.

## Stage 3: `abs` and `**` on every route

### Observed before the predictions (2026-11-14)

Probes against the native build, the contract reader and the pinned compiler
(`baddd25a9`) of main `4cf6d188`, built in this worktree. Each probe is one
method whose body is the expression, with Integer parameters.

- **Status lane** (`spinel-core-kernel`). `a.abs` builds: `absOp` fails
  `MIN.abs` as `ARITHMETIC` ("abs of the minimum"). `a ** n` and `a ** 2` are
  refused with three reasons: `unsupported-operator` ("`**` is not in this
  version"), and `type-evidence` twice, because the checker derives no type
  for `**` (`isBinaryArithName` does not list it), so the expression and the
  entry's result are `conflicting`.
- **Native `--core`** (`tools/core/spinel-core-build --core calculate`):
  `a ** b` is `unproved-arithmetic` ("overflow, nil and failure effects are
  not proved for **"), and `a.abs` is `unresolved-call` ("no scalar effect
  contract for abs").
- **Freestanding** (`spinel-fs-emit`, x86_64 host profile): `a ** n` is
  refused by the subset table's `**` row ("`**` can produce a Bignum, ...
  Write the power out, or move the computation to the host."), and `a.abs`
  is `unsupported: CallNode`.
- **The pinned Spinel** (`lib/sp_cold.c`, `sp_int_pow`; `lib/spinel_rt.h`,
  `sp_int_abs`; read, not run):
  - `sp_int_pow` raises `RangeError`, `negative exponent` for `n < 0`, then
    squares and multiplies over the bits of `n`, checking each step. A
    squaring is done, and checked, only while bits of `n` remain. The
    message is `integer overflow in **`. In wrap mode both steps wrap.
  - `sp_int_abs` raises `RangeError`, `integer overflow in abs` for `MIN`,
    and gives `MIN` back in wrap mode.
- **Freestanding trap codes** in use: 1 (overflow), 2 (division by 0), 3
  (narrowing), 4 (bounds), 5 (NULL buffer), 6 (negative length). 7 is free.

### Predictions (2026-11-14, before any implementation)

1. **Where the change lands,** and nowhere else (nothing in `vendor/` or in
   the contract reader):
   - `MlirGen.cpp`:
     - `absOp` serves every mode. `MIN.abs` fails as each mode delivers an
       overflow; `Wrap` and `None` give `MIN`. On the status lane it emits
       the same operations in the same order as today.
     - A new `powOp` serves every mode (below), reached from `binop` when
       the status lane or `bitOperators()` holds. The unary arm admits `abs`
       under `bitOperators()`.
     - The `op=` list gains `**`, so `x **= n` means `x = x ** n`.
   - `Importer.h`: `CoreFailKind::NegativeExponent = 3`, `CoreFailOp::Abs =
     8` and `CoreFailOp::Pow = 9`.
   - `Core/Emit.cpp`: the header gains `SPC_CORE_FAIL_NEGATIVE_EXPONENT`,
     `SPC_CORE_OP_ABS` and `SPC_CORE_OP_POW`. The shim maps kind 3 to
     `RangeError`, `negative exponent`, and the two operators to `integer
     overflow in abs` and `integer overflow in **`.
   - `Importer.cpp`: the closed operator set admits `**` on the status lane,
     and `abs` and `**` on freestanding and `--core`.
   - `Core/Eligibility.cpp`:
     - `**` derives `int` from two `int` operands, as `*` does;
     - the `unsupported-operator` refusal of `**` is removed;
     - the unchecked mode (`--core`) admits `abs` and `**` under the same
       type rule as the others;
     - the `op=` and `[]op=` lists gain `**`.

     `+@` on `--core` stays `unresolved-call`: it is not in 0042.
   - `FreestandingSubset.cpp`: the `**` row is applied only when the
     receiver or the argument is not typed `int`.
   - `SubsetRefusals.cpp`: the `**` reason no longer says to write the power
     out. It says that `**` is admitted on two Integers, and why this one is
     refused.
2. **The lowering of `**`.** Branch-free and without a loop, on every mode:
   - **A constant exponent `e` in `0..w-1`** (or any `e >= 0` under `Wrap`):
     an unrolled chain with `bit_length(e) - 1` squarings and
     `popcount(e) - 1` multiplications. `a ** 0` is 1 and `a ** 1` is `a`.
   - **Otherwise:**
     - `n < 0` fails as a negative exponent;
     - for `n >= w`, the checked modes compute `a ** (2 + n % 2)`, which is
       right for `a` in -1, 0, 1, and fail for any other `a`;
     - below `w`, a fixed chain over the `log2(w)` low bits (6 at 64, 5 at
       32), each step's result selected by its bit. A squaring's overflow
       counts only while higher bits remain, and a multiplication's only
       when its bit is set.
     - `Wrap` and `None` run the chain over all `w - 1` bits without
       checks, since the low bits of `a ** n` need every bit of `n`.

   Checked, `a ** 2` has one `llvm.intr.smul.with.overflow` in the 64-bit
   status kernel's MLIR (`--emit-mlir`), `a ** 63` has 10, and `a ** n` has
   10 (5 squarings, 5 multiplications).

   Each failure is delivered the mode's own way:
   - status: `ARITHMETIC`;
   - `Abort`: `spc_core_fail(OVERFLOW, POW)` or
     `spc_core_fail(NEGATIVE_EXPONENT, POW)`;
   - `Trap`: the hook with code 1 for an overflow, and with the new code 7
     for a negative exponent (also under `Wrap`, as 0042 decides).
3. **Values.** One hand-written table, `tests/core-bitwise/powers.tsv`, has
   78 rows per width (64 and 32). Each row is `op a n` with the checked
   answer (a value, `fail`, or `negative`) and the wrapped answer. It was
   generated by a scratch script from 0042's rule, as `shifts.tsv` was; no
   compiler ran to make it. Its rows:
   - `abs` of 0, 5, -5, `MAX`, `MIN + 1` and `MIN` (`fail`, wrapped `MIN`);
   - `pow` with the bases 0, 1, -1, 2, -2 and 3 and the exponents -1, 0,
     `w - 2`, `w - 1`, `w` and `w + 1`. `(-2) ** (w - 1)` is `MIN`, and
     `2 ** (w - 1)` fails;
   - `pow` across the edge: `3 ** 39` and `3 ** 40` (19 and 20 at 32
     bits), `(-3) ** 39`, `10 ** 18` and `10 ** 19` (9 and 10). Also `MIN ** 0`,
     `MIN ** 1`, `MIN ** 2`, `7 ** -3`, and `-1`, 1, 0, 2 and 3 to the
     power `MAX`. `MIN ** MIN` is `negative`;
   - `powk`, a constant exponent: 0, 1 and 2 (`a ** 2` across
     `sqrt(MAX)`), then 31 and 63, each with the bases above.

   Each route gives the table's answers on every row:
   - the status lane, at 64 bits natively and at 32 bits on wasm32 under
     node. Both `fail` and `negative` are `ARITHMETIC` there, with the
     result word untouched;
   - freestanding `trap` at 64 bits (x86_64 host) and 32 bits (wasm32):
     `fail` is the hook with code 1, `negative` the hook with code 7;
   - freestanding `wrap` at both widths, matching the wrap column, and
     `negative` is still code 7;
   - `--core` at 64 bits, for the cases in 6.
4. **`--core`'s messages** are the pinned Spinel's, on stderr with exit
   status 1, as the hosted `--int-overflow=raise` build prints them:
   `integer overflow in abs (RangeError)`, `integer overflow in **
   (RangeError)` and `negative exponent (RangeError)`. Stage 2's `<<` message
   is unchanged. The object keeps `spc_core_fail` as its one undefined
   symbol.
5. **No loop in the report.** A status kernel of `a ** n`, built with
   `--report --profile hosted-stage2`, reports no loop.
6. **Refusals.**
   - Freestanding: `b ** 2` on a buffer parameter and `1.5 ** n` are both
     refused by the `**` row's new words.
   - Status lane: `**` on a reopened `Integer` is `binding-environment`.
   - `--core`: `+@` stays `unresolved-call` (unchanged, not checked again).
7. **Fixtures and documents that move,** and no others:
   - `tests/native-core/arith.sh`:
     - `reject_pow` (`7 ** 2`) and `reject_abs` (`(-7).abs`) become the
       admitted cases `pow_ok` (49) and `abs_ok` (7). The refusal rows
       `power` and `abs` go.
     - Eleven cases are added: `abs_ok`, `abs_values`, `abs_min`, `pow_ok`,
       `pow_values`, `pow_const`, `pow_const63`, `pow_overflow`,
       `pow_big_exp`, `pow_negative` and `pow_const_overflow`.
     - From 99 passed and 1 pending to 119 passed and 1 pending (eleven
       cases of two checks, two refusal rows fewer).
   - `tests/native-core/driver.sh`: "an ineligible source is refused" uses
     `reject_pow.rb`, which is admitted now. It takes `reject_array_shl.rb`,
     whose `heap-operation` no decision plans to lift. Still 44 checks.
     `tests/native-core/run.sh` has no `**` and no `abs` (checked in the
     inline sources too), and does not move.
   - `tests/core-boundary/fixtures/arithmetic/cases.tsv`:
     - `pow-refused` becomes five rows: `pow-ok` (`2 ** 3`, 8), `pow-min`
       (`(-2) ** 63`, `MIN`), `pow-overflow` (`2 ** 63`, `overflow`),
       `pow-negative` (`2 ** -1`, the new reason `negative-exponent`) and
       `pow-big-one` (`(-1) ** 64`, 1).
     - `oracle.rb` gains `**` and the reason. It is edited, not run.
     - `arithmetic.sh`'s unchecked-slice pair for `power.rb` becomes
       `type-evidence` with the poly-parameter words, as `shl.rb` did in
       stage 2.
   - `tests/core-bitwise`: from 22 to 34 checks:
     - freestanding: the table's `trap` and `wrap` runs at both widths (4);
     - the status lane: build and table at both widths (4);
     - refusals: `buf_pow` (freestanding) and `reopen_pow` (status) (2);
     - the report (1);
     - a control planting a wrong `powers.tsv` row (1).

     `fs/k.rb` and `fs32/k.rb` gain an `op=` function (`x **= 3`). Its line
     goes into both `expect.txt` files, which are already one check each.
   - `tests/freestanding/e040/run_reject.sh`: `a09_pow` (`n ** 2` on an
     `i32` parameter) is admitted now. It becomes `1.5 ** n`, which still
     tests a refused power. The lane's counts do not change.
   - `tests/subset/fixtures/call-pow.rb` puts its `**` on a buffer
     parameter. `tests/subset-tables/pin.tsv` takes the new reasons digest.
   - `README.md`, `docs/native-core/supported-envelope.md`,
     `docs/roadmap.md`, `docs/core/buffer-boundary.md`,
     `tests/native-core/arith.md` and `Eligibility.h`'s comment.
8. **Nothing else moves.** The suites `affected.rb --base origin/main`
   selects pass with stage 2's counts, apart from the ones in 7. In
   particular, no DOOM kernel's status-lane result changes, because the
   status lane's `abs` emits what it emits today and no DOOM kernel uses
   `**`. The board suites and `doom-loop-reports` wait for the end of the
   plan.

### Results (2026-11-14)

The implementation is `60b3e89a` (code, with the subset pin and the subset
fixture) and `930f3749` (tests and documents). Every prediction held, and
nothing was rerun.

1. **Where the change lands:** as predicted, and nowhere else. The status
   lane's `abs` keeps its operations and their order.
2. **The lowering of `**`:** as predicted. In the 64-bit status kernel's MLIR,
   `a ** 2` has one `llvm.intr.smul.with.overflow`, `a ** 63` has 10 and
   `a ** n` has 10.
3. **Values:** as predicted. All 78 rows per width of
   `tests/core-bitwise/powers.tsv` are given on the six table runs:
   freestanding `trap` and `wrap` at 64 and 32 bits, and the status lane at
   64 and 32 bits.
4. **`--core`'s messages:** as predicted: `integer overflow in abs`,
   `integer overflow in **` and `negative exponent`, each a `RangeError`
   with exit status 1.
5. **No loop in the report:** as predicted. `loop_bound` is `pass` with no
   loop and a work bound of `0`.
6. **Refusals:** as predicted. The e040 lane's `a09_pow` (`1.5 ** n`) is
   refused with the `**` row's new words.
7. **Fixtures and documents that move:** as predicted. `core-bitwise` has 34
   checks, `native-core/arith.sh` 119 passed and 1 pending, `driver.sh` 44,
   and core-boundary's arithmetic lane executes 70 of 70 cases.
   `native-core/run.sh` did not move.
8. **Nothing else moves:** as predicted. Every other selected suite passed
   with stage 2's counts.

### Suites (2026-11-14)

The suites `ruby tools/test/affected.rb --base origin/main` selected at
`930f3749`, 28 of them (the same list as stage 2), were run once on Debian
x86_64 with LLVM 23.1.1. All 28 passed, in 452 s in all.

| suite | result | wall |
|---|---|---|
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 skipped | 14 s |
| `tests/core-bitwise/run.sh` | 34 passed, 0 failed, 0 skipped | 3 s |
| `tests/core-blocks/run.sh` | 47 passed, 0 failed, 0 skipped | 1 s |
| `tests/core-boundary/run.sh` | 12 lanes, 12 passed | 38 s |
| `tests/core-eligibility/run.rb` | 52 passed, 0 failed | 2 s |
| `tests/core-boundary/intrinsics.sh` | 50 checked, 50 pass | 2 s |
| `tests/core-report/run.sh` | 785 passed, 0 failed, 1 skipped | 80 s |
| `tests/core/run.sh` | 33 passed, 0 failed | 1 s |
| `tests/core-stack/run.sh` | 31 checked, 31 pass, 1 skipped | 2 s |
| `git diff --check origin/main -- docs` | clean | 0 s |
| `tests/doom-core/borrowed-calls.sh` | 51 checked, 51 pass | 0 s |
| `tests/doom-core/control-flow.sh` | 55 checked, 55 pass | 2 s |
| `tests/fiber/core.sh` | 43 passed, 0 failed, 0 skipped | 81 s |
| `tests/freestanding/run.sh` | every lane passed; the two board lanes NOT RUN (no `FRDM_HOST`) | 175 s |
| `tests/imports/run.sh` | 10 checked, 10 pass | 2 s |
| `tests/lowering/duplicate.sh` | 3 checked, 3 pass | 0 s |
| `tests/lowering/locations.sh` | 9 checked, 9 pass | 0 s |
| `tests/lowering/reopened.sh` | 11 checked, 11 pass | 0 s |
| `tests/lowering/split.sh` | 6 checked, 6 pass | 1 s |
| `tests/native-core/arith.sh` | 119 passed, 0 failed, 1 pending | 32 s |
| `tests/native-core/driver.sh` | 44 passed, 0 failed | 5 s |
| `tests/native-core/ledger.sh` | 23 passed, 0 failed | 0 s |
| `tests/native-core/run.sh` | 8 passed, 0 failed | 4 s |
| `tests/oracle/check.sh` | 0 failures | 4 s |
| `tests/source-stamp/run.sh` | 12 checked, 12 pass | 1 s |
| `tests/subset/map.sh` | 13 checked, 13 pass | 0 s |
| `tests/subset/reasons.sh` | 42 checked, 42 pass | 2 s |
| `tests/subset-tables/run.sh` | 12 checked, 12 pass | 0 s |

- The skips and the pending case are each suite's own named ones, as in
  stages 1 and 2.
- No oracle section ran. `oracle.rb` in core-boundary gained `**` and is not
  run here. The long `doom-loop-reports` lane and the board suites
  (`intrinsics-board`, `rt1186`) wait for the end of the plan.

## Stage 4: the wrapping and unsigned forms (W1 and U1)

### Observed before the predictions (2026-11-14)

Probes against the native build, the contract reader and the pinned compiler
(`baddd25a9`) of main `c2e4eac8`, built in this worktree.

- **0022's names on the routes they are not admitted on yet:**
  - The pinned Spinel, given a call to an undefined `core_w64_add`, refuses it
    as `unsupported call` and writes nothing.
  - Freestanding (`spinel-fs-emit`) refuses `core_w32_add`, `core_w64_add`
    and `core_u32` at stage C: "call to 'X', which is not a top-level method
    in this file and is not declared by the profile".
  - `--core` refuses `core_w32_add` as `type-evidence`: the method's result is
    unknown.
  - The status lane builds `core_w32_add`. It refuses `core_w64_add` and
    `core_u32(0xdeadbeef)` as `type-evidence`: the entry's result is unknown.
- **The contract reader** (`spinel-typedump`) is Spinel's own inference, and
  `--core` and freestanding take their types from it. A call to an
  intrinsic's name has no definition there:
  - its node is `unknown`, and a local assigned from it and an operation on
    that local are `poly`;
  - with a definition of the name appended to the source, all three are
    `int`, and the source's own node ids and lines do not change (ids are
    given in source order, so the appended nodes come after);
  - at `--int-width=32`, a definition whose literals are beyond the i32 range
    types its result `bigint`, and the caller's values become `bigint` too.
    Written with i32-range literals only, they stay `int`;
  - `core_u32(0xdeadbeef)`'s literal is itself `bigint` at 32 bits. A
    `core_u32` that builds its result from the literal's bits answers `int`
    all the same;
  - the reader analysing every name's definition takes about 0.4 s for the
    four faces, against 33 ms for a small source alone.
- **Where a copy of the source can be read from:** the pinned parser resolves
  a `require_relative` from the directory of the path it was given. The
  freestanding route already analyses a synthetic copy in a temporary
  directory (stage 2) and maps its identity back to the source afterwards.
- **A prelude of Ruby definitions,** written so that no operation overflows
  64 bits, compiles with the pinned Spinel in 0.37 s. Run, it gives
  `core_w64_add(MAX, 1) = MIN`, `core_w64_mul(-1, -1) = 1`,
  `core_w64_shl(1, 63) = MIN`, `core_u64_lt(-1, 1) = false`,
  `core_u64_shr(-1, 60) = 15`, `core_w32_shl(-2**31, 1) = 0`,
  `core_u32(0xdeadbeef) = -559038737` and `core_fixed_div(1, 0) = 2**31 - 1`,
  each what the rules below give.
- **Codes in use:** `CoreFailKind` 1 to 3, freestanding trap codes 1 to 7.

### The owner's answers (2026-11-14)

Asked before the predictions and answered by the owner on 2026-11-14,
relayed by the lead. Each is the recommendation that was put to the owner.

1. **The hosted half (A).** `tools/core/spinel-core-build` appends an
   Extended prelude to the copy of the source that the pinned Spinel
   compiles, and never to the core source. The prelude is Spinel-compilable
   and written without an overflowing operation. No vendor change.
2. **Failure delivery.** `--core` gets a new `CoreFailKind` 4, which prints
   `RangeError` with the same text the hosted prelude raises. Freestanding
   gets trap code 8.
3. **Scope.** The whole intrinsic table on `--core` and freestanding:
   0022's `core_w32_add` / `sub` / `mul` / `neg`, `core_u32_lt` / `le` / `gt`
   / `ge` / `shr`, `core_fixed_mul` and `core_fixed_div`, and the new W1 and
   U1 names.
4. **Shifts.** `core_w64_shl` and `core_w32_shl` are the low 64 or 32 bits
   of Ruby's `a << n` for every `n`: a negative `n` shifts right, and
   `n >= width` gives 0. `core_w32_shl` fails only on the w32 operand range.
   `core_u64_shr` takes a count of 0..63 and fails otherwise, as
   `core_u32_shr` takes 0..31.
5. **The reader's types (T1).** On `--core` and freestanding, the reader's
   input is the source with the Extended prelude appended. The prelude's
   definitions only give intrinsic calls a type:
   - they are not the user's definitions, so a user definition of an
     intrinsic's name is still the conflict refusal;
   - they are never in the closure or the object;
   - the core artifact and its digests stay the user's source;
   - the status lane is unchanged.

### Predictions (2026-11-14, before any implementation)

1. **The prelude,** `tools/core/hosted-prelude.rb`:
   - It defines the table's names and nothing else, each definition
     standing alone (no helper, and no definition calling another).
   - No operation in it overflows 64 bits.
   - Every name a 32-bit body admits uses only i32-range literals, and
     `core_u32`'s result is built from bits, so the reader types each call
     `int` (or `bool`) at both widths.
   - Each failure raises `RangeError` with the text the failure hook prints
     (4 below).
   - A copy gets the definitions of the table names the source spells, as
     whole words, in the prelude's order, and nothing when it spells none.
     So a source that names no intrinsic is read and compiled exactly as
     today, and the reader's added cost falls only on sources that use the
     forms.
   - It is embedded in the native build by CMake, as
     `tools/realtime/alloc_vocabulary.tsv` is, and the kernel's source stamp
     (`tools/test/source-stamp.rb`) lists it, so a build made from another
     prelude is refused as stale.
   - `spinel-core-emit --print-prelude [--for SOURCE]` prints the embedded
     prelude, or the definitions a copy of SOURCE gets.
2. **Where the rest of the change lands,** and nowhere else (nothing in
   `vendor/` or in the contract reader's C):
   - **The reader library** (`Contract/Reader.h`, `lib/Contract`):
     `ContractInputs` gains the first line of the appended prelude. Before
     its cross-face checks, `readContract` drops every node of the entry
     file from that line on, the methods and locals of their scopes, and
     their ids from every array. With no prelude line, nothing changes.
   - **`Core/Input.cpp`** (`loadContract`, used by `spinel-core-check` and
     `spinel-core-emit`, never by the status lane's `Boundary.cpp`):
     - The reader reads a copy: the source and the prelude, written beside
       the source under a unique dot-file name and removed on every exit.
       Beside it, so that a `require_relative` resolves as before.
     - Each face's ledger must name the copy and nothing else. The ledger
       handed to the caller names the source.
     - The module's file names are mapped back to the source, and the
       snapshot check still compares the source with itself.
   - **`Freestanding/Emit.cpp`:** stage 2's synthetic source gains the
     prelude after its driver, in the same temporary directory. Its identity
     is already mapped back to the source. Stage 1 and `spinel-fs-check`
     read the source as today.
   - **`Core/Intrinsics.h`:**
     - the ten new names, with the operations below;
     - `core_u32` marked as a compile-time form;
     - each 64-bit form marked as such;
     - each row's failure codes (4 below).
   - **`Core/Eligibility.cpp`:**
     - The recognition serves both modes: the status lane as today, and the
       unchecked mode (`--core`), whose operand types are the reader's.
     - `derive` types the new names.
     - `core_u32` takes an Integer literal in `0..4294967295`, and nothing
       else.
     - A 64-bit form is refused at once on a 32-bit body.
     - On `--core`, a top-level definition of a table name is refused
       wherever it is, called or not. (The prelude would replace it in the
       hosted copy and in the reader's analysis.) The status lane keeps its
       refusal where the closure calls one.
   - **`Frontend/Scalar/Importer.cpp`:** an intrinsic call is left out of
     the closure on `--core` (abort mode) and freestanding as well as the
     status lane.
   - **`Frontend/Scalar/MlirGen.cpp`:** `intrinsicCall` serves every mode,
     with the new operations, and delivers its failures each mode's own way
     (4).
   - **`Freestanding/Declaration.cpp`:** stage C admits a table name, under
     the same rules as `--core`: no receiver, the arity, `core_u32`'s
     literal, a 64-bit form refused on a 32-bit body, and a top-level
     definition of a table name refused. Two categories are added with the
     checkers' spellings: `conflicting-intrinsic` and
     `unsupported-intrinsic-call`.
   - **`Scalar/Importer.h` and `Core/Emit.cpp`:** `CoreFailKind::Intrinsic =
     4`. The header gains `SPC_CORE_FAIL_INTRINSIC`, and the shim prints
     each of its texts.
   - **`tools/core/spinel-core-build`:**
     - stage 0 snapshots the prelude with the rest, and its digest enters the
       manifest;
     - the driver refuses a core emitter whose embedded prelude is not the
       snapshot's;
     - stage 2 hands the pinned Spinel `hosted.rb`, the source and the
       definitions `--print-prelude --for` names. Its ledger must name
       `hosted.rb`;
     - stages 1 and 3 read `input.rb`, as today.
   - **`tools/core/intrinsics.rb`** (the CRuby prelude) gains the new names:
     - a `w64` or `u64` operand must be an Integer in the i64 range;
     - `core_u32`'s argument must be in `0..4294967295`;
     - anything else raises `CoreIntrinsics::Arithmetic`, as today.
3. **What each form computes** (MIN and MAX are the body width's):
   - `core_w64_add` / `sub` / `mul` / `neg`: the low 64 bits of the exact
     result, read as signed. `core_w64_shl(a, n)`: the low 64 bits of
     `a << n` for `n` in 0..63, 0 for `n >= 64`, and `a >> min(-n, 63)` for
     `n < 0`. None of them fails.
   - `core_w32_shl(a, n)`: the same at 32 bits, with `a >> min(-n, 31)` for
     `n < 0`. On a 64-bit body both operands must be in the i32 range, as
     every 0022 operand is.
   - `core_u64_lt` / `le` / `gt` / `ge`: the unsigned order of the 64-bit
     patterns. `core_u64_shr(a, n)`: the logical right shift for `n` in
     0..63, else a failure.
   - `core_u32(LIT)`: a constant, the literal's 32-bit pattern read as
     signed. No code runs for it.
   - 0022's names are unchanged. On the status lane they emit the same
     operations in the same order as today, so no DOOM status kernel
     changes.
4. **Failures,** each the mode's own way. The texts are the prelude's:
   - `<name>: an operand is outside the i32 range`, for an operand of a
     0022 name or `core_w32_shl` outside the i32 range on a 64-bit body;
   - `core_u32_shr: the count is outside 0..31` and
     `core_u64_shr: the count is outside 0..63`.

   Delivery:
   - the status lane: `ARITHMETIC`, with the result word untouched (as
     today);
   - `--core`: `spc_core_fail(4, op)`, where `op` names the text. The shim
     prints `<text> (RangeError)` on stderr and exits with status 1, the
     same as an uncaught raise of the prelude's error in the hosted half;
   - freestanding: the trap hook with code 8, under every overflow policy
     (an operand out of range has no wrapped meaning). With no hook, it is
     the RangeError raise the other freestanding failures use.

   A 64-bit body's `core_w64_*` and `core_u64_lt` .. `ge` have no failure,
   so a core object using only them references no hook.
5. **Values.** One hand-generated table, `tests/core-bitwise/words.tsv`. Each
   row is `width op a b answer`, where the answer is a value (1 or 0 for a
   comparison) or `fail`. It has 110 rows at 64 bits (15 of them `fail`)
   and 57 at 32 (2 `fail`). A scratch script generated it from the rules in
   3 and 4; no compiler and no prelude ran to make it. Its rows:
   - every name of the table, with its edges: MIN and MAX of both widths,
     -1, 0, the counts 0, `w - 1`, `w`, `-1`, `-w`, beyond `±w`, and
     `±2**31` (`MIN` of the other operand);
   - an operand outside the i32 range, at 64 bits only;
   - the u32 literal, `core_u32(0xdeadbeef)` = `-559038737`, at both widths;
   - `w32_add` in a freestanding function declared `overflow: :wrap`, at 64
     bits only: `MAX + 1` gives `MIN`, and an operand of `2**31` is still
     code 8.

   Each route gives the table's answers at the widths it has:
   - freestanding `trap` at 64 bits (x86_64 host) and 32 bits (wasm32 under
     node), where `fail` is the hook with code 8;
   - the status lane at 64 bits natively and 32 bits on wasm32 under node,
     where `fail` is `ARITHMETIC` with the result word untouched;
   - `--core` at 64 bits, for the cases in 7.
6. **Checksums against published check values.** The step of each, written
   with the forms, is iterated over the bytes by the driver:
   - FNV-1a 32: `core_w32_mul(h ^ b, 16777619)` from `0x811c9dc5`.
     `"a"` gives `0xe40c292c` (-468965076) and `"foobar"` `0xbf9cf968`
     (-1080231576);
   - FNV-1a 64: `core_w64_mul(h ^ b, 1099511628211)` from
     `0xcbf29ce484222325` (-3750763034362895579). `"a"` gives
     `0xaf63dc4c8601ec8c` (-5808556873153909620) and `"foobar"`
     `0x85944171f73967e8` (-8821353812377114648);
   - a CRC-32 byte step (reflected, `core_u32(0xedb88320)`, eight
     `core_u32_shr(c, 1) ^ (core_w32_neg(c & 1) & POLY)` steps). From -1,
     over `"123456789"` and complemented, it gives `0xcbf43926`
     (-873187034).

   They run on freestanding and the status lane at both widths (FNV-1a 64
   at 64 bits only), and on `--core`.
7. **`--core`**, `tests/native-core/arith.sh`:
   - **14 new cases**, with the hosted half calling the prelude where a
     case starts a checksum (`h = core_u32(0x811c9dc5)` in the program, not
     in the root):
     - `fnv32`, `fnv64`, `crc32` (the values in 6);
     - `u32_lit` (-559038737);
     - `w64_add_values`, `w64_mul_values`, `w64_shl_values`,
       `u64_shr_values`, `u64_ge_values` and `w32_shl_values`, rows of 5;
     - four failures, each on stderr with exit status 1:
       - `intrinsic_operand`: `core_w32_add: an operand is outside the i32
         range (RangeError)`;
       - `u32_shr_count`: `core_u32_shr: the count is outside 0..31
         (RangeError)`;
       - `u64_shr_count`: `core_u64_shr: the count is outside 0..63
         (RangeError)`;
       - `hosted_intrinsic_fail`: the hosted half's own call, with the same
         text as `intrinsic_operand`.
   - **Undefined symbols:** the cases whose root has no failure path (`fnv64`,
     `u32_lit`, `w64_*_values`, `u64_ge_values` and `hosted_intrinsic_fail`)
     have none; the others have `spc_core_fail`.
   - **5 new refusal rows:**
     - an unused top-level `def core_w64_add` (`conflicting-intrinsic`);
     - `core_u32(a)` (`unsupported-intrinsic-call`);
     - `core_u32(4294967296)` (`unsupported-intrinsic-call`);
     - `self.core_w64_add` (`unsupported-intrinsic-call`);
     - a wrong arity (`arity-mismatch`).
   - **Count:** from 119 passed and 1 pending to 152 passed and 1 pending
     (14 cases of two checks, five refusal rows of one).
8. **Refusals elsewhere,** each with its own words:
   - **Freestanding:**
     - a `w64` form on the wasm32 profile's 32-bit body;
     - `core_u32` of a parameter, and of `4294967296`;
     - `self.core_w64_add`;
     - a wrong arity;
     - a block;
     - an unused top-level `def core_w64_add`.
   - **The status lane:** a `w64` form at `--int-width=32`, and `core_u32` of
     a parameter and of `4294967296`. Its existing refusals in
     `tests/core-boundary/intrinsics.sh` keep their categories.
9. **Fixtures and documents that move,** and no others:
   - **`tests/core-bitwise`:** from 34 to 55 checks:
     - the words table and the checksums, on freestanding at both widths
       (4);
     - the status lane's build, words table and checksums at both widths
       (6);
     - the refusals in 8 (10);
     - a control planting a wrong `words.tsv` row (1).

     New files:
     - `words.tsv`;
     - `fs/words.c`, `fs32/words.mjs`, `status/words.c`,
       `status/words.mjs`;
     - `status/src/words.rb`;
     - the refusal sources.

     `fs/k.rb` and `fs32/k.rb` gain the word and checksum functions. Their
     `expect.txt` lines do not change.
   - **`tests/core-boundary/intrinsics.sh`:** from 50 to 55 checks:
     - the CRuby prelude gives every row of `words.tsv`;
     - the hosted prelude, compiled by the pinned Spinel, gives every
       64-bit row, with `fail` as its RangeError;
     - each failure text of the generated shim is one the hosted prelude
       raises, and the reverse;
     - both preludes define exactly the table's names;
     - `spinel-core-emit --print-prelude` is `tools/core/hosted-prelude.rb`.

     Its cases and refusals do not change.
   - **`tests/native-core/arith.sh`** as in 7, and `arith.md` lists the new
     cases. `driver.sh`, `run.sh` and `ledger.sh` have no intrinsic name
     (checked in their inline sources too), and do not move.
   - **Documents:** `README.md`, `docs/native-core/supported-envelope.md`,
     `docs/roadmap.md`, `docs/core/applications.md`,
     `docs/core/lowering-inputs.md` (the two categories),
     `Intrinsics.h`'s header comment and `tools/test/source-stamp.rb`'s
     list.
10. **Nothing else moves.** The suites `affected.rb --base origin/main`
    selects pass with stage 3's counts, apart from the ones in 9:
    - A source that spells no intrinsic name gets no prelude, so its
      analysis, its hosted C and its objects are made from the same inputs
      as before.
    - No DOOM status kernel changes (3).
    - The board suites and `doom-loop-reports` wait for the end of the plan.

### Addendum to the predictions (2026-11-14, before any implementation)

After the lead's review of the choices above. Where this addendum and the
predictions differ, the addendum holds, and the results are read against it.

- **A change to 0022's rule.** 0022 refuses a user definition of an
  intrinsic's name (`conflicting-intrinsic`) only where the closure calls
  one. On `--core` and freestanding, prediction 2 widens that to any
  top-level definition of a table name, called or not, because the appended
  prelude would replace it in the hosted copy and in the reader's analysis.
  The status lane keeps 0022's rule. So:
  - `tests/core-boundary/intrinsics.sh` part 5 (the CRuby prelude packed with
    a caller) builds through the status lane's contract route and is not
    affected;
  - `fixtures/intrinsics/refuse/conflict.rb` is a status-lane fixture and
    keeps its refusal;
  - the checks that move are the new unused-definition refusals in 7 and 8.
- **Picking definitions (prediction 1).**
  - A picked definition brings every other table name it spells, to the
    closure. Today's prelude has no shared helper and no definition calling
    another, so for it this picks nothing more; the rule is there for an
    edit that adds one.
  - A source that spells no table name gets no copy at all: the reader is
    handed the source's own path, and its input is the source's bytes, as
    today. Checked in the build: `--print-prelude --for` prints nothing for
    such a source, and the checker's ledger then names the source itself
    (`tests/core-boundary/intrinsics.sh`, one more check: 56).
- **Where the reader's copy is written (prediction 2, `Core/Input.cpp`).**
  - In the loader's own temporary directory, unless the source spells
    `require_relative`, the one load the parser resolves from the source's
    own directory. Only then is the copy written beside the source.
  - Beside the source:
    - it has a unique name starting `.spinel-prelude.`;
    - it is removed on every exit, and on SIGINT and SIGTERM through LLVM's
      remove-on-signal list;
    - a directory that cannot be written is refused with a message that names
      it;
    - the driver's snapshot globs do not pick up a dot name (checked when the
      driver is changed).
  - `tests/native-core/ledger.sh` gains three checks, from 23 to 26:
    - a source with `require_relative "empty"` that calls `core_w32_add` is
      refused for the ledger, as `r_empty` is;
    - after that refusal, no `.spinel-prelude.*` file is left beside it;
    - in a directory without write permission, the same source is refused
      with the words `not writable`.

### Results (2026-11-14)

The implementation is `e8569eb4` (code), `bbd5dc09` (tests and documents)
and `59622f56` (the import record), on `2bf05f53`. Three predictions missed:
5 (a count), 7 and 9. The misses of 7 and 9 were found while writing the
tests and the import record's in the first final run; each was taken to the
lead, who decided how to go on, and the selected suites were then run once
more on the rebased branch.

1. **The prelude:** as predicted. `tools/core/hosted-prelude.rb` defines the
   23 names of the table, each standing alone; the 32-bit-capable names use
   only i32-range literals, and `core_u32` builds its result from bits.
   `spinel-core-emit --print-prelude` prints it, and the kernel's source
   stamp lists it.
2. **Where the rest of the change lands:** as predicted, with the addendum.
   One detail of the reader library was found while writing the
   freestanding fixtures: the entry file whose nodes the prelude line cuts
   is the `FILE` row that `SOURCE_FILE` names. The root node does not say:
   with a `require_relative`, the program node carries the required file's
   id. (`docs/core/lowering-inputs.md` section 7 records it.)
3. **What each form computes:** as predicted, on every route that ran it.
4. **Failures:** as predicted: the status lane's ARITHMETIC with the result
   word untouched, `--core`'s RangeError with the prelude's text and exit
   status 1, and freestanding's trap code 8, also under `overflow: :wrap`.
5. **Values: a miss in the table's count.** `tests/core-bitwise/words.tsv`
   has 112 rows at 64 bits (16 `fail`) and 57 at 32 (2 `fail`), against the
   predicted 110 (15) and 57 (2). The predicted count left out the two
   `w32_add_w` rows (`MAX + 1`, and an operand of `2**31`) that the same
   prediction lists. Every row is given on freestanding at both widths, on
   the status lane at both widths (but `w32_add_w`, which only a
   freestanding declaration has), by the CRuby prelude, and by the hosted
   prelude at 64 bits.
6. **Checksums:** as predicted. FNV-1a 32 of `"a"` and `"foobar"`
   (-468965076, -1080231576), FNV-1a 64 of both (-5808556873153909620,
   -8821353812377114648) and CRC-32 of `"123456789"` (-873187034) on
   freestanding and the status lane (FNV-1a 64 at 64 bits only) and on
   `--core`.
7. **`--core`: a miss.** The `--core` top level admits only definitions and
   calls into the selected closure whose arguments are integer literals
   (`Eligibility.cpp`, `isInferenceCall` and `admittedOutputCall`). So the
   predicted fixture shapes that called a form from the program
   (`h = core_u32(0x811c9dc5)`) or nested the root's calls cannot be
   built, and `hosted_intrinsic_fail` (the hosted half's own call) cannot
   exist. The lead kept that rule, which 0042 does not change: each
   checksum's starting value is in the root and its bytes are literal
   arguments, one call per vector, and `hosted_intrinsic_fail` is dropped.
   `arith.sh` has 13 new cases and 5 refusal rows: 150 passed and 1 pending,
   against the predicted 152 and 1. The undefined symbols are as predicted
   for the 13. Two fixture shapes were also rewritten for the envelope: a
   modifier `if` on an assignment is a ternary (`implicit-nil` otherwise),
   and the CRC byte step is unrolled (`--core` has no `while`).

   The hosted half of a `--core` build never runs a prelude body: its top
   level may only call the selected closure, and those calls go to the core
   object. So the claim of answer 2, that kind 4 prints the text the hosted
   prelude raises, is checked twice against the same hand-written strings:
   `arith.sh` reads the `--core` failures' stderr, and `intrinsics.sh`
   part 7 compiles the hosted prelude with a caller as a plain hosted
   program (no `--core`) with the pinned Spinel and reads each failure's
   text.
8. **Refusals elsewhere:** as predicted, each with its own words: seven on
   freestanding (one on the wasm32 profile) and three on the status lane.
   The existing refusals of `intrinsics.sh` keep their categories.
9. **Fixtures and documents that move: a miss in `intrinsics.sh`, and one in
   the import record.**
   - `core-bitwise` has 55 checks and `ledger.sh` 26, as predicted.
   - `intrinsics.sh` has 56, as predicted, but one check reads differently:
     the shim's failure texts are the hosted prelude's raise texts **but
     one**, `core_u32: the value is outside 0..4294967295`. The prediction
     said "and the reverse". CORE refuses a `core_u32` argument that is not
     a literal in 0..4294967295 at compile time
     (`unsupported-intrinsic-call`), so no core object fails there and the
     shim has no case for it; the prelude keeps the raise for a plain hosted
     program. The check names the excluded text, and the compile-time
     refusal is checked in `core-bitwise` (freestanding and status) and in
     `arith.sh` (`--core`).
   - `docs/imports.tsv`: the new `lib/Core/Prelude.cpp` was not registered,
     and `tests/imports/run.sh` failed in the first final run (9 of 10). Its
     `lib/Core` row lists files by name; `59622f56` adds it, and the rewrite
     pin follows. `tools/test/affected.tsv` maps
     `tools/core/hosted-prelude.rb` to what the kernel reaches and the
     driver's suites.
   - The documents named in 9 moved, and `docs/core/lowering-inputs.md`
     gained section 7.
10. **Nothing else moves:** as predicted in the run at `59622f56` below. The
    first final run, at the old base `c2e4eac8`, also failed four checks of
    `tests/doom-core/source-pack.sh`; they were stages 2 and 3's, fixed on
    main by `2bf05f53` after this branch's point, and not a stage 4 miss.

### Suites (2026-11-14)

The suites `ruby tools/test/affected.rb --base 2bf05f53` selected at
`59622f56`, 31 commands with the board and long lanes left out, were run
once on Debian x86_64 with LLVM 23.1.1. All 31 passed, in 585 s in all.

| suite | result | wall |
|---|---|---|
| `git diff --check 2bf05f53 -- docs` | clean | 0 s |
| `tests/core-eligibility/run.rb` | 52 passed, 0 failed | 2 s |
| `tests/affected/run.sh` | 67 checked, 67 pass, 0 fail | 3 s |
| `tests/app/cross.sh` | 48 checked, 48 pass, 0 fail, 0 skipped | 14 s |
| `tests/core-bitwise/run.sh` | 55 passed, 0 failed, 0 skipped | 5 s |
| `tests/core-blocks/run.sh` | 47 passed, 0 failed, 0 skipped | 1 s |
| `tests/core-boundary/intrinsics.sh` | 56 checked, 56 pass, 0 fail | 6 s |
| `tests/core-boundary/run.sh` | 12 lanes, 12 passed, 0 failed, 0 could not run | 38 s |
| `tests/core-report/run.sh` | 785 passed, 0 failed, 1 skipped | 82 s |
| `tests/core-stack/run.sh` | 31 checked, 31 pass, 0 fail, 1 skipped, 0 not applicable | 2 s |
| `tests/dist/export.sh` | 1 checked, 1 pass, 0 fail | 33 s |
| `tests/dist/run.sh` | 104 checked, 104 pass, 0 fail | 10 s |
| `tests/doom-core/borrowed-calls.sh` | 51 checked, 51 pass, 0 fail | 1 s |
| `tests/doom-core/control-flow.sh` | 55 checked, 55 pass, 0 fail | 1 s |
| `tests/doom-core/source-pack.sh` | 104 checked, 104 pass, 0 fail | 72 s |
| `tests/fiber/core.sh` | 43 passed, 0 failed, 0 skipped | 81 s |
| `tests/freestanding/run.sh` | every lane passed; the two board lanes NOT RUN (no `FRDM_HOST`) | 171 s |
| `tests/freestanding/stamp-controls.sh` | 7 checked, 7 pass, 0 fail | 1 s |
| `tests/imports/run.sh` | 10 checked, 10 pass, 0 fail | 2 s |
| `tests/lowering/duplicate.sh` | 3 checked, 3 pass, 0 fail | 0 s |
| `tests/lowering/locations.sh` | 9 checked, 9 pass, 0 fail | 0 s |
| `tests/lowering/reopened.sh` | 11 checked, 11 pass, 0 fail | 1 s |
| `tests/lowering/split.sh` | 6 checked, 6 pass, 0 fail | 0 s |
| `tests/native-core/arith.sh` | 150 passed, 0 failed, 1 pending | 42 s |
| `tests/native-core/driver.sh` | 44 passed, 0 failed | 5 s |
| `tests/native-core/ledger.sh` | 26 passed, 0 failed | 0 s |
| `tests/native-core/run.sh` | 8 passed, 0 failed; its CRuby section NOT RUN (oracle) | 4 s |
| `tests/oracle/check.sh` | 222 rows, 90 gated sections, 90 gate calls, 202 files found by the patterns, 0 failure(s) | 4 s |
| `tests/source-stamp/run.sh` | 12 checked, 12 pass, 0 fail | 1 s |
| `tests/subset/reasons.sh` | 42 checked, 42 pass, 0 fail | 3 s |
| `tests/core/run.sh` | 33 passed, 0 failed | 0 s |

- The skips and the pending case are each suite's own named ones, as in
  stages 1 to 3. No oracle section ran.
- The long `doom-loop-reports` lane and the board suites
  (`intrinsics-board`, `rt1186`) wait for the end of the plan.

### Review findings (2026-11-14)

The independent review at `829a013e` found two defects, both fixed before
the merge check, each with a check that fails without its fix:

- **Medium, the prelude picked from the root alone.** Freestanding stage 2
  reads the files the root requires, but `preludeFor` read the root's bytes
  only, so a required helper that called an intrinsic was refused (`'f'
  returns unknown`) unless the root happened to spell the name. The names
  are now picked from the root and every other file stage 1 lists
  (`Freestanding/Emit.cpp`). `tests/core-bitwise` part 8 compiles a root
  whose required helper alone calls `core_w32_add`: 56 checks. On `--core`
  a source with a required file is refused for the input ledger before any
  analysis (`tests/native-core/ledger.sh`), so no picking arises there.
- **High, the reader's copy not held still.** `loadContract` compared the
  source with its snapshot after each face, but with the prelude the reader
  is handed a copy, and a reader that edited that copy produced a core
  object from the edited text (an executable printing 9 for a source that
  says 8). The copy is now compared with the text written to it after each
  face and at the end, beside the source check (`Core/Input.cpp`).
  `tests/native-core/ledger.sh` plants a reader that edits its input: with
  an intrinsic the input is the copy, refused by the new check; without
  one it is the source, refused by the existing check: 28 checks.

After the fixes, the same 31 commands `ruby tools/test/affected.rb --base
2bf05f53` selected at `af9cf3de` were run once more. All 31 passed, in 578 s
in all: `tests/core-bitwise/run.sh` 56 passed and
`tests/native-core/ledger.sh` 28 passed, and every other suite with the
count in the table above.

## Stage 4 follow-up: the prelude before the program

### Observed before the predictions (2026-11-14)

Upstream `1782a9e13` ("A call that runs before a method's first def raises
NoMethodError") gives each method called at the top level before its
definition runs a version entry: a global `$__spinel_ver_N`, a synthesized
scope-0 `DefNode` row and an `if` chain with a `NoMethodError` arm. The nodes
face carries those rows; the ast face has no such ids. Stage 4 appends the
prelude after the program, so every intrinsic is defined after the top-level
calls that reach it, and on a vendor with that commit the reader refuses the
analysis (`nodes:137: dangling-reference: node id 290 is not in the ast` for
`tests/native-core/fixtures/arith/fnv32.rb`); `tests/native-core/arith.sh`
and `tests/core-bitwise/run.sh` fail on the sync branch's vendor. The same
definitions placed before the program give no version entry. The pinned
vendor here predates the commit, so main passes. The lead chose option A:
the prelude goes before the program.

### Predictions (2026-11-14, before any implementation)

1. **Where the prelude goes.** Every copy that gets the prelude (the
   `--core` reader's copy in `Core/Input.cpp`, freestanding's stage 2 file,
   and `spinel-core-build`'s `hosted.rb`) is the source's leading lines that
   are blank or comments, kept first (a `# spinel: int64` line among them),
   then the picked definitions, then the rest of the source. A source that
   names no intrinsic is read as it is. T1 is unchanged: the prelude types
   intrinsic calls and is never in a user definition, the closure, the core
   object or a digest; only its position moves.
2. **What the reader drops.** `ContractInputs` carries the prelude's first
   line and its line count. `dropPrelude` drops the entry file's nodes in
   that range, but the program node and its statements node, whose position
   is the first statement's and so falls inside it; those two take the
   position of the first statement left. Every entry-file node after the
   range has the count subtracted from its line in both faces (`node_line`
   and the nodes face's line); a nodes row that the ast lacks (an anonymous
   module's added rows) moves when an entry-file node has its position. No
   column moves.
3. **Diagnostics keep the user's lines.** The reader's own failure text
   (`Parse errors in ...`, as `spinel-core-check` prints it, and
   freestanding's `typedump-failed` note) names the copy, and every
   `copy:LINE` in it after the prelude gets the count subtracted. The
   checkers' locations come from the module, so they move with item 2. The
   hosted compiler's stderr is not rewritten: a parse error is refused by
   the reader first, and the pinned Spinel printed no line for any of five
   constructs probed in a hosted-only method (`eval`, an unavailable
   `require`, an undefined call, `Foo::Bar.new`, `instance_variable_get`).
4. **Checks.** `tests/native-core/ledger.sh` gains 2 (30): with comment
   lines and an intrinsic call, a parse error keeps its line and column
   (`8:5`), and a refusal keeps its location (`4:2`), each hand-written.
   `tests/core-bitwise/run.sh` gains 1 (57): a freestanding refusal in a
   source with comment lines and an intrinsic call names the source line
   it names without the intrinsic. Every other count stays: `arith.sh` 150
   passed and 1 pending, `intrinsics.sh` 56.
5. **Against the sync vendor.** With the new native tools and the sync
   branch's built reader (vendor `4e0a59bd9`, read only),
   `spinel-core-check tests/native-core/fixtures/arith/fnv32.rb --method
   fnv32_step` accepts with no dangling reference, and its typedump of the
   copy has no `$__spinel_ver` row. Whole suites against that vendor are run
   only if the suites take another reader and compiler without edits.
6. **Nothing else moves.** `ruby tools/test/affected.rb --base 289163f7`
   selects the suites; every one passes with the counts it had at
   `289163f7`, but for item 4's.

### Results (2026-11-14)

The implementation is `236569b7`, on the predictions at `e95732ac`. One
prediction missed in its wording (5).

1. **Where the prelude goes:** as predicted, in the three copies
   (`Core/Prelude.cpp` `insertPrelude`, which `Core/Input.cpp` and
   `Freestanding/Emit.cpp` call, and an `awk` step in `spinel-core-build`
   with the same rule).
2. **What the reader drops:** as predicted (`Contract/Reader.cpp`
   `dropPrelude`).
3. **Diagnostics keep the user's lines:** as predicted. The reader's failure
   text goes through `sourceLines`; the hosted compiler's stderr is left as
   it is.
4. **Checks:** as predicted: `tests/native-core/ledger.sh` 30 and
   `tests/core-bitwise/run.sh` 57, with `arith.sh` 150 passed and 1 pending
   and `intrinsics.sh` 56. The freestanding check reads the module's
   locations through `--emit-mlir`, because a freestanding refusal prints no
   location and a parse error stops at stage 1, which reads the source
   without the prelude. A build that kept the shift and the text mapping off
   failed all three new checks, each naming the copy's line (`20:5` for
   `8:5`, `10:2` for `4:2`, `13:0` to `15:6` for `7:0` to `9:6`); the
   committed code passes them.
5. **Against the sync vendor: a miss in the wording.** With the sync
   branch's reader (vendor `4e0a59bd9`), `spinel-core-check
   tests/native-core/fixtures/arith/fnv32.rb --method fnv32_step` reports no
   dangling reference, and the typedump of the new copy has no
   `$__spinel_ver` row (the appended copy has 6). But it does not accept:
   main's checker does not know two fields that vendor adds, and reports
   `unsupported-field` for `DefNode.locals` and `CallNode.ignore_visibility`.
   A source with no intrinsic gets the same diagnostics from that reader,
   so they are not this change's; the sync branch carries that field work.
   For the same reason the whole suites were not run against that vendor
   from here: they belong on the sync branch once this change reaches main.
6. **Nothing else moves:** as predicted in the run below.

### Suites (2026-11-14)

The 27 commands `ruby tools/test/affected.rb --base 289163f7` selected at
`236569b7`, with the board and long lanes left out, were run once on Debian
x86_64 with LLVM 23.1.1. 26 passed at once. `tests/freestanding/run.sh`
failed only in e084's host leg, for a missing runtime bitcode in the new
worktree (`no runtime bitcode at .../tools/llvm/build/libspinel_rt_lto.a`);
after `tools/llvm/build_rt_bc.sh` and the pass plugin were built, it passed
every lane (the two FRDM lanes not run without `FRDM_HOST`). The final
clean pass took 583 s in all. Every count is the one the same suite gave in
a full run at `289163f7`, but `tests/core-bitwise/run.sh` (57 passed, from
56) and `tests/native-core/ledger.sh` (30 passed, from 28). No oracle
section ran; the long `doom-loop-reports` lane and the board suites
(`intrinsics-board`, `rt1186`) were not run.

### Review findings (2026-11-14)

The independent review at `015dfff4` found one defect, fixed before the
merge check, with checks that fail without the fix:

- **Medium, a byte order mark moved into the program.** Both inserters
  (`Core/Prelude.cpp` and `spinel-core-build`'s `awk` step) put the prelude
  before a leading UTF-8 byte order mark, so the mark landed inside the
  program and a valid source was refused (the mark followed by `def
  calc(a)`, a `core_w32_add` call, `end` and `puts calc(7)`: `unexpected
  'end'` at its line 3). The mark now stays the copy's first three bytes,
  in both. The parser counts the mark in line 1's columns, so when the
  program itself starts on line 1, which then follows the prelude in the
  copy, the reader adds the 3 columns back on that line, in both faces
  (`ContractInputs::preludeColumns`) and in the reader's failure text.
  `tests/native-core/ledger.sh` checks that such a source is checked, and
  that a refusal and a parse error on line 1 keep their columns (`1:16`,
  `1:38`, by hand): 33 checks. `tests/native-core/arith.sh` builds
  `fixtures/arith/bom.rb`, whose first line of code follows a mark, and it
  prints 8: 152 passed and 1 pending. Controls, each built and run once: an
  `awk` step without the mark line fails `bom`; a reader that keeps the mark
  but adds no columns fails the two column checks (`1:13`, `1:35`); a
  reader that ignores the mark fails `l_bom` (`unexpected 'end'`) and the
  refusal check.

The review also found nothing else in the line, drop and drift cases it
probed; a CRLF source's freestanding location one line off predates this
change (the reader gives the same line for the source itself).

After the fix, the same 27 commands `ruby tools/test/affected.rb --base
289163f7` selected at `5f9b1efb` were run once more. All 27 passed, in 583 s
in all: `tests/native-core/ledger.sh` 33 passed and
`tests/native-core/arith.sh` 152 passed and 1 pending, and every other
suite with the count of the run above (`tests/freestanding/run.sh` every
lane, the two FRDM lanes not run).
