# The CORE build report

Status: the loop bound and work bound are implemented, in observe mode, as
step 1 of [decision 0010](../decisions/0010-core-resource-contract.md), and
the stack budget as step 2. The other four properties appear in every report
with their mode, and are marked as not evaluated. Extern effects (step 3) and
strict loop bounds (step 4) are planned, not implemented.

For every CORE entry and target, `spinel-core-kernel` can write one versioned
JSON document. It states what the build establishes about the entry, and the
evidence each statement rests on.

- **Schema:** [`tools/mlir/native/schema/core-report-v1.schema.json`](../../tools/mlir/native/schema/core-report-v1.schema.json).
- **Checks:** [`tests/core-report/run.sh`](../../tests/core-report/run.sh).

## Producing a report

```sh
spinel-core-kernel app.contract --root DIR -o app.o --clang "$CLANG" \
  --report app.report.json --profile hosted-stage2 [--report-revision REV]
```

- **Both flags together.** `--report` and `--profile` are required together.
  The profile is an explicit input recorded in the report, and has no
  default.
- **Profiles.** `hosted-stage2` applies today's rules and adds only the
  report. `realtime` selects decision 0010's other column of modes and adds
  exactly one admission rule this build enforces: no dynamic stack
  allocation. Any other profile name is refused. **Selecting `realtime` is not
  a claim that the build was enforced.** Its other rows read `enforce` in
  0010 and this build does not evaluate them; they appear with that mode and
  `evaluated: false`, and a consumer must treat an unevaluated property under
  `enforce` the way it treats `unknown` — not a pass.
- **Revision.** `--report-revision` records the source revision. Without it
  the revision is `null`.
- **Timing.** The report is written after the object and the header, through
  a temporary file and a rename. A report path naming the object, the header
  or the MLIR is refused, because writing it there is the one way this flag
  could change an artifact.
- **Refused entries.** An entry the kernel refuses gets no report.
- **Code generation is untouched.** The object, the header and the
  `--emit-mlir` output are byte-identical with and without `--report`.
  `tests/core-report/run.sh` checks this for every fixture, and
  `tests/doom-core/loop-reports.sh` checks it for every DOOM entry.

## Document

| key | meaning |
|---|---|
| `format`, `version` | `spinel-core-report`, `1` |
| `entry` | the contract's entry method |
| `target` | `clang -print-target-triple` with the caller's clang arguments |
| `profile` | `hosted-stage2` or `realtime` |
| `inputs.contract` | the contract file's name, and the sha256 of the bytes the kernel read |
| `inputs.source` | the root as the contract declares it, the revision, and the sha256 of the analysed snapshot |
| `object` | the object's file name and sha256 |
| `tools` | sha256 of the kernel, the contract reader and clang, and clang's version line |
| `properties` | the six properties of decision 0010, always all six |

A property that step 1 does not evaluate looks like this:

```json
"extern_effects": {"mode": "enforce", "evaluated": false}
```

It carries no verdict. Recursion and allocation are enforced by the existing
checker, and a build that reaches the report has passed them. The report does
not restate them as `pass` until it also records the evidence for them.

An evaluated property has two separate axes:

- **Verdict:** `pass`, `fail` or `unknown`.
- **Evidence:** a list of items. Each is
  `{kind, subject, value, artifact: {file, revision, sha256}}`, and its kind is
  one of `static_proof`, `runtime_guard`, `measurement`, `declaration` or
  `attestation`.

The schema requires a verdict and evidence whenever `evaluated` is true.

## The loop bound

`properties.loop_bound` has four parts:

- `verdict`;
- `evidence`: one `static_proof` item holding the work bound when the verdict
  is `pass`, and empty otherwise;
- `work_bound`: the entry's composed bound;
- `loops`: every `while` in the entry's admitted closure.

Step 1 never emits `fail`, and never refuses a build.

### Loop identity

A loop is identified by three things:

- **`id`:** `method#ordinal`, where `ordinal` counts the method's loops in
  source order from 0: its `while` loops and, since decision 0041 stage 1,
  its loops with a literal block, in one sequence.
- **`header`:** for a `while`, `while ` followed by a canonical rendering of
  the condition. For a loop with a literal block, the call's name followed
  by the rendering of its receiver and of its argument, if any:
  `times (lvar n)`, `upto (lvar a) (lvar b)`, `downto (lvar a) (lvar b)`,
  `each (lvar buf)`, `each_with_index (lvar buf)`. The block is not part of
  the header.
  - Literals are written as values.
  - `(lvar x)` is a local and `(const X)` a constant.
  - `(call op receiver args...)` is a call with a receiver, `(fcall name
    args...)` one without, and `(and l r)` and `(or l r)` are the logical
    operators.
  - Parentheses are dropped, and source positions never appear.
- **`digest`:** the sha256 of `v1:` followed by the header. `digest_version`
  is `1`. Changing the rendering must also bump the version, so that a later
  contract naming the old digest becomes stale on purpose.

Layout, comments and parentheses do not change a digest. Any change to the
condition does. `label` is `null` until contract version 2 lets a declaration
supply one.

`location` is the declared root with the loop's line and column. For a packed
DOOM source those are positions in the packed file.
`tests/doom-core/loop-reports.sh` maps them back to the maintained file.

### Rules

A loop's bound is a `static_proof` when every one of these holds, checked in
this order. The first rule that fails gives the loop's `reason`.

1. **Condition.** The condition is `true`, which fails as `no-exit-condition`,
   or it is an ordered comparison `<`, `<=`, `>` or `>=`.
   - One side is a plain local assigned in the loop: the induction variable.
   - A comparison written the other way round is read reversed.
   - With `A && B && ...`, the first conjunct in source order that passes every
     rule supplies the bound, and `conjunct` records its index and rendering.
     This is sound because the loop continues only while every conjunct holds.
2. **Other assignments.** The induction variable has no assignment other than
   a step, in the loop or in its condition.
3. **Constant step.** Each step is `i += c`, `i -= c`, `i = i + c`,
   `i = i - c` or `i = c + i`, where `c` is an integer literal or a resolved
   constant.
4. **Direction.** Every step moves the variable toward the bound. When steps
   differ, the smallest magnitude is used.
5. **Next.** No `next` reaches the next iteration before the step.
6. **Exactly once.** Every path to the next iteration steps exactly once, not
   inside a nested loop and not in the right operand of `&&` or `||`.
   - `break`, `return` and `core_fail` only shorten a run.
7. **Bound.** The bound is fixed for the loop and expressible:
   - it reads no buffer element;
   - it calls no method;
   - it reads no local the loop assigns;
   - its value at the loop head is an expression over the method's parameters
     and constants.
8. **Start.** The induction variable's value before the loop is such an
   expression.

A local's value comes from its definitions before the loop:

- Two branches that assign different values make it not expressible.
- So do a buffer element, a call result, and an operator outside the grammar.
- A local assigned in an enclosing loop varies with that loop, and so does a
  local assigned in an earlier loop after that loop ends.

The bound is `ceil_div(max(0, span), step)`, which reads as `max(0, span)`
when the step is 1:

| comparison | span |
|---|---|
| `i < b` | `b - start` |
| `i <= b` | `b - start + 1` |
| `i > b` | `start - b` |
| `i >= b` | `start - b + 1` |

Checked arithmetic refuses an induction variable that would overflow, so no
wraparound is assumed.

### Loops with a literal block

A loop with a literal block (decision 0041 stage 1) has a hidden counter, not
an induction variable the source can assign, so rules 1 to 6 hold by
construction: assigning the block parameter, or the receiver, does not step
it. The receiver and the argument are read once, before the first iteration,
and rules 7 and 8 apply to them as to a bound and a start, with the same
reasons when they fail. Each is read in Ruby's order. The receiver is its
value at the call. The argument is its value after the receiver has run. So
`(n -= 1).times` is bounded by `max(0, n - 1)`, and `a.upto(a = 0)` by
`max(0, 0 - a + 1)`.

| loop | bound |
|---|---|
| `n.times` | `max(0, n)` |
| `a.upto(b)` | `max(0, b - a + 1)` |
| `a.downto(b)` | `max(0, a - b + 1)` |
| `buf.each`, `buf.each_with_index` | the buffer's count |

A buffer's count is the entry's count parameter (`n_buf`) or its declared
constant. In a helper, where the buffer is a parameter the caller passes, it is
written `size(buf)`, and each call's term replaces it with the count of the
buffer the caller passed.

`break`, `return`, `next` and `core_fail` in the block only shorten a run, as
in a `while`. A `while` whose step is inside a block loop is
`step-conditional`, as when the step is inside a nested `while`.

### Reasons

| reason | the first rule the loop fails |
|---|---|
| `no-exit-condition` | the condition is `true`, and the loop is left only by `break`, `return` or failure |
| `condition-not-induction` | not an ordered comparison of a plain local the loop assigns: `!=`, `\|\|`, a call, `i + 1 < n`, or neither side assigned |
| `induction-reassigned` | the variable is assigned something other than a step, or is assigned in the condition |
| `step-not-constant` | a step by a non-constant amount or operator, such as `i += k` or `i = i * 2` |
| `step-away-from-bound` | a step of zero, or away from the bound |
| `step-skipped-by-next` | a `next` reaches the next iteration before the step |
| `step-conditional` | a path reaches the next iteration with no step or with two, or the step is inside a nested loop or `&&`/`\|\|` |
| `bound-varies` | the bound reads a local the loop assigns, or both sides of the comparison are assigned in the loop, which is decided with rule 1 and so precedes the step rules |
| `bound-from-buffer-element` | the bound reads a buffer element, directly or through a local |
| `bound-from-call` | the bound calls a method of the closure, directly or through a local. A call with a receiver, such as `n.abs`, is an operator outside the grammar and gives `bound-not-expressible` |
| `bound-not-expressible` | the bound has no expression over parameters and constants |
| `start-not-expressible` | the start has no expression over parameters and constants |

The first six are 0010's list. The rest are provisional: the DOOM catalogue
decides which of them are kept.

For `bound-not-expressible` and `start-not-expressible`, `detail` begins with
a token:

- **`enclosing-induction:`** the value is an expression over the induction
  variable of an enclosing loop, as in `b = a + 1` inside `while a < n`. Step 1
  does not derive through it.
- **`enclosing-varying:`** a local assigned in an enclosing loop.
- **`after-loop:`** a value left by an earlier loop.
- **`buffer-element`, `call-result`, `multiple-definitions`,
  `unsupported-operator`, `unbound`:** the opaque value's cause.
- **`expression-too-large`:** the value met the limit below.

### Limits

An expression is shared inside the analysis but written out as text, so a
graph of a few nodes can be an enormous expression: `m = m + m`, thirteen
times, is 8191 terms. Two limits keep a report readable and the build alive.

- **4096 terms in one expression.** A bound over it is `unknown`, with the
  detail `expression-too-large`, and a work-bound occurrence over it has the
  reason `expression-too-large`.
- **4096 loop occurrences in the work bound.** The expansion stops there,
  `work_bound.limit` is `too-many-terms`, and the work bound is `unknown`. The
  terms already listed stay, and each is still true of the entry.

`work_bound.limit` is otherwise `null`. Both limits were measured: without
them, a doubling chain wrote gigabytes and a call graph that fans out
exhausted the stack, in both cases after the object had been written.

### Expressions

A bound is an expression over mathematical integers, not machine words:

```
expr    := term (("+" | "-") term)*
term    := unary ("*" unary)*
unary   := "-" unary | primary
primary := integer | name | name "(" expr ("," expr)* ")" | "(" expr ")"
```

The functions are:

- `max(a, b)`;
- `ceil_div(a, c)`, for `a >= 0` and a constant `c > 0`;
- `floor_div(a, b)` and `floor_mod(a, b)`, which are Ruby's Integer `/` and
  `%`.

A loop's own bound is written over its method's parameters. A work bound and
its terms are written over the entry's parameters, including the counts.

### The work bound

`work_bound.terms` lists every occurrence of every loop in the entry, with
the call graph expanded from the entry. A term records:

- the loop's `id`;
- `context`: the enclosing loops (`loop:<id>`) and calls
  (`call:<method>@<line>:<col>`) from the entry inward;
- the occurrence's `iterations`, or a `reason` and a `detail`;

and `work_bound` carries `expression`, `limit` and `terms`.

An occurrence's iterations are the loop's own bound, with the call's
arguments substituted for the callee's parameters, multiplied by the bounds
of every enclosing loop on the way. A call in a loop's condition runs at most
one more time than the loop body, so that loop contributes its bound plus 1.

An occurrence can be unknown when its loop passes:

- **`argument-not-expressible`:** an argument substituted into the bound has
  no expression over the entry's parameters. Examples are a buffer element, or
  a variable of the calling loop.
- **`enclosing-unknown`:** an enclosing loop is unknown.
- **`expression-too-large`:** the occurrence's expression met the limit above.

An occurrence of a loop that is itself unknown carries that loop's reason.

**The work bound is the sum of the effective iterations of every loop
occurrence, outer loops included.** For `n` outer iterations around `m` inner
ones it is `max(0, n) + max(0, n) * max(0, m)`. It counts loop body
executions, not operations or time. If any occurrence is unknown, the work
bound is `null` and the property is `unknown`. An entry with no loop has work
bound `0` and passes.

## The stack budget

Step 2 of decision 0010. The report answers how much stack the entry needs,
and — when the profile supplies the two policy terms — whether that fits.

```
kernel_stack      = max over paths of (sum of frame sizes + per-target call overhead)
pass  iff  kernel_stack + interrupt_reserve <= provisioned_stack
```

**`kernel_stack` is reported under every profile**, because it is a property of
the artifact and not of a policy. The two terms on the right-hand side are
policy, and neither profile in this tree declares them, so the verdict is
`unknown` **with the reason recorded** — a reader must not be able to take it
for `pass`.

**Checks:** [`tests/core-stack/run.sh`](../../tests/core-stack/run.sh), which
is decision 0010's proof-of-concept acceptance and nothing else.

### Where the three inputs come from

All three are taken from the IR code generation consumed — the file the
two-step emission leaves behind — so the call graph and the frame sizes cannot
describe different programs.

- **Frame sizes** (`measurement`). A side compile of that IR with
  `warn-stack-size`=0 on every function, and clang's diagnostic parsed. The
  side compile uses the object's own code generation line, so the sizes are
  the object's sizes. The diagnostic tests `size > threshold`, so **a function
  it says nothing about has a zero-byte frame**, not an absent measurement;
  the side compile therefore carries a control function with a 4096-byte
  allocation, and if the control's diagnostic does not arrive the analysis
  refuses rather than reading every silence as a zero.
- **The call graph** (`static_proof`). Read from the same IR, after
  optimisation and inlining, so an inlined call correctly has no frame.
- **Per-call overhead** (`declaration`). A property of the target, recorded
  with the measurement behind it: 8 bytes on x86-64, where the call pushes a
  return address no frame contains, and 0 on arm64, where the callee saves the
  link register inside its own frame, which the reported size already counts.
- **Unreserved call frames** (`measurement`, Arm, Thumb and x86-64). When a
  function's largest outgoing argument area is 2047 bytes or more, the Arm
  backend does not reserve call frames in the function's frame. It moves sp
  around each call instead, and the diagnostic leaves that area out: a call
  with 520 pointer arguments is reported as 24 and made after
  `sub.w sp, sp, #2064`. A further side compile prints the same module as
  assembly with the same line, which is read against the reported frames:
  - A prologue is a run of sp decrements (push, vpush, `sub sp` by an
    immediate) at the function's start, or beginning with a push.
  - Whatever the largest run moves sp by beyond the reported frame is a call
    frame allocated with the prologue. Any other `sub sp, #N` is a call frame
    of N.
  - The larger of the two is added to the function's frame and recorded as an
    evidence entry `unreserved call frame in <function>` with its bytes.
  - A prologue smaller than the reported frame, or sp moved by a register, is
    refused.
  - A control module with a 600-argument call must report such a frame on
    every run.

  Unwind tables would mark prologues with `.pad`, but they change code (a
  noreturn function gains a `push {r7, lr}`), so they are not used.
  `tests/core-stack/run.sh` checks 520 arguments (2064 added) and 500
  (reserved, not added twice). The FRDM-IMXRT1186's scheduler thread
  overflowed (decision 0021) before this was counted: the step entry's
  `sp_doom_core_step` holds 3504 bytes the frame size left out.

  On x86-64 the same gap comes from the other side: the backend turns a
  call's stack arguments into pushes just before the call, which the
  diagnostic does not count either (8 pointer arguments: reported 8, then
  16 bytes pushed). The prologue is the function's first sp decrements up to
  the reported frame. After it, the pushes and `subq $N, %rsp` before each
  call, net of `addq` and pops, are that call's frame, and the largest is
  added and recorded in the same way. `tests/core-stack/run.sh` checks 8 and
  12 arguments (16 and 48 added; at 12 the prologue's pushes run into the
  arguments') and 6 (nothing pushed, nothing added). arm64 reserves its call
  frames and is not read this way.

### What it refuses to answer

An indirect call has no callee to charge, a cycle has no longest path, and an
extern on the worst path has a frame that is not this artifact's to measure.
Each ends the analysis with `evaluated: false` and a reason, rather than a
number.

A **dynamic stack allocation** is the one refusal a profile can turn into a
verdict. `realtime` admits none, so an entry that needs one is `fail` with the
reason and deliberately no `kernel_stack`: the frame it would have counted does
not exist. Under `hosted-stage2` the same entry is `evaluated: false`.

### The method, and its cross-check

The frame-size diagnostic is object-format independent, which is why the report
uses it. ELF's `.llvm_stack_sizes` (`-fstack-size-section`) is exact but
ELF-only, and changes the object, so it cannot be the shipped path; it is an
independent cross-check on Debian, run by `tests/core-stack/run.sh` over the
same IR. Prologue decoding, 0010's fallback, is not implemented and was not
needed.

`--emit-optimised-ir PATH` keeps the IR the object was generated from. The
build always produces that file; the flag only says where. It exists so the
cross-check can be run by something other than the kernel itself, and the
object is byte-identical with and without it.

### Verifying the figure at run time

[`tests/core-stack/highwater.c`](../../tests/core-stack/highwater.c) runs an
entry on a painted stack and reports how far below the call site the run wrote.
**It is a lower bound**: painting sees bytes that were written, so a frame that
was allocated and not written through is invisible, and a path the run did not
take costs nothing. Staying within `kernel_stack` is the expected result;
exceeding it means the static method missed something. The harness calibrates
its own overhead against a control of known size and refuses to report a figure
if it cannot see that control.

### The two policy terms

`interrupt_reserve` and `provisioned_stack` come from a target profile that
does not exist yet, or — for the provision alone — from the entry's contract.
Until then the verdict is `unknown` and says which terms were missing.

For the proof of concept alone, `--fixture-stack-provision` and
`--fixture-interrupt-reserve` supply both. **They are not a target profile and
must never stand in for one.** Three mechanisms keep them out of a real build,
each working without the others: they are refused outside `--profile
realtime` and carry `fixture` in their name at the point of use; a report built
with them records `"origin": "fixture"` on the declaration evidence, so the
artifact says so afterwards; and `tests/core-stack/run.sh` greps the tree and
fails if anything outside the tools that accept them passes them.

## Version 2: application entries (decision 0014)

An entry under `core-contract 2` writes `"version": 2`, which is the version 1
document plus a required `application` object, an evaluated
`extern_effects` property, and two shapes version 1 does not have: `object`
may be `null`, and a stack evidence item may be an `attestation`. The schema
is `tools/mlir/native/schema/core-report-v2.schema.json`.

- `application.context` is `thread` or `interrupt`.
- `application.buffers[]` lists the entry's state buffers: `element`, `cross`
  (reached from more than one context), `elements` (the constant count) and
  `written` -- the transitive write effect: a store in the entry, a store
  through a helper's parameter that received it, or an `inout` extern
  argument.
- `application.externs[]` has one item per declared extern: `name`
  (`Module.fn`), `symbol`, `calls` -- an expression over the entry's
  parameters, the sum over call sites of the product of the enclosing derived
  bounds, composed through helpers, both arms of a conditional counted -- with
  `calls_derived` and, when not derived, `calls_reason`; `sites`; `const_args`
  -- one array per call site in the source, holding, per declared argument,
  the integer literal or resolved constant passed there, or `null` for a
  buffer or a computed scalar (the application tool reads a device's instance
  index from it; `sites` counts the loop expansion's occurrences, which is a
  different number when a helper is reached along several paths); `isr_ok`
  and `bound` as declared; the `guards` and `statics` as written; `stack`
  and `effects` from the extern's provider evidence.
- **Evidence binding.** The kernel is given `--config-binding
  <dts>:<config>:<flags>`, three sha256 digests. An evidence file (the
  contract's `evidence` path, relative to the contract) is accepted only if
  its format, `symbol`, `target` and the three digests match; then `stack`
  is `{"bytes", "evidence": "attestation", "method", "artifact",
  "provider_object"}` and `effects` carries the provider's `isr_ok`,
  `blocking`, `row` and `provenance`. Otherwise both are `unknown` with the
  reason -- unreadable, not evidence, another symbol, another target, or
  which digest differs -- and nothing is defaulted.
- `application.work_bound.extern_terms[]` lists every extern call site with
  its context (`loop:` and `call:` steps, then `extern:<Module.fn>@line:col`)
  and its count.
- **An extern whose bound is unknown** (decision 0021; the owner's decision of
  2026-10-20). An extern line may declare `bound iterations unknown
  "<reason>"` in place of `bound iterations <expr>`.
  - The reason is quoted and may span fields. It must not be empty, and must
    hold neither `"` nor `*/`. A missing, unclosed or empty reason is
    refused as `bad-field`.
  - The extern's item carries `bound` as written, plus `bound_reason`.
  - An entry that calls such an extern has `properties.loop_bound` verdict
    `unknown`, however its own loops derive. The verdict carries
    `unknown_externs[]`, one `{extern, reason}` per such extern called, and
    `work_bound` keeps the entry's own derived work.
  - `unknown_externs` is written only when it has an item, so a report
    without one is unchanged.
  - Such an entry is **not a realtime claim**: its work has no bound,
    whatever the profile. The application tool admits it only for the
    DoomCore members a `core_session` generates (docs/core/applications.md),
    and records it in `build.json` with the reason.
- `properties.extern_effects` is evaluated for a version 2 entry: `pass` when
  every extern's call count is derived and its evidence is bound, otherwise
  `unknown` with one reason per extern per cause. The context rule, the
  cross rule and declaration are admission's, so a report exists only for an
  entry that satisfied them.
- On the stack budget, a callee the IR only declares takes its frame from
  its bound evidence, recorded as an `attestation` evidence item with the
  bytes and the artifact; without bound evidence the path through it has no
  answer.
- **An admission-only report** is written by `--admit-only --report`: the
  same document with `"object": null`, `stack_budget` and
  `undefined_symbols` unevaluated with their reasons. The `application`
  object is already final there. A full build writes it with the object.

## Canonical JSON

A golden report is compared as bytes on both hosts, so the harness writes its
own JSON instead of delegating the formatting it is judged on.
`JSON.pretty_generate` is not a stable target. Measured on both hosts: json
2.12.2 writes `[]` and `{}`, while json 2.7.2, which Debian's ruby 3.3.8
ships, writes an empty array with a blank line between its brackets and an
empty object with a newline and an indent -- **two shapes, two different
renderings, one library**, and neither is visible from the host that wrote
the file. That is why the emitter owns the whole rendering instead of being
patched for the shape that happened to be caught: the next divergence will be
in a shape nobody patched.

`CoreReport::Json.dump` in [`tests/core-report/lib.rb`](../../tests/core-report/lib.rb)
writes:

- **Indentation.** Two spaces per level. Each element of a non-empty array or
  object is on its own line, and the closing bracket sits at the indentation
  of the line that opened it.
- **Empty collections.** `[]` and `{}`, with nothing between the brackets.
- **Key order.** The order the keys were inserted in, which is the kernel's
  order. Keys are never sorted.
- **Separators.** `": "` after a key, and `,` at the end of a line that is
  followed by another.
- **Strings.** `"` and `\` are escaped; the control characters below `0x20`
  use `\b`, `\t`, `\n`, `\f` and `\r` where JSON defines them and `\u00xx`
  otherwise. Everything else is written as itself, so text stays UTF-8 and
  **non-ASCII is never escaped**. `/` and `DEL` are ordinary characters.
- **Numbers.** An integer is `Integer#to_s`, of any size. **A float is
  refused**: the schema admits none, so a rendering for one is a decision to
  make rather than something to discover from a library.
- **End.** Exactly one trailing newline.

Nothing in it calls the json library, so a library change cannot move the
output quietly. [`tests/core-report/fixtures/canonical.json`](../../tests/core-report/fixtures/canonical.json)
holds these bytes for the union of the shapes both hosts' probes found to be
version-sensitive. In the fixture:

- **Containers:** an empty array and an empty object under a key; a
  one-element array and a one-element object, so the non-empty rendering is
  pinned too; empties nested in an array, including an object holding an
  empty array; empties nested in an object.
- **Strings:** non-ASCII in the BMP (U+00FD and U+3042) and outside it
  (U+1F600, where an emitter may write a surrogate pair instead); U+0001 and
  U+001F, whose hex case is pinned; quote and backslash; newline and tab; DEL;
  `/`, which stays raw although `\/` is legal JSON and some emitters write it;
  an empty string as a value and as a key, at two levels.
- **Numbers:** the largest and the most negative 64-bit integer, one beyond
  that range, `-1` and `0`.
- **Literals:** `true`, `false` and `null` in one object.
- **Structure:** an object whose keys are `z` then `a`, so sorting them would
  be caught.

Three things a fixture whose top level is an object cannot hold are stated as
assertions in `check.rb` instead: that a top-level empty array and empty
object are `[]` and `{}`, and that the bytes end in exactly one newline and
are binary.

**A float is deliberately absent from the fixture.** A probe of the library
measures one, because the library renders it; this emitter refuses it, so a
float among these bytes would contradict the contract. It is covered by an
assertion that the emitter raises, next to the one for invalid UTF-8. Anyone
diffing this fixture against a library probe should expect that one case to
be missing here rather than dropped. A
future json version fails that fixture, with its cause named, rather than a
golden report failing on the other host.

The same emitter writes the catalogue's `summary.json`, so evidence from two
hosts is comparable as bytes too. The run records and summaries of the 0009
DOOM harness are parsed and judged by key, never compared as bytes, and are
not written through it.

## Where reports live

The repository holds the schema, this document, the fixtures and three golden
reports in [`tests/core-report/golden/`](../../tests/core-report/golden). A
golden report is normalised before comparison: the target, object, tools and
revision are replaced with placeholders, so the same file holds on Debian
x86_64 and macOS arm64 and still validates.

Reports for the DOOM CORE entries are regenerated evidence, not tracked files.
`tests/doom-core/loop-reports.sh OUTDIR` builds every kernel-built DOOM entry,
writes its report and the catalogue of unknown loops into `OUTDIR`, and checks
object identity for each entry. `OUTDIR` must be outside the checkout.

## Limitations

- **Observe only.** A loop without a `static_proof` bound is reported, not
  refused, and gets no counter.
- **Unknown occurrences.** A loop that passes in its own method can still be
  unknown where it is called, and the catalogue shows those occurrences
  separately.
- **Enclosing induction variables.** The analysis does not reason about their
  ranges. Loops whose start or bound depends on one are reported with the
  `enclosing-induction:` detail, and the catalogue counts them.
- **Unit.** Bounds count iterations. Operation cost and WCET are separate
  properties for later decisions and steps.
- **No stack verdict anywhere yet.** `kernel_stack` is reported under every
  profile, but no target profile declares `interrupt_reserve` or
  `provisioned_stack`, so every real build's stack verdict is `unknown`. The
  one exception is a dynamic stack allocation under `realtime`, which fails on
  an admission rule that needs no number.
- **`realtime` is one rule, not a column.** Its other five rows read `enforce`
  in decision 0010 and are written `evaluated: false`. Under `enforce`, an
  unevaluated property is not a pass.
- **Extern stack is not composed.** 0010 takes each extern's stack from its
  overlay; no overlay exists, so an extern on the worst path ends the analysis
  with a reason instead of a number. No entry in this tree has one.
