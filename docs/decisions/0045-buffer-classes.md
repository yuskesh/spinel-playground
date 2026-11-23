# 0045: Dedicated buffer classes in place of the Array spelling

- Date: 2026-11-15
- Status: **Accepted by the owner on 2026-11-15.** The direction is the
  owner's (2026-11-15, relayed by the bpf-mlir coordinator): replace the Array spelling of
  lent and declared buffers with small dedicated classes. The owner's
  answers (2026-11-15):
  - the Array spelling is **refused at once**, by a named refusal that points
    to the `Core::Buffer`/`Core::Table` spelling (this replaced an earlier
    answer that kept it during a migration), and every existing user is
    migrated **in the same change**;
  - hosted programs, including the tensor and image hosts, keep `Array`
    (former question Q5, H1);
  - no general CRuby library: the only CRuby definition is the minimal one the
    CORE application host runner needs (section 2), so the former questions on
    the CRuby implementation and on CRuby store conversion are dropped;
  - the names are `Core::Buffer` and `Core::Table` (former question Q1);
  - Q3: S1, `each` and `each_with_index` with a literal block are admitted;
  - Q6: O1, main first, then the MPC branch at its next rebase.

  No CRuby oracle runs for this work.
- Scope: how a program's Ruby source spells a buffer that a CORE,
  freestanding or MPC kernel indexes, wherever it is spelled as an Array
  today (inventory below); how the compiler maps the classes to today's
  buffers; the refusals' wording; the minimal CRuby definition.

  Out of scope: the boundary itself. Element types, directions, counts,
  bounds checks, aliasing and ownership stay as 0007, 0014, 0041, 0043 and
  0044 decided them, and the generated C prototypes do not change. Also out
  of scope: a pin move or a vendor change, the typedump, `state`
  declarations (already a dedicated spelling), 0041 stage 1's array literals
  in literal blocks, and hosted (Full) Ruby, which keeps `Array`.

## Context

### Why Array is the wrong spelling

The owner's reasons (2026-11-15):

- `Array` suggests `push`, `map` and growth, none of which a buffer has.
- The element type comes from the initial value (`Array.new(256, 0.0)` is a
  Float buffer because of `0.0`), not from anything the reader can see as a
  type.
- `.freeze` as the mark of a read-only table (0043) is obscure: in Ruby it
  means "this object will not change", and here it is written before the
  table is filled.
- The refusals read as "Ruby's Array is banned" (`'fill' parameter 0 'buf'
  is float_array`, `push` refused on an array), when what is refused is an
  operation a buffer does not have.

### Where a buffer is spelled as an Array today

Measured on main `73d75b0f` and `origin/feat/mpc-plugin-sdk` on 2026-11-15.

| Place | Today's spelling | Who decides the element type |
|---|---|---|
| MPC instance buffer (0043, branch only) | `@line = Array.new(256, 0.0)` in `initialize` | the initial value (`0.0` = f64) |
| MPC read-only table (0043, branch only) | `@wave = Array.new(1024, 0.0).freeze`, filled by a loop in `initialize` | the initial value |
| Scratch array in a method (0041 stage 2, main) | `a = Array.new(n, 2)` | the body's integer width (0019); `2` is the fill |
| Helper parameter that borrows a scratch array (0041 stage 2) | `def fill(b, k)`; inference types `b` as an Integer array | the caller's array |
| Freestanding entry buffer (E077) and helper parameter (0044) | `def process(out, frames)`; the type is in `freestanding_def ... [:f32_buf, :inout]` | the declaration |
| CORE entry buffer (0007 contract file, 0008 helpers) | a parameter; the type is in the `.contract` file (`param scr buffer u8 inout`) | the contract |
| CORE application `state` (0014) | `state :frame, :u8, 4` | the declaration |

The compiler accepts the Array spelling in three places only: the MPC
buffer, the MPC table and the scratch array. Everywhere else `Array.new` in
a kernel is already refused (a heap operation), and the entry and helper
parameters have no spelling of their own; there the Array shows through only
in the refusals (`float_array`) and in the CRuby code that lends a Ruby Array
to an entry.

### What the compiler sees

The pinned Spinel infers `Array.new(n, 0.0)` as a `float_array` and
`Array.new(n, 0)` as an `int_array`, and every route here starts from that
inference. The vendor is read-only, so a new class cannot be taught to the
inference. A buffer class written in ordinary Ruby (an object holding
an Array) would be inferred as a heap object with an instance variable, which
every route refuses. The mapping therefore has to happen before the
analysis, in Extended's own reader, as `spinel-mpc` already rewrites the
instrument class and as 0042's prelude is added for the reader.

## Proposal

### 1. The classes

```ruby
@line  = Core::Buffer.f64(48_000)                     # read-write, zero-filled
@note  = Core::Buffer.i32(8, -1)                      # read-write, filled with -1
@wave  = Core::Table.f64(1_024) { |i| Math.sin(2.0 * Math::PI * i / 1_024) }
a      = Core::Buffer.i32(n, 2)                       # 0041 scratch, in a method
```

- `Core::Buffer.<elem>(count, fill = 0)` makes a read-write buffer of `count`
  elements, each `fill`. `<elem>` is one of the boundary's element names:
  `i8 i16 i32 i64 u8 u16 u32 f32 f64`. A route admits the names it admits
  today; 0019 still refuses `i64` on 32-bit targets. `fill` is a literal, as
  today's second argument of `Array.new` is (0041's `fill` refusal, 0043's
  literal rule).
- `Core::Table.<elem>(count) { |i| ... }` makes a read-only buffer filled once by
  the block, element `i` from the block's value. It has `[]` and `size` and
  no `[]=`.
- The surface is `b[i]`, `b[i] = v` (`Core::Buffer` only) and `b.size`, plus Q3.
- The element type is in the name. The count is an Integer literal where a
  route needs a static size (MPC, 0043) and a scalar expression where it does
  not (0041 scratch); the rules on where the call may stand (0041's
  `array-position`, 0043's "before any other statement") are unchanged.

### 2. The one CRuby definition

There is no general CRuby library. The classes exist for the compiler,
which recognises them by their spelling (section 3). One place runs a kernel
source under CRuby as a routine check: the CORE application host runner,
`spinel-core-app run-host`, which loads `app.rb` together with the generated
board and channel simulators and the stimulus (`tests/scratch` uses it,
"array on the host" and the rest). It cannot be compiled by Spinel today: it
uses `eval` of generated source, `load`, `Object.send` and
`define_singleton_method`. Replacing it is a separate decision if it is ever
wanted.

So `tools/app/lib/spinel/core.rb`, which already makes `state` and `scratch`
no-ops under CRuby, gains a minimal `Core::Buffer` and `Core::Table`: each
`<elem>` method returns an Array of `count` elements (`fill`, or the block's
values for a table). A plain CRuby load, such as
`tests/app/fixtures/channel/bytes.rb`, gets that. The MPC and freestanding
routes have no routine CRuby run, and get no definition.

*Corrected on 2026-11-15, from reading the code (accepted by the coordinator):* an
earlier text said that `Array.new` is Ruby's own under the host runner. It is
not. `tools/app/lib/core_app/host_runner.rb` prepends `Array.new`, and in an
application file with a data stack it calls the runner's own model,
`Scratch#make`, which fails with `CAPACITY` past the region and `BOUNDS` for a
negative size, and gives elements of the body's width.
`tests/scratch` `capfull` and `samename` (`CAPACITY`) and `narrow`
(`ARITHMETIC`) rely on it. That prepend moves to `Core::Buffer`'s
singleton, so under the host runner `Core::Buffer.<elem>` is `Scratch#make`,
as `Array.new` was. An element name other than the body's width is refused,
as the build refuses it. The `Array.new` prepend is removed, since the build
refuses that spelling. Nothing else is modelled.

Inside `module Doom`, `Core::Buffer` would resolve to DOOM's own
`Doom::Core::Buffer` (a hosted Struct in `examples/doom/core/full/session.rb`)
under CRuby. DOOM's CORE sources make no buffer, so nothing is affected now; a
kernel inside such a module writes `::Core::Buffer`, which the reader also
recognises.

`IO::Buffer` was considered as the user-facing class and is not recommended:
it is indexed by byte offset with `get_value(:F32, offset)` rather than by
element, and it has many more methods than a buffer here has. The compute
route's host code keeps using it where it does (0031); that is a host API,
not a kernel's buffer.

### 3. How the compiler maps them

Extended's reader rewrites each recognised call before the analysis, on the
same line, so line numbers stay:

| Source | Given to the analysis |
|---|---|
| `Core::Buffer.f64(n, v)` (`f32` likewise) | `Array.new(n, v)` with `v` as a Float literal (`0.0` by default) |
| `Core::Buffer.i32(n, v)` (the other integer names likewise) | `Array.new(n, v)` with `v` an Integer literal (`0` by default) |
| `Core::Table.f64(n) { \|i\| e }` | `Array.new(n, 0.0)` and a fill loop at the same place, `while` over `i` writing `e` |

and records, per variable, the class and the element name. After that each
route is unchanged: MPC treats a rewritten `Core::Table` as 0043's table (`:in`
outside the setup), and 0041 stage 2 sees its `Array.new`. The boundary
declarations stay where they are. The recorded element name is checked
against what the route already knows. In MPC the class decides the state
array, as the initial value does today. In a scratch array the name must equal
the body's integer width (0019). In a freestanding or CORE helper that
receives a `Core::Buffer.f32`, the declaration's `[:f32_buf, ...]` must match.
Otherwise the build refuses, naming both.

**The Array spelling is refused**, at the place it is accepted today, by a
refusal that names the new spelling, the line and a rewrite:

- `pluck.rb:20: @note = Array.new(8, -1): a buffer is Core::Buffer.i32(8, -1)`;
- `wavetable.rb:13: @wave = Array.new(1024, 0.0).freeze: a table is Core::Table.f64(1024) { |i| ... }`;
- `app.rb:36: a = Array.new(n, 2): a scratch array is Core::Buffer.i32(n, 2)`.

*Added on 2026-11-15, from reading the code (accepted by the coordinator):*

- **Lines and columns.** The analysis gives each node only its starting line
  and column, and refusals are reported at `file:line:col`. The rewrite never
  adds or removes a line. It keeps the call's starting column, and pads
  after `Array.new(` with spaces, so that each argument keeps its column too.
  An omitted fill, which the rewrite appends as `, 0` (or `, 0.0`), would
  move what follows it on the same line. So the rewrite records each
  insertion, and the contract reader moves every node after one back to its
  source column (the review). Every column a refusal prints is the
  source's. The calls are found by parsing with the vendored Prism, so
  strings, heredocs and comments never look like a call.
- **The record.** It is kept as a line, a column, a class and an element for
  each rewritten call. On the scratch route, an `Array.new` that the rewrite
  did not produce is the Array refusal (`array-spelling`). A version 1
  contract has no data stack, and keeps today's refusal.
- **Reserved names.** In a source the reader rewrites, `Core::Buffer` and
  `Core::Table` are the buffer spelling, so the source does not define them as
  a module, class, constant or method. Nor does it rebind `Core` itself (`Core =
  ...`, `class Core < X`), while an ordinary `module Core ... end` with other
  declarations stays allowed. Such a definition is refused with
  `array-reserved` (the review). DOOM's `Doom::Core::Buffer` is hosted
  code that this reader does not read.
- **Where the rewrite runs.** It runs in the CORE reader (`core::loadContract`,
  composed with 0042's prelude copy), and only when the source spells
  `Core::Buffer.` or `Core::Table.`. The CORE kernel, `spinel-core-app` and
  the fiber rewrite all reach it. The freestanding reader is not changed:
  that route has no local buffer.
- **`Core::Table` in stage 1.** No user on main has one, and the scratch
  route has no read-only array. So in stage 1 the CORE reader recognises
  `Core::Table` and refuses it by name (`array-table`). The table is
  admitted with MPC in stage 2.
- **The element check.** On the CORE route, a spelled buffer meets a type
  only as a scratch array. There the element name must be the body's integer
  width (`i32`, or `i64` for a listed 64-bit body); any other name, `f32` and
  `f64` included, is `array-element`, naming both.
- **Wording from inference.** Where no spelling is visible (a helper's
  parameter or result, typed by inference), `int_array`, `float_array` and
  `poly_array` in a refusal become "an Integer buffer", "a Float buffer" and
  "a buffer of more than one element type".

The integer name in a suggestion is the route's integer width. Other
refusals name the class: `Core::Buffer has no push`, `@wave is a Core::Table and has no
[]=`, and `'fill' parameter 0 'buf' is a Core::Buffer.f32` (instead of
`float_array`). Where the reader cannot see a spelling (an entry's
parameter, typed by its declaration or contract), a refusal says "buffer"
and the declared element type, never "array".

### 4. Every existing user, migrated in the same change

Counted on 2026-11-15 with `git grep -c 'Array\.new'` (main `73d75b0f`,
`origin/feat/mpc-plugin-sdk` `39510f72` and later).

**On main: 0041 stage 2 scratch.**

- `tests/scratch`: 48 `Array.new` lines in 39 `.rb` files, plus
  `kernel-reject.tsv` and `run.sh`. The accepted programs (`array`, `capfull`,
  `int64`, `narrow`, `pair`, `samename`, `wide`, `kernel/huge`, `outer`,
  `room`, `room32` and `size`) move to `Core::Buffer.<int>`. Each reject fixture
  keeps testing its own refusal with the new spelling (`push`, `ret`,
  `store`, `inif`, ...). `nofill.rb` (`Array.new(2)` without a fill) becomes
  a case of the Array refusal, since `Core::Buffer` has a default fill. One new
  reject fixture per route checks the Array refusal and its suggested
  rewrite.
- `docs/core/applications.md` (lines 162-189, the `array-position` and
  `scratch-missing` rows at 292-294).
- `tests/app/fixtures/channel/bytes.rb`, a CRuby driver that lends
  `Array.new(32, 0)` and `Array.new(4, 0)` to the app's `fill` entry. CRuby
  code is not refused; it moves to `Core::Buffer.u8(32)` so the example spells a
  buffer one way.

**On `feat/mpc-plugin-sdk` (0043), in the same change on that branch.**

- `examples/mpc-spinel-pluck/pluck.rb`: 12 lines (`@note = Array.new(8,
  -1)` and the other voices, `@noise = Array.new(4096, 0.0)`), and its README.
- `tests/mpc`: 15 lines in 5 files: the fixtures `count`, `delay`, `echo`
  and `wavetable` (`.freeze` becomes `Core::Table.f64(...) { ... }`), and
  `run.sh`'s planted cases (lines 192-216, 264 and 283: the size, late and
  freeze plants and the store refusal), which expect the new wording.
- `tools/mpc/spinel-mpc` (the rewrite: `Core::Buffer`/`Core::Table` accepted,
  `Array.new` and `.freeze` refused) and `tools/mpc/README.md` (4 lines).
- `examples/mpc-spinel-saw` has no buffer and does not change.

**Wording only, no source spelling.**

- 0044's and E077's refusals about a buffer parameter (`spinel-fs-emit`,
  `tests/fs-helper-buffers` expected messages) say `Core::Buffer` and the element
  name.
- `tests/freestanding/e084/reject/n2_array_new.rb` stays refused (no local
  buffer on that route). If its expected text names the array, it moves to
  the new wording.

**Not changed.**

- DOOM. `examples/doom/core/src` has no `Array.new`; its CORE buffers are
  contract parameters. `examples/doom/lib` and `core/full` are hosted Ruby,
  which keeps `Array`.
- `state` (0014), the tensor, image and compute routes' host programs (hosted,
  answered: they keep `Array`), and the generated board simulators for CRuby
  (`tests/app/fixtures/trace/sample-run/board_host.rb`).
- Accepted decision records and reports (0040, 0041, 0043 and their results)
  are historical and keep their text. Each gets one line under its status
  pointing to 0045 for the current spelling.

## Owner questions

All answered (see the status). Q1, Q2, Q4 and Q5 were settled before these
two; the numbers are kept as first sent, and the options are kept as asked.

**Q3. The surface beyond `[]`, `[]=` and `size`.**

- **S1 (recommended):** also `each` and `each_with_index` with a literal
  block. 0041 stage 1 already lowers them on a buffer, and
  `tests/scratch/array` uses `each_with_index`. Nothing else.
- S2: exactly `[]`, `[]=` and `size`; a loop over a buffer is a `while`, and
  `tests/scratch/array` is rewritten to one.

**Q6. Order.**

- **O1 (recommended):** main first (CRuby definition, reader, refusals, scratch,
  wording, `bytes.rb`, documents), then the MPC branch moves in its own
  change when it is next rebased onto main. The branch is not merged to main
  before publication, so it never sees main with the Array spelling still
  accepted there.
- O2: both in one step: the MPC branch is rebased onto the main change at
  once.

## Stages

1. On main: the minimal CRuby definition in
   `tools/app/lib/spinel/core.rb`, the reader's rewrite and record, the Array
   refusal and the renamed refusals, and every main user above. Predictions
   are written before code. Acceptance is the routes' own suites as
   `affected.rb` selects (`tests/scratch`, `tests/fs-helper-buffers`,
   `tests/app`, `tests/core-*`, `tests/freestanding`), plus the new reject
   cases. No CRuby comparison.
2. On `feat/mpc-plugin-sdk`, after its rebase: the MPC rewrite and every
   MPC user above, with `tests/mpc` as the acceptance.
