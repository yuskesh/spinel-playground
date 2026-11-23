# 0041: Ideas from Goose for CORE: inlined blocks, a bounded data stack, slot pools

- Date: 2026-11-14
- Status: Accepted by the owner on 2026-11-14 (relayed by the bpf-mlir coordinator). Stages 2
  and 3 are accepted in direction; each starts only after the previous
  stage's results are reported to the owner. Stage 1 is authorized.
- Spelling: since [decision 0045](0045-buffer-classes.md) a buffer is written
  `Core::Buffer` / `Core::Table`, and the Array spelling shown here is refused.
  This record keeps its text.
- Scope: What CORE admits beyond today's subset: literal blocks on a few
  iterator calls, arrays whose lifetime ends in the method that makes them,
  and fixed-capacity slot pools. It also records which other ideas of Goose
  CORE already has, and which it does not take.

## Context

### Goose

Goose is a language by Wouter van Oortmerssen (2026,
[documentation](https://aardappel.github.io/goose/),
[reference](https://aardappel.github.io/goose/docs/reference.html)). It has no
heap and no garbage collector. The parts that bear on CORE, as its reference
states them (section numbers are the reference's):

- **Data stacks (§4).** Values whose size is not fixed live on data stacks
  the compiler manages: each is an address-space reservation with a bump
  pointer. Values are pushed in lifetime order and freed together at scope
  exit, "a single store". At most one resizable value is live per stack, and
  it stays on top for its whole life, so growing it moves nothing. The
  compiler assigns values to stacks statically and reuses a stack once a scope
  frees it. Exhausting a data stack is a clean abort in every build.
- **Roots (§12).** "A reference or slice must not outlive the variable that
  owns its target." The owner of each reference, its root, is inferred and
  never written, and a function is specialized per distinct root.
- **Blocks (§18).** "Function values are compile-time entities passed as
  generic parameters, not runtime data." A trailing block may read and write
  its enclosing function's locals; storing, returning or putting one in data
  is a compile error. There are no closures and no function pointers.
- **`return E from f` (§20).** It returns from the innermost active call of
  `f` through a hidden discriminant that each frame checks after a call, not
  through an unwinder, and the compiler checks that every call of the
  function using it lies within a call of `f`.
- **Slot pools (§14).** `alloc_index` reuses a freed slot; `free` releases no
  memory, and a stale index "reads a different value of the correct type": a
  logic bug, never memory corruption. A double free is not detected.
- **Threads (§22).** Workers share no memory and exchange only flat values,
  which hold no reference at any depth, through bounded queues.
- **Relative references and `from_bytes` (§11, §23).** A link is an offset
  from a field or from a pool's base; `from_bytes` checks an image's framing,
  tags, lengths and every link before any of it is used.

This record adopts ideas, not code: nothing from Goose is imported, and its
performance claims are not relied on.

### CORE today

- **Blocks are refused.** The freestanding subset refuses `BlockNode`,
  `LambdaNode`, `YieldNode`, and the calls `times`, `each` and `map`
  (`tools/mlir/native/lib/Core/SubsetRefusals.cpp`); the eligibility checker
  reports blocks as `UNKNOWN` ([tools/core](../../tools/core/README.md)).
  [Decision 0007](0007-doom-core-preparation.md) refused them in its first
  version along with recursion and dynamic dispatch.
- **One rewrite already turns blocks into loops.** For a fiber body,
  [decision 0035](0035-stackless-fiber.md) rewrites `while`, `until`, `loop`,
  `Integer#times`, `Integer#upto`, `Range#each` and `Array#each` into explicit
  loops (`tools/fiber/spinel-fiber-core`).
- **No allocation in CORE.** Data that outlives an entry is a `state` buffer
  declared with an element type and a count
  ([decision 0014](0014-core-applications-on-zephyr.md) §2) or a buffer the
  caller lends ([0007](0007-doom-core-preparation.md)). `ArrayNode` and `new`
  are refused as heap operations.
- **Failure is a status.** `OK`, `ARGUMENT`, `ARITHMETIC`, `BOUNDS` and
  `CAPACITY` (0007, 0014). `core_fail(:capacity)` has no successful return and
  lowers to status propagation through the whole closure (0007): a hidden
  discriminant checked after each call, as Goose's `return ... from` is.
- **A finite capacity is a contract** (0010's clarification of 2026-09-18): a
  declared capacity is valid when every consuming site checks it first, the
  result below it is unchanged, and exhausting it fails deterministically with
  nothing written past the end.
- **Loop bounds are observed, not enforced.** 0010 step 1 derives and reports
  a bound per `while` loop; strict enforcement (step 4) has not started. A
  loop-bound excess is `CAPACITY`. Stack budgets are measured from code
  generation's frame sizes (0010 step 2).
- **Slots exist in two forms.** DOOM's fixed-capacity state slots with indices
  (0007), and 0035's fiber slots, where every misuse of a slot is `BOUNDS`.
- **The core-to-core channel already carries flat values only**
  ([0027](0027-amp-two-core-channel.md), "What a message may hold"): fixed
  integer fields and fixed arrays, no pointer, and an address only as an
  offset into a declared region, checked against the region's extent before
  use. Each core's heap stays its own.

### Not a refinement of 0003

[Decision 0003](0003-gc-and-arena-build-modes.md) chose the process as the
arena's unit and noted that the predecessor scoped its arena to one request.
It does not propose a scoped arena for CORE. The data stack in stage 2 below is
a new contract, not an extension of 0003's.

## Options

Each idea of Goose was weighed against what CORE has.

| Idea | CORE has | Proposed |
|---|---|---|
| Blocks as compile-time entities | refused | **Stage 1**: inline literal blocks of a few iterator calls |
| Data stacks | nothing; data that outlives an entry is `state` | **Stage 2**: one bounded data stack per context, for arrays that do not leave the method making them |
| Slot pools | slots without a free list (0007, 0035) | **Stage 3**: a declared pool with a free list |
| Root inference | none | the stage-2 rule is root inference at its smallest; per-root specialization deferred |
| `return ... from` | `core_fail(:capacity)` status propagation | nothing new; `raise`/`rescue` stays refused (below) |
| Flat values between threads | 0027's message rules; 0014's one writing context per `state` | nothing new |
| Relative references, `from_bytes` | 0027's checked offsets | deferred until a format has variable structure |

### Not taken

- **Inferring a foreign buffer's root or lifetime.** A buffer a caller lends
  (0007) or an extern receives (0014 §6) keeps its declared direction, length
  and ownership. The foreign side is not visible to the analysis, and
  AGENTS.md forbids inferring ownership, lifetime or aliasing there. Root
  inference applies only to data CORE itself makes.
- **`raise` and `rescue` mapped onto statuses.** Decision 0001 refused
  `raise` for freestanding code, and 0007 fixed the status set. Letting a
  `rescue` in the closure catch a declared failure would change that failure
  contract; it needs its own proposal, if the owner wants one.
- **Address-space reservations.** A microcontroller cannot reserve gigabytes
  per stack. Every data stack here has a declared size in the image.
- **Undetected double frees.** See stage 3.

## Decision

Three stages, each a separate unit of work with its
own branch and its own acceptance, smallest first. Stage 2 depends on stage 1
only for iterating an array; stage 3 is independent of both.

### Stage 1: literal blocks on iterator calls

**Question.** Can CORE admit `n.times { |i| ... }` and its relatives with no
`Proc`, as a loop whose body is the block?

**What is admitted.**

- The calls `Integer#times`, `Integer#upto`, `Integer#downto`, and `each` and
  `each_with_index` on a buffer CORE already admits (a `state`, a lent buffer
  or a `freestanding_def` buffer parameter), each with a literal block
  (`{ ... }` or `do ... end`) and at most the parameters the call yields.
- The block body follows the same subset as its method. It reads and writes
  the method's locals, as a Ruby block does. A local first assigned inside the
  block is the block's own, as in Ruby, and is not visible after it.
- `next` continues with the next iteration, `break` without a value leaves
  the loop, and `return` returns from the enclosing method. After inlining
  they are the loop's own control flow, so no status path is needed.
- The call is a statement: its value is unused. (`times` answers its receiver
  and `each` the buffer; using the buffer whole is already refused.)

**How it lowers.** The importer lowers the call to a loop over a hidden
counter. The block parameter is a fresh local each iteration, so assigning to
`i` inside the block does not change how many times the loop runs, as in Ruby.
The counter cannot overflow: `upto` to the largest Integer runs to it and
stops.

**Still refused, by name.** A block passed to a method of the program
(`yield`, `&block`), `proc`, `lambda`, `Proc.new`, `&:sym`, a block whose
value the call would use (`map`, `select`), `break` with a value, `redo`,
`retry`, and numbered or `it` parameters. A method that yields to a literal
block, specialized at each call site as Goose does, is a later step.

**Loop bounds.** The bound comes from the call itself, so 0010's derivation
reports it as `static_proof` when the receiver is loop-invariant:
`max(n, 0)` iterations for `times`, `max(b - a + 1, 0)` for `upto`, and the
buffer's count for `each`. These loops never reach step 4's strict refusal
for want of a bound.

**Predictions.**

1. The contract reader's AST face carries the `BlockNode`, its parameters and
   their locals; the analysis types the parameter as Integer for `times`,
   `upto` and `downto` and as the element type for a buffer's `each`. This is
   checked first; if the parameters are not typed, the stage stops and
   reports that rather than guessing types.
2. A `times` loop and the `while` loop written by hand compile to the same
   kind of MLIR loop. The test compares the two inside the same new build;
   no old-versus-new comparison is involved.
3. The 0035 rewrite keeps working unchanged: a fiber body's `times` is still
   rewritten before CORE sees it.

**Checks.**

- Accept fixtures for each call, with `next`, `break` and `return` inside the
  block, and with a block-local variable.
- Each refusal above has a fixture that names it, at its line and column.
- The block parameter reassigned inside the block still runs `n` iterations
  (a planted assignment and a count).
- The core report shows each new loop's bound as `static_proof`, and a
  `times` whose receiver the loop changes is not `static_proof`.
- `upto` to the body's largest Integer runs to it and ends (no `ARITHMETIC`).
- The subset refusal table drops `times` and `each` as unconditional rows;
  its coverage fixtures move with it.

**Gated by** the suites `tools/test/affected.rb` selects for the changed
files. The expected set: `subset-tables`, `subset-map`, `subset-reasons`,
`lowering-locations`, `freestanding`, `core-run`, `core-report`,
`core-eligibility`, `native-core-run`, `fiber-core` and `app-host`.

### Stage 2: one bounded data stack, for arrays that stay in their method

**Question.** Can a CORE method make an Integer array that lives until the
method returns, with no collector, no heap and a declared bound, and refuse
every use that would let it outlive the method?

**The declaration.** The first route is 0014's applications, which already
declare `state` and contexts:

```ruby
scratch 4096, context: :thread     # bytes for this context's data stack
```

- Each context that makes arrays has its own data stack. An interrupt entry
  can preempt a thread entry, so two contexts cannot share one bump pointer;
  a context that makes an array and declares no `scratch` is refused.
- The stack is a static region in the image. The build's resource report
  lists its size beside the `state` buffers and the fiber frames.

**What is admitted.**

- `a = Array.new(n, v)` in a method, with `v` an Integer literal and `n` a
  scalar Integer expression. Elements have the body's integer width
  ([0019](0019-target-integer-width.md)). Float arrays wait: the pinned
  inference already types a Float local multiplied in a loop as either class
  (seen in `spinel-mpc` on 2026-11-13).
- `a[i]`, `a[i] = x`, compound assignment on an element, `a.size`, and
  stage 1's `each`. Indexes are checked as a buffer's are, and a negative
  index is `BOUNDS`, not counted from the end.
- `a` passed as an argument to a direct callee in the closure. The callee's
  parameter is then a borrow of the caller's array, lowered as a buffer
  parameter, and the same rules apply to it inside the callee.
- The array is freed when its method returns, on every path, a failure status
  included: the method restores the stack pointer it saved on entry.

**Refused, each with its location.** Returning the array; storing it in a
`state`, an instance variable, a global or another array; assigning it to a
second local or reassigning its local; passing it to an extern or a
`fiber_def` body; making an array inside a loop (a loop body is not a scope
the stack can free); `push`, `<<` and any other resize; and an array literal
`[...]`.

**The bound.** Every `Array.new` checks the remaining space before it moves
the pointer, and an allocation that does not fit fails with `CAPACITY`,
writing nothing. That meets 0010's three obligations for a finite capacity.
When every size on a path is a constant, the report also states the worst
path's total against the declared size as `static_proof`, composed as 0010
composes stack frames. Otherwise the evidence is `runtime_guard`. The fill of
`n` elements counts as `n` iterations of work.

**Predictions.**

1. The analysis types `Array.new(n, 0)` and a helper's parameter that
   receives it as an Integer array. `spinel-mpc` saw a helper's Array
   parameter typed as an Integer array; here that is the type wanted.
2. Every escape listed above is visible in the closure's AST and local faces,
   so no escape check needs a new analysis of the vendor's.
3. Freeing on every path costs one store per method that makes an array.

**Checks.**

- Accept fixtures: an array in a method, one passed down two calls, and one
  in each of two contexts at once.
- A refusal fixture per escape above.
- A planted capacity control: a `scratch` one element too small fails with
  `CAPACITY` at the same allocation every run, and the bytes after the region
  are unchanged.
- After an entry that failed with `CAPACITY` partway, the next release starts
  with the whole stack free.
- An interrupt entry that makes an array while a thread entry holds one
  leaves the thread's array intact (on QEMU, with the interrupt planted
  between two of the thread's writes).
- The resource report shows the region, and `static_proof` for constant
  sizes.

Comparing results below the capacity with CRuby's is an oracle (0010's second
obligation); it runs only when the owner instructs.

**Gated by** the expected set: `core-report`, `core-stack`, `freestanding`,
`app-contract`, `app-host`, `app-reserves`, `app-effects`, `app-cross`,
`subset-tables`, `subset-reasons` and `core-run`.

**Later, each its own question.** One resizable array on top of a data stack,
as Goose allows; arrays made in a block, freed per iteration; Float arrays;
`freestanding_def` and `spinel-mpc` as further routes.

### Stage 3: a declared slot pool

**Question.** Can CORE reuse slots of a fixed-capacity table through a free
list, with exhaustion as `CAPACITY` and every misuse as a status?

**The declaration**, generated like 0035's `fiber_def`:

```ruby
pool_def :node, max: 64       # slots 0...64
state :node_next, :i32, 64    # the application's fields, one state each
state :node_key,  :i32, 64

def insert(key)
  i = Node.alloc              # a free slot, or CAPACITY
  ...
  Node.free(i)                # BOUNDS if i is not allocated
end
```

- `Node.alloc` answers a free slot's index, reusing freed ones first, or
  fails with `CAPACITY`. `Node.free(i)` returns slot `i`. `Node.live?(i)`
  answers whether it is allocated.
- The free list and an occupancy bit per slot are generated `state` buffers,
  owned by one context, as 0035's frames are.

**The owner's question: what a misuse does.**

1. As Goose: no occupancy check. A double free puts a slot on the free list
   twice, and two later `alloc`s answer the same slot. Memory stays safe;
   the program's data does not.
2. **Recommended:** an occupancy bit per slot. A double free and a `free` of
   a slot never allocated are `BOUNDS`, as every misuse of a fiber slot is in
   0035. A stale index to a reused slot still reads that slot's new contents.
3. A generation count per slot carried in each handle, so a stale handle is
   `BOUNDS` too. Handles then become two numbers.

**Predictions.** The rewrite needs no kernel change, as 0035's did not:
`CAPACITY` comes from `core_fail(:capacity)`, and `BOUNDS` from a checked
access one past the slot range.

**Checks.** Accept fixtures that allocate, free and reuse; a planted
exhaustion at `max + 1` that fails with `CAPACITY` at the same call each run;
a planted double free and a free of a slot never allocated, each `BOUNDS`;
a pool reached from two contexts, refused.

**Gated by** the expected set: `app-host`, `app-contract`, `core-report`,
`fiber-core` and `core-run`.

## Validation

- Each stage is accepted on its own checks above, run once at its end through
  the suites `tools/test/affected.rb --base origin/main` selects, with every
  figure printed by a command.
- Controls plant their own failing input in a copy, never borrow a row that
  progress would remove.
- No oracle runs unless the owner instructs: comparisons with CRuby, and any
  byte comparison of an old build with a new one, are oracles.
- DOOM's CORE entries still admit and build after each stage; nothing in this
  record changes a construct they use.

## Consequences

- Stage 1 changes the subset refusal table and its coverage fixtures, and
  gives 0010 a second loop form to derive bounds for.
- Stage 2 adds a declaration (`scratch`), a region in the image and a line in
  the resource report. It does not change 0007's statuses, the buffer
  contract, or what a lent buffer means.
- Stage 3 adds a generated module, as 0035 did, and no kernel change.
- Root inference beyond stage 2's rule (a callee returning a reference into
  its argument, specialized per root), per-call-site blocks for methods that
  `yield`, and verified decoding of variable-structure network formats remain
  open; each needs its own proposal.
- 0040 is on an unmerged branch, so this record takes the next free number.
