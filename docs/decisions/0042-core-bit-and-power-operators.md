# 0042: Bitwise, shift, `abs` and `**` operators in every CORE route, with explicit wrapping and unsigned forms

- Date: 2026-11-14
- Status: Accepted by the owner on 2026-11-14 (relayed by the bpf-mlir coordinator), with the
  recommended choices: S1 (Ruby's shift rule), W1 (named wrapping operations)
  and U1 (named unsigned operations and the `core_u32` literal), and the
  order as proposed. Stage 1 starts after 0041 stage 1 is merged, and each
  stage commits its predictions before its implementation. The pin's
  `a >> -n` defect stays recorded only. The direction was decided by the
  owner earlier the same day: "embedded code uses these operations a lot, so
  I want the constraint that refuses them removed."
- Scope:
  - the operators `&`, `|`, `^`, `~`, `<<`, `>>`, `abs` and `**` on Integer,
    on the three routes that compile CORE:
    - the status lane ([decision 0007](0007-doom-core-preparation.md),
      [0014](0014-core-applications-on-zephyr.md));
    - the native `--core` slice ([decision 0015](0015-core-scalar-arithmetic.md));
    - the freestanding route (`freestanding_def`);
  - what each operator does at the body width
    ([0019](0019-target-integer-width.md), [0022](0022-core-word-arithmetic.md))
    when Ruby's answer does not fit in it;
  - how embedded code asks for wrapping arithmetic, and how it writes and
    reads an unsigned value at the target width.

  Rational and imaginary literals are out of scope. So are Float operators.

## Context

### What each route admits today

Measured on 2026-11-14 with the native build of `0bec85e4` plus the
uncommitted 0041 stage 1 work (which changes none of these paths). Each line
is one probe method whose body is the expression with Integer operands `a`
and `b`.

| operator | status lane (0007, 0014) | native `--core` (0015) | freestanding |
|---|---|---|---|
| `&`, `\|`, `^` | admitted by 0007 task 2 | refused, `unresolved-call` | refused, `unsupported: CallNode` |
| `~` | admitted by 0007 task 2 | refused, `unresolved-call` | refused, `unsupported: CallNode` |
| `<<` | admitted by 0007 task 2 | refused, `unproved-arithmetic` | refused by the subset table: "`<<` on an Array or String appends to a heap object. (Integer#<< is a shift and would be fine, but the freestanding subset has no shift yet, so the two cannot be told apart here.)" |
| `>>` | admitted by 0007 task 2 | refused, `unproved-arithmetic` | refused, `unsupported: CallNode` |
| `abs` | admitted by 0007 task 2 | refused, `unresolved-call` | refused, `unsupported: CallNode` |
| `**` | refused, `unsupported-operator` | refused, `unproved-arithmetic` | refused by the subset table: "`**` can produce a Bignum" |

The status-lane column comes from the checker
(`tools/mlir/native/lib/Core/Eligibility.cpp`, the arithmetic branch of the
call rule) and its lowering (`MlirGen.cpp`, `shiftOp`, `absOp` and the
status-mode arm of `binop`). The other two columns are the tools' own
messages.

So most of this is not new semantics. The status lane already has rules for
every operator but `**`. What is missing is those rules on the other two
routes, `**` everywhere, and a decision on the shift counts where the status
lane's rule and Ruby's differ.

### The status lane's rules today (0007 task 2)

- `&`, `|`, `^` and `~` are exact: two's complement at any width agrees with
  Ruby's infinite-precision two's complement in the low bits, and the result
  of these four fits whenever the operands do.
- `<<` and `>>` take a count in `0..w-1`, where `w` is the body width.
  Any other count is `ARITHMETIC`. A left shift whose result does not shift
  back to the operand is `ARITHMETIC`. `>>` is arithmetic (it copies the sign
  bit), which is Ruby's `>>`: floor division by `2**n`.
- `abs(MIN)` is `ARITHMETIC`; every other value has an `abs`.

### What the pinned Spinel does under `--int-overflow=raise`

From the pinned runtime (`vendor/spinel/lib/spinel_rt.h`, `sp_int_shl`,
`sp_int_shr`, `sp_int_abs`; `lib/sp_cold.c`, `sp_int_pow`), read for this
record, not run:

| case | CRuby | pinned Spinel, raise mode |
|---|---|---|
| `a << n`, result past the width | a Bignum | `RangeError`, `integer overflow in <<` |
| `a << n`, `n >= w` | a Bignum (0 when `a` is 0) | `RangeError` when `a != 0`, else 0 |
| `a << -n` | `a >> n` | `a >> n` |
| `a >> n`, `n >= w` | 0, or -1 when `a < 0` | 0, or -1 when `a < 0` |
| `a >> -n` | `a << n`, a Bignum past the width | a C left shift with no check: it wraps, or is undefined behaviour when it shifts into the sign bit. A defect of the pin, recorded here and not fixed by this record |
| `MIN.abs` | `2**63` (a Bignum) | `RangeError`, `integer overflow in abs` |
| `a ** b`, result past the width | a Bignum | `RangeError`, `integer overflow in **`, by exact square-and-multiply |
| `a ** -b` | a Rational (`ZeroDivisionError` for `0 ** -1`) | `RangeError`, `negative exponent` |
| `&`, `\|`, `^`, `~` | exact | exact |

So the status lane already refuses less than Spinel answers in two places: a
negative shift count, and `>>` by `w` or more. Both have a value in Ruby and
in Spinel, and both are `ARITHMETIC` in the status lane.

### How an Integer operator is told apart from a heap method

`<<` is the case that matters: `Integer#<<` shifts, `Array#<<` and
`String#<<` append. The status lane and the `--core` checker already decide
by the analysis's type of the receiver: an operator is admitted only when
the receiver, the argument and the result are typed `int`. This is the
decision the hosted build makes too. Spinel compiles `a << n` to
`sp_int_shl` exactly when its whole-program analysis types `a` as an Integer,
so CORE reading the same type cannot disagree with the hosted program about
which method runs. A receiver typed as a union (`int` or an array) is not
`int` and is refused.

Two things can still make the type's answer wrong, and both are refused
today on the status lane and in the `--core` checker
(`binding-environment`): a reopened `Integer` that redefines an operator, and
`Integer.prepend`. The freestanding route does not consult the type at all:
its subset table refuses `<<` by name, before types are read.

[Decision 0041](0041-goose-ideas-for-core.md) stage 2 adds Integer arrays
made by `Array.new` with a declared bound. Their type is an array, never
`int`, so `<<` on one stays a refused `Array#<<` with no ambiguity. Stage 2
does not admit `push` or `<<` on them.

### Wrapping arithmetic in embedded code

CRCs, hashes and counters mean arithmetic modulo `2**w`. Under 0015's raise
contract, `h * FNV_PRIME` overflows and fails. Today's forms:

- **The status lane at 32 bits.** 0022's word intrinsics: `core_w32_add`,
  `core_w32_sub`, `core_w32_mul`, `core_w32_neg`, `core_u32_lt` / `le` / `gt`
  / `ge` and `core_u32_shr`. A Ruby prelude gives the CRuby route the same
  answers. There is no 64-bit counterpart and no wrapping shift.
- **The freestanding route.** `freestanding_def ..., overflow: :wrap`
  makes every operation in that function wrap.
- **Masking.** `(a * b) & 0xffff_ffff` is what CRuby computes exactly, but in
  CORE the product is checked first, so the mask comes too late.

DOOM's frame digests (FNV-1a) are computed in Full, not in CORE, so no
admitted CORE program needs 64-bit wrapping yet.

### Unsigned values at the target width

Ruby has one signed Integer. At a 32-bit body width, `0xdeadbeef` is past
`INT32_MAX`: Spinel makes it a Bignum there, and CORE has no form for it.
0022 wrote such a value as its signed pattern (`ANG180` is `-2147483648`) and
compared and shifted angles with `core_u32_*`. Buffer elements declared
`u8`, `u16` and `u32` ([decision 0018](0018-narrow-buffer-elements.md))
load as non-negative Integers, and a `u32` element at a 32-bit width has no
Integer for its top half.

### Goose

Goose ([reference](https://aardappel.github.io/goose/docs/reference.html),
section 3, read for this record) has:

- signed and unsigned integer types, `i8` to `i64` and `u8` to `u64`, with
  arithmetic at the operands' own width;
- unsigned arithmetic that wraps modulo `2**width` by definition;
- signed overflow that aborts in a debug build and wraps in a release build;
- `>>` that shifts in zeroes on an unsigned type and copies the sign on a
  signed one;
- a shift count masked to the width;
- no operator overloading, so the static type decides every operator;
- a literal above `i64.max` as a `u64` constant;
- no `abs` and no power operator.

What applies to CORE is two ideas:

1. **Wrapping is part of what the program says, not a build mode.** In Goose,
   a type says it; in CORE, an operation's name can say it, as 0022's
   `core_w32_*` already does. Goose's release-mode wrap of signed overflow
   is the opposite: a build flag that changes meaning. CORE does not take it.
2. **Unsigned is a view with its own `>>` and comparisons.** Goose attaches
   it to a type. Ruby has no unsigned type, so CORE attaches it to named
   operations (`core_u32_shr`, `core_u32_lt`).

Goose's masked shift count is not taken: `1 << 64` is a Bignum in Ruby and
`RangeError` in Spinel, and masking would make it 1. The static-type rule
for operators is already CORE's.

Goose adds little beyond 0015's contract and 0022's names. This record would
look the same without it, except for the framing of wrapping and unsigned as
named, explicit forms.

## Options

### Shift counts

- **S1. Ruby's rule wherever the value fits** (recommended).
  - A negative count shifts the other way.
  - `>>` by `w` or more is 0, or -1 for a negative operand.
  - `<<` that loses bits, including any `<<` by `w` or more of a non-zero
    operand, fails.
  - `a >> -n` is checked as `a << n`, where the pinned Spinel does not check
    it.
  - This is the pinned Spinel's rule, so `--core` keeps 0015's promise that
    the program means what it means without `--core`.
- **S2. Today's status-lane rule everywhere.** A count outside `0..w-1` fails.
  This is simpler to state, but on `--core` it aborts where the hosted
  program has a value. That breaks 0015's rule, so `--core` would need S1
  anyway, and the routes would differ.
- **S3. Goose's masked count.** Not taken: it gives a value where Ruby and
  Spinel give a Bignum or a raise.

### Wrapping

- **W1. Named wrapping operations** (recommended). Extend 0022's family with
  the same recognition rules and a Ruby prelude for CRuby:
  - `core_w64_add`, `core_w64_sub`, `core_w64_mul`, `core_w64_neg` and
    `core_w64_shl`, and `core_w32_shl`;
  - each answers the low `N` bits of the exact result, read back as signed.
  - On a 32-bit body width, a `w64` intrinsic is refused at once, as `int64`
    is ([decision 0019](0019-target-integer-width.md)'s revision); its
    operands could not be written there.
  - The default meaning of `+ - * <<` does not change. A reader sees the
    wrap where it is meant.
- **W2. Masked expressions.** An expression of `+ - * << ~ & | ^` whose
  value is only used through `& M`, where `M` is a constant with
  `0 <= M < 2**(w-1)`, is computed modulo `2**w` and then masked.
  - This is exact with respect to CRuby: the low bits of a sum, difference,
    product or left shift depend only on the operands' low bits.
  - It needs no new names, and code written for CRuby already reads this way
    (`(h * P) & 0xffff_ffff`).
  - But it answers where the pinned Spinel raises, since Spinel checks the
    product first. So it is a deliberate divergence from the hosted build,
    which 0015 has so far not allowed. And whether an operation wraps depends
    on where its value goes, which a reader has to work out.
- **W3. A per-function `wrap` declaration on the status and `--core` routes**,
  like freestanding's `overflow: :wrap`.
  - This is 0022's option (d), narrowed to one function.
  - Index and count arithmetic in the same function would wrap too.
  - 0022 found that the emitter treats status and wrap as exclusive, so
    failure delivery and the overflow policy would have to be separated
    first.
- **W4. Unsigned types, as in Goose.** Not taken: Ruby has no place to
  declare a local's type, and adding one is a language change far beyond
  this record.

### Unsigned views

- **U1. Named unsigned operations and a literal form** (recommended).
  - Comparisons and the logical right shift: `core_u32_lt` / `le` / `gt` /
    `ge` and `core_u32_shr`, as 0022 has them. Add the `u64` set, with the
    same 32-bit refusal as W1.
  - `core_u32(LIT)`: a compile-time form whose argument is an Integer literal
    in `0..2**32-1`. It is the literal's 32-bit pattern read as signed:
    `core_u32(0xdeadbeef)` is `-559038737`.
    - Any other argument is refused at compile time.
    - At a 64-bit width it is the same signed i32 value, so one source means
      the same on both widths.
    - The prelude defines it for CRuby.
  - `>>` stays Ruby's arithmetic shift. A logical shift is always written by
    name.
- **U2. Signed patterns only.** No literal form: write `-559038737` or
  `~0x2152_4110`, as 0022 wrote `ANG180`. This needs nothing new, but a
  register constant then reads as a negative number.

### `**`

`**` has one rule on every route: the exact result, or a failure where it is
past the width. A negative exponent is a failure: CRuby's answer is a
Rational, the pinned Spinel raises `RangeError` (`negative exponent`), and
neither fits. No option is offered, since every other rule would differ from
the pinned Spinel.

## Decision

### The operators, per route

All the rules below are at the body width `w` (64, or 32 for a body without
`# spinel: int64` on a 32-bit target, per 0019).

| operator | result | failure |
|---|---|---|
| `a & b`, `a \| b`, `a ^ b`, `~a` | exact | none |
| `a << n` | `a * 2**n` for `n >= 0`, `a >> -n` for `n < 0` | the result is past the width (S1) |
| `a >> n` | `floor(a / 2**n)` for `n >= 0` (0 or -1 for `n >= w`), `a << -n` for `n < 0` | only through `a << -n` (S1) |
| `a.abs` | `\|a\|` | `a` is `MIN` |
| `a ** n` | the exact power for `n >= 0`; `0 ** 0` is 1 | the result is past the width, or `n < 0` |

How a failure is delivered stays each route's own:

- **Status lane:** `ARITHMETIC`, as for `+ - *`.
- **Native `--core`:** 0015's `spc_core_fail(kind, op)`. The shim gains the
  operator codes for `<<`, `>>`, `abs` and `**`, and one kind for a negative
  exponent. The message is the pinned Spinel's text for the same case:
  - `RangeError`, `integer overflow in <<` (also for `a >> -n`);
  - `RangeError`, `integer overflow in abs`;
  - `RangeError`, `integer overflow in **`;
  - `RangeError`, `negative exponent`.

  The hook's prototype does not change. A code the shim was not generated
  for still traps, as 0015 records.
- **Freestanding:** under `overflow: :trap`, the platform's trap hook with
  the existing overflow code. A negative exponent gets a code of its own,
  added beside the others.

  Under `overflow: :wrap`, each operator does what the pinned Spinel's wrap
  mode does:
  - `<<` keeps the low bits, and `<<` by `w` or more is 0;
  - `MIN.abs` is `MIN`;
  - `**` wraps.

  A negative exponent still traps: it has no wrapped value.

### Telling `<<` apart

On every route an operator is admitted only on operands and a result the
analysis types `int`, and only when `binding-environment` holds: no reopened
or prepended `Integer`. The freestanding subset table's `<<` and `**` rows
become conditional:

- `<<` is refused on a receiver that is not typed `int`, with today's text;
- `**` is refused only when its operands are not typed `int`.

The walk reads the reader's node types for this, which the importer already
has.

### `**` and the loop bounds

`**` lowers without a loop, so [decision 0010](0010-core-resource-contract.md)'s
report gains nothing.

- **A constant exponent `e`.** An unrolled chain of checked multiplications:
  square-and-multiply, at most `2 * bit_length(e)` of them.
- **A variable exponent:**
  1. `n < 0` fails.
  2. When `n >= w`, the result is 1 for `a == 1`, 0 for `a == 0`, and 1 or
     -1 for `a == -1`, by `n`'s parity. Any other `a` fails.
  3. Otherwise `n` has at most `log2(w)` bits: 6 at 64, 5 at 32. A fixed
     straight-line square-and-multiply of that many steps computes the
     result, with each multiplication checked.

A step that overflows fails only when the true result is past the width.
Squaring a base past `sqrt(MAX)` and then multiplying it in leaves a result
at least as large. `(-2) ** 63` is `MIN` at 64 bits and does not fail. The
cost is a constant per operation. The report counts loop iterations, not
operations, so the cost is not in it.

### Wrapping and unsigned forms

The recommendation is W1 and U1. Both are new vocabulary in 0022's family,
under 0022's recognition rules: no receiver, exact arity, a refusal on a
conflicting top-level definition, and a Ruby prelude for the CRuby route that
is never handed to CORE.

They are admitted on the status lane and on `--core`. Freestanding already
has `overflow: :wrap`, and gets the same names for code shared with the
other routes.

## Stages

Each stage commits its predictions to `0042-results.md` before its
implementation. Each reports its results to the owner (via the bpf-mlir coordinator) before
the next one starts. No CRuby comparison runs unless the owner asks for one.

### Stage 1: `&`, `|`, `^` and `~` on `--core` and freestanding

- **Question.** Do the four exact operators admit and lower on the two routes
  that refuse them, with nothing else moving?
- **Change.**
  - The `--core` checker admits the four. Its lowering already has them for
    the status mode, and they need no failure path.
  - The freestanding walk and lowering admit them.
- **Checks:**
  - a fixture per operator per route, with hand-written expectations
    including negative operands and `MIN`;
  - masks and field extraction as an embedded register read writes them,
    such as `(r >> 4) & 0xf`;
  - the refusal of a non-`int` operand on each route.
- **Gating suites:** what `tools/test/affected.rb --base origin/main`
  selects.

### Stage 2: `<<` and `>>` on every route

- **Question.** Do the shifts follow S1 (or the owner's choice) on all three
  routes, and is `Integer#<<` told from `Array#<<` by type on freestanding?
- **Change:**
  - the `--core` checker and lowering admit them, with the operator codes in
    the shim;
  - the freestanding table's `<<` row becomes conditional, and `>>` is
    admitted;
  - the status lane's count rule follows the owner's choice of S1 or S2.
- **Checks:**
  - every row of the shift table at `w = 64`, and at `w = 32` on a 32-bit
    profile;
  - the counts -1, 0, `w - 1`, `w` and `w + 1`;
  - `-1 << (w - 1)` is `MIN`, and `1 << (w - 1)` fails;
  - `a >> -1` past the width fails;
  - `<<` on an Array local stays refused, on each route;
  - a reopened `Integer#<<` is refused.

### Stage 3: `abs` and `**` on every route

- **Question.** Do `abs` and `**` give exact results, and fail exactly past
  the width or on a negative exponent, with no loop in the report?
- **Checks:**
  - `MIN.abs`, `(MIN + 1).abs`;
  - `**` with a constant exponent (0, 1, 2, 63) and a variable one;
  - bases 0, 1, -1, 2, -2 and 3, and exponents -1, 0, `w - 2`, `w - 1`, `w`
    and `w + 1`;
  - `(-2) ** (w - 1)` is `MIN`;
  - the core report for a method using `**` has no loop for it;
  - `--core`'s four messages are the pinned Spinel's text.

### Stage 4: the wrapping and unsigned forms (the owner's W and U choices)

- **Question.** Do the chosen forms give the low bits of the exact result on
  both widths, and are they refused where 0022's names are?
- **Checks:**
  - FNV-1a 32 and 64 and a CRC-32 step written with the forms, against
    hand-computed vectors. The published FNV and CRC check values are
    constants, not another implementation's run;
  - each form's recognition refusals;
  - `core_u32(0xdeadbeef)` on both widths;
  - a `w64` form refused at once on a 32-bit body.

## Choices for the owner

Answered by the owner on 2026-11-14: S1, W1, U1, and the first order below.
The questions stay as they were asked.

1. **Shift counts:** S1 (recommended) or S2 for the status lane. On `--core`,
   S1 is needed to keep 0015's rule.
2. **Wrapping:** W1 (recommended), W2, W3, or W1 now and W2 later.
3. **Unsigned values:** U1 (recommended) or U2.
4. **Order:** this record's stages 1 to 3 after 0041 stage 1 is merged, and
   before 0041 stage 2. Or after all of 0041.

## Ordering against 0041

This plan goes after 0041 stage 1 is merged and beside 0041 stages 2 and 3.

- **Why after stage 1.** Both change the same files:
  - the checker's call rule and the lowering's call dispatch;
  - the freestanding walk;
  - the subset refusal table.

  0041 stage 1 is implemented, and its results are about to be reported.
  Starting this plan on top of it avoids a merge between two unreported
  changes.
- **Why beside stages 2 and 3.** They are independent. The only point of
  contact is `<<` on a stage 2 array, which stays refused under either order
  because the type tells the two apart.
- **Why stages 1 to 3 here may go before 0041 stage 2.** They lift
  refusals the owner wants lifted for embedded code, and they add no
  storage.

## Validation

As listed per stage. Each stage passes the suites `affected.rb` selects, with
the counts printed. A long suite runs once at the end of the whole plan. No
oracle runs unless the owner asks.

## Consequences

- Register and protocol code (masks, fields, flags, shifts) compiles on every
  CORE route without being rewritten as arithmetic.
- `--core` stays a check: a program means the same with and without it,
  including the four new failure messages, which are the pinned Spinel's.
- Wrapping and unsigned use are visible by name in the source, not set by a
  mode.
- The pinned Spinel's unchecked `a >> -n` is recorded as a defect of the pin.
  CORE checks that case; the hosted build does not. Fixing it upstream is a
  separate question.
