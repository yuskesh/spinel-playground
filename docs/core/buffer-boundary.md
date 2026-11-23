# The CORE buffer boundary: version-1 contract file

Decision [0007](../decisions/0007-doom-core-preparation.md). This page covers
what exists **now**: the contract file, its validation, the C header generated
from it, the checked scalar kernel, the borrowed-buffer boundary, and the
generated Full adapter a Ruby caller reaches them through. Tasks 1–4 of the
[plan](../decisions/0007-doom-core-preparation-plan.md) are implemented and
accepted. What that stage-1 slice is offered as — and, at the same length, what
it does not establish — is in [the stage-1 capability](stage1-capability.md).

## The file

```
core-contract 1
root fixtures/schema/src/buffer.rb
entry accumulate
result i64
param dst buffer i32 inout count n_dst
param n_dst scalar u64
param src buffer u8 in count n_src
param n_src scalar u64
```

| field | rule |
|---|---|
| `core-contract <version>` | first field, exactly once. Only `1` is accepted. |
| `root <path>` | exactly once; the source, resolved against `--root`. It is read once, copied into a private snapshot, and the SHA-256 recorded in the header is of that copy. |
| `entry <name>` | exactly once; a plain identifier. |
| `result <domain>` | exactly once; `i32`, `u32` or `i64`. **`u64` is refused** — it is a buffer count type. |
| `param <name> scalar <domain>` | `i32`, `u32`, `i64` or `u64`. |
| `param <name> buffer <element> <mode> count <name>` | element `u8`/`i8`/`u16`/`i16`/`i32`/`u32`/`i64` (the narrow three are [decision 0018](../decisions/0018-narrow-buffer-elements.md)'s); mode `in` or `inout`. |

Parameters appear in the order of the method's own parameters, which is also the
order of the generated C signature. **Counts bind by name, not by position.**

## What is refused, and why

Nothing defaults. An unrecognised key, a repeated key, a missing field, a
duplicate parameter name, an unknown type, an unresolved root or entry, and a
parameter list that disagrees with the source are each a diagnostic in the shape
`<file>:<line>: <category>: <detail>`. A contract that was partly understood is
never published.

Three rules are worth their own sentence:

- **`out` is not a mode in version 1.** A write-only promise is misleading when a
  failure can leave a partial prefix, so a buffer that gets written must also be
  initialised by the caller and declared `inout`.
- **Each buffer carries its own count, and the binding is checked from both
  ends.** The named count must exist, be a scalar, be `u64`, and belong to no
  other buffer. The predecessor's positional `:len` bound to whichever parameter
  preceded it, so two buffers could quietly share one length; naming it only
  helps if both directions are verified.
- **The entry must resolve in the snapshot, checked against the analysed AST.**
  The root must contain exactly one **unconditional top-level** definition of
  the entry, with plain required parameters whose names match the contract's in
  order. "Unconditional top-level" means the definition appears directly in the
  program's own statement list — so a `def` inside `if false` at column 0, a
  `def` inside a heredoc, and a `def` inside a `module` are all refused, and each
  has a fixture. No Ruby parser is added here: this walks the same
  `ContractModule` the eligibility checker walks. Whether the *body* is
  admissible is that checker's question, in Task 2.
- **`u64` must be some buffer's count.** It is an element count type at this
  boundary, not a general scalar domain, so a `u64` parameter no buffer claims is
  refused. The count binding is checked in both directions, and this is the
  second one.
- **Names must be spellable in C.** A parameter or entry that is a C or C++
  keyword is refused, as is one that collides with a name the generator itself
  produces — the result pointer is `result`, and `spinel_core_` is reserved.
  Refusing is deliberate where mangling would be possible: a mangled name makes
  the generated signature depend on a rule nobody reads.
- **No contract name reaches C as an identifier.** The entry does, prefixed; the
  parameters do not. A parameter name is a declaration in a C prototype, so a
  parameter called `uint8_t` shadows that typedef for the rest of the list and
  the next parameter declared `const uint8_t *` is a syntax error. This cannot
  be fixed by refusing names, because the names that break it are the
  *consumer's* typedefs and a generator cannot enumerate translation units that
  do not exist yet — so the prototype uses positional identifiers and carries
  the contract's names in comments. Parameter names have no ABI, so nothing a
  caller can observe changes.

## Using it

```sh
spinel-core-boundary <contract> --root <dir> --header out.h
spinel-core-boundary <contract> --root <dir> --identity
```

`--root` is the directory the contract's `root` path resolves against, so a
contract does not depend on the caller's working directory. `--identity` prints
the canonical identity line and nothing else; that is what a packaging step
compares before linking a header against an object.

The generated header carries the contract identity, the snapshot digest and the
target layout as macros, and declares the entry:

```c
int32_t spinel_core_accumulate(int32_t *sp_arg0,        /* dst (i32 inout, count n_dst) */
                               uint64_t sp_arg1,        /* n_dst (u64, element count of dst) */
                               const uint8_t *sp_arg2,  /* src (u8 in, count n_src) */
                               uint64_t sp_arg3,        /* n_src (u64, element count of src) */
                               int64_t *sp_result);     /* result (i64) */
```

`in` buffers are `const`. The result is a separate pointer and is written only on
`SPINEL_CORE_OK`. The status values are this ABI's own — `OK 0`, `ARGUMENT 1`,
`ARITHMETIC 2`, `BOUNDS 3`, `CAPACITY 4` — and are never a predecessor trap code
forwarded through.

## The snapshot

The tool reads the `root` file **once**, copies those bytes into a directory it
creates for the run, and from then on names only the copy: the SHA-256 in the
header, the four contract-reader faces, and the input ledger checked after each
face. The declared path is never read again.

Reading the path before and after and comparing the two would not be the same
thing. A file changed to `B` and back to `A` between the two reads agrees with
itself, and the bytes analysed in between were `B`; and the reader is a separate
process making its own reads, which can differ from both. Comparing a path to
itself authenticates the path, not the analysis.

One consequence is visible: the snapshot holds one file, so a root that
`require_relative`s a second one is refused (`unanalysable-root`) rather than
analysed as whatever the reader could find beside the original. That is the same
single-file rule the Extended driver applies, enforced the same way.

## Tests

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 tests/core-boundary/schema.sh
```

Every `bad-*` fixture must be refused **for its own declared reason** — a
refusal with the wrong diagnostic fails, because it would pass again the moment
the real defect was fixed. Every `bad-*` fixture is also checked to be **one edit**
from an accepted contract, since a fixture three edits away proves nothing about
which edit was caught. Then an independently written C consumer is compiled
against the generated header, a consumer built for a different contract identity
is required to fail at compile time, and **two entries' headers are included in
one translation unit** — they share the status enum, so it carries its own guard,
and a single-header test cannot see that.

Then three checks on the two rules above. The reader's own diagnostic must name
a path that is not the declared one, which is how the run shows it analysed the
copy; no snapshot directory may survive an accepted or a refused run. Each
header's digest is compared against an independently computed SHA-256 of its own
root, and the two fixtures' digests must differ, so a digest wired to a constant
fails rather than agreeing with itself. And a contract whose parameters are
named `uint8_t`, `src`, `n_src` and `int64_t` must generate a header that
compiles under `-Werror` — **with the mutation that restores those names into
the prototype, which must not compile**. Without the mutation the check would be
vacuous.

## The checked scalar kernel (task 2)

```sh
spinel-core-kernel <contract> --root <dir> -o kernel.o --header kernel.h \
                   --clang "$LLVM_PREFIX/bin/clang"
```

One run produces the object and the header, so the declaration a caller
compiles against and the definition it links cannot describe two contracts.

The exported symbol is a **wrapper** with the header's signature. The body the
importer lowers computes in i64 — that is the width the arithmetic is checked
in — and the contract declares the boundary's own widths, so the wrapper widens
each parameter in its declared signedness (`i32` sign-extends, `u32`
zero-extends: 4294967295 arrives as the same 32 bits either way and means
4294967295 in one domain and -1 in the other) and calls the body. Without it a
C caller would pass an `int32_t` where an `i64` was expected and nothing would
notice, because a symbol name carries no types.

Failure is a **return**, not a call that does not come back. There is no raise,
no trap hook and no nil sentinel:

- overflow of `+ - * -@`, of a left shift, of `abs(INT64_MIN)` and of a
  power past the width is `SPINEL_CORE_ARITHMETIC`, and so is `**` with a
  negative exponent ([decision 0042](../decisions/0042-core-bit-and-power-operators.md)
  stage 3; Ruby's answer there is a Rational);
- a zero divisor is `SPINEL_CORE_ARITHMETIC`, and so is `INT64_MIN / -1`, while
  `INT64_MIN % -1` succeeds with Ruby's zero — those are the same `idiv` on
  x86-64 and it faults for the pair whichever half of the result you wanted, so
  the remainder replaces the divisor with 1 rather than issuing it;
- a shift follows Ruby's count rule ([decision 0042](../decisions/0042-core-bit-and-power-operators.md),
  S1): a negative count shifts the other way, and `>>` by the width or more
  is 0 or -1. A left shift that loses bits, including `a >> -n` and any `<<`
  by the width or more of a non-zero value, is `SPINEL_CORE_ARITHMETIC`
  (decision 0007 refused every count outside 0..63);
- a result outside the contract's declared domain, checked at the return rather
  than at each operation, is `SPINEL_CORE_ARITHMETIC`;
- a NULL **or misaligned** result pointer is `SPINEL_CORE_ARGUMENT`, checked
  before anything is written. Those are what a scalar boundary can see of the
  caller's own defects; a parameter outside its declared `i32`/`u32` range
  cannot arrive at all, because the C type is the check. The alignment required
  is the one the store will use — 8 for an `i64` result, 4 for `i32`/`u32`;
- `core_fail(:capacity)` returns `SPINEL_CORE_CAPACITY`. It is the one
  application-requested failure: the other internal categories belong to
  failures the compiler establishes, and an application asking for one of them
  would be naming a failure it cannot have established. `:ok`, any other
  symbol, a computed argument, a second argument, and a conflicting
  `def core_fail` in the source are each refused by name. It is a return, so it
  is admitted where a `return` is and refused in expression position;
- a callee's status is propagated unchanged, so the category the failing
  operation chose is the one the caller sees.

**The result is written only on `SPINEL_CORE_OK`**, so a failing call leaves the
caller's variable exactly as the caller left it. Every failure case in the test
table checks that as well as the status.

These are this ABI's own numbers. The freestanding lane's trap codes share some
of them and mean different things; nothing here reads one and translates it.

Admission comes from the same eligibility checker, told which boundary is
asking (`EligibilityMode::CheckedScalar`). That mode admits `+ - * / % ** << >>
& | ^ ~ -@ +@ abs`, the matching `x op= e` forms, parentheses, `while`, **early
`return`** and literal scalar constants — both anonymous (`a * 2 + 3`) and **named** — on proven non-null
integer operands.

**The whole signed i64 domain.** Decision 0007 keeps the entire signed i64
range at this boundary and gives native entry values no nil sentinel, so
`-9223372036854775808` is an ordinary literal here — as a named constant, as a
literal in an expression, and as a result read back through the C harness. The
hosted route still reserves `INTPTR_MIN` for nil and still refuses the same
file; a lane holds it there.

What makes that safe is measured rather than assumed. For a literal outside
signed 64 bits the analysis emits a **saturated** `value` beside the exact
decimal text in `bigval`: `9223372036854775808` arrives as `value
9223372036854775807`, and `-9223372036854775809` as `value
-9223372036854775808`. Reading `value` alone would accept both, and the second
would land on INT64_MIN — a legal value on this route, and the wrong one. So
where `bigval` is present it is authoritative, and a node is a literal only if
the two agree exactly. `-9223372036854775808` itself is a single `IntegerNode`
with both fields saying so; the producer folds the unary minus.

A named constant is a single unconditional top-level `NAME = <integer
literal>`, resolved at compile time and read like any other integer. A second
assignment, an initialiser that is not a literal, a definition inside an `if`,
and a read of a name nothing assigns are each refused by their own name
(`constant-redefinition`, `dynamic-constant`, `binding-environment`,
`unresolved-constant`). A definition inside a method body does not arise: Ruby
itself calls that a dynamic constant assignment and will not parse it.
On the application lane, decision 0014 D5 adds one more form: a module of the
packed root may carry integer constants in its own body, read as `Mod::NAME`,
one level. A path of more than one level, a module this source does not
define, a name that module does not carry, and a value in a module body that
is not an integer literal are each refused as `unresolved-constant`, and a
name assigned twice in one module as `constant-redefinition`. A bare name
never resolves to a module's constant. A call cycle, direct or through two
methods, is refused: decision 0007 admits only a closed, statically resolved
call graph. (`**` was refused here too until decision 0042 stage 3.) Those
two fixtures also check that the derivation *terminates* on a
cycle, since a derivation that chased one would hang, and a hang is not a
refusal. The unchecked slice of decision 0005
is unchanged, down to the wording of its diagnostics: it lowers with no
overflow policy and no failure channel, so admitting any of this there would
define wrapping silently.

**A contract with no `result` is refused**: the ABI is a status plus a written
result and has no form without one.

## Buffers (task 3)

Each buffer is a pointer and its own `uint64_t` element count, with an explicit
`in` or `inout` mode. All descriptor validation happens **before any kernel
write**, so an entry failure leaves buffers and the result untouched:

- zero count permits a NULL pointer; a nonzero count requires a non-NULL
  pointer aligned for its element type;
- `count × element-size` and `base + size` are checked in **unsigned 64-bit**,
  which is the count's whole domain. The size check divides rather than
  multiplying and inspecting the result;
- a count with no i64 value is refused as an invalid **entry scalar**, and only
  for a count the closure actually reads. That is a different question from the
  descriptor's: a count nothing reads needs no Ruby value, and refusing it
  would narrow the contract's `uint64_t` for the body's convenience;
- the result pointer must be non-NULL, aligned, and **disjoint from every
  buffer range**;
- any overlap involving an `inout` buffer is refused, including two names for
  the same storage and two ranges that merely intersect — and between **two
  `inout` buffers**, not only between a written one and a read-only one. Two
  read-only buffers may overlap and are not compared.

Every one of those is `SPINEL_CORE_ARGUMENT`: they are all defects in what the
caller supplied, and splitting them across statuses would invent categories the
ABI does not have.

On a target with 32-bit pointers the rules and the accepted set are the same,
and the comparisons are narrower
([decision 0022](../decisions/0022-core-word-arithmetic.md) §3). The wrapper
first refuses a count whose upper word is not zero. It then checks
`count × element-size <= UINTPTR_MAX - base` in 64 bits, where the product
cannot overflow. Only after that does it compare addresses in 32 bits: a
buffer's base and exclusive end, and the result pointer. The result's end can
be 2^32, so the result overlap is tested against its last byte, which cannot
carry once the pointer is non-NULL and aligned. The pairs of buffers are
compared by a loop over a table in the wrapper's frame, rather than unrolled.
The table holds each range's begin and end, `inout` ranges first, and a
zero-length range as `[0, 0)`. Each `inout` range is compared with every range
after it, which is the same set of pairs with the same test. On the
FRDM-IMXRT1186, DOOM's step and render wrappers compare 18,639 and 15,714
pairs. Unrolled, that was about 1 MB of code each, run from the QSPI flash
every call. `tests/app/cross.sh` item 7 runs the positive and negative cases
on wasm32.

Inside the kernel, every load and store checks `0 <= index < count` as **two**
comparisons — a signed one for the lower end, an unsigned one against the count
— and an out-of-range index is `SPINEL_CORE_BOUNDS`. One unsigned test would be
equivalent only while every count fits i64, and above `INT64_MAX` a negative
index compares *below* the count and would pass. The bound comes from the
**parameter as it arrived**, captured before the body runs. Reading it out of
the environment let a kernel move its own bound: `n_dst = n_dst + 1;
dst[n_dst - 1] = 77` with a count of 1 returned success, wrote one element past
the count, and left the result alone — and `n_src = 1000; src[500]` on a
four-element buffer read 496 bytes past the end and reported success.

A count parameter is an **ordinary local** and may still be assigned; that is
the point of separating it from the descriptor rather than forbidding the
assignment. Three executed cases hold both directions: `n_dst = n_dst + 1` and
`n_dst += 1` compile and then fail with `BOUNDS`, leaving the guard element and
the result untouched; `n_dst = 0` followed by `dst[0]` **succeeds**, because the
descriptor still says one element. A bound taken from the local would have got
each of those the wrong way round.

Rebinding a *buffer* parameter is refused (`buffer-rebound`) as an
**implementation limit of version 1**, and is stated as one rather than dressed
up as an ownership rule. Nothing in this ABI makes reassigning a local name
drop a borrow, and saying it did would be deriving a fact the contract does not
contain. What is true is narrower and checkable: version 1 resolves an indexed
receiver only as a buffer **parameter by name**, so a rebound name has nothing
to resolve to. Refusing it at the assignment keeps that limit where it can be
read, instead of surfacing as a confusing failure at the index.

Which descriptor rule refuses a call first is an **implementation detail**:
they are all `ARGUMENT` and a caller cannot tell them apart. A test shape
therefore establishes what it exercises by violating **no other rule**, and
`buffers.sh` measures that rather than asserting it — the `addr-overflow` shape
was quietly being refused on the result overlap, because a range spanning half
the address space contains everything. Loads
zero-extend `u8`, `u16` and `u32` and sign-extend `i8`, `i16` and `i32` into
i64. Stores range-check
**before** writing: a value that does not fit the element type is
`SPINEL_CORE_ARITHMETIC` and **that store does not execute**. There is no
implicit truncation; a caller wanting a masked value computes the mask.

Once execution has begun there is no rollback. `partial_store` writes every
element and then makes one more store that may fail: the written prefix stays,
and only the failing store is skipped. `write_then_oob` is the same shape with
a *bounds* failure rather than a narrowing one — the prefix stays, the store
does not happen, and the result is not published.

The element types are exercised on both sides: an `i32` store of 2147483647
succeeds and 2147483648 is `ARITHMETIC`; a `u32` store of 4294967295 succeeds
and -1 is `ARITHMETIC`; `i8`, `u16` and `i16` stores succeed at both ends of
their ranges and are `ARITHMETIC` one past either end, leaving the buffer as it
was, and their loads sign- or zero-extend at the ends; a `u16` or `i16` pointer
one byte off is refused at entry; and an `i64` element takes `INT64_MIN` in, back out and
through the result pointer unchanged. A store's index comes from the caller in
`store_at`, so both ends of the range are checked on the writing side and not
only the reading one.

**The count is 64 bits and is not truncated.** `count_value` returns its count
and touches no storage, which is the only way to tell 2^32 from a value
truncated to its low 32 bits without owning four gibibytes: truncated it would
read as an empty buffer, and it returns 4294967296.

**Sanitisers.** `buffers.sh` rebuilds **both the kernel object and the driver**
under each available sanitiser and re-runs every case, requiring the same
statuses and no diagnostic. The driver allocates each buffer to exactly its
content, so a read one element past the count lands in a redzone rather than in
the middle of a large array where nothing would notice.

Availability is probed by building *and running*, because a toolchain can
accept the flag and fail to link or start the runtime. Anything unavailable is
reported on its own line with the reason — a missing sanitiser is a gap in the
evidence, not a check that passed.

"No diagnostic" is also what a sanitiser that is not watching reports, so each
one has to be shown catching something, and at two levels. The **runtime** must
report the defect that sanitiser exists to find — an out-of-bounds read for
`address`, a signed overflow for `undefined` — identified by its own diagnostic
text rather than by a non-zero exit, and with its own defect rather than one
control shared between them.

The **kernel** needs separate evidence, and getting it exposed something.
`-fsanitize=address` is a frontend flag: on C input clang gives each function
the `sanitize_address` attribute and the pass instruments it. The input here is
already IR, so the pass ran, the object gained ASan's module constructor, and
**it instrumented nothing** — measured, `__asan_init` present and not one
`__asan_report_load`. A sanitiser run over that object watched only the harness
around it. The emitter now marks the functions it translates, and the control
is functional rather than a symbol grep: a caller that **lies about the count**,
passing four over an allocation of three. Decision 0007 is explicit that a raw
foreign pointer's real capacity cannot be established by the compiler, so entry
validation accepts it and the kernel's own in-bounds load runs off the end —
and is reported, from inside `spinel_core_sum_u8`. That case exists only under
the sanitiser; outside one it is undefined behaviour and is not in the table.

`undefined` gets no such evidence and the suite says so rather than implying
otherwise: its checks are emitted by the frontend while compiling C, and no
function attribute adds them to pre-existing IR. Its runtime and the harness
are covered; the kernel itself is not.

On this Debian baseline both `address` and `undefined` run, over all 28 cases.

**The undefined set stays empty, and that needed doing.** Measured: `clear_u8`'s
`while` loop became an undefined `memset` at the shared emitter's `-O2`.
Neither `-fno-builtin` nor `-ffreestanding` stops it — those are frontend flags
and the input at that point is already IR — and a `no-builtins` passthrough
attribute did not survive the conversion to LLVM. The kernel tool passes
`-mllvm -disable-loop-idiom-all`, first, so a caller's own flags follow it; and
because an option alone is not proof, `buffers.sh` reads every object's symbol
table at that same optimisation level.

## The declaration supplies the entry facts

A CORE source has no caller, so the producer's type inference has nothing to go
on: every parameter comes back `poly` and every expression `unknown`. The
contract is what fills that in. Each declared scalar domain — `i32`, `u32`,
`i64` — is a Ruby Integer, so what reaches the checker is one fact per
parameter: **it is a non-null integer**. The width is the C boundary's business
and the generated wrapper's parameter types enforce it.

No caller is synthesised. From those facts the rest of the closure is
**derived**, one operation at a time: a literal is an integer, `a + b` is an
integer when both operands are, a comparison is a boolean, a call binds its
callee's parameters and takes that callee's derived result. A use whose
operands are not derivable simply stays untyped, and the per-node checks are
what refuse it — so the derivation only ever says what it can prove, and
validation stays where it already was.

Four states, and they are not interchangeable:

| | |
|---|---|
| `Unreached` | nothing has reached this yet — **not** an error, and not a conflict |
| `Int`, `Bool` | the two value types in this subset |
| `NoReturn` | a path that does not fall through at all: a `return`, a `core_fail`. It never reaches a join, so it says nothing there and takes the other arm's type rather than destroying it |
| `NilValue` | a path that **does** fall through and has no scalar value: a `while`, which is nil in Ruby. Nil is not in this subset, so meeting it with a type is a conflict |
| `Conflict` | two types met here. Absorbing, and never anything else again |

Those last two are not one state. `if c then (while ...) else 7 end` yields nil
on one path and 7 on the other; calling the `while` arm non-fallthrough made
the `if` an integer, and only the lowering caught it afterwards. Now the
checker does, and a fixture holds it there.

Everything ascends — `Unreached` → a type → `Conflict` — and nothing descends.
Separating "not yet" from "conflicting" is load bearing in both directions. An
operation whose operand is merely *not yet known* is itself not yet known, or a
callee not derived in the first round would make its caller conflict, and
`Conflict` is absorbing so the join across rounds could never recover. And an
operation whose operand is definitely the wrong type is a conflict that stays
one, or `int` joined with `bool` would collapse to "nothing" and the next `int`
would revive it.

**Termination is an argument, not a bound.** A round that does not settle has
moved at least one signature cell strictly up a four-element lattice, and cells
never move down; so at most three rounds per cell can fail to settle, and the
round limit is computed as `3 × cells + 1`. The same reasoning bounds a loop's
environment. A derivation that somehow exceeded its bound is **refused**
(`type-derivation-unsettled`) rather than published — that refusal is defence in
depth and is not reachable by construction, so it is declared here rather than
presented as a tested path. What is tested is the case that motivates the
computed bound: a seventy-deep helper chain, which needs one round per link,
converges and is accepted.

That is the difference between deriving and painting, and `arithmetic.sh` holds
it with seven refusals: a result that is a comparison; two `if` arms binding one
local to different types, and the same with the arms swapped; a helper reached
at two different types; three returns of `int`, `bool`, `int`, which an earlier
join revived; a type mismatch carried backwards one variable per loop iteration
with every local reassigned an integer afterwards, so the final environment
looks clean; and a five-deep helper chain ending in a comparison. A source that
*does* have a caller is still accepted, which is the eighth — though not
"through the producer's types": a contract always supplies facts here, so the
derivation is the authority for these checks whether an evidence call is
present or not. The producer's types stay authoritative on the ordinary route
and nowhere else.

That is also why `INT64_MIN` works on this route and not the other. The
producer types it `bigint`, because `INTPTR_MIN` is the hosted nil sentinel;
the derivation types it `int`, because at this boundary it is one. The two
disagree exactly where the decision says the domains differ.

Every fixture under `tests/core-boundary/fixtures/arithmetic/src/` is
caller-free, so the 64 executed cases are themselves the positive evidence.

## Arithmetic reference and acceptance (task 2)

```sh
tests/core-boundary/arithmetic.sh
```

`tests/core-boundary/fixtures/arithmetic/cases.tsv` fixes what the checked
scalar mode must answer: 64 cases over floor division, divisor-signed
remainder, `abs`, shifts, bitwise operators, explicit masking, overflow at the
operation, at an intermediate and at the result type, untaken failure branches,
parentheses, loops and literal constants. The table was written **before** the
mode existed, so the answers are not a transcript of what it produced.

The declared status, value and reason are a claim written from this decision.
`tests/core-boundary/oracle.rb` derives all three again, and a disagreement
fails rather than being copied over. It runs each definition twice: once plainly
— CRuby is the reference for every successful value — and once with operands
that check each operation as it happens, which is what derives the status. The
second run is Ruby's own dispatch over the same untouched method bodies, not a
second interpreter, and the two runs are required to agree wherever both
produce a value.

A domain check on the final value alone would not do: `(INT64_MAX + 1) - 1` is
INT64_MAX in Ruby, fits, and must still be refused. Six mutation controls check
that the derivation is not vacuous: C truncation for `/`, the C sign for `%`,
decision 0007's shift count rule (replaced by decision 0042), refusing `INT64_MIN % -1` instead
of special-casing it, a final-value-only domain check, and a case naming an
entry that is not in the fixture. Each rewrites cells of one line and the
changed-line count is checked.

A third lane generates a contract per case and requires the boundary tool to
accept it, which is what binds the table's entry names and arities to the Ruby
definitions; a contract naming a parameter the definition does not have is
required to be refused, so that lane is not vacuous either.

Every case is built into a kernel, run from C, and must land in exactly one
bucket: `ok` (status 0 and the declared value), `arithmetic` (status 2 and the
result word **untouched**, checked in the harness rather than in the shell),
or `refused` (the kernel does not build and the diagnostic names the declared
category). A case that reaches none of them fails, and the executed count is
printed either way so that "nothing ran" cannot read as "everything passed".

Two more lanes: every emitted object must have **no undefined symbols** and
exactly one exported symbol, inspected at the `-O2` the shared emitter uses
rather than in a debug build; and the unchecked slice must still refuse `+`,
`<<`, `&` and `**` with the diagnostics it used before, so that the checked
mode gaining four operators did not widen the mode that cannot report them.

## The Full adapter (task 4)

A CORE kernel takes pointers, and a Full Ruby program has none to give. The
adapter is what it lends instead: a registry of allocations named by integer
ids, one C operation per action on them, and a generated Ruby module that is
what a Full caller actually calls.

```sh
spinel-core-adapter <contract> --root <dir> --outdir <dir> \
                    [--core-header spinel_core_<entry>.h]
```

It prepares the contract exactly as the header and the kernel tools do — the
same snapshot, the same reader — so the adapter cannot be generated from a
different reading of the source than the object it calls. A contract with no
`result` is refused (`unsupported-boundary`): the adapter publishes one. One run
writes five files into `--outdir`:

| file | what it is |
|---|---|
| `spinel_adapter_registry.h`, `.c` | the storage, the ids and the lock. One per program: every contract's operations delegate to it |
| `spinel_adapter_<entry>.h`, `.c` | this contract's C entry points, thin over the registry, plus its own `invoke` |
| `core_<entry>.rb` | the Full-facing Ruby module |

### The module, and how a Full program reaches it

The module is `CoreBoundary` followed by the entry name in camel case, in a file
named after the entry: `entry sum_u8` generates `CoreBoundarySumU8` in
`core_sum_u8.rb`. It declares one `ffi_func` per C operation and wraps each in a
`def self.`, so a caller uses ordinary method calls and never the raw bindings.
Those wrappers call the bindings **through the module name** (`CoreBoundarySumU8.spinel_adapter_sum_u8_load(...)`);
a bare call to one inside `def self.` does not resolve on this pin.

A Full program `require_relative`s the generated file and is compiled by the
**pinned** compiler, with the generated directory on the include path and the
objects linked in:

```sh
spinel caller.rb -o caller -I <outdir> \
  --link spinel_adapter_<entry>.o \
  --link spinel_adapter_registry.o \
  --link <entry>.o \
  --link -lpthread
```

The first two are the generated C compiled for the host; the third is the kernel
tool's CORE object. `-lpthread` is the **adapter's** dependency, not the
kernel's: the lock and `malloc` are on the Full side, and the
zero-undefined-symbol gate applies to the CORE object alone. `spinel-core-package`
checks that the two are not confused — an adapter object in the CORE object's
place is refused with `digest-mismatch`.

### The operations

`ELEM_U8 = 1`, `ELEM_I32 = 2`, `ELEM_U32 = 3`, `ELEM_I64 = 4`, `ELEM_I8 = 5`,
`ELEM_U16 = 6`, `ELEM_I16 = 7` and
`OK = 0`, `ARGUMENT = 1`, `ARITHMETIC = 2`, `BOUNDS = 3`, `CAPACITY = 4` are
constants of the module.

| call | answer |
|---|---|
| `M.startup` | `0` if the registry's lock initialised, `1` if it did not |
| `M.allocate_storage(element, count)` | a positive **id**, or `0` on failure |
| `M.bind_storage(element, count, address)` | a positive **id** for read-only storage the caller placed, or `0` on failure: see [Bound storage](#bound-storage-decision-0021) |
| `M.store(id, index, value)` | a status |
| `M.load(id, index, element)` | **not** a status: see below |
| `M.store_i64_words(id, index, low, high)` | a status |
| `M.load_i64_words(id, index, out_id, low_index, high_index)` | a status |
| `M.invoke(arg0, …, result_id)` | a status |
| `M.release(id)` | a status |

There is no unlocked fallback: if `startup` answers `1`, every later operation
refuses. Allocated storage is zeroed. An allocation of **zero elements** is a
live positive id with no data — releasable, but every load and store on it is
`ARGUMENT`.

`store` and `load` accept every element but `i64`; `i64` storage
requires the words operations, and using the wrong one is `ARGUMENT` rather than
a reinterpretation. A stale, dead, double-released or poisoned id, an index
outside `0...count`, and **a value the element type cannot hold** are each
`ARGUMENT` with nothing written. That last one is the caller's value, which is
why it is not `ARITHMETIC`: `ARITHMETIC` is for a value the *kernel* computed
and could not store.

`load` answers in one call, and the encoding is what makes that possible: a
**negative** answer is the status, and anything else is the element's unsigned
32-bit pattern. A signed element — `i8`, `i16` or `i32` — is sign-extended to
32 bits before it is answered, so -128 in `i8` storage answers 4294967168. The
wrapper decodes it for the element type the caller names — only the signed
elements are decoded, by subtracting 4294967296 above 2147483647, because an
unsigned pattern already is the value. So neither a success nor a failure
can produce `INT64_MIN`, which this pin returns as nil, and validation and
access stay one operation rather than a check followed by an unchecked read.

`i64` storage travels as **two unsigned 32-bit words**, `low` and `high`. They
are numbers, so the transport does not depend on the native byte order and
`INT64_MIN` is never built by negating. A word outside `0..4294967295` is
`ARGUMENT`. `load_i64_words` validates the source, the destination and **both**
output indices before writing **either** word: the destination must be live
`u32` storage with a different id from the source, and the two indices must be
in range and different from each other. The transfer is under one lock, but a
*sequence* of calls is not a transaction — the caller owns the destination and
must not let another thread mutate or release it between the two reads that
follow.

`invoke` takes the contract's parameters **in their declared order, with the
count scalars removed**, and the result id last. The registry supplies each
buffer's count from the allocation itself, so a Full caller cannot pass a count
that disagrees with the storage. Buffers are passed as ids, ordinary scalars as
values. The result storage must be live, unpoisoned, of the contract's declared
result domain, at least one element long, and **not the id of any participant** —
all checked before the kernel runs, so a refusal leaves the previous result
exactly as it was. The scalar result is written to element zero only on `OK`. An
`i64` result is read back with `load_i64_words`. One lock is held across the
whole invocation and no callback into Full happens while it is held.

**A failed `invoke` poisons the mutable participants.** Every `inout` buffer of
a refused call is invalid for every operation but `release`: it must be released
and recreated. A failing kernel may have written a prefix and no rollback is
promised, so the poison is what keeps a half-written buffer from being read back
as data. The **result storage is not poisoned** — a failed invocation left its
previous value alone — and read-only `in` buffers stay usable. A contract whose
buffers are all `in` has nothing to poison. This is where the two paths
genuinely differ: a direct C caller reads whatever the kernel wrote before the
access that failed.

**IDs are not addresses, and are never reused.** They ascend from 1; `release`
frees the storage and marks the slot dead but does not return the id to the
pool, so a second release refuses rather than freeing whatever took its place.
Exhausting the space **fails the allocation** — `allocate_storage` answers `0` —
rather than wrapping onto an id its previous holder still believes in. The
budget is an `int32_t`'s worth and is a finite process budget: storage is meant
to be reused across ticks, not allocated per column or per job. The registry
keeps forged integers from becoming addresses, but it is **not a security
boundary**: a caller that passes another live id still reaches that storage, and
the generated wrapper checks the expected element type and nothing about intent.

### Bound storage (decision 0021)

[Decision 0021](../decisions/0021-doom-core-on-frdm-imxrt1186.md) lets a
`resource` buffer live at an address the boundary did not allocate.
`bind_storage(element, count, address)` registers `count` elements the caller
already placed at `address`. In C it is
`spinel_adapter_registry_bind(int32_t element, int64_t count, uint64_t address)`;
the Ruby module passes the address as `:int64`. Nothing is allocated, copied or
zeroed.

The descriptor is checked as the kernel's entry checks one (task 3):

- the element must be known and the count must not be negative;
- a count of zero is a live id with no data, whatever the address;
- a nonzero count needs a non-NULL address aligned for the element;
- `count × width` and `address + size` must not overflow unsigned 64 bits or
  the address space.

A refusal answers `0`, as `allocate_storage`'s does. Whether the caller's memory
really holds `count` elements cannot be checked, just as a raw pointer's
capacity cannot be at the kernel's own boundary (decision 0007).

**Bound storage is read-only, and the registry enforces it:**

- `store`, `store_i64_words`, and a `load_i64_words` whose destination is bound
  each answer `ARGUMENT` and write nothing;
- `invoke` refuses a bound id as an `inout` participant, and as the result
  storage, before the kernel runs. That refusal is not a failed call, so
  nothing is poisoned;
- a bound id in an `in` position is passed like any other;
- `release` invalidates the id and never frees the memory, because it is the
  caller's.

`load` reads it as usual. The ids come from the same budget as allocations and
are never reused.

**The contract stays version 1.** The kernel's signature, its descriptor rules
and the generated CORE header are unchanged: a kernel already receives a
pointer and a count, and cannot tell who placed them. What changed is the
Full-side registry: one operation and one flag per entry. The registry is
generated per program from the same tool, so a caller and its registry cannot
disagree about it.

**Use it on the host and in Full-side tools.** On the board, decision 0014's
application builds each entry's descriptors directly, with no registry: the
resources at their NOR addresses, the writable buffers in RAM. `bind_storage` is
what proves the same thing on the host: the entries run over resources they did
not allocate, and those resources are not written. It is also how a Full
program uses a mapped session image.
`tests/core-boundary/fixtures/adapter/operations.tsv` covers it with these
cases (the `bind-*` rows):

- each descriptor refusal, violating one rule and no other;
- each refused write;
- a passing `in` invoke;
- a release that leaves the caller's memory alone.

`tests/doom-core/bound-resources.sh` binds every resource of DEMO1's session
image, mapped with `PROT_READ`, and requires the same frames as allocated
storage (`examples/doom/core/README.md`, "The session image").

### Not implemented in this version

- **No bulk transfer.** Every element crosses one call at a time, by design, and
  what that costs has not been measured. Decision 0007 puts performance after
  correctness and no timing is claimed here.
- **No teardown.** There is no operation that releases everything or reclaims
  registry slots; a long-running Full process releases what it allocated, and a
  leak is a Full-side leak.
- **No Ruby-level lane for the module's own error paths.** `adapter.sh` runs the
  operation table against the C registry and builds and runs one Full probe; the
  Ruby wrappers are exercised by that probe, not by a case per refusal.

### A working example

This is `tests/core-boundary/fixtures/adapter/full_probe.rb` in short, against
the `sum_u8` contract (`param src buffer u8 in count n`, `result i64`), with
each printed answer beside the call. Its full form and expected output are that
fixture and `full_probe.expected`.

```ruby
require_relative "core_sum_u8"
M = CoreBoundarySumU8

puts M.startup                      # 0

b = M.allocate_storage(M::ELEM_U8, 4)
r = M.allocate_storage(M::ELEM_I64, 1)
w = M.allocate_storage(M::ELEM_U32, 2)

M.store(b, 0, 10)
M.store(b, 1, 20)
M.store(b, 2, 30)
M.store(b, 3, 40)
puts M.load(b, 2, M::ELEM_U8)       # 30

puts M.invoke(b, r)                 # 0  -- the sum is in element zero of r
M.load_i64_words(r, 0, w, 0, 1)     # an i64 result comes back as two words
puts M.load(w, 0, M::ELEM_U32)      # 100
puts M.load(w, 1, M::ELEM_U32)      # 0

puts M.load(b, 9, M::ELEM_U8)       # -1 -- the negative IS the status, ARGUMENT
puts M.invoke(b, b)                 # 1  -- the result may not be a participant
puts M.release(b)                   # 0
puts M.release(b)                   # 1  -- the id is dead, not reusable
```

### Tests

```sh
SPINEL=<pinned binary> tests/core-boundary/adapter.sh
tests/core-boundary/artifacts.sh
```

`adapter.sh` runs `fixtures/adapter/operations.tsv`, a table written from
decision 0007 **before** the adapter existed, so its answers are not a
transcript of what the adapter does. It is the only suite that uses the pinned
compiler, and it looks for it in this checkout's `vendor/spinel/bin` and, failing
that, in the main checkout's — never on `PATH`. `artifacts.sh` asks the other
half of the question: it runs each extracted DOOM capability through the adapter
as well as through the direct C harness, from **one** harness source compiled
twice, and requires the same answer.
