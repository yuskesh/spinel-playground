# What a whole-DOOM CORE closure would still need

Decision 0007 task 5 asks for the remaining closure gaps to be recorded, and
says what the record is for: **stage-2 design input, not permission to call the
existing object-oriented game CORE-ready.** Nothing here is a plan. It is a
list of what was measured while extracting three capabilities, and what the
measurements say is still in the way.

Everything below is checked by `tests/core-boundary/closure.sh`, which probes
each construct against the checker, runs the census again, and requires this
document to state the numbers it found, each against the row it belongs to. A
record of this kind rots quietly otherwise.

What the lane does NOT establish: it builds each probe and reads the verdict,
and it links and runs nothing. The six admitted probes are known to compile and
no more. `ternary` is the exception, and only because `capabilities.sh` runs
the fixed-point helpers against the original for thirty cases, which is what
makes restoring those ternaries safe rather than merely legal.

## What was extracted, and what that shows

Three capabilities are extracted and held to the original Full code:

| capability | entries | what it is |
| --- | --- | --- |
| `fixtures/capabilities` | 5 | the fixed-point helpers and the angle normalisation |
| `fixtures/framebuffer` | 3 | the wall column, the plane span, the fuzz column |
| `fixtures/slots` | 5 | the thinker list and the mobj slot allocator |

Thirteen entries, each answering what the original answers, through a direct C
harness and through the Full adapter. That is the evidence that the boundary
carries real DOOM work. It is not evidence about the rest of the game, and the
census below is the reason to be careful about the difference.

## The census

`fixtures/closure/census.rb` walks every `def` in `examples/doom/lib/doom/`
and counts which refused constructs appear in its body or its parameter list.

**573 `def`s over 34 files. 72 of them contain nothing the checked subset
refuses.**

The census was first taken at `57bcc74`, with 571 `def`s over 33 files. Two
later commits added the other two. `4724871` added `ppm.rb` and its
`Ppm.write`, which holds an allocation and a block. `0dfc2f7` added
`Jobs#zone_byte`, which reads instance state. Neither was clean, so the 72 did
not change.

`def` is not the same as "every method", and the difference is large enough to
matter: `attr_reader` and its relatives define a further **381 methods**. They
are all instance-state readers and none of them could be an entry, so they are
counted here rather than left out of the denominator without saying so. Those
381 come from **69 call sites**, which the census counts separately as
`attr_sites` and the lane holds like every other figure here. Against all 954, the 72 are **8%**; against the 573 `def`s
alone, 13%. Neither figure is a percentage of the game that is done, and the reason is
the next paragraph.

The category names are the census's own, so a row here and a row of its output
are the same thing.

| category | construct | methods | share |
| --- | --- | --- | --- |
| `instance-state` | instance state (`@x`) | 475 | 83% |
| `no-else-branch` | an `if` or `unless` with no else | 282 | 49% |
| `allocation` | array, string or hash literals | 118 | 21% |
| `and-or` | `&&` and `\|\|` | 115 | 20% |
| `raise` | `raise` | 87 | 15% |
| `element-op-assign` | `buf[i] += 1` | 33 | 6% |
| `break-next` | `break` and `next` | 27 | 5% |
| `blocks` | calls taking blocks | 14 | 2% |
| `case` | `case`/`when` | 10 | 2% |

Read those two directions carefully, because they are not the same kind of
number. **72 is an upper bound** on what could be extracted without changing
the subset: a method with none of these constructs is not thereby admissible,
since it may still call a method the census does not follow, use an operator
with no contract, or need a shape the ABI cannot declare. **The per-construct
counts are lower bounds** on what is blocked, for the same reason. Both are the
honest direction for their purpose, and neither is a percentage of the game
that is "done".

The census is calibrated against what this repository actually extracted, and
the calibration is in its output rather than in this sentence — it names the
five methods and which side each fell on, and the lane requires them to be
here:

* `fixed.rb#to_i32`, `fixed.rb#bam` and `fixed.rb#mul` are **clean**, and their
  original bodies build as CORE entries unchanged.
* `fixed.rb#cdiv` is **clean and does not build in its original form**:
  `(n < 0) == (d < 0) ? q : -q` compares two booleans, which is refused. It is
  the clearest example of why 72 is an upper bound and not a count of what can
  be extracted.
* `fixed.rb#div` is **blocked**, by the `unless` without an else that the
  extraction had to rewrite.
* `bytes.rb#u8` is **clean** and builds, with `getbyte` spelled `[]`. There is
  no `Bytes` extraction in this repository; what was measured is that it
  compiles, not that it is held to the original anywhere.

## The gaps

### 1. Instance state, in 83% of methods

The Full game is objects. `Doom::Game` holds the mobj arrays, the thinker
arrays, the level, the random state and the player in instance variables, and
its methods read them by name. A CORE entry has no instance: everything it
touches arrives as a parameter, and everything it keeps between calls has to be
a buffer the caller owns.

The three capabilities show this is workable where the state is already a flat
array — `thinker_add` takes four arrays and a two-element `state` buffer, and
thirty declared buffers build and generate an adapter, which is the width the
mobj state would need. It is not workable where the state is a graph of Ruby
objects, and most of the game is that.

*Probe: `ivar`.*

### 2. An `if` with no else, in 49% — CLOSED by 0008 task 4, in statement position

**When this was written**, half the methods in the tree had a branch that
produced no value on one path, and the subset required both arms because a
missing one is nil. At that share it was a language question rather than a
per-method adaptation, and 0008 took it as one.

**It is no longer true in statement position.** A missing `else` is admitted
where nothing reads what the branch would have produced, which is what makes
it not-nil rather than nil-by-another-name. In VALUE position it is still nil
and still refused, with `implicit-nil` naming exactly that. `unless` without
an else is the same form with the arms swapped and follows the same rule, and
a modifier `if` and a modifier `return` are two more spellings of it.

*Probes: `modifier_if`, `unless_no_else`, `early_return`, all admitted since
0008 task 4; `plain_return` was already admitted. The value-position refusal
is `tests/doom-core/fixtures/control-flow/src/if_value.rb`.*

### 3. `&&` and `||`, in 20% — CLOSED by 0008 task 4, for boolean operands

**Admitted since 0008 task 4** with statically boolean operands and real short
circuiting; `!` with them. An INTEGER operand is still refused, by name
(`non-boolean-operand`), because admitting it would need Ruby's truthiness,
where 0 is true. `docs/core/doom-stage2-language.md` states the rule and
`tests/doom-core/control-flow.sh` measures the short circuit with a side
effect and an unreachable fault, not only with constants.

What this section said when it was written:


`unsupported-node: AndNode`. A two-part guard has to become nested ifs or a
computed flag, which `thinker_add` and `mobj_alloc` both do — each carries a
`room` local that exists only because the guard could not be written as one
expression. `!` is refused separately, as a call with no scalar contract.

*Probes: `and_op`, `or_op`, `not_op`.*

### 4. Allocation, in 20%

Array, string and hash literals. The word `core` means no allocation, so this
is not a gap to be closed so much as a boundary to be respected: the Full side
allocates and hands buffers down. It is listed because a fifth of the tree
would have to be restructured before it could cross, not because the rule
should change.

*Probe: `array_literal`.*

### 5. `raise`, in 15%

The Full code signals failure by raising. A CORE entry answers with a status,
and `core_fail(:capacity)` is the only category the decision admits it to
choose. Every other kind of failure the game raises — a malformed lump, a
missing texture — has no status to become.

*Probe: `raise_error`.*

### 6. A helper may not take a declared buffer — CLOSED by 0008 task 3

**When this was written**, the probe answered `type-evidence: parameter
th_func is buffer`: the entry's buffer facts did not propagate into a direct
callee, so a kernel that would factor a shared body over a buffer had to
inline it instead. `thinker_add` inlines the link step and `thinker_collect`
inlines `free_thinker` for that reason, and both say so.

**It is no longer true.** Decision 0008 task 3 derives the borrow through the
call, so a helper's parameter is an address when the calls that reach it pass
one, and the bound travels as a hidden count from the caller's descriptor.
`tests/doom-core/borrowed-calls.sh` measures it: the borrow crosses one call
and two, two live buffers each keep their own count, a write through a
borrowed `inout` lands, and the same read-only buffer may be passed twice.
The `helper_buffer` row in `constructs.tsv` now records `admitted`, and the
inlining above is a simplification those two kernels no longer need.

*Probes: `helper_scalar` admitted, `helper_buffer` admitted since 0008 task 3.*

### 7. There is no dispatch

`run_thinkers` chooses among ten thinker functions by a stored kind. A call
whose target is a value rather than a name is refused, so the sweep was
extracted and the dispatch left in Full — which is where the boundary sits for
this capability and probably where it should sit. A whole-game closure cannot
leave it there: the dispatch is the tick.

Probing this turned up something separate and worth its own line. `send(f, a)`
with `f` a local is refused with a diagnostic, which is the probe below. But
`send(:name, a)` with a LITERAL symbol never reaches the checker at all: the
reader answers `nodes:23: dangling-reference: node id 21 is not in the ast`,
which is a shape the AST it was handed refers to and does not contain. That is
a reader defect rather than a subset boundary, it is not fixed here, and it
means the literal-symbol form has no measured verdict.

*Probe: `dispatch_var`.*

### 8. Smaller subset holes, each with a count

When this was written: `buf[i] += 1` (`unsupported-node:
IndexOperatorWriteNode`, 33 methods), `break` and `next` (27 between them),
calls taking blocks (13), `case`/`when` (10), and — present in the subset's
refusals but not in this tree — `until`, multiple assignment,
`Integer#zero?`, float literals, `Integer#to_i`. None is deep; together they
are why a method that looks simple often is not.

**Three of them are closed by 0008 task 4**: `buf[i] += 1` (index evaluated
once, and no store if the bounds test, the arithmetic or the narrowing fails),
`break` and `next` (without a value, nearest loop). The counts above are what
the tree held at the revision this was taken and are left as they were — they
are a fact about that revision, not a running total. Blocks and `case`/`when`
remain refused; 0008 refactors a `case` into explicit integer-tag branches
with an adaptation record.

**Decision 0041 stage 1 admits literal blocks** on `times`, `upto` and
`downto`, and on `each` and `each_with_index` over a declared buffer: the
block is inlined as a loop body, and no Proc exists. A block on any other call,
`yield`, `&block` and a block argument stay refused. The census still counts
every call with a block under `blocks`, so that row now includes calls the
checker may admit; it was not re-measured.

*Probes: `elem_opassign`, `break_in_while`, `next_in_while`, `each_block`,
`map_block`, `case_when`, `until_loop`, `multiple_assign`, `zero_pred`, `float_lit`,
`to_i_call`. The last two are a pair: `float_lit` was first written as
`(a * 2.0).to_i`, which is refused for the `to_i` whether or not the float is
there, so `to_i_call` is the control that keeps the float row honest.*

### 9. A refusal through the adapter poisons; a refusal in C does not

This one is not a subset gap but an ABI one, and it is the only gap here that
could change a caller's behaviour rather than refuse to compile.

A failed `invoke` poisons the mutable participants, so a Full caller cannot
read a half-written buffer at all. A direct C caller reads whatever the kernel
wrote before the access that failed — the ABI promises no atomicity, and
`tests/core-boundary/fixtures/slots/trace.tsv` declares how many cells each
refusal moves.

The consequence worth designing for: **a Full caller that exhausts a fixed
capacity loses access to the arrays.** The hosted game does not behave that
way — `add_thinker` raises and the thinker list is still there, and the next
tick carries on. Whether a capacity refusal should poison is a stage-2
question; today it does, and `slots.sh` orders its exhaustion so that
everything checkable on both paths happens before the refusal.

### 10. What is NOT a gap

Worth recording so stage 2 does not spend effort on it:

* **Width.** Thirty declared buffers build and generate an adapter. The mobj
  state's parallel arrays are expressible.
* **Ternaries.** A ternary with both arms is admitted. Three of the four
  fixed-point extractions had rewritten one into an if/else and said the subset
  required it; it does not, and they were put back.
* **Nested indexing.** `cmap[cm + atlas[i]]` is admitted, which is what the
  framebuffer kernels are made of.
* **Buffer-derived values crossing a branch.** They were refused until
  measured — the producer's hosted-Ruby nullability analysis answered a
  question the checked route does not ask — and the derivation answers now.
* **Two answers.** An entry can write several buffers and return a status;
  `two_stores` is admitted.
* **`return`, and calls to helpers.** `plain_return` — `return` on both arms of
  an if/else — is admitted, and so is `helper_scalar`, a call to a helper
  taking scalars. What §2 refuses is narrower than either: a `return` on only
  one path.
* **A helper carrying a buffer.** `helper_buffer` was refused when this record
  was written and is admitted since decision 0008 task 3, which derives the
  borrow through the call and carries the bound as a hidden count from the
  caller's descriptor. §6 says what changed and what measures it.
* **The control flow this record calls missing.** Nine more probes were
  refused when this was written and are admitted since decision 0008 task 4:
  `modifier_if` and `unless_no_else` (a conditional with no else, in STATEMENT
  position only — in value position it is still nil and still refused),
  `early_return`, `break_in_while` and `next_in_while` (without a value,
  nearest loop), `and_op`, `or_op` and `not_op` (boolean operands, real short
  circuiting), and `elem_opassign` (`buf[i] += 1`, index evaluated once, no
  store if any check fails). `docs/core/doom-stage2-language.md` states each
  form with its position and its exact refusal, and
  `tests/doom-core/control-flow.sh` measures them — against CRuby running the
  same source, where the answer is an integer.
* **A literal block on a counting or buffer loop.** `each_block`
  (`4.times { |i| ... }`) was refused when this record was written and is
  admitted since decision 0041 stage 1, which inlines the block as the loop
  body. `map_block` stays among the gaps in §8.

*Probes: `thirty_buffers`, `ternary`, `nested_index`, `two_stores`,
`plain_return`, `helper_scalar`, `helper_buffer`, `modifier_if`,
`unless_no_else`, `early_return`, `break_in_while`, `next_in_while`, `and_op`,
`or_op`, `not_op`, `elem_opassign`, `each_block`. The fourth
bullet has no probe of its own: it is held by `fixtures/buffers/src/walk_links.rb`
and its four descriptor rows, which build and run.*

## What the traversal comparisons do not cover

Recorded after Mac review of 33da4d9, which found that both the BSP and the
sound comparison had stopped being comparisons at all — each had a transcribed
"original" and a predicate shared by both sides, so 400/400 and 60/60 were two
routines agreeing with themselves. Both now call the real
`Doom::Sight#cross_bsp_node` and `Doom::Enemy#recursive_sound`, and each
carries a raise-injection control that fails if the original is not reached.
Three limits remain, and they are limits rather than defects:

* **The traversal loop is not CORE source.** `examples/doom/core/src/bspwalk.rb`
  holds the small helpers — push, near, far, is-leaf, leaf-index, the side
  predicate, and sound's skip/mark/other. The loop that drives them is Ruby in
  `tests/doom-core/bsp-model.rb` and `sound-model.rb`. Nothing in this lane is
  compiled to a CORE object or invoked natively. `tools/doom/core-cycles.tsv`
  says PROTOTYPE for all three rows for this reason; it said IMPLEMENTED before
  the review and that was wrong.

* **Openness is an input, not a comparison.** `recursive_sound` calls
  `line_opening`, which is not ported. `sound-model.rb` samples it once from
  the original and both sides read that table, so a defect in `line_opening`
  moves both and this comparison cannot see it. Corrupting `dc_sound_other` —
  which the port calls and the original computes inline — is caught, and that
  control is in the file.

* **`check_bbox` is not ported.** `Renderer#render_bsp_node`'s DESCENT is now
  compared against the original in `tests/doom-core/render-model.rb`, using
  `dc_point_on_side` — a second side predicate, kept separate from
  `dc_sight_side` because they differ in three ways that can change an answer.
  The gate itself is not ported: it needs `point_to_angle`, the `viewangletox`
  table and the solidsegs clip list, which is a rendering subsystem rather
  than a helper. Both sides call one controlled gate, so what is compared is
  the traversal around it.

  The model carries a liveness control — an inverted predicate changes all 40
  walks — and one measurement worth stating plainly: folding `dc_sight_side`
  in (its on-the-line 2 taken as 0) gives the SAME walk on E1M1 every time.
  The two predicates are different functions; whether that difference is
  observable in this walk is a question about the map, and on this one it is
  not. That is reported, not asserted away.

## The real schema and native execution

Decision 0008 task 5 says the session "exposes their IDs to generated
adapters". Until Mac review of 33da4d9 named it, nothing did: every native
lane used a fixture's own invented layout, so the 700-field schema and the
compiled entries had no connection at all.

`tools/doom/state-schema.rb` now emits `registry.h` alongside `slots.rb` — the
same rows, for the side that has no Ruby. It carries one `#define` per scalar
slot, one id per allocation, and the allocation table with each element type
and count. `tests/doom-core/state.sh` drives `dc_add_thinker` from it: the
buffer sizes and both scalar slot indices come from the header, and the answer
is compared against `Doom::Game`'s own arrays over the same sequence.

Two things were measured while building it, and neither was assumed:

* **Two disjoint one-element slices of one allocation are accepted**, which is
  the shape the real schema forces — `th_free` and `th_alloc` both live in
  `core_state`. **Genuinely overlapping `inout` ranges answer ARGUMENT and
  write nothing**, which is what 0007 requires. So no signature had to change.

* **The registry's slot indices were not load-bearing at first.** Shifting
  every index by one left the lane at 115/115, because the driver allocates
  `core_state` itself and only uses the indices relative to each other. The
  lane now compares the indices in `registry.h` against those in `slots.rb`
  directly — two generated views of one layout — and that check does fail
  under the same mutation.

What this lane still does not cover: `remove_thinker` and `run_thinkers` are
not ported, so the harness performs the unlink and free itself, and says so in
the driver. Only `dc_add_thinker` is native here.

## What this record is not

It is not a schedule, an estimate, or a claim that what is left is a matter of
filling in these holes. Several of the gaps above — instance state,
dispatch, allocation — are the shape of the program rather than the shape of
the subset, and closing them is a design question about what a CORE DOOM would
be, not a list of features to add to the checker.
