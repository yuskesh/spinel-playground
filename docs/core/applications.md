# CORE applications on Zephyr

Status: implemented and merged for decision 0014
([record](../decisions/0014-core-applications-on-zephyr.md),
[plan and coverage](../decisions/0014-core-applications-on-zephyr-plan.md)).
The contract entered `main` at `7a7f453`; the implementation was merged at
`8fbe4d1` into the integration subsequently merged to `main` at `59c6a83`.
Boards: `mps2/an521` (built and run under QEMU) and FRDM-MCXN947 (built;
not run on the physical board).
The commands, their environment and every suite are in
[building](../building.md#zephyr-for-core-applications-decision-0014); this
page is what an application can say, and what it cannot.

## What an application is

One Ruby file of declarations and `def`s. Each timer-driven entry is a CORE
function: no allocation, no Spinel runtime, loops with a derived bound, and
integer arithmetic that is checked (an overflow is a failure, never a wrap).
The tool reads the declarations, generates the glue, and builds firmware in
which every entry, every provider and every stack is accounted for.

Integer arithmetic follows the board's pointer width: these 32-bit boards use
signed i32 bodies, with ARITHMETIC on overflow. A first-line
`# spinel: int64` is refused for them unless `tools/core/int64-allow.tsv`
lists the source, and so is an i64 scalar boundary of an unlisted source; the
declaration changes nothing on a 64-bit target. State element widths do not
change: an i64 state buffer stays i64.
See [decision 0019](../decisions/0019-target-integer-width.md), including the
width controls and the distinction between body arithmetic and buffer storage.

This is the acceptance sample, `tests/app/fixtures/build/sample/app.rb`,
which `tests/app/build.sh` builds and boots and `tests/app/verify.sh` runs
and verifies:

```ruby
require "spinel/core"
require "spinel/net"
state :reading, :i32, 1
state :pressed, :i32, 1
state :frame, :u8, 16
state :command, :u8, 8
state :level, :u32, 1
channel :telemetry, :out, size: 16, depth: 4, uart: true
channel :commands, :in, size: 8, depth: 2, uart: true
every_us 1000, :sample, context: :interrupt
every_ms 5, :report
every_ms 10, :command_poll

# interrupt context: the latest ADC reading, published to the thread context
def sample(reading)
  reading[0] = Adc.latest(Adc::CH0)
  0
end

# thread context: reads the cross state and the button, drives the LED,
# reports over the channel
def report(reading, pressed, frame, level)
  pressed[0] = Button.read(Button::SW0)
  v = reading[0]
  n = put_i32(frame, 0, v)
  n = put_u8(frame, n, pressed[0] & 0xff)
  n = put_u8(frame, n, level[0] & 0xff)
  Led.set(Led::LED0, level[0] & 1)
  Telemetry.put(frame, n)
  0
end

# thread context: consumes commands, the first byte sets the level
def command_poll(command, level)
  n = Commands.get(command)
  if n > 0
    level[0] = command[0]
  end
  0
end
```

## The declarations

- **`state NAME, ELEMENT, COUNT`** -- a statically allocated buffer
  (`:u8 :u32 :i32 :i64`, a count fixed at build). An entry
  names the states it uses as its parameters, by name. A state that entries
  of both contexts name is *cross*: its accesses are atomic, element by
  element, and it may have one writing context only.
- **`every_us N, :entry` / `every_ms N, :entry`**, with `context: :interrupt`
  or the default thread context -- one trigger per entry. A period must be a
  multiple of the 100 us tick.
- **`channel NAME, :in | :out, size:, depth:, uart: true`** -- a
  fixed-size-message ring between one entry context and the UART transport.
  `NAME.put(buf, n)` queues `n` bytes (`1 <= n <= size`, else ARGUMENT or
  BOUNDS) and returns 1, or 0 when the ring is full; `NAME.get(buf)` returns
  the length of the message it dequeued, or 0. (`put`/`get` are the names:
  decision 0014 D4.) UART is the only transport of this milestone.
- **Board members** -- `Led.set`, `Button.read`, `Adc.latest`, `Pwm.set`,
  `Clock.uptime_us` and the others the generated board package declares for
  the board, by devicetree instance index. `Clock.uptime_us` and
  `Clock.cycles` answer i64; `Clock.cycles32` answers the cycle counter's low
  32 bits as a signed i32 pattern (`k_cycle_get_32`), for a body at 32 bits,
  which refuses an i64 extern value (decisions 0019 and 0022). A span is
  `core_w32_sub(c1, c0)`, exact while it is shorter than one period of the
  counter (17.9 s at 240 MHz). The other named word forms (decisions 0022
  and 0042: the wrapping `core_w32_*` and `core_w64_*`, the unsigned
  `core_u32_*` and `core_u64_*`, and `core_u32(LIT)` for a constant such as
  a mask written in hex) are called the same way; a body at 32 bits refuses
  the 64-bit ones (`unsupported-intrinsic-call`). **Board constants** name those
  indexes: `Led::COUNT`, and `Led::LED0` from an alias, `Led::USERLED0` from
  a label, `Led::LED_0` from a node name (decision 0014 D5). A member the
  board does not have is refused (`unknown-member`), not stubbed.
- **Your own externs** -- `module Sensor; core_extern :read, params: {...},
  returns: ..., isr_ok: ..., bound: ..., provider: "drivers/sensor.c"; end`.
  The provider is compiled, screened (no allocation, no blocking call, no
  interrupt configuration, no call back into an entry) and measured like the
  board's adapters. Its stack evidence is its own frame, so it may call
  nothing it does not define: a call to `printk`, or to any Zephyr or libc
  function, is refused at step 5, naming the call.
  `tests/app/fixtures/build/own-provider/` is built by `build.sh`, and
  `printk-provider/` beside it is the refused case.
- **`fiber_def :reader, max: N`** -- a stackless fiber kind with `N`
  statically allocated frames ([decision 0035](../decisions/0035-stackless-fiber.md)
  stage 2). The body is the top-level method `reader`, and `Fiber.yield`
  suspends it. `Reader.start(slot, args...)`, `Reader.resume(slot, value)`
  and `Reader.alive?(slot)` drive slot `0 ... N`. Each `resume` runs one step,
  and a misuse is `BOUNDS`. Every loop that suspends must suspend on every
  path through an iteration, and one context owns a kind.
  `sh tests/fiber/core.sh` checks it on the host and under QEMU.
- **`enum_def :evens, max: N`** -- the CORE form of `Enumerator.new`
  (decision 0035, owner 2026-11-11), with the same frames and rules as
  `fiber_def`. The body `def evens(y, args...)` takes the yielder first and
  suspends at `y << v` or `y.yield v`, each a statement of its own.
  - `Evens.start(slot, args...)` starts a slot.
  - `Evens.next?(slot)` steps until a value is buffered or the body ends,
    and answers whether a value is there.
  - `Evens.next(slot)` and `Evens.peek(slot)` return that value, stepping
    first if none is buffered. `next` consumes it.
  - `Evens.alive?(slot)` is true until `next?`, `next` or `peek` finds the end.
  - `next` or `peek` with nothing left is `BOUNDS`, where Ruby raises
    `StopIteration`. A slot restarts with `start` once its body has ended.
    There is no `rewind`, `each` or `to_a`.
- **`pool_def :node, max: N`** -- a slot pool with a free list
  ([decision 0041](../decisions/0041-goose-ideas-for-core.md) stage 3,
  owner 2026-11-14). The application keeps its own fields in `state`
  buffers of `N` elements and indexes them by slot.
  - `Node.alloc` answers a free slot: the most recently freed one, or else
    the lowest slot never handed out. With all `N` slots allocated it fails
    with `CAPACITY`.
  - `Node.free(slot)` returns a slot. A double free, a free of a slot never
    allocated, and a slot outside `0 ... N` are `BOUNDS`.
  - `Node.live?(slot)` answers whether the slot is allocated.
  - A slot number kept after its `free` reads whatever the slot's next owner
    writes. This is not detected; it is a known limit.
  - The build writes three `:i32` states, `(2N + 2) x 4` bytes, and prints
    their size. One context owns a pool, and a `fiber_def` or `enum_def` body
    may not use one. `sh tests/fiber/core.sh` checks it on the host and
    under QEMU.
- **`scratch BYTES, context: :thread`** -- the data stack of one context
  ([decision 0041](../decisions/0041-goose-ideas-for-core.md) stage 2,
  owner 2026-11-14), where its methods make arrays. `context:` is `:thread`
  (the default) or `:interrupt`, and each context declares at most one.
  The build places a `.bss` region of `BYTES` (16 to 2147483647) per
  context and passes it to that context's entries. Its first word is a bump
  offset, and the elements follow it.
  - `a = Core::Buffer.i32(n, v)` makes a buffer of `n` elements filled with
    `v` on the data stack ([decision 0045](../decisions/0045-buffer-classes.md));
    `v` may be left out, and is then 0. The element name is the body's
    integer width: `i32` on the 32-bit targets, `i64` for a listed
    `# spinel: int64` body. Any other name is `array-element`. It is admitted
    only as a statement of a method's own body, outside every loop, block and
    branch (`array-position`), and `v` is an Integer literal (`array-fill`).
  - The Array spelling, `a = Array.new(n, v)`, is refused with
    `array-spelling`, and the refusal gives the `Core::Buffer` to write.
    `Core::Table`, a read-only table, belongs to the MPC route and is
    refused here with `array-table`.
  - A negative `n` is `BOUNDS`. When `n` elements do not fit in what is
    left, `Core::Buffer` fails with `CAPACITY` before it writes anything.
  - `a[i]`, `a[i] = x`, `a[i] += x`, `a.size`, `a.each` and
    `a.each_with_index` work as on a `state` buffer, checked against `n`.
    `a` may be passed to a method the application defines, which borrows
    it.
  - The array is freed when the method that made it returns, by any path:
    a value, a failure, or a callee's failure passed up. So the next
    release starts with the region as the previous one found it.
  - The array stays in its method. It cannot be returned, stored, assigned
    to a second local, reassigned, or passed to an extern or a fiber
    (`array-escape`, `array-alias`, `array-rebound`), and no other method
    applies to it (`push`, `<<`: `array-method`). A `fiber_def` or
    `enum_def` body makes none: it returns at every suspension. An array
    literal stays refused. A context that makes a buffer without a `scratch` is
    `scratch-missing`.
  - When every size on every path from an entry is a constant, the kernel
    reports the worst path's bytes against the region as `static_proof`,
    and refuses a larger total at build time (`scratch-capacity`).
    Otherwise the report says `runtime_guard`, and `CAPACITY` is the guard.
    `build.json` lists each region with each entry's evidence.
  - The `--core` route and the trap mode have no region and refuse
    `Core::Buffer` as they refused `Array.new` before.
    Under `run-host`, `Core::Buffer` takes its elements from a model of the
    region, with the same `BOUNDS` and `CAPACITY`.
  `sh tests/scratch/run.sh` checks it on the host and under QEMU.
- **`spinel/net.rb`** -- `put_u8`, `put_u16`, `put_i32`, `put_dec`, `put_str`:
  serialisation into a `:u8` buffer, each returning the next position.

## A session of DOOM's entries (decision 0021)

DOOM's board loop is an application whose entry calls decision 0008's three
entries. It runs on FRDM-IMXRT1186 over a session the host prepared.
`examples/doom/core/board/app.rb` is that application.

- **`core_session "<entries dir>"`** names the three entries' contracts
  (`examples/doom/core/entries`). The build then takes two arguments:
  - `--session-image DIR` is the session at open, written by
    `tools/doom/session-image.rb --demo DEMOn`;
  - `--session-objects DIR` holds the three entries built for the target,
    with their headers, reports and contracts. The contracts must be the
    entries directory's, byte for byte.
- **`core_session "<entries dir>", dtcm: ["<field>", ...]`** keeps writable
  fields of the session in the data TCM (0021, the owner's decision of
  2026-10-21: the board application keeps `renderer_screen` there).
  - Each field is its own array in the data TCM. At boot it is filled from
    the NOR's writable part, with the rest of that part, and the entries and
    the application's states are given that array.
  - A name that is not a writable field of the image is refused at step 1.
  - On a board whose devicetree chooses no `zephyr,dtcm`, the fields stay in
    the writable part.
  - Step 8 refuses a build whose fields and scheduler stack do not fit the
    data TCM, naming each field's bytes. The stack counts as its stack object,
    with the MPU guard on the Cortex-M7.
  - `build.json`'s `session.dtcm` records the fields, and the placement is
    part of the session id.
- **`DoomCore.input`, `DoomCore.step` and `DoomCore.render`** take the
  entries' scalar arguments only, and answer the entry's 0007 status.
  - Their providers are generated (`session.c`). Each hands the entry every
    buffer at its place in the session, with its count.
  - They are the only providers the screen lets call CORE, and that is by
    name. Any other provider that calls a DOOM entry is refused as a call
    back into CORE.
- **Session states.** An entry parameter named after a writable field of the
  session, or `core_state`, receives that field's storage.
  - A resource field may be named too, read-only. The build refuses an entry
    whose kernel report says it writes one.
  - A slot is read through `core_state[Slot::NAME]`.
  - The demo's place in the IWAD is `Image::DEMO_OFFSET`, and its length
    `Image::DEMO_TICS`.
- **One writing context.** Every entry that calls `DoomCore` or names a
  session state must be in one context.
- **Placement.** The resources are read in place at the NOR address of the
  board's session area (`session_flash_offset` in the board table). The
  writable part is copied to RAM at boot, after the digests of both parts
  are checked against the image the build was made from. A mismatch prints
  `SPC_SESSION_REFUSED` and nothing starts. Otherwise the firmware prints
  `SPC_SESSION_ID <id>`, the build's id that `build.json` records as
  `session.id`: a digest of the application, the board, the image, the
  entries' objects and what generates the glue (with the data TCM
  placement and, on the Cortex-M7, the launcher's sources), by which a lane tells this build's run from earlier
  firmware's.
  - The build refuses code that reaches the session area, and a session
    that does not fit it.
- **Stack.** Each `DoomCore` member's stack is the sum of three terms:
  - its provider's frame, with the call frame it passes the entry's buffers
    in (3536 bytes for `DoomCore.step`, which `.su` does not count);
  - the entry's `kernel_stack`, from its report;
  - the deepest compiler runtime helper the entry's object calls. These are
    attested in `tools/app/zephyr/v4.4.2/helpers.tsv`, bound to the libgcc
    archive the link uses, and recorded in `build.json`.
- **Not a realtime claim.** The step and render entries have loops without a
  derived bound. So `DoomCore.step` and `DoomCore.render` declare `bound
  iterations unknown "<reason>"`, and an entry that calls them has loop_bound
  `unknown` (docs/core/core-report.md).
  - The build admits that only through `DoomCore`, and records it in
    `build.json` as `realtime profile, loop_bound unknown through DoomCore:
    not a realtime claim`.
  - `DoomCore.input`'s work derives, and it carries its bound.
- **On the host,** `CoreApp::SessionHost` runs the entry release after
  release under CRuby. It runs over the image's session, with the entries'
  CORE source executing in CRuby.
- **`tests/app/session.sh`** checks all of this. It takes the image and the
  objects the board lane makes:
  - the host run's commands against Full's `Demo` object, and its frames
    against the recording, for 200 tics;
  - the build and its record;
  - one control per refusal above.

## What is refused, and where

Each refusal names its code. The codes an application meets most often:

| code | what it means | a fixture that shows it |
|---|---|---|
| `loop-unbounded` | a loop whose bound the kernel cannot derive | `tests/app/fixtures/contract/elig/loop-unbounded-thread.rb` |
| `unresolved-call` | a call to something neither defined nor declared | `.../contract/elig/undeclared-extern.rb` |
| `unresolved-constant` | a constant that is not `NAME` at top level or `Mod::NAME` in a module body, each an integer literal | `.../contract/elig/const-path-deep.rb` and its siblings |
| `extern-context` | a non-`isr_ok` member called from interrupt context | `.../contract/elig/extern-context.rb` |
| `cross-to-extern` | cross state passed to an extern | `.../contract/elig/cross-to-extern.rb` |
| `shared-writer` | a state written from two contexts | `tests/app/fixtures/apps/shared-writer/` |
| `device-owner` | one device driven from two contexts, including through two modules or a computed index | `.../apps/device-owner/`, `.../apps/device-owner-computed/` |
| `channel-end` | one end of a channel used from two contexts | `.../apps/channel-end/` |
| `channel-buffer` | a `get` into a buffer smaller than the channel's `size` | `.../apps/channel-buffer/` |
| `unknown-member` | a member the board does not provide | `.../apps/unknown-member/` |
| `member-effect` | a blocking, or not-proven-non-blocking, member | `.../apps/member-effect/` |
| `declaration` | a malformed declaration | `.../apps/decl-*` |
| `array-spelling` | a scratch array spelled `Array.new`, or a `Core::Buffer` without its parentheses | `tests/scratch/reject/arraynew.rb`, `.../kernel/reject/nofill.rb`, `.../kernel/reject/bare.rb` |
| `array-element` | a `Core::Buffer` whose element name is not the body's integer width | `tests/scratch/kernel/reject/element.rb`, `.../kernel/reject/float.rb` |
| `array-table` | a `Core::Table` on this route | `tests/scratch/kernel/reject/table.rb` |
| `array-position` | `Core::Buffer` other than as `local = Core::Buffer.i32(n, v)`, a statement of its method's body | `tests/scratch/kernel/reject/inif.rb` and its siblings |
| `array-escape` | a buffer on the data stack returned, stored, or passed to an extern or a fiber | `tests/scratch/reject/extern.rb`, `.../kernel/reject/ret.rb` |
| `scratch-missing` | `Core::Buffer` in a context that declares no `scratch` | `tests/scratch/reject/missing.rb` |
| `scratch-capacity` | a constant worst path larger than the region | `tests/scratch/reject/capstatic.rb` |

The tool refuses at the step that owns the fact: declarations at step 1, the
kernel's eligibility at step 7, a stack that does not fit at step 8, an
image that does not match what was measured at step 10. A refused build
leaves no firmware.

## Running it

**On the host, under CRuby.** `spinel-core-app run-host` runs the same file
on a virtual clock with the scheduling and channel semantics of the target,
driven by a stimulus script. `tests/app/host.sh` runs its fixtures.

**Building firmware.** `spinel-core-app build --app app.rb --board mps2_an521
[--board-overlay FILE] --out DIR` runs the eleven steps of 0014 §8: the
generated board package from the final devicetree, the kernel on every
entry, the glue, the stack inequalities of §9 with attested reserves, the
link, and the image checks. `DIR/firmware/build.json` records each stack's
requirement term by term. A unit's frames are its `-fstack-usage` frames
plus any call frame clang did not reserve. These are found as the kernel
finds them (docs/core/core-report.md, "Unreserved call frames"), from a side
compile whose assembled code must equal the object's. They are listed under
`unreserved_call_frames` with the method's control on that build.

**Verification.** `spinel-core-app verify ... --stimulus S.tsv` builds a
recorded variant, runs it under QEMU, and checks the trace -- integrity,
workload and timing, channel conservation, linearisability, and a byte-exact
replay of every invocation under CRuby. A stimulus script is lines of
`horizon_us`, `drain_us`, and timed `adc`, `gpio` and `inbound` items;
`tests/app/fixtures/stimulus/sample.tsv` is the sample's. A trace is
compared within a host, never across hosts (see building).

**Stress.** `tests/app/stress.sh` runs the production primitives under
preemption with the build's sampling source (`--stress`), both directions
of the ring at once.

## Limits of this milestone

- Channels are UART channels only; no inter-entry channel.
- No floating point in an entry, and no FPU in the configuration.
- The 64-bit division helpers are refused in production (their stack is not
  attested) and admitted only in a verification build, which measures them.
- The sampling source can preempt only the thread side of a ring operation;
  the interrupt side runs inside the system clock's handler.
- FRDM-MCXN947 is built, not run; running on hardware is outside
  acceptance.
