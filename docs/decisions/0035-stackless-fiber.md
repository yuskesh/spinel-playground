# 0035: Stackless Fiber where a stack cannot be switched

- Date: 2026-11-11
- Status: Accepted by the owner on 2026-11-11.
- Scope: `Fiber` and `Enumerator.new` on the hosted WASM route
  (`tools/wasm/spinel-wasm`) and under CORE (freestanding and Zephyr). The
  native hosted route is unchanged.

## Context

Upstream Spinel implements `Fiber` as stackful coroutines: each fiber gets an
`mmap`ed C stack and a switch swaps the stack pointer (`lib/sp_fiber.c`). Two of
our targets cannot do that.

- **WASM.** The engine's call stack is not addressable, so the stack pointer
  cannot be swapped. Upstream raises `FiberError` at `Fiber.new` on
  `wasm32-wasi`, and `tools/wasm/spinel-wasm` refuses `Fiber` by name.
- **CORE.** There is no allocation, so there is no per-fiber stack to map.

The ways to keep stackful semantics on WASM were measured on 2026-11-11 with
minimal C, wat and Go programs (ns per resume plus yield, yield at depth 1):

| Method | Result | Limit |
|---|---|---|
| Stackless state machine | 1.7–2.3 | yield only where the transform reaches |
| Stack Switching (wasmtime 50.0.1) | 11.0 | Phase 3; not shipped on Workers or Fastly; LLVM cannot emit it |
| Asyncify (binaryen 133) | 20.7–22.3, growing with depth | cannot process our `try_table` modules (Flatten aborts on `hello-http`) |
| Go's resume points (Go 1.27.3) | 135.9 | every call pays, about 2x on code that never switches |
| JSPI (node 24.20.0) | 308.2 | JS hosts only; every switch passes through a Promise |

Native stackful switching measured 14.9, so stackful is not slow in itself. It
is slow on WASM today because every available way around the hidden stack is
indirect.

## Options

1. **Stackless now.** The compiler turns a fiber body into a state machine whose
   locals live in a frame object. It runs on every target with no engine
   feature. It limits where `Fiber.yield` may appear.
2. **JSPI now.** Keeps the semantics on Workers and node only, at about 300 ns
   per switch, and leaves Fastly and CORE without `Fiber`.
3. **Wait for Stack Switching.** Keeps the semantics everywhere it ships, but
   nothing ships today.

## Decision

Option 1. Stackful `Fiber` on WASM is revisited when Stack Switching is enabled
by default on both Cloudflare Workers and Fastly Compute. CORE keeps the
stackless form even then.

### Where the transform runs

The transform is a source-to-source rewrite on the Extended side, before the
pinned Spinel compiles the program. Vendor code is not changed.

- It reads the pristine parse and the analysis through `spinel-typedump`
  (`ast`, `nodes`, `methods`, `locals`) to resolve which method a call reaches.
  It does not build a new Ruby IR or a general AST visitor. It rewrites only the
  fiber bodies and the methods defined below.
- The rewritten program is ordinary Ruby that Spinel already compiles. Each
  transformed body becomes a step lambda. The frame is the lambda's closure:
  the body's locals are hoisted into an enclosing lambda, so they persist from
  one step to the next. The step dispatches on a state number with `case`.
  A step reports through one global whether it yielded or finished. A small
  `SpinelFiber` class holds the step and implements `resume` and `alive?`.

### What may yield

- **A yielding method** is a method whose body contains `Fiber.yield`, or that
  calls a yielding method. The set is the closure over call sites that the
  analysis resolves to a single target or to a set of targets.
- Each yielding method also gets a factory for its frame. A call to it from a transformed
  body creates the callee's frame and steps it until it completes. A yield
  inside the callee suspends the whole chain, in the way nested futures do in
  Rust's `async`.
- `Enumerator.new { |y| ... }` with `y << v` or `y.yield v` is the same
  transform. `#next`, `#peek` and `#rewind` drive its frame.
- **Refused, with a diagnostic that names the call site:**
  - a call whose targets cannot be resolved and could reach a yield (`send`,
    `method_missing`, a proc stored and called later);
  - a yield inside a block passed to a method that is not transformed. The
    exceptions are `while`, `until`, `loop`, `Integer#times`, `Integer#upto`,
    `Range#each` and `Array#each`, which the rewrite turns into explicit loops;
  - `Fiber#transfer`, `Fiber#raise`, `Fiber#kill`, `Fiber.current`, fiber
    storage, and `Fiber.set_scheduler`.

### Semantics kept

- The values passed by `resume` and `Fiber.yield` in both directions.
- `alive?`.
- `FiberError` when a finished fiber is resumed.
- An exception that escapes a fiber body propagates to the `resume` that
  stepped it. `ensure` runs when the body leaves its scope normally or by
  exception. A fiber that is never resumed again does not run its `ensure`.
  CRuby does not promise one either.

### CORE

- A fiber is declared with an inert method, as other declarations are:
  `fiber_def :reader, max: 2`.
- Frames are allocated statically, `max` of each kind. Their size is known at
  build time and is reported with the build's resource report.

**Stage 2 decision (owner, 2026-11-11): the slot API.** Under CORE an entry
does one release's work and only `state` buffers outlive it
([decision 0014](0014-core-applications-on-zephyr.md) §2, §4), so a fiber is
named by its kind and a slot number, not held as an object.

```ruby
fiber_def :reader, max: 2          # two reader frames, allocated statically

def reader(limit)                  # the body: an ordinary method with Fiber.yield
  i = 0
  while i < limit
    Fiber.yield i
    i += 1
  end
end

every_ms 20, :tick
def tick(out)
  Reader.start(0, 5) unless Reader.alive?(0)
  out[0] = Reader.resume(0, 0)     # one step per release
end
```

- `fiber_def :name, max: n` declares the kind. The body is the top-level
  method `name`. The generated module (`Reader` for `:reader`) has
  `start(slot, args...)`, `resume(slot, value)` and `alive?(slot)`. A slot is
  an integer from 0 to `n - 1`, so it can be a constant or live in a `state`.
- **Frames.** Each slot's frame holds the state number and the body's locals,
  as generated static storage that the application does not name. Locals,
  arguments, and the values passed by `resume` and `Fiber.yield` must be CORE
  scalars. Their element types come from the analysis (`spinel-typedump`'s
  `locals` face). A buffer is reached through a `state` parameter, never
  stored in a frame.
- **Failures are 0014's statuses.** No status is added, and every misuse is
  `BOUNDS` (owner, 2026-11-11): a slot that is not live is outside the live
  slots. [Decision 0007](0007-doom-core-preparation.md) lets application code
  request only `core_fail(:capacity)`, so the generated code reaches `BOUNDS`
  through an ordinary checked buffer access, and neither the kernel nor 0007
  changes.
  - `resume` of a slot that has not started or has finished is `BOUNDS`.
  - A slot outside `0 ... n` is `BOUNDS`.
  - `start` on a live slot is `BOUNDS`.
- **One owning context.** All calls to one kind's `start`, `resume` and
  `alive?` must come from one context, as for a device (0014 §4). Calls from
  two contexts are refused at build time.
- **Per-step bound.** 0014 needs a derived bound for one release's work. Under
  CORE, every loop that contains a suspension must suspend on every path
  through an iteration. A loop that can complete an iteration without
  suspending is refused, with its location. A step then visits each state at
  most once, so its bound is the number of states times the bounds of the
  straight-line code between them. No new analysis is needed. The WASM route
  does not have this rule.
- **Host reference.** Under CRuby the board simulator implements the generated
  module with real `Fiber`s, so the application runs unchanged (0014 §10).
- `Fiber.new`, `Fiber#resume` and `Fiber.yield` outside a `fiber_def` body are
  refused under CORE.

### Thread

Unchanged.
- The native hosted route keeps upstream's threads.
- The WASM route keeps refusing `Thread`, `Mutex`, `Queue` and
  `ConditionVariable`.
- CORE keeps 0014's thread and interrupt entries.

A cooperative stackless `Thread`, which would treat blocking calls such as
`sleep` and `Queue#pop` as suspension points in the same rewrite, is possible
later and would need its own decision.

## Stages

1. The hosted WASM route: fiber bodies, yielding methods, and the loop rewrites.
2. CORE: `fiber_def` and static frames, on the Zephyr QEMU lane.
3. `Enumerator.new` with external iteration. External iteration over runtime
   enumerators such as `[1, 2, 3].each.next` is examined separately.

## Validation

- **Stage 1.** A new `tests/fiber/` runs on node and wasmtime:
  - accepted programs, with expected output written by hand, including yields
    from nested yielding methods, values in both directions, and an exception
    crossing `resume`;
  - every refusal above, each checked for its diagnostic.
  - No oracle is used.
- **Stage 2.** The same accepted programs that fit CORE, built with `fiber_def`,
  with the frame sizes in the resource report.
- **Every stage.** The native hosted route's existing Fiber tests stay
  unchanged.

## Stage 1 as implemented

`tools/fiber/spinel-fiber-rewrite` (Ruby, Prism) does the rewrite;
`tools/wasm/spinel-wasm` runs it on an entry file that names `Fiber`. The
limits are listed in [tools/wasm/README.md](../../tools/wasm/README.md#stackless-fiber).
Stage 1 refuses some forms beyond the list above, each with a diagnostic, and
each can be lifted later without changing what is accepted now. The owner
accepted them on 2026-11-11.

- a suspension inside `begin` with `rescue` or `ensure`;
- a suspension in an expression, behind anything with an effect that Ruby
  evaluates first in the same statement, or one that Ruby evaluates only
  under a condition;
- a yielding method that is not a top-level `def` called without a receiver.
  Resolution is by name in the entry file; `spinel-typedump` is not used yet.
  Lifted in stage 3, see "Typed receivers" below;
- a `Fiber` in a required file, which keeps the existing symbol-scan refusal.

Lifted after the first merge: `case`/`when` and `case`/`in`, `Fiber.new` inside
a fiber body or a yielding method, and suspensions inside expressions and in
`if` and `while` conditions. The rewrite moves such a suspension ahead of
the rest of its statement, which keeps Ruby's order only when the parts
evaluated before it have no effect.

When the program defines no `resume` or `alive?` of its own, SpinelFiber's
methods have reserved names and every `.resume` / `.alive?` call is renamed. A
fiber reached through a boxed value would otherwise get Spinel's generic
dispatch, which also adds an arm for the runtime Fiber that wasm cannot link.
The program is read through `require_relative` and through `require` that the
`-I` roots resolve. If a `require` cannot be followed, nothing is renamed, and
a fiber reached through a boxed value is then refused at build time.

How much Ruby the rules refuse was measured on 2026-11-11 against upstream's own
test programs at the pin (`vendor/spinel/test/*.rb`, 116 files calling
`Fiber.new`). Those programs exercise edge cases on purpose, so they are a
harsh sample. At the first merge the rewrite accepted 52 files. 42 used
something this decision refuses (`transfer`, `Fiber.current`, storage,
`Fiber#raise`, `kill`, the scheduler) or other Fiber class API. 22 were
refused only by stage-1 limits, 2 of them by the block rule. 22 of the 52
accepted files built for wasm. The other 30 were refused for `Thread` or
external `Enumerator` iteration, and none for Fiber.

After the lifts the rewrite accepts 55 files. 42 are still refused for
what this decision refuses, and 19 only by stage-1 limits: 10 by
`rescue`/`ensure` and 2 by the block rule. 22 of the 55 build for wasm.
The other 33 are refused for `Thread` (24), `Enumerator#next` (8) or
`Enumerator.new` (1), and none for Fiber. No output was compared with
upstream's expected files, because that comparison is an oracle.

## Stage 2 as implemented

`tools/fiber/spinel-fiber-core` (Ruby, Prism) rewrites an application that
declares `fiber_def` into ordinary CORE Ruby. `spinel-core-app package`,
`admit` and `build` run it first and work on the result; `run-host` runs the
original on `spinel/core.rb`'s module over real `Fiber`s.

- Each kind becomes one `state :sfb_KIND_FIELD, :i32, max` per frame field:
  the state number (`st`, 0 when the slot is not live) and one field per body
  local and argument. The body becomes `sfb_KIND_start`, `sfb_KIND_resume`
  and `sfb_KIND_alive`, using the stage-1 lowering with frame elements in place
  of closure cells. Each `Reader.*` call is replaced by a call to them, and
  the frame states are passed as parameters to every entry and helper
  that reaches the kind, transitively through receiver-less calls.
- `resume` steps a dispatcher loop over the states, bounded by their number.
  A misuse writes one element past the slot range, which the kernel's
  checked access turns into `BOUNDS`.
- The rewrite prints one line per kind with its frame count, fields, states
  and bytes, as `fiber_def :reader: 2 frame(s) x 4 i32 field(s) (st, limit,
  i, got), 9 states, 32 bytes of state`. `build` shows it in its log.
- Refused, each with a diagnostic at its position: a loop that can finish an
  iteration without suspending (the per-step bound), `Fiber.new` and other
  `Fiber.*` calls, `Fiber.yield` outside a `fiber_def` body, a body called
  directly or recursively, a body that drives a fiber, a body with
  parameters other than required positional ones, the wrong number of
  arguments to the module, `.resume` on an object, and a kind reached from
  entries of two contexts.

Stage 2 has these limits, each of which can be lifted later:

- a `fiber_def` body cannot call a yielding method, and `Fiber.yield` may
  appear only in the body itself;
- every frame field is an i32, whatever the local's type;
  `spinel-typedump`'s element types are not read yet. No value is changed
  silently. Every board `spinel-core-app` builds for is a 32-bit Thumb
  target whose integer arithmetic is 32-bit
  ([decision 0019](0019-target-integer-width.md)), so a value outside i32
  fails with `ARITHMETIC` where it is computed, before a frame field could
  hold it. A store into a frame field is range-checked like every `i32`
  store ([decision 0007](0007-doom-core-preparation.md)), so a target
  with wider arithmetic would get `ARITHMETIC` at the store, never a
  truncated value. The host reference uses CRuby's Integer and keeps such a
  value, as it does without a fiber;
- a refusal from the kernel or the application checks (not from the rewrite)
  names the rewritten file in a temporary directory, and its line numbers are
  those of the rewritten file.

`sh tests/fiber/core.sh` checks the refusals and admits six applications
through the kernel. It runs five of them on the host runner:
- `reader`'s values against hand-written ones;
- `limits`, which carries 2147483647 and -2147483648 across a suspension,
  against hand-written ones;
- three misuses (`resume` of a slot never started, a slot outside
  `0 ... max`, `start` on a live slot), each as its declared `BOUNDS`.

With the Zephyr environment it builds for `mps2_an521` and runs under QEMU:
- `reader`, with the frame report checked against the linked image's
  `.bss`, and `limits`, each against the same values;
- the never-started misuse, built with `--failure-sites`, which must fail
  with `BOUNDS`;
- `u32wide`, which tries to pass a `:u32` value of 2^31 through a fiber and
  must fail with `ARITHMETIC` at the `+` that makes it.

The stage-1 programs print strings, which CORE has no, so the CORE
applications are new programs, not copies of them.

## Stage 3 as implemented

`tools/fiber/spinel-fiber-rewrite` also rewrites `Enumerator.new { |y| ... }`
in the entry file, and `spinel-wasm` runs it when the entry file names
`Fiber` or `Enumerator`. The block is lowered like a fiber body, with
`y << v` and `y.yield v` as the suspensions, into a `SpinelEnum`.
- `next` and `peek` drive the external position and raise `StopIteration`
  at the end. `rewind` starts again.
- A lowered `loop` ends at `StopIteration`, as `Kernel#loop` does. The stage-1
  fiber bodies get this as well.
- Internal iteration (`each`, `to_a`, `first`, `take`, `take_while`,
  `find`, `include?`, `map`, `select`, `reject`, `filter_map`,
  `each_with_index`, `with_index`, `with_object`, `each_with_object`) runs a
  fresh frame. It stops early when its block breaks, even on an endless
  enumerator, and does not move the external position.
- The remaining `Enumerable` methods are Spinel's. They read the whole
  sequence first, so on an endless enumerator they do not return.
- `lazy`, `to_set` and the other methods that Spinel routes through its
  runtime `Enumerator` are refused by the symbol scan, as is external
  iteration over a runtime enumerator (`[1, 2].each.next`).
- The yielder may only receive `<<` or `yield`, one value at a time, and
  `Enumerator.new` with a size argument is refused. CORE has no
  `Enumerator.new` yet.

**A stage-1 defect, fixed here.** Spinel gives the locals a lambda captures
one cell per activation of the method around it, not one per call of the
lambda. Measured on 2026-11-11, a lambda that returns a counter lambda,
called twice in one method, gives two counters that share one count. Stage 1
built each fiber's frame with such a lambda, so two fibers made by one site
in one activation shared their frame. For example, `Fiber.new` inside
`2.times do ... end` gave the second fiber the first one's position, with no
error. The stage-1 tests made each fiber once per activation and did not see
it.
- A site that one activation can run more than once now builds its frame in
  a method of its own. That covers a site inside a loop, a block, a
  lambda or a `begin` whose `rescue` retries, and every `Enumerator.new`
  site, because `rewind` and internal
  iteration build the frame again.
- The locals of the surrounding scope that the block uses are passed in,
  copied when the frame is made. The rewrite refuses the cases where Ruby's
  block would see a later assignment instead: the block assigns one, or the
  scope assigns one after the site, in a loop, block or retried `begin`
  around it, or inside any block or lambda before it, since that block may
  be stored and called later.
- A site that runs once per activation keeps the stage-1 form.

`tests/fiber/run.sh` adds `repeat.rb`, which makes fibers in a block, in a
`while` loop, in a lambda called twice and in a retried `begin`, and three
Enumerator programs.
Together they cover `next`, `peek` and `rewind`, the `StopIteration` end,
`loop` over `next` both inside an enumerator and inside a fiber, an exception
through `next`, enumerators in a method and in a class, internal iteration
that breaks out of an endless enumerator, and eleven refusals.

Measured on 2026-11-11 against upstream's test programs at the pin, without
comparing any output:
- **Files calling `Enumerator.new` (62).** The rewrite accepts 30. Of those,
  12 build for wasm. The other 18 are refused by the symbol scan, 2 for
  `Thread` and 16 for a runtime `Enumerator`. That count does not separate
  `cycle`, `each` or `lazy` without a block from an `Enumerable` method that
  Spinel routes through the runtime `Enumerator`.
- **Files calling `Fiber.new` (116).** The rewrite now accepts 47, against
  55 before:
  - 4 are refused because they also use `Enumerator.new` in a way that
    stage 3 refuses. None of them built before.
  - 4 are refused by the copy rule. 1 of them built before:
    `ensure_in_proc_body_keeps_loop_ensure`. Its fiber finishes before the
    next assignment, so it was not affected; the rule cannot see that.
  - 23 build, against 22 before. The other 24 are refused, for `Thread` (22)
    and a runtime `Enumerator#next` (2), and none for Fiber.

## Typed receivers

On 2026-11-11 the rewrite started reading the `nodes` face of
`spinel-typedump` (`--typedump PATH` or `SPINEL_TYPEDUMP`). A node's type is
keyed by its kind, line and column. A key that two nodes share with
different types has no type. `spinel-wasm` passes the reader when it is
built. Without one, the forms below stay refused, and the refusal names the
missing reader. CORE does not read it.
- **`each` over a variable.** A suspending `each` whose receiver is typed
  as an Array is lowered like one on a literal, reading the length at every
  step as `Array#each` does. A receiver typed as an Integer Range is walked
  from its `begin`, `end` and `exclude_end?`, read once, so an endless range
  runs until the block leaves it and nothing is materialized. Another Range
  (`str_range`) or a `poly` receiver is refused, and the refusal names the
  type.
- **Yielding instance methods.** An instance method of a top-level class
  that reaches `Fiber.yield` gets a `__sf_mk_NAME` factory beside it in the
  class, and a call to it from a fiber body steps that factory's lambda,
  which keeps `self`.
  - A call without a receiver or through `self` resolves in the class
    around it, then its superclasses, then the top-level `def`s.
  - Any other receiver must be a local variable that the analysis types as
    an instance of a top-level class. The call goes through the receiver,
    so Ruby picks the override at run time. Every override must therefore
    yield exactly when the method it overrides does, or the rewrite refuses
    it.
  - Refused: a receiver typed `poly` or not typed, an instance variable or
    other expression as receiver, a yielding method in a module or a
    singleton class, one defined twice in a class, and one reached through
    `send` or `method`.
  - The override check sees only the `def`s of top-level classes. Anything
    else that could put a method of a yielding name in front of the yielding
    one on a receiver is refused. That covers a `def` of the name outside a
    top-level class (in a module, a nested class or a singleton), and
    `define_method`, `attr_*`, `alias` and `alias_method` making the name or
    a computed one. It also covers `include` or `prepend` in a class that
    defines or inherits a yielding method, `extend` anywhere, and
    `Class.new` on such a class.

The same change fixes a stage-1 defect. A yielding method written as an
endless `def` (`def t = Fiber.yield(1)`) lost its factory, because the
insertion after the `def` fell at the end of the rewritten `Fiber.yield` and
was dropped. The rewrite then exited 0, and Spinel refused the call to the
missing `__sf_mk_t`. Nothing ran wrongly.

A `retry` in a plain `begin` inside a `rescue` clause retries the outer
`begin`. The stage-3 rule missed that shape and now counts it.

`tests/fiber/run.sh` section 4 builds `typed/each_var.rb` and
`typed/methods.rb` with the reader and runs them, and checks three refusals
that need the reader. Without the reader, it checks that both programs are
refused naming it. It also adds `accept/endless.rb` and nine refusals that do
not depend on the reader: an override that does not yield, a module method
that yields, the nested `retry`, and six hidden overrides (`*_override.rb`).

Measured on 2026-11-11 against upstream's test programs at the pin, without
comparing any output, with and without the reader:
- **`Fiber.new` (116 files).** The rewrite accepts 49, against 47 before.
  The reader adds none. The two new ones, `bundle_class_09` and
  `fiber_ivar_cycle_collect`, call yielding instance methods through `self`.
  The second also uses an endless `def`.
- **Builds for wasm.** 25 build, against 23 before: the 23 that built before
  and the two new ones.
- **`Enumerator.new` (62 files).** Unchanged: 30 accepted, 12 build.

## CORE Enumerator (`enum_def`)

The owner chose this form on 2026-11-11, out of three: no new form (use
`fiber_def`), `enum_def`, or no `Enumerator` under CORE. `Enumerator.new`
makes an object, which CORE has none of. With `fiber_def`, a caller cannot
tell whether the next `resume` gives a value or ends the body, and the body's
return value looks like one more element.

```ruby
enum_def :evens, max: 1
every_ms 10, :tick

def evens(y, limit)
  i = 0
  while i < limit
    y << i
    i += 2
  end
end

def tick(frame)
  Evens.start(0, 5) unless Evens.alive?(0)
  v = -1
  if Evens.next?(0)
    v = Evens.peek(0) * 100 + Evens.next(0)
  end
  # ... v goes out as a frame: 0, 202, 404, -1 (the end), then 0 again
end
```

- The body takes the yielder as its first parameter. It suspends at
  `y << v` and `y.yield v`, each a statement of its own, since CORE has no
  value for them. The yielder may receive nothing else, is not passed on and
  is never assigned. `Fiber.yield` in the body is refused.
- The frame is `fiber_def`'s with two more fields: `has` and `buf`, one
  buffered value. The module has these calls:
  - `start(slot, args...)`;
  - `next?(slot)` runs at most one step, when nothing is buffered and the body
    has not ended, and answers whether a value is buffered;
  - `next(slot)` and `peek(slot)` return the buffered value, after that step if
    needed, and `next` consumes it;
  - `alive?(slot)` is true while the body has not ended.
- Misuse is `BOUNDS`, as for `fiber_def`. That covers `next` or `peek` with
  nothing left, where Ruby raises `StopIteration`, a slot outside `0 ... n`,
  and `start` on a live slot. A slot restarts with `start` after its end.
  There is no `rewind`, and no `each`, `to_a`, `map` or `size`, since they
  take blocks or allocate.
- One owning context and the per-step bound apply as for `fiber_def`. A
  `next?`, `next` or `peek` runs at most one step.
- The host reference runs each slot on a real `Enumerator`, so the
  application runs unchanged under CRuby.

The same change fixes a stage-2 defect. A body local named `st` shared the
frame field that holds the state number. An assignment to it changed the
state silently. The rewrite now refuses locals named `st`, as well as `has`
and `buf` in an `enum_def` body and names of the form `t`, a letter and
digits, which its temporaries use.

`tests/fiber/core.sh` adds two fixtures:
- `evens`, with next?, peek, next, the end and a restart, on the host and
  under QEMU;
- `pastend`, `next` after the last value, `BOUNDS` on the host and under
  QEMU.

It also adds nine refusals, one of them the yielder inside a lambda.

## Open items

- Answered on 2026-11-11: `spinel-typedump` needs no call-target face for
  stage 3. Its `nodes` face gives each receiver node its type (`obj_Gen`,
  `enumerator`, `int`, `fiber`) through locals, instance variables,
  parameters and method returns, and `methods` gives each method its class.
  A receiver of mixed type is `poly` with no member set, so a call on one
  would be resolved by name over every class that defines the method. That
  is safe, being a superset. `enumerator` does not tell `Enumerator.new` from
  a runtime enumerator. Stage 3 does not need it to, because a `SpinelEnum`
  is its own class. The rewrite now reads it for two lifts; see "Typed
  receivers".
