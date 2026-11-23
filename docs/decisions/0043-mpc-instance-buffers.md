# 0043: Buffers that live across calls in an MPC plugin: owned by the plugin instance

- Date: 2026-11-14
- Status: Accepted by the owner on 2026-11-14 (relayed by the bpf-mlir coordinator): **option A**
  (declared buffers as extra boundary buffer pairs, owned by the plugin
  instance). **Stage 1 starts now**, carried by the coordinator on
  `feat/mpc-plugin-sdk` (its work in progress is committed there). **Stages 2
  and 3 start only after the stage-1 report** to the owner. The text below was
  written as a proposal and is unchanged except for this status and the
  correction in the next paragraph.
- Correction (2026-11-14, owner's relay): there is no `tests/mpc/drive.c` at
  `2c972bdd`; the task's mention of it was mistaken. Only `tests/mpc/run.sh`'s
  `nm -u` check exists. So the no-allocation check is **part of stage 1**, not
  something already in place: stage 1 adds the check on the C++ side (a
  `malloc` interposer around `process` in the host-simulator run counting zero
  calls between the first and last block) beside the existing undefined-symbol
  check, and both must pass with buffers declared.
- Spelling: since [decision 0045](0045-buffer-classes.md) a buffer is written
  `Core::Buffer` / `Core::Table`, and the Array spelling shown here is refused.
  This record keeps its text.
- Scope: `tools/mpc` (`spinel-mpc`, the generated plugin class), and what the
  freestanding route must already do for it. It covers declared buffers owned by
  one plugin instance, read-only tables, block processing, `MPC::Effect` and
  stereo, and the memory contract.

## Context

### Where 0040 leaves us

Decision 0040 (`docs/decisions/0040-mpc-plugins-without-the-runtime.md`, on branch
`feat/mpc-plugin-sdk` and not yet on main) chose the runtime-free route:
`spinel-mpc build` rewrites the instrument class into `freestanding_def`
functions, and the generated C++ plugin owns the instance's state and calls
`sample` once per frame. This record builds on it and does not reopen it: no
Spinel runtime, no allocation on the audio thread, a trap ends the instance and
not the process.

What 0040 says it cannot do, and this record is about:

- "No state outside the instance: no constants, globals or tables. A wavetable
  would need a buffer the plugin owns."
- "A freestanding helper cannot take a buffer from its caller (inference types
  the parameter as an Array), so the loop would need `sample`'s body inlined".
  The plugin therefore calls `sample` once per frame.
- "Instruments only, one output value per frame."

### What already exists (read from the tree, not run for this record)

- **State is two arrays.** `spinel-mpc` gives each instance variable an element
  of `ist` (Integer, `int32_t`) or `fst` (Float, `double`; the parameters
  follow). Each entry it generates is
  `freestanding_def :sample, params: [[:i32_buf, :inout], :len, [:f64_buf, :inout], :len, ...], returns: ...`
  (`tools/mpc/spinel-mpc`, `kernel_rb`). The C++ class owns
  `int32_t ist_[N]` and `double fst_[N]` as members, so the instance object
  holds all its state and the audio thread allocates nothing.
- **A buffer parameter is already a boundary feature.** From
  `tools/freestanding/spinel/freestanding.rb` (E077): an entry takes
  `[:<elem>_buf, :in | :out | :inout]` followed by `:len`; the kernel may index
  it (`b[i]`, `b[i] = v`) and nothing else; a store through an `:in` buffer
  does not compile; an index outside `0...len` traps with code 4; a NULL buffer
  (5) and a negative length (6) trap at the entry. `returns:` is a scalar only.
  There is no struct. Element types include `:f32` and `:f64`, so a Float
  buffer needs no new compiler work.
- **0041 stage 1** admits `Integer#times`, `upto`, `downto`, `each` and
  `each_with_index` with a literal block on "a `freestanding_def` buffer
  parameter" among others. 0041 stage 2's data stack is method-scoped and
  cannot hold a delay line across calls; its "Later" list names
  `freestanding_def` and `spinel-mpc` as further routes. 0041 stage 3's slot
  pool is for CORE's `state` buffers (0035's pattern).
- **0042** (merged to main as `8f4ff32d`) adds bitwise, shift and `abs` to every
  route, with named wrapping and unsigned forms. A delay line indexed by
  `pos & mask` or a phase accumulator that wraps is written with it.
- **0014 §2**: `state name, element, count` is the CORE application form of the
  same idea (storage owned by generated glue, zero-initialised, aligned to the
  element size, an access past the count is `BOUNDS`). 0007 fixes the buffer
  boundary (borrowed, count passed with each buffer, overlap rules). 0010's
  clarification of 2026-09-18 says a finite capacity is a contract: every
  consuming site checks it, the result below it is unchanged, exhaustion fails
  deterministically and nothing is written past the end.

### What I did not find or measure

- No `drive.c` exists in `tests/mpc` at `2c972bdd`. The "nothing to allocate
  with" check I can see is `tests/mpc/run.sh`'s `nm -u` over `kernel.o`: the
  object may need only C math functions and `spinel_trap`.
- Nothing here ran on an MPC. The SDK's `ProcessContext` was read only in
  outline: whether `inputs` and `outputs` may alias, and when the sample rate
  becomes known to an instance, are open questions below.
- I did not re-measure 0040's "inference types the parameter as an Array" claim
  or the "Float multiplied in a `while` loop" limit; I take both from 0040.
- The coordinator has uncommitted buffer work on `feat/mpc-plugin-sdk`, waiting for the
  owner's commit word. I have not read its code; the next section is the coordinator's
  own summary of it (2026-11-14), and I cite it as work in progress, not as
  something I checked.

### The coordinator's work in progress (as reported, unverified here)

- **Declared buffers** are written in `initialize`: `@x = Array.new(size,
  literal)` with an Integer literal size of 1 to 2**24 is a buffer, `i32` or
  `f64` by the literal. Each entry takes it as one more buffer argument `b_x`
  with a length `n_x`; `@x.size` is `n_x`; `@x[i] op= v` is written out as
  `b_x[i] = b_x[i] op (v)`.
- **Owner:** the plugin, with vectors made with the instance, never on the audio
  thread. A negative or out-of-range index traps with code 4. Buffers cannot be
  passed to a helper; there are no constants or globals.
- **Setup:** the statements of `initialize` after its assignments become a setup
  function that the plugin calls once per instance (the example fills a noise
  table).
- **Not done:** block-wise `process`, `MPC::Effect`; still `sample` once per
  frame, instruments only, one output per frame. Example `examples/mpc-spinel-pluck`
  (an 8-voice Karplus-Strong; the delay lines share one `f64` buffer `@line`).
  Also added to the freestanding subset: Float `to_i`, `floor`, `ceil` and
  `to_f`, trapping with code 3 when the value does not fit.

So the instance-owned buffer (option A below, and sections 1 and 2) is already
being built the way this record recommends. The parts of this record that are
not in that work are: read-only tables checked by direction, block `process`,
`MPC::Effect` and stereo, the memory report, and the checks. The sections
below keep the full proposal so it stands alone; where the coordinator's form differs
(the declaration syntax, the setup method), section 1 and 2 say which form is
recommended and why.

## Options

The question is how a plugin author declares a buffer that survives between
calls, who owns it, and how the rewritten Ruby reads and writes it.

### A. Declared buffers become more boundary buffers (recommended)

The class declares a buffer; `spinel-mpc` generates one more
`[:f64_buf, :inout], :len` (or `:i32_buf`, `:f32_buf`) pair on every entry that
uses it, and the generated C++ class owns the storage as a member, as it owns
`ist_` and `fst_`. The Ruby reads `@name[i]`, which the rewrite turns into the
parameter, indexed.

- Needs no compiler change: the boundary, the direction check, the range trap
  and the Float element are there (above).
- Same ownership as 0040's state: the instance, so two instances never share
  one.
- Cost: every entry that touches a buffer takes more parameters, so a
  freestanding function with three buffers has eleven or more. They are
  generated, not written.

### B. One packed buffer with offsets

Allocate a single `fst`-like arena and have the rewrite turn each declared
buffer into an offset range of it (`fst[BASE + i]`). One extra parameter pair
instead of many.

- The range check then guards the whole arena, not a buffer: a bad index into
  the delay line can read the wavetable and trap code 4 never fires. That
  breaks 0010's "nothing written past the end" per buffer. Rejected unless the
  rewrite emits its own per-buffer check, which duplicates the boundary's.

### C. Make the freestanding route allocate (a static array in the object)

`kernel.o` would carry `static double wave[2048]` in `.bss`. Rejected: the
object is shared by every instance of the plugin in the MPC process, so the
buffer is global state and the instance is no longer the owner; a plugin loaded
twice would mix two instruments' delay lines. It also reintroduces "no state
outside the instance" as a hidden exception.

### D. Share the full runtime's arrays

Rejected by 0040: the runtime is why 0040 exists.

**Recommendation: A**, with B kept as the answer if the parameter count ever
matters, and C refused for the ownership reason.

## Decision (proposed)

### 1. The declaration and the owner

**Form.** The coordinator's declaration in `initialize` (`@x = Array.new(n, literal)`)
reads as ordinary Ruby and runs under CRuby unchanged, which is a real
advantage over a new keyword: the class still loads and sounds in plain Ruby.
This record therefore recommends keeping it for buffers. What it adds is a
read-only marker for tables (section 2), which needs a second spelling. The
class-level lines below are the alternative form (the clearest to read, but a
new keyword that CRuby does not know); the rest of the section applies to both.

Two class-level lines, read from the source as `param` and `info` are, with
literal arguments only:

```ruby
class Echo < MPC::Effect
  info name: "Spinel Echo", vendor: "spinel-extended", uid: "SpEc"
  param :mix, "Mix", 0..100, default: 30

  buffer :line,  :float, 48_000     # element type, count: instance-owned, zero at start
  table  :shape, :float, 1_024      # read-only after `prepare` (section 2)

  def initialize
    @pos = 0
  end
  ...
end
```

- **Element types:** `:float` (the boundary's `f64`; what `fst` is today),
  `:float32` (`f32`; half the memory for a delay line) and `:int` (`i32`, as
  `ist`). Anything else is refused with the source line. The count is an
  Integer literal greater than zero.
- **The owner is the plugin instance.** The generated C++ class holds
  `double line_[48000]` (or a `std::array`) as a member, next to `ist_` and
  `fst_`; the host allocates the instance on a non-audio thread; the buffer is
  zero when the instance starts and again when it is reset. This is Goose's
  rule (an owner outlives everything that borrows from it) with the instance as
  the single root and nothing inferred. It is also 0014 §2's `state` with the
  instance in the place of the generated application glue.
- **Rewriting.** `@line[i]` becomes `line[i]` on a buffer parameter
  `line, line_n` added to every entry that mentions `@line`; `@line[i] = x`
  likewise; `@line.size` becomes the literal count. Any other use of `@line`
  (assigning it, passing it, returning it, `@line.each`, `[]=` with a range,
  `push`) is refused with the line, as 0040 refuses `nil` instance variables.
  A helper that mentions a buffer is refused, as one that mentions state is:
  helpers cannot take buffers (0040's finding), so a buffer is reached from the
  entries only. (If 0041 stage 1 is extended to these entries, `@line.each` can
  be admitted by lowering to a counted loop; see 3.)
- **Bounds.** The boundary's range check is the contract: an index outside
  `0...count` traps with code 4 and nothing is written outside the buffer. On
  this route that means the instance goes silent (0040), which is the
  freestanding spelling of 0007/0014's `BOUNDS`. `bounds: :unchecked` is not
  offered (0007 rejects it, and a delay line indexed by a modular position is
  the case where a mistake would be silent).
- **Index wrapping** is the author's, with 0042's operators:
  `@pos = (@pos + 1) & 48_127` needs a power-of-two count, so
  `buffer :line, :float, 65_536` is the natural choice; the Integer `%` works
  for any count. Integers are 32 bits on the arm32 units (0040), enough for
  every count in this record.

### 2. Read-only tables

A wavetable is a `table`: filled once, then only read.

- **Filling.** The coordinator's setup (the statements after `initialize`'s
  assignments, called once per instance) already does this. The alternative,
  a separate optional method `prepare`, makes the direction rule (below)
  possible, because the setup entry and the audio entries can then take the same
  buffer with different directions. With setup inside `initialize`, a table is
  distinguished by a marker instead, for example `@shape = Array.new(1_024, 0.0).freeze`
  (a call CRuby also accepts), and the rewrite gives it `:in` everywhere but the
  setup. Either way the setup runs once per instance on the instance's own
  thread, never on the audio thread:

  ```ruby
  def prepare
    i = 0
    while i < 1_024
      @shape[i] = Math.sin(2.0 * Math::PI * i / 1_024)
      i += 1
    end
  end
  ```

  `prepare` takes no arguments, may write `table`s and `buffer`s, and may not
  call the four MIDI/sample entries. It is compiled like the others; a trap in
  it silences the instance.
- **Read-only is checked by the boundary.** `prepare` receives the table as
  `[:f64_buf, :inout]`; every other entry receives it as `[:f64_buf, :in]`, so
  a store to a `table` anywhere else is a compile error (E077's direction rule),
  not a convention.
- **Alternatives.** (i) Build the table at plugin build time and embed it in
  the object as constant data. That is a different feature (a literal array
  constant, refused today as a heap operation) and stays out. (ii) One table per
  process instead of per instance: saves memory (a 1,024-point table is 8 KB),
  but the sharing rules (who fills it, thread safety on first use) are the
  problem 0040 avoided. Per instance is recommended.
- **Sample rate.** A table in samples or a delay in seconds needs the sample
  rate. Today `saw.rb` writes `44_100`. Open: whether the SDK reports the rate
  before the first block (`effSetSampleRate` is in `mpc_vst2_abi.h`); if only
  at set-rate time, `prepare` must be re-run (and buffers zeroed) then. Stage 1
  below fixes 44.1 kHz as now and leaves this to stage 3.

### 3. Block processing, and what blocks it

Today the C++ calls `spinel_sample(...)` once per frame, between MIDI events.
The per-call cost is one call and the state arrays' pointers, and the Ruby
cannot hold a running value in a local across frames (it must go through `fst`).

Proposed: an optional entry that fills a block.

```ruby
# fill one segment of the output; the segment never contains a MIDI event
def process(out, frames)       # out: a Float block, as long as `frames`
  i = 0
  while i < frames
    ...
    out[i] = ...
    i += 1
  end
end
```

The generated C++ splits the host's block at each MIDI event's offset and calls
the kernel once per segment with the pointer advanced and the segment's length.
That keeps sample-accurate events without a per-frame call. `sample` stays
supported; a class defines one of `sample` and `process`.

What blocks it today, and what each blocker costs:

1. **The host's buffer must be lent, not owned.** This is the 0007 route: a
   borrowed buffer with a count, direction `:inout`, no overlap with another
   `:inout` buffer. The freestanding boundary already has it; the generated
   `process` entry would take `[:f32_buf, :inout], :len` for the host's `float*`.
   No compiler change.
2. **The Array typing of a helper's parameter** (0040) does not block this: the
   buffer is a parameter of the entry itself, and the entries call each other
   nowhere. It blocks sharing code between `process` and a helper, which stays
   refused (the helper rule above).
3. **The pin's Float-in-a-loop limit** (0040, Known limits): a Float local that
   a `while` loop multiplies is typed as either class and refused. A filter or
   an envelope in a block loop naturally multiplies a running value
   (`z = z * a + x * b`). The rewrite keeps such values in `fst` elements, not
   locals, so `@z = @z * a + x * b` is an array store, which the limit does not
   name; this must be measured first (stage 2, first step). If it fails, a block form
   is not usable for filters until the pin's inference is fixed, and `sample`
   per frame stays the way.
4. **`return` inside the loop** is fine in an entry; 0040's concern was a
   `sample` body inlined into a loop, which this does not do.

Does 0041 stage 1's `each` help? Only in how the code reads: `frames.times {
|i| out[i] = ... }` replaces the counter, and the loop bound is
`static_proof`. It lowers to the same counted loop, so it does not lift
blocker 3, and it is not a prerequisite. It is worth admitting on these entries
when stage 1 lands, as an ergonomic step; the proposal works without it.

### 4. `MPC::Effect`, and stereo

- **`MPC::Effect`** is a class kind with `numInputs` 2 (or 1) and no MIDI
  entries. It defines `process(in, out, frames)` (input and output blocks) or a
  per-frame `sample(x)` that takes one input value and returns one. The kernel
  entry takes `[:f32_buf, :in], :len` for the input and `[:f32_buf, :inout],
  :len` for the output.
- **Aliasing.** 0007 rejects any overlap involving an `:inout` buffer. Hosts
  often process in place (the same `float*` for input and output). The generated
  C++ must therefore copy the input block into an instance-owned scratch buffer
  (one `buffer`, `frames_max` long, allocated with the instance) when
  `in == out`; or the entry takes one `:inout` block and reads then writes each
  element in order, which is the in-place form 0007 already allows ("in-place
  neighboring reads use one `inout` buffer"). The second is cheaper and is
  recommended; whether the SDK ever aliases is to be read from its source in
  stage 3.
- **Stereo.** Today one value is sent to both outputs. Two shapes: (a)
  `process(out_l, out_r, frames)` with two `:inout` blocks (distinct host
  buffers, so no overlap); (b) a per-frame `sample` that returns one value,
  with a second entry `sample_r`. (a) is recommended: no new return type (the
  boundary returns a scalar only), no two calls per frame, and stereo in an
  `Effect` is the same shape with inputs added. The mono example keeps working
  unchanged: no `process`, no change.

### 5. Memory

- **Sizes are declared and literal.** `spinel-mpc build` prints a total (for
  `Echo` above, `48,000 * 8 + 1,024 * 8 = 392 KB`) and refuses a count that is
  not a positive Integer literal. It states no cap: I have not found a
  documented per-plugin memory limit for the MPC; the owner may set one once a
  device run gives a number.
- **Storage is allocated by the C++ class, per instance, with the instance.**
  Members, not `new` on the audio thread: the host constructs the plugin
  object when it loads the plugin, on its own thread. A very large delay line
  as a member makes the object large; a heap allocation in the constructor
  (`std::unique_ptr<double[]>`) is equally off the audio thread and is the
  fallback if a member is too big for the host's allocator. Neither allocates
  in `process`.
- **No allocation on the audio thread** stays checked by what `run.sh` checks
  today: `kernel.o` needs only C math functions and `spinel_trap`. Buffers add
  parameters, not undefined symbols, so the check is unchanged and must pass
  with a buffer declared (prediction 1). The C++ side is a new check: a
  `malloc` interposer around `process` in the host simulator run counts zero
  calls between the first block and the last.
- **A buffer is zero when the instance starts**, and when the plugin resets.
  A reset hook is the C++ class's, not Ruby's.

### 6. Stages, predictions, checks

Each stage commits its predictions before its implementation, as 0041 does, and
is accepted only on the checks listed, run once at its end. No oracle comparison
runs unless the owner instructs.

**Stage 1: declared buffers and tables, per-frame `sample` unchanged.**
Largely in progress as the coordinator's uncommitted work (declared buffers, owner,
setup, code-4 bound, the pluck example). What this record adds to it: the
read-only table with its direction check, the memory report at build time, and
the checks below, which should be run against that work once it is committed.
No change to the freestanding compiler is needed beyond the Float conversions
the coordinator added.

Predictions:
1. `kernel.o` for a class with three buffers needs only C math functions and
   `spinel_trap` (the same `nm -u` check).
2. Direction is enforced: a store to a `table` outside `prepare` does not
   compile, with a message the rewrite can point at the source line.
3. An index past the count traps with code 4 and the instance goes silent; the
   bytes after the buffer are unchanged.
4. A delay-line Effect-like instrument (`@line[@pos] = x`, read at `@pos - n`)
   renders the same sample values as a plain-Ruby model computed in the test, on
   the native build (a model written in the test, not CRuby run on the plugin).

Checks: an accept fixture per element type; one refusal per misuse in 1 (assign,
pass, return, `push`, a helper that mentions a buffer, a non-literal count); the
planted out-of-range control; the zero-at-start check (the first block of a
delay line is silence); the `nm -u` check; and the host simulator renders a
wavetable instrument at 440 Hz as `saw.rb` does (zero crossings, as
`run.sh` measures).

**Stage 2: block `process` for instruments.** The entry, the segment-splitting
loop in the generated C++, mono and stereo outputs. Blocker 3 above (a Float running value stored
in an array element in a `while` loop) is measured first, in the stage's first step; if
it fails, the stage stops and reports that.

Predictions: (1) a `process` instrument and a `sample` instrument for the same
sound produce identical samples; (2) a MIDI event at offset k sounds from
exactly sample k; (3) the number of kernel calls per block is the number of
segments, not the number of frames; (4) one filter written in `process` with its
history in an instance variable renders the same as a model in the test.

**Stage 3: `MPC::Effect`.** Input and output blocks, aliasing handling, stereo,
sample rate (section 2). Predictions and checks follow stage 2's, plus an
in-place run (`in == out`) and a silence test (zero input gives zero output
until the line fills).

**Later, each its own question.** Slot pools for polyphonic voices (0041
stage 3, once it reaches this route; the slots would be indices into
instance-owned buffers); one table shared by all instances; build-time
constant tables (no arrays at all today); Integer arrays wider than 32 bits on
arm32.

## Validation

- Each stage is accepted on its checks, through the suites
  `tools/test/affected.rb --base origin/main` selects, plus `tests/mpc/run.sh`,
  with every figure printed by a command.
- Controls plant their own failing input in a copy of the example, as
  `run.sh` does.
- Not validated: any run on an MPC or other ARM machine (0040 has none either);
  the SDK's aliasing and sample-rate behaviour; any memory limit.

## Consequences

- `spinel-mpc` grows `buffer`, `table`, `prepare` and, later, `process` and
  `MPC::Effect`; its generated C++ gains members and a segment loop. The
  freestanding compiler, the subset and 0040's trap contract do not change.
- Entries with buffers take more parameters; nobody writes them by hand.
- `tools/mpc/README.md`'s "No state outside the instance" limit is replaced by
  what stage 1 admits; "Instruments only" by stage 3.
- This record depends on 0040 being merged, since it extends its tool. It
  depends on nothing in 0041 or 0042 for stage 1; stage 1 of 0041 is an
  ergonomic bonus for stage 2, and 0042's operators serve index wrapping.
- The coordinator's uncommitted buffer work on `feat/mpc-plugin-sdk` already covers
  most of stage 1. If the owner accepts this record, stages 2 and 3 and the
  table, report and checks of stage 1 are the new work; the owner decides the
  declaration form (initialize-based, as built, or the class-level lines).
