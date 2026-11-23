# 0014: CORE applications on Zephyr

- Date: 2026-09-22
- Status: Accepted
- Scope: How a Ruby application compiled as CORE runs on an RTOS target:
  - the application source surface;
  - the board package generated from the target's devicetree;
  - execution contexts, thread and interrupt, and every generated actor;
  - data shared between contexts, and channels;
  - the extern effect contract (0010 step 3, amended here);
  - byte buffers and text;
  - the build order and the glue it generates;
  - stack budgets on Cortex-M;
  - verification.

  The first target is Zephyr on QEMU `mps2/an521`. The second is FRDM-MCXN947,
  which is taken as far as a build. This record amends 0010 and, for
  application entries only, 0007. It does not change the DOOM CORE entries,
  the 0007 ABI of existing contracts, or the freestanding lane.

## Authorization and status

On 2026-09-22 the owner took Stage 3 (freestanding preparation) and 0010 step 3
(the extern effect contract) together. After a design discussion and a survey
of embedded-language notations, the owner decided the following, and it is
incorporated below.

1. **First target.** Zephyr on the QEMU Cortex-M33 `mps2/an521`, an automated
   lane that runs on both hosts without hardware.
2. **Python is allowed for Zephyr's own build only.** Zephyr's west, Kconfig
   and devicetree tooling cannot run without it.
   - It is confined to the pinned Zephyr installation outside the repository.
   - No `.py` file enters the repository.
   - Nothing else in the project may come to depend on that Python.
3. **Interrupt context is in scope from the start.** Thread context alone is
   not the target.
4. **The application writer writes Ruby only.** Extern declarations for board
   devices, stack sizes, the C glue, timers and threads are derived or
   generated.
5. **Board definitions are generated** from the devicetree and Zephyr. Only one
   adapter per device class is written by hand.
6. **Generation targets.** `mps2/an521` is run and compared in QEMU.
   FRDM-MCXN947 is taken up to a build.
7. **Communication goes through fixed-capacity queues and a Zephyr thread.**
   This record designs `channel`. This milestone implements the queues and a
   UART transport. UDP and MQTT come in the next milestone.
8. **Text is handled as bytes in buffers of fixed size.** String literals are
   admitted as constant data, and `put_str` and `put_dec` are provided.

The owner accepted items 1–6 with "I approve all of them" and items 7–8
with "I approve" (the owner's words, translated) on 2026-09-22.

An independent review of the first draft (`1400c07`) raised fourteen findings,
four of them blockers. The same day the owner chose the recommended resolution
for each of the six that needed a decision, with "Yes, redesign with the
recommended resolutions…" (the owner's words, translated):

- **A. Zephyr's own stack use** is an attested reserve bound to the exact
  configuration. The painted-stack measurement only tries to falsify it
  (§9).
- **B. State shared between contexts is never passed to an extern.** Only CORE
  code touches it (§5).
- **C. Every loop in an application entry needs a derived bound**, in thread
  context as well as interrupt context. Declared bounds with run-time guards
  are not part of this milestone (§6, §8).
- **D. `on_edge` (GPIO edge entries) is deferred** until its interrupt
  injection and context contract are designed (Consequences).
- **E. Due thread entries run in declaration order.** A period that cannot
  start on time is skipped and counted, never caught up (§4).
- **F. The `mps2/an521` acceptance uses only devices that exist there or have a
  Zephyr emulator:** `Led`, `Button` and `Adc`. `Pwm` is exercised only where a
  board provides it (Validation).

The other eight findings are corrections within the approved direction and are
folded into the sections below.

A second review (of `83a0786`) found two blockers and seven should-fix items,
all within A–F. They are folded in as well:

- the verification trace now linearises accesses and channel operations;
- the interrupt inventory is bound to the configuration, not read from the
  image;
- call counts are summed over call sites;
- releases are defined;
- devices have one owning context, with no exception;
- the build is staged and published only after the final checks;
- the atomic-access contract is stated as behaviour, not as a count of
  physical accesses.

A third review (of `0aa0799`) found two blockers and five should-fix items,
again within A–F. They are folded in as well:

- verification is split into a serialised semantic check and an unmasked
  check of the production primitives, and each result names its artifact;
- the critical section and compiler barriers are named;
- releases are decided from a recorded clock that advances during callbacks,
  so skips can be recomputed on the host;
- scheduling is a fixed sweep;
- verification runs are finite, with a drain and stranded-message reporting;
- a full inbound channel is an explicit, checked drop reason;
- the interrupt inventory covers driver-connected interrupts and NMI.

A fourth review (of `134e5a8`) found no blocker, and three bounded should-fix
items. It judged the record ready for the owner's decision once those three
were explicit. They are now:

- every admitted release ends in exactly one terminal class, including
  cancellation by failure and cut by horizon, with quiescence before the drain;
- the image comparison classifies every vector slot, including the initial
  stack pointer word, the reset handler and reserved entries;
- the production stress runs claim only what they observe.

The owner approved this record on 2026-09-22 ("approved"), in reply to a
request naming commit `c93be6a` (tree `bb16dbc`) after the fourth review and
its confirmation. The text is unchanged from that commit apart from this
status.

Acceptance approves the decision, not a delivery. Nothing in this record is
implemented. Every command name, keyword and diagnostic below is planned until
a delivery lands it together with its validation.

## Context

**What CORE is today.**

- A CORE entry is a Ruby method that the CORE kernel compiles into an object
  with one export and, today, no undefined symbols.
- Failure is a status: `OK 0`, `ARGUMENT 1`, `ARITHMETIC 2`, `BOUNDS 3`,
  `CAPACITY 4`.
- Buffers are borrowed. The caller owns the storage and passes a count with
  each buffer ([0007](0007-doom-core-preparation.md),
  [buffer boundary](../core/buffer-boundary.md)).
- The kernel carries each entry buffer's name, element, count and whether it is
  read-only (`EntryBufferFact`, `include/spinel-mlir/Core/Eligibility.h`). It
  refuses a write through a read-only borrow where it occurs, and a helper
  inherits read-only from any caller that reaches it.
- The kernel does **not** compute which buffers an entry writes. A write-set
  analysis is new work (§5).
- 0010 added a per-entry build report. Step 1, loop bounds, was delivered by
  merge `4e1db3f`. Step 2, the stack budget, was delivered by merge `b47d89b`.
  Step 2 refuses an extern on the worst path, because its stack was left to a
  target overlay that does not exist yet (`lib/Core/StackBudget.cpp`).

**What 0010 planned for step 3.**

- Externs are declared in a separate semantic manifest, with a per-target
  overlay for stack and provider evidence.
- `no_alloc` and `no_reentry` are required on every extern. `no_block` is
  required under `realtime`.
- CORE proves the use-site obligations.
- An extern's own properties come from `derived` or `attested` provenance.
  Measurement-based provider evidence is attestation, not proof.

**Nothing calls CORE from an RTOS today.** The only CORE consumer is Full Ruby,
which drives the DOOM entries. The freestanding lane (`tools/freestanding`) is
separate: it has trap semantics and a closed YAML profile schema.

**What the notation survey found.** The survey covered TinyGo, Rust (Embassy,
RTIC), Zig (MicroZig), Swift Embedded, MicroPython, PicoRuby with mruby/c, and
Ada (Ravenscar).

- Every one of them declares C or SDK functions in the source, or imports them
  from a C header. None uses a separate manifest.
- Most expose named device objects.
- The rule that interrupt code must not allocate or block is enforced in three
  ways:
  - as documentation only (TinyGo);
  - at run time (MicroPython);
  - at compile time, for the whole program (Rust `no_std` and RTIC; Ada
    Ravenscar).
- None checks such effects per function at build time.

Zephyr documents per-function properties `isr-ok` and `sleep`
(<https://docs.zephyrproject.org/latest/develop/api/terminology.html>), but
nothing checks them.

**Platform facts relied on.** These are taken from current upstream Zephyr
documentation and source. Each is to be confirmed against the pinned release.

- The configure step writes the final devicetree to `build/zephyr/zephyr.dts`
  (<https://docs.zephyrproject.org/latest/build/dts/howtos.html>).
- A `k_timer` expiry function runs in the system clock interrupt
  (<https://docs.zephyrproject.org/latest/kernel/services/timing/timers.html>).
- `mps2/an521` is a Cortex-M33 board with user LEDs and CMSDK GPIO, supported
  under QEMU
  (<https://docs.zephyrproject.org/latest/boards/arm/mps2/doc/mps2_an521.html>).
  That it has no ADC or PWM is believed but not yet established.
- `zephyr,adc-emul` and `zephyr,gpio-emul` accept injected values. The GPIO
  emulator fires callbacks synchronously in the injecting caller's context,
  not from an interrupt (`drivers/gpio/gpio_emul.c`, `gpio_emul_pend_interrupt`
  calls `gpio_fire_callbacks` directly).
- Cortex-M threads run on PSP and handlers on MSP. Zephyr shares one interrupt
  stack among nested interrupts
  (<https://docs.zephyrproject.org/latest/hardware/arch/arm_cortex_m.html>).

**Constraints carried forward.**

- The DOOM CORE path must not change, and its objects stay byte-identical.
- The hosts are Debian x86_64 and macOS arm64, with the official LLVM 23.1.1
  and never Apple Clang.
- Mid-course verification has a budget of ten minutes. Longer checks go to a
  final verification that the owner defines.
- A measurement of observed usage is a lower bound and proves no global bound
  (0010, step 2 acceptance and the clarification of 2026-09-18).

## Options

**Where externs are declared.**

1. As 0010 wrote it: a separate manifest and overlay, a hand-written port, and
   buffer wiring written by the application.
2. Declarations in the source and constant-receiver calls (`Led.set`), with a
   hand-written board package.
3. The application writes Ruby only. The board package is generated from the
   devicetree, and the glue from the application's declarations.

Option 1 is the one arrangement the survey found nowhere. Option 2 still leaves
per-board ports and glue to the application writer. **Option 3 is chosen.**

**Which contexts may run an entry.**

- Thread only.
- Thread and interrupt.

Thread-only excludes control loops and sampling. What an interrupt handler
needs is no allocation, no blocking, bounded work and a known stack, and those
are exactly what CORE proves. **Thread and interrupt are chosen.**

**How to reach the network.** Socket calls block and take packet buffers from
pools, so they cannot be CORE externs. **A queue boundary is chosen:** CORE
reads and writes fixed-capacity queues, and a Zephyr thread does the blocking
work.

**How to bound Zephyr's own stack use.**

- A static upper bound over Zephyr's objects. Indirect calls through driver
  vtables and callbacks make this research.
- An attested reserve, bound to the configuration, with the painted-stack
  measurement as a falsification check.

**The attested reserve is chosen (A).** The report says that the verdict rests
on attestation.

**How to protect state shared between contexts inside externs.**

- Forbid passing it to externs.
- Add an atomic-access contract with provider evidence.

**Forbidding it is chosen (B).**

## Decision

### 1. Target and toolchain

- **Pinned Zephyr.** One Zephyr release and one Zephyr SDK are pinned when
  implementation begins. They are installed on both hosts outside the
  repository and recorded in [provenance](../provenance.md) with an
  installation record, as LLVM 23.1.1 is. Zephyr's Python environment lives
  inside that installation.
- **Boards.**
  - `mps2/an521/cpu0`, a secure image without TF-M, under
    `qemu-system-arm -machine mps2-an521`.
  - FRDM-MCXN947, under the board target name the pinned Zephyr uses. The name
    is recorded when confirmed.

  The security configuration of each board target is recorded as an
  assumption of the stack evidence (§9).
- **One compiler for our code.** CORE objects, board adapters, application
  providers and the generated glue are all compiled by the kernel's clang
  (LLVM 23.1.1) for `thumbv8m.main-none-eabi`. The target flags are taken from
  the compile commands the Zephyr build records for the board. They are linked
  into the Zephyr application as objects. Our code is therefore measured by the
  0010 step 2 method, and only Zephyr's own code is compiled by Zephyr's
  toolchain.
- **Stack overhead for the new target.** Step 2's call-overhead table gains a
  `thumbv8m` row, measured from prologues as the other rows were.
- **No floating point.** Builds use `-mfloat-abi=soft`, and a configuration
  that enables the FPU is refused. There is then no floating-point context to
  stack, lazily or otherwise.

### 2. Application source surface

An application is one Ruby file. Its declarations are method calls that do
nothing under CRuby. The application tool reads them from the AST, as the
freestanding lane reads `freestanding_def`.

```ruby
require "spinel/board"                    # generated board package; the simulator under CRuby
require "spinel/net"                      # channel and byte-buffer helpers

state :target, :i32, 1                    # element, count
state :pi,     :i32, 1
channel :telemetry, :out, size: 16, depth: 8, uart: true
every_us 1000, :control, context: :interrupt
every_ms 20,   :ui_tick                   # context defaults to :thread

def control(target, pi)                   # parameters bind to `state` by name
  ...
end
```

- **`state name, element, count`.**
  - The element is a 0007 buffer element: `u8`, `i32`, `u32` or `i64`.
  - The generated glue owns the storage. It zero-initialises the storage and
    aligns it to the element size.
  - An entry receives a `state` by naming a parameter after it.
  - **Application entries have no count parameters.** The count is the
    declared constant. This replaces 0007's count parameter for application
    entries only.
- **`every_us n, :entry` and `every_ms n, :entry`.**
  - Each binds one entry to one periodic trigger, in `context: :thread` (the
    default) or `context: :interrupt`.
  - The application declares no priority (§4).
  - A period the pinned Zephyr cannot represent at the board's tick rate is
    refused at build time.
  - Each entry has exactly one trigger.
- **Entry results.** An entry has no result. The value of its last expression
  is discarded, and failure is a status.
- **Calls through a constant receiver.** `Mod.fn(args)` is admitted when
  `Mod.fn` is a declared extern: a board package member, or an application
  `core_extern`. Every other receiver stays refused.
- **`core_extern` inside a module** declares an extern the application itself
  provides, for a driver the board package does not cover:

  ```ruby
  module Sensor
    core_extern :read, params: [:u32], returns: :i32, isr_ok: true,
                bound: "iterations 1", provider: "drivers/sensor.c"
  end
  ```

  - **Keywords:**
    - `params:` and `returns:` (omit `returns:` for no result);
    - `isr_ok:`;
    - `reads:` and `writes:`, naming buffer parameters;
    - `bound:`, the extern's own worst-case work in 0010's grammar (required);
    - `provider:`, the C source the build compiles.
  - **No `max_calls:` keyword in this milestone.** Every loop in an application
    entry has a derived bound (§6), so every call count is derived.
  - **`no_alloc`, `no_block` and `no_reentry` are not keywords.** Every
    application extern carries them (§6), so they cannot be switched off.
- **What the application writer does not write:** extern declarations for board
  devices, count parameters, sharing declarations, priorities, stack sizes,
  glue, timers or threads.

### 3. Board package generation

**Input.** The final `build/zephyr/zephyr.dts` of the configure step (§8,
step 3). A generator written in Ruby reads the DTS text.

**Device classes.** The first set has one hand-written adapter per class.

| class | devicetree source | Ruby surface |
|---|---|---|
| `Led` | `gpio-leds` | `set(index, duty)` |
| `Button` | `gpio-keys` | `read(index)` (polled) |
| `Pwm` | `pwm-leds` | `set(index, value)` |
| `Adc` | `io-channels` of `zephyr,user` | `latest(index)` |
| `Clock` | the system timer | `uptime_us`, `cycles` |

Each adapter has three parts:

- C over the Zephyr driver API in a non-blocking form. For example, the `Adc`
  adapter samples in the background and `latest` returns the last completed
  value.
- A CRuby simulator that records calls and replays scripted inputs.
- The declaration template.

**Effects follow the device instance, not the API.** A GPIO write through a
memory-mapped controller does not block, but the same write through an I2C
expander does.

- The generator decides `isr_ok` and blocking for each instance from an effect
  table keyed by the controller's `compatible` and its bus.
- Each row names the Zephyr release it was established for, and its evidence:
  a documentation reference or a measurement.
- A driver missing from the table, or a row for another release, generates an
  instance that is not `isr_ok` and not known to be non-blocking. Under
  `realtime` it is refused.
- A class whose instances differ in effect is split into two modules.
- The table's verdict is attestation, never proof.

**Outputs, for each board build:**

- the board module: constants from aliases and labels, counts, declarations;
- the CRuby simulator;
- the adapter C;
- provenance: the Zephyr release, the sha256 of the final DTS and of `.config`,
  the compile flags, and the effect-table revision.

The adapter objects' measurements belong to §8, step 5.

**No stored copy to go stale.** Every build and every host run regenerates the
board package. The application's references are resolved against the fresh
package:

- a reference to a member the board does not provide is a build error;
- so is a signature mismatch;
- so is an effect the calling context requires but the member lacks, such as
  `isr_ok` from interrupt context.

The same source therefore builds on every board that provides the members it
uses. Generated outputs are not tracked. The `board` command writes them where
the application writer can read them.

### 4. Execution model and actors

**One invocation is one release's work.**

**Contexts.** A context is the generated scheduler thread, or one interrupt
source. An interrupt source is an exception or IRQ line, identified by its
vector, not by a pin.

- Entries in the same context run one after another and never preempt each
  other.
- Entries in different contexts can preempt each other.
- All timer-driven interrupt entries share the system clock interrupt, which is
  one context.
- The target is single-core. Only `cpu0` of `mps2/an521` runs.

**Every actor and its context:**

| actor | context |
|---|---|
| scheduler thread: runs thread entries | the thread context |
| timer dispatch: runs timer-driven interrupt entries from `k_timer` expiry | system clock interrupt |
| transport thread: drains `:out` channels, fills `:in` channels, drains record buffers | its own thread |
| `Adc` background sampler: publishes each channel's latest value word-atomically | the ADC driver's completion context |
| failure handler (below) | the failing entry's context |
| recorder, verification builds only (§10) | each recording context |

Actors other than CORE entries are generated or adapter code, and they follow
the same rules for shared data (§5).

**Each device has one owning context.**

- A device is a devicetree node that a board module instance drives. Two
  modules that wrap the same node, or the same controller channel, are the
  same device. The generator records which node each instance drives, so
  ownership is decided by the node, not by module names.
- Every device is used from exactly one context. The context is derived from
  the call sites. A device reached from two contexts is refused, and there is
  no exception for operations that are safe to call concurrently.
- `no_reentry` concerns callbacks into CORE. It says nothing about two CORE
  callers overlapping, which this rule covers.

**Releases and scheduling (E).**

- **Releases.** Each periodic entry has releases numbered `r = 1, 2, …`.
  Release `r` is pending from time `epoch + r × period`.
- **The clock** is a free-running hardware cycle counter read through
  `k_cycle_get_64()`, with its frequency recorded. It must advance while
  callbacks run.
  - Zephyr's logical uptime does not qualify. While timeout callbacks run,
    `k_uptime_ticks()` reports the tick being announced, not physical time.
  - That the chosen counter advances during a callback is a property of the
    pinned Zephyr. It is confirmed by the long-interrupt test in Validation. If
    it does not advance, a dedicated hardware timer is used instead.
- **Selection.** To select an entry, the dispatcher reads the clock once, at
  time `t`. The entry's newest pending release is then
  `floor((t − epoch) / period)`.
  - If that release is newer than the entry's last run release, the entry runs
    once for it.
  - Every release strictly between the two is recorded as skipped. Skipped
    releases are never caught up.
  - If nothing newer is pending, the entry does not run.
  - The reading at selection is authoritative. An interrupt that lands between
    selection and start delays the start, and does not change the decision.
- **Thread context.** The scheduler thread repeats a sweep:
  1. Wake at the earliest pending release of any thread entry.
  2. Visit every thread entry once, in declaration order, applying the
     selection rule with a fresh clock reading per entry.
  3. Sleep until the next release.

  A sweep never restarts from the first entry, so an entry that is due often
  cannot starve the ones declared after it. Two entries due at the same time
  record no skip unless the first runs past the second's next release.
- **Interrupt context.** Each `k_timer` expiry applies the selection rule to
  each timer-driven interrupt entry in declaration order. The timeout subsystem
  may deliver several late expiries in a row. Those that find nothing newer
  pending do nothing, so a late expiry never runs an entry twice for one
  release.
- **Records.** Skip records carry the entry, the release numbers and the clock
  reading at selection (§10).

**Priorities** are those Zephyr configures for each exception and interrupt.
The application declares none. The nesting assumption comes from the
configuration-bound inventory of §9.

**Failure.** When an entry returns a status other than `OK`:

- its writes before the failure remain, as 0007 specifies;
- the handler records the entry, the status and the release;
- the handler stops every entry of that context and puts every device that
  context owns into its safe state (for example PWM 0);
- every device has one owning context, so no entry left running can undo that
  safe state;
- entries in other contexts continue.

Customising this policy is future work.

### 5. Shared data and channels

**Writing context.**

- An entry *writes* a `state` if it, or any helper it reaches, assigns an
  element of a buffer bound to that `state`, or passes it as a `writes:`
  argument of an extern. This transitive write-effect inference over the
  admitted closure is **new analysis**. It is not an existing report field.
- A `state` is *cross-context* if entries in more than one context reach it.
  Each cross-context `state` must have exactly one writing context. A state
  written from two contexts is refused.

**Cross-context state is touched only by CORE code (B).**

- Passing it to an extern, whether as a `reads:` or a `writes:` argument, is
  refused.
- Context-private state may be passed to externs under the usual mode rules.

**Access to cross-context state.**

- **The contract is coherent single-copy atomic behaviour per element.**
  - Each access that can reach cross-context state is an LLVM atomic load or
    store with `monotonic` ordering on an aligned element.
  - For each element there is one modification order, the writer's.
  - A reader never sees a torn value.
  - A reader never sees an earlier value after a later one of the same element.
- **The number of physical accesses is not part of the contract.** LLVM may
  merge or elide some `monotonic` accesses. Verification builds record each
  source-level access (§10), and their recording calls stand between accesses,
  so nothing is merged across them. The recorded accesses are therefore the
  source's.
- A helper reached with both private and cross-context buffers is compiled with
  atomic accesses throughout.
- **Admitted elements.** Admitted elements are those the target accesses
  single-copy atomically when aligned. On Cortex-M33 these are `u8`, `i32` and
  `u32`. `i64` is refused.
- **No ordering across elements.** `monotonic` gives no ordering between
  different elements, so a reader may see a mix of old and new values across
  elements. State that needs consistency across several values goes through a
  channel.

**Channels** are generated single-producer, single-consumer rings of
fixed-size messages.

- `Name.put(buf, n)` (named `send` when this was accepted; D4, below):
  - requires `1 <= n <= size`. `n < 1` is an `ARGUMENT` failure and
    `n > size` is a `BOUNDS` failure;
  - `buf` is bounds-checked for `n` bytes;
  - returns 1 when queued, and 0 when the queue is full, in which case the
    queue is unchanged.
- `Name.get(buf)` (named `recv` when this was accepted; D4, below):
  - requires `buf` to hold at least `size` bytes, checked at build time from
    the `state` declaration;
  - returns the dequeued message's length, which is always at least 1, or 0
    when the queue is empty.

  Messages are never empty, so 0 means only "empty".
- **Queue behaviour.**
  - `depth` is the exact usable capacity.
  - A queue starts empty.
  - Order is first in, first out.
  - A queued message is delivered once and never duplicated.
- **Publication.**
  - The producer copies the payload and length into the slot, then publishes
    the head with release ordering.
  - The consumer reads the head with acquire ordering, copies the payload and
    length out, then publishes the tail with release ordering.
  - The producer reads the tail with acquire ordering.
- **One producer context and one consumer context.** The transport thread is
  the consumer of an `:out` channel and the producer of an `:in` channel, and
  it counts in that accounting.
- **Capacity is a contract** (0010's clarification of 2026-09-18). A full queue
  refuses deterministically and writes nothing.
- **Inbound drops.** The transport drops an inbound message for one of exactly
  two reasons, and counts each drop by reason:
  - the message is longer than `size`;
  - the channel is full when the transport attempts the enqueue.

  A channel-full drop is legal only if the channel's occupancy at that attempt
  equals `depth`. Verification checks exactly that (§10). No other loss is
  permitted.
- **Transports.**
  - `uart:` is implemented in this milestone.
  - `udp:` and `mqtt:` are designed here and implemented next. Endpoints,
    network interfaces and TLS material then come from Zephyr configuration and
    a secrets file outside the repository.
  - `udp:` on an `:out` channel is implemented since 2026-10-22 (see the
    clarification of that date, below); `udp:` on an `:in` channel and `mqtt:`
    are still refused as not implemented.
- **Request and response** are two messages, in different periods, correlated
  by an identifier in the payload. No call waits for a reply.

### 6. Extern effect contract (amends 0010 step 3)

- **Required effects.** Every application extern is `no_alloc`, `no_block` and
  `no_reentry`.
  - `no_block` on every extern strengthens 0010, which requires it only under
    `realtime`. Application entries always build under `realtime` (§8), so the
    two coincide there, and the strengthening is stated rather than implied.
  - DOOM entries have no externs and are unaffected.
- **`isr_ok` is added.** An entry in interrupt context may call only `isr_ok`
  externs.
- **Semantics unchanged from 0010:** `reads` and `writes` (feeding the mode,
  aliasing and writing-context rules), and `bound` in 0010's grammar. An
  extern's `bound` adds to the calling entry's work bound.
- **Call counts are always derived (C).**
  - Every loop in an application entry must have a derived bound.
  - `max_calls` of an extern per entry invocation is **the sum over its call
    sites** of the product of the derived bounds that enclose each site. The
    count is composed through helpers: a call inside a helper counts once for
    each invocation of that helper.
  - Both arms of a conditional are counted, which over-approximates soundly.
  - The extern's own `bound`, weighted by its call count, adds to the entry's
    work bound. This follows 0010, which sums over loop nests and multiplies
    only within a nest.
  - Examples:
    - two calls without a loop count 2;
    - loops of 2 and 3 in sequence count 5;
    - a call in a loop of 3 inside a helper called twice counts 6.
  - A declared `max_calls` enforced by a counter that returns `CAPACITY` is part
    of 0010 step 4's remainder, and not part of this milestone.
- **Where externs are declared.** Externs are declared in the generated board
  package or by `core_extern`, not in a separate manifest.
  - Meaning lives in the declaration.
  - Target-specific evidence lives in the measurement record of that board
    build (§8, step 5).
  - No file can set both, so 0010's control "an overlay sets a semantic key"
    has no input to apply to. That is recorded here as its disposition.
- **Provider evidence is `attested`.**
  - The evidence is the provider object's sha256, its undefined symbols, its
    stack by the step 2 method, the effect-table row, and the adapter or
    provider tests. All of it is bound to the target triple and to the board's
    DTS, `.config` and flags digests.
  - A record for another target or configuration is refused.
  - A **screen** reads the provider object's undefined symbols and refuses the
    object if they include:
    - a listed allocating or blocking Zephyr primitive (for example
      `k_malloc`, `k_heap_alloc`, `k_sleep`, `k_msleep`, `k_sem_take`);
    - a listed interrupt-configuration primitive (for example
      `irq_connect_dynamic`, `arch_irq_enable`, `arch_irq_disable`, or setting
      an interrupt priority);
    - any CORE entry export or generated entry wrapper, which would re-enter
      CORE.

    An application's own provider (`core_extern ... provider:`) is also
    refused if its object has any undefined symbol. Its stack evidence is its
    own frame, so a call outside it would have no stack figure (the coordinator's
    correction, 2026-10-22: a provider's `printk` overran the scheduler
    stack).

    The screen covers direct calls only. Calls through function pointers stay
    attested, so passing the screen is evidence, not proof. It gives inputs to
    0010's "provider without `no_alloc`" control and "provider without
    `no_reentry`" control, and to §9's rule against dynamic interrupt
    reconfiguration.
- **Not part of this milestone:** `derived` provenance (an extern implemented
  by another CORE entry), and with it 0010's stale-derived-provider control;
  and 0010's `status` form of externs.
- **Undefined symbols.** An application entry object's undefined set must equal
  its declared externs. DOOM entries keep the empty set.

### 7. Text as bytes

- Ruby `String` objects remain refused. They are allocated, garbage-collected
  and of unbounded length.
- A string literal is admitted as the argument for a read-only `u8` buffer
  parameter. It is lowered to constant data in the object, and its count is its
  length. 0010's rule of 2026-09-18 on data references permits this.
- `spinel/net` provides `put_u8`, `put_u16`, `put_i32`, `put_str` and `put_dec`
  (decimal, at most 20 digits). Each takes a buffer and a position and returns
  the next position.
- These helpers are written in admitted CORE Ruby, so the same file runs under
  CRuby. They are written so that every loop has a derived bound (§6). For
  example, `put_dec` counts to 20 digits and breaks early, rather than looping
  while the value is non-zero.
- A write past a buffer's end is a `BOUNDS` failure, and nothing is written
  outside the buffer.

### 8. Build order and generated glue

`spinel-core-app build app.rb --board <board>` (name provisional).

- Each step consumes only the outputs of earlier steps.
- Configuration is fixed at step 2 and verified unchanged at step 11.
- Everything before step 11 is written to a staging directory and is not a
  deliverable. Firmware reaches the output location only when step 11 passes.
  On any failure the staging directory is removed and no firmware exists.

1. **Declarations.** Read `state`, `channel`, `every_*` and `core_extern`.
2. **Configuration and skeleton.**
   - Generate the application's devicetree overlay and Kconfig fragment from
     the declarations and the board: the UART for channels, and in verification
     builds the ADC and GPIO emulators.
   - Write a fixed project skeleton: a `CMakeLists.txt` template that names
     generated source and object files it does not yet need. Neither depends on
     any CORE output, and nothing later changes the overlay or the fragment.
3. **Zephyr configure.** Produce the final DTS, `.config` and the recorded
   compile flags. Nothing is linked.
4. **Board package.** Generate it from the final DTS (§3), and resolve the
   application's references against it.
5. **Providers and evidence.** Compile the board adapters and application
   providers with the kernel's clang and the recorded flags. Then measure:
   - stack by the step 2 method;
   - undefined symbols, with the screen of §6;
   - the digests.
6. **Interrupt inventory.** Build the configuration-bound inventory of §9 from
   the final DTS, `.config` and the attested reserve table. A source without an
   attested row stops the build here.
7. **Kernel.** For each entry, write an internal contract in the existing
   format extended for application entries: context, buffers bound to constant
   counts, the cross-context marker, and declared externs. Then check and build
   the objects and reports under `realtime`, composed with the evidence of step
   5. The checks are the existing ones (allocation, recursion, admitted forms)
   plus:
   - interrupt-context calls go only to `isr_ok` externs;
   - each cross-context `state` and each channel end has one writing context;
   - cross-context state is never passed to an extern;
   - cross-context elements are single-copy atomic;
   - each device has one owning context;
   - every loop has a derived bound;
   - call counts are derived (§6);
   - constant-receiver calls and string literals are admitted where §2 and §7
     allow them.

   The undefined set must equal the declared externs.
8. **Glue.** Generate:
   - storage;
   - entry wrappers;
   - the scheduler thread and timer dispatch;
   - channels;
   - the failure handler;
   - in verification builds, the recorder.

   Compile the glue with the kernel's clang, and measure it by the same method.
   Compute stack sizes and check both inequalities of §9 from steps 5–8.
9. **Zephyr build.** Link the image into staging with `west build`.
10. **Artifact checks, on the linked image.**
    - The DTS and `.config` digests equal those that the evidence of steps 4–8
      is bound to.
    - The image's thread stack sizes and `CONFIG_ISR_STACK_SIZE` equal the
      values §9 checked.
    - Each declared extern resolves to the measured provider object.
    - Every vector and interrupt slot of the image, after word 0, falls into
      one of the five classes of §9.
    - The objects linked are the ones measured.
    - The image fits the board's memory.
11. **Publish.** Copy the firmware and its reports to the output location.

DOOM contracts, their kernel invocation and their objects pass through none of
these steps, and must not change.

### 9. Stack budgets on Cortex-M

Each inequality lists every consumer.

- **Evidence kinds.**
  - Terms from our code are `measurement` by the step 2 method.
  - Terms from Zephyr's code are `attestation`: a reserve per item, for the
    exact pinned release and configuration, with its method named.
  - Assumptions are `declaration` evidence: no FPU, the security
    configuration, single core, and the inventory's scope.
- **Verdict.** Under `realtime`, a `pass` may rest on attestation, and the
  report says so.

**The interrupt and exception inventory** is built from the configuration at
step 6, not read from the linked image. An interrupt table lists handler
addresses. It says nothing about enable state, priority or masking.

- **Scope.** The inventory lists every exception and interrupt that can become
  active:
  - Zephyr's system exceptions: SysTick or the system timer, PendSV and SVC;
  - each interrupt that an enabled driver connects;
  - every interrupt the glue connects. The glue connects none directly: it uses
    `k_timer` and driver APIs.
- **Driver interrupts come from attested driver rows**, not from the
  `interrupts` property alone. A driver may connect its interrupt with
  `IRQ_CONNECT` or `IRQ_DIRECT_CONNECT` and choose the priority in code. Each
  row states, for its compatible and the pinned release:
  - which interrupts the driver connects;
  - where each priority comes from;
  - whether the driver changes enable state or priority after initialisation.
- **Exceptions outside the budget.** HardFault and the configurable faults end
  the run, and are declared out of scope. NMI must be unused in the
  configuration. A configuration in which any driver can raise NMI is refused.
- **Each inventory entry carries:**
  - its priority;
  - the priority grouping in effect;
  - an attested handler reserve. The reserve covers Zephyr's common
    architecture entry, exit and dispatch paths, including the PendSV context
    switch.
- **Consistency with the image.** At step 10, the linked image's vector and
  interrupt tables are compared with the inventory.
  - **Word 0 is excluded.** It is the initial stack pointer, which is data, not
    a handler.
  - **Every other slot is classified into exactly one of five classes:**
    - a **budgeted source**: a slot with an inventory entry;
    - the **reset handler**: slot 1, Zephyr's startup path. It runs once,
      before any budgeted context exists, and is outside the budget;
    - a **terminal handler**: NMI and the fault handlers (HardFault,
      MemManage, BusFault, UsageFault and SecureFault), named in a fixed list
      for the pinned release. These slots are present in every image, are
      outside the budget, and are not evidence that the source is enabled;
    - a **reserved slot**: a position the architecture reserves, holding zero;
    - an **unused slot**: a slot that points at Zephyr's default, reserved or
      spurious handler, as named for the pinned release.
  - A slot that fits none of these fails the build, for example a connected
    handler with no inventory entry, or a non-zero reserved slot.
  - The check covers which handlers are present. Priority and enable state
    rest on the rows.
- **Dynamic reconfiguration.**
  - Our providers may not reconfigure interrupts. The screen of §6 refuses the
    interrupt-configuration primitives it can see.
  - Inlined register writes and wrapped calls are not visible to the screen, so
    the no-reconfiguration property of an adapter is also part of its
    attestation.
  - A driver row that declares post-initialisation changes must attest the most
    conservative envelope of those changes.
- **Unknown sources.** A source without a row, or a row for another release or
  configuration, makes the verdict `unknown`. Under `realtime` the build then
  fails.

**Thread stack (PSP) of the scheduler thread**, requirement `R`:

```
glue frames (scheduler loop, wrapper, failure handler, recorder in
             verification builds)
+ max over thread entries (worst entry path, including extern stacks)
+ Zephyr's cost on the thread stack (the context switch, the kernel calls
  the glue makes, and any guard or reserved area the configuration takes
  from the stack)                                          [attested]
+ the hardware exception frame an interrupt pushes on PSP:
  32 bytes without FP, plus alignment padding up to 4 bytes
= R
```

The transport thread has its own requirement of the same form, over its own
glue and Zephyr's UART calls, with attested terms.

**Interrupt stack (MSP)**, shared by all nested handlers:

```
sum over the worst nesting chain of the inventory's priorities of
  ( hardware frame + alignment padding            [on MSP, for nested entries]
  + handler cost )
<= CONFIG_ISR_STACK_SIZE
```

For the system clock interrupt, the handler cost is:

- Zephyr's timer dispatch (attested);
- plus the timer-dispatch glue;
- plus the worst interrupt entry path, including extern stacks.

**What is independent, and what is not.**

- The generated thread stack size is set to `R`, so "size ≥ requirement" is
  true by construction and proves nothing about `R`.
- `R` rests on its terms: measurement for our code, attestation for Zephyr's,
  and the falsification below.
- Two gates are independent of `R`. They check feasibility, not correctness:
  - `R` must not exceed the board's maximum thread stack, stated in the board's
    attested data;
  - the linked image must fit the board's memory.
- `CONFIG_ISR_STACK_SIZE` is configuration, not generated, so the interrupt
  inequality is a real comparison.

**The painted stack tries to falsify the evidence.**

- In verification builds, the thread and interrupt stacks are painted.
- Runs force nesting and exercise the failure and recorder paths.
- A high-water mark above the static value refutes the evidence and fails
  verification. A mark below it confirms nothing beyond that run.

**Undersized controls.**

- A build whose generated thread-stack allocation is altered to `R − 1` before
  the link must be refused by step 10.
- A configuration whose `CONFIG_ISR_STACK_SIZE` is below the interrupt
  requirement must be refused at step 8.
- A configuration that enables the FPU must be refused.

### 10. Host reference and verification

**The oracle.** CRuby runs the same application file with the generated
simulator. A host runner releases entries on a virtual clock, with the
scheduling of §4.

- The runner applies the checked-domain discipline of the existing
  [arithmetic reference](../core/buffer-boundary.md). A result outside the
  domain is `ARITHMETIC`, as in CORE, not a Ruby Bignum.
- It also checks `BOUNDS` and the channel argument rules.

**Two kinds of verification, and what each covers.**

- **(a) Semantic verification** runs a *verification build*, which serialises
  recorded operations. It establishes the application's behaviour against the
  CRuby oracle, and the integrity of the trace.
- **(b) Primitive concurrency verification** runs the *production* primitives,
  unmasked and unrecorded. It provides:
  - production-artifact stress evidence, for the preemptions it observes,
    that the channel ring and cross-context accesses behave correctly;
  - static checks of the atomic lowering.

  It does not establish that every instruction boundary or every interleaving
  was exercised. No claim of exhaustive preemption coverage is made.

Neither covers the other's subject. Each acceptance result below names the
artifact it covers.

**(a) Linearised events, verification builds only.**

- **Critical section.** Every recorded operation is performed together with the
  appending of its record inside one critical section:
  - it saves `PRIMASK`, sets it, and restores the saved value afterwards, so
    nested sections restore correctly;
  - `PRIMASK` masks every exception of configurable priority, including
    Zephyr's zero-latency interrupts, which `BASEPRI` locking does not mask.
    NMI is unused (§9), and HardFault ends the run.
- **Compiler barriers.** Entering and leaving the section are compiler barriers
  (`asm volatile` with a `memory` clobber). The record append is reached
  through them, so the compiler cannot move the recorded access across the
  section, whatever the append's own attributes or link-time optimisation.
- **Nothing inside may block.** The append writes into a fixed ring and never
  waits. When the ring is full it sets an overflow flag instead, and
  verification then fails. Nothing inside the section yields.
- **Recorded operations:**
  - each cross-context load or store;
  - each channel enqueue and dequeue, by CORE code or by the transport;
  - each selection decision, with its clock reading;
  - each invocation's start and end.
- **Consequence.** The target is single-core, and no actor that can touch a
  recorded object runs while the section is held. The global sequence number
  taken inside the section is therefore the order in which the operations took
  effect.
- **Timing perturbation.** The masked windows perturb timing. Verification
  builds are not production builds, and stack evidence is computed for both.

**(b) Production primitives, unmasked.**

- **Stress runs.** A test application built exactly as production (no
  recorder, no masks) runs the channel ring and cross-context accesses under a
  high-rate timer interrupt. The interrupt preempts a thread consumer, and a
  thread producer, at varying points.
- **Detection by content.**
  - Each message carries a sequence number and a checksum. The consumer checks
    FIFO order, no duplicate, no loss of accepted messages, and payload
    integrity.
  - Each shared word carries a self-checking value, the low half and the
    complement of the high half. The reader checks it for torn values, and for
    coherence: it never observes an older value after a newer one.
- **Coverage evidence.** In the stress build, the interrupt reads the
  preempted program counter from its exception frame and counts hits in the
  ring's copy and publication ranges. Acceptance requires hits inside both
  ranges, for both directions.
- **Artifact checks.**
  - The optimised IR that code generation consumed (0010 step 2) shows every
    cross-context access, and every ring index access, as an atomic operation
    with the specified ordering.
  - The object shows each cross-context access as one load or store
    instruction of the element's width, with no paired or multiple transfer.

**Record buffers.** Each context appends to its own record buffer, which is
single-producer and single-consumer. The transport thread drains the buffers
over UART. An overflowing buffer makes the trace incomplete, and verification
fails.

**Run lifecycle.** A verification run is finite by construction.

- **Horizon.** The stimulus script states a horizon `H` in clock time.
  - A release is admitted only if its pending time is strictly before `H`.
  - The stimulus ends before `H`.
- **Every admitted release ends in exactly one terminal class**, recorded in
  the trace:
  - *run*: selected and started;
  - *skipped*: by the rule of §4;
  - *cancelled by failure*: its entry's context was stopped by a recorded
    failure before the release was selected. Cancellation records name that
    failure, and are written when the context stops, for every admitted
    release that has not been classified;
  - *cut by horizon*: still pending, and not selected, when the clock reaches
    `H`. At `H` the dispatchers stop selecting, and write one cut record per
    entry covering those releases.
- **Quiescence.**
  - An invocation selected before `H` runs to completion, and may still send.
  - The end sequence begins only after every context has ended every
    invocation it started.
  - Only then does the transport drain the outbound queues to the UART.
  - Inbound messages still queued are reported as unconsumed. An unconsumed
    message fails verification, unless its consumer context was stopped by a
    recorded failure. It is then reported as *stranded by failure*, together
    with that failure.
- **End.**
  - After quiescence and draining, or after a bounded time `D` from `H`, the
    recorder emits an end marker.
  - The marker states whether quiescence and the drain completed. If either
    did not, the trace is incomplete.
  - A failed run ends the same way. Its failure record is the expected outcome
    only if the stimulus script declared that failure.

**Trace contents.**

- **Start.** The initial state: all storage zero and all channels empty. Also
  the clock's epoch and frequency.
- **Every event:** the global sequence number, the context, the entry and its
  release number.
- **Selections:** the clock reading, the release chosen, and the releases
  skipped (§4).
- **Invocations:** start and end.
- **Cross-context accesses:** the state, the element index, load or store, and
  the value.
- **Channel operations:**
  - the channel, the operation, the message identifier, and the result
    (queued, full, empty);
  - the message identifier is a per-channel counter, assigned at a successful
    enqueue;
  - the payload bytes and length.
- **Transport events:**
  - each inbound message received, with the identifier of the stimulus item it
    came from;
  - each outbound message handed to the UART;
  - each drop, with its reason (§5).
- **Per invocation:**
  - each extern return value;
  - each extern call with its arguments;
  - the status;
  - the entry-private state at exit.
- **End:** the end marker.

**Checks.** Each check is independent of the replay.

1. **Workload and timing.**
   - Every admitted release has exactly one terminal class, and each class
     is justified:
     - *skipped* by the recomputation below;
     - *cancelled by failure* only after a recorded failure in that entry's
       context, and only for releases not yet selected;
     - *cut by horizon* only for releases pending at `H`.
   - For every selection, the host recomputes the newest pending release from
     the recorded clock reading, the epoch and the period. The chosen release
     must be exactly that, and the skipped set exactly the releases strictly
     between it and the last run release.
   - Every stimulus item appears.
   - There is no gap in sequence numbers.
   - The end marker is present, and states completed quiescence and drain.
2. **Channel conservation, from linearised events.**
   - Occupancy is reconstructed from enqueue and dequeue events. A `put`
     returns 0 exactly when occupancy equals `depth`. A `get` returns 0
     exactly when occupancy is zero. A channel-full drop occurs exactly when
     occupancy equals `depth`.
   - Every enqueued message is dequeued exactly once, first in first out,
     before the end marker, or is reported as stranded by failure.
   - Every inbound stimulus message is enqueued, or is dropped for a reason
     that the check confirms: its length, or the occupancy.
   - Every dequeued outbound message is handed to the UART.
3. **Shared-state linearisability.** For each state and element:
   - the modification order is the writing context's stores, taken in global
     sequence;
   - **each load returns the value of the latest store to that element before
     it in global sequence**, or the initial value if there is none.

   This is stronger than per-element coherence. It is exact under the
   conditions of (a) above.
4. **Replay.** Each invocation is replayed under CRuby with its recorded
   inputs: extern returns, loads and `get` results. Its outputs must match
   byte for byte: extern calls, stores, enqueues, status, and private state at
   exit.

**Mutation controls.** Each of these must make verification fail:

- a dropped inbound message, with and without an incremented drop count;
- a channel-full drop recorded while the occupancy was below `depth`;
- a duplicated message;
- a corrupted payload byte;
- a load replaced by an older value of the same element;
- a load that regresses to an earlier value after observing a later one;
- a truncated trace;
- a trace without an end marker, and one whose drain timed out;
- an overflowed record buffer;
- a selection that chose an older release than its clock reading allows;
- a skip recorded that its clock reading does not justify.
- a release left without a terminal class, or given *cancelled by failure*
  without a recorded failure in its context.

**Inputs on QEMU.** A verification-only thread sets `zephyr,adc-emul` and
`zephyr,gpio-emul` from the stimulus. Buttons are polled by thread entries. No
claim of interrupt context depends on the GPIO emulator, because its callbacks
run in the injecting thread.

## Validation

**Negative controls.** Each lands with an input that makes it fail, and that
input is kept (0010, "what makes a check a check").

- **Carried from 0010 step 3:**
  - an undeclared extern;
  - `writes` on an `in` buffer;
  - a provider refused by the screen of §6: one control for an allocating
    symbol, one for a blocking symbol, one for a CORE entry symbol (the
    `no_reentry` control), and one for an interrupt-configuration symbol;
  - evidence for another target or configuration.
- **Dispositions:** 0010's `max_calls` run-time control moves with step 4's
  remainder. Its overlay-key and stale-derived-provider controls are disposed
  of as stated in §6.
- **Added by this record:**
  - a non-`isr_ok` extern called from interrupt context;
  - a `state` written from two contexts;
  - cross-context state passed to an extern;
  - a device used from two contexts, including through two modules that wrap
    the same node;
  - a channel sent to, or received from, two contexts;
  - a loop without a derived bound, in a thread entry and in an interrupt
    entry;
  - a 64-bit cross-context element on Cortex-M33;
  - a reference to a board member the board does not provide;
  - a driver missing from the effect table, generated as not `isr_ok`;
  - an interrupt source missing from the inventory;
  - `put` with `n = 0`, and with `n > size`;
  - a `get` buffer smaller than `size`;
  - a write past a buffer's end: `BOUNDS`, with nothing written outside;
  - the undersized controls of §9;
  - a configuration that enables the FPU.

**Call-count fixtures.** Each has an expected count:

- two sequential calls: 2;
- loops of 2 and 3 in sequence: 5;
- a call in a loop inside a helper that is called twice;
- a call in each arm of a conditional.

**Channel behaviour, in the verification build.** These tests exercise the
semantics (a):

- wraparound over many times `depth`;
- FIFO order, no duplication, and no loss of accepted messages;
- refusal when full, with the queue unchanged;
- 0 from an empty queue;
- an inbound channel driven past full, with every channel-full drop confirmed
  against occupancy.

**Production primitives.** The stress runs of §10 (b) run on the production
build. They require:

- preemption hits inside the copy range and inside the publication range, in
  both directions;
- no content check failing;
- the IR and object artifact checks passing.

**Scheduling.** A verification-only application uses bounded busy work in an
entry, which is an ordinary derived-bound loop and not an extern, to force:

- an entry overrunning its own period;
- one entry delaying another past that entry's next release;
- several missed releases in a row;
- a timer-driven interrupt entry running across several periods, followed by
  the late expiries the timeout subsystem delivers. This also confirms that the
  clock advances during a callback (§4).

Every selection must pass the recomputation of §10, check 1, and nothing may
be caught up. Two entries due at the same time, where the first finishes before
the second's next release, must record no skip. The overrun fixtures must
record their skips.

**Lifecycle.** Two further fixtures:

- an expected-failure run: a context fails partway, and its remaining
  admitted releases are cancelled by that failure;
- a horizon-straddling run: an invocation selected before `H` runs past it,
  and some releases are still pending at `H`.

**Acceptance on `mps2/an521` in QEMU (F).** A sample application exercises:

- one timer-driven interrupt entry, and two thread entries;
- cross-context state;
- one inbound and one outbound UART channel;
- `Led` (real), `Button` (polled, through `gpio-emul`) and `Adc` (through
  `adc-emul`).

It must:

- build under `realtime`;
- run in QEMU;
- pass the four checks of §10 and the mutation controls, on the verification
  build;
- pass the production-primitive runs of §10 (b), on the production build;
- report the stack inequalities with their evidence kinds;
- keep the painted-stack high-water marks within the static values.

**Acceptance on FRDM-MCXN947.** The same source, which uses only members both
boards provide, generates, builds, and passes the gates, the report and the
artifact checks of §8. If the board's devicetree provides `pwm-leds`, a second
sample that uses `Pwm` also builds. Running on the board is the owner's, and is
not part of acceptance.

**Unchanged DOOM.** The DOOM CORE objects are byte-identical before and after
the kernel changes, on both hosts. This is an admission check, not a lane.

**Out of acceptance:**

- `on_edge`;
- UDP and MQTT;
- running on hardware;
- declared loop bounds and `max_calls` with run-time guards;
- `status`-form externs;
- `derived` providers;
- deadlines and WCET.

## Consequences

- **0010 is amended by this record, not edited.**
  - Extern declarations move from a separate manifest to the board package and
    `core_extern`.
  - `isr_ok` is added.
  - `no_block` is required on every application extern.
  - Step 3 is delivered by this record's implementation, except `derived`
    providers and the `status` form, which remain as 0010 defines them.
  - Step 4 applies in full to application entries, in its strict derived form
    and without guards. For DOOM entries, step 4 is unchanged and still to come.
- **0007 is amended for application entries only.** Counts come from `state`
  declarations, entries have no result, and the undefined set equals the
  declared externs. Existing contracts and the DOOM entries are unaffected.
- **The admitted language grows** by constant-receiver calls to declared
  externs and by string literals as constant bytes.
- **New analyses:** transitive write effects, writing-context and
  device-ownership derivation, call counts summed over call sites, and atomic
  lowering of cross-context accesses.
- **Cortex-M33 target facts now exist twice:** in the freestanding lane's YAML
  profile, and in what the Zephyr build records for the board. The
  freestanding lane is not changed here. Unifying or retiring it needs its own
  decision.
- **The no-Python rule gains one exception:** Zephyr's own build.
- **Future work:**
  - `on_edge` and other event entries. These need a real interrupt-injection
    path for verification, since the GPIO emulator does not raise one, and a
    definition of edges, coalescing, and the vector as the context.
  - UDP and MQTT transports.
  - Customisable failure policy.
  - `status`-form externs and `derived` providers.
  - Declared bounds with guards.
  - Further device classes and boards.
  - A static bound for Zephyr's own stack use.
  - Deadline and cost properties (0010 leaves these to their own decisions).
  - A 32-bit integer mode, deferred by the owner on 2026-09-22; the input
    for that decision is the per-entry instruction count, and the share of
    it inside `__aeabi_ldivmod`, that the verification runs record.

## Clarification (2026-10-23): the `udp:` transport, for `:in` channels

Decision 0025 (Accepted by the owner on 2026-10-23) takes a host keyboard's
input over UDP. It does so through §5's `udp:` transport on an `:in` channel,
as §5 designs it. Until it is implemented, the declaration is refused as
before. What 0025 fixes for this transport:

- **The queue is §5's, unchanged.**
  - First in, first out.
  - A message is never empty, and `get` returning 0 means only "empty".
  - The transport drops an inbound message only when it is longer than
    `size` or the channel is full, and counts each drop by reason.
  - Merging several messages into one state is the application's work, not
    the channel's.
- **Before the queue, and not counted as its drops**, the receiving side
  refuses:
  - a datagram from an address other than the network file's host for the
    channel, read from the datagram's source;
  - an empty datagram, which §5 has no message for.

  A datagram longer than `size` is detected and never queued in part.
- **Configuration.** The network file gains `inbound <channel> <port> from
  <address>`:
  - the board's local port, and the one host address accepted;
  - a socket of its own, not shared with an `:out` channel;
  - no restriction on the source port;
  - port 0 switches the channel off, opening no socket, so `get` always
    returns 0.
- **On the FRDM-IMXRT1186** the producer is the M33's network firmware.
  - It feeds a second OCRAM ring, M33 to M7, which makes the ring ABI
    version 2 (0025). Version 2 is not compatible with version 1.
  - The firmware's one thread serves both directions fairly: one send
    attempt per turn, at most one held message, and a receive pass bounded
    by the channel's depth.
  - It is ordinary Zephyr C, outside the CORE budget, as for `:out`.
- **Not decided here**: the attested reserves of the receive path (§9), as
  for `:out`. Until they exist, a production build with a `udp:` channel
  does not pass step 8. That is a disclosure about the transport, not a
  defect of the application.

## Clarification (2026-10-22): the `udp:` transport, for `:out` channels

Decision 0024 sends DOOM's frames over UDP through §5's `udp:` transport.
It is implemented as §5 designs it, for `:out` channels only (the coordinator,
2026-10-22: DOOM needs no inbound UDP, and an `:in` channel would add a
receive path to budget). What the implementation fixes:

- **Declaration.** `channel :name, :out, size: s, depth: d, udp: true`. A
  message is one datagram in one Ethernet frame, so `size` is at most 1472
  (1500 bytes of MTU less 20 of IPv4 and 8 of UDP header). An `:in` channel,
  an endpoint written in the source, both transports on one channel, and
  `mqtt:` are refused as declarations, each naming why.
- **Configuration.** The build is given a network file with `--net`, kept
  outside the repository: the interface, the board's IPv4 address and
  netmask, and per channel the host's address and UDP port
  (`tools/app/lib/core_app/net.rb`). Port 0 switches a channel off. The
  board's Zephyr fragment for the network is added to `prj.conf` only when
  the application declares a `udp:` channel (`zephyr_net_conf` in the board
  table); a board without one refuses the channel. No board table names one
  yet: on the FRDM-IMXRT1186 the owner gave the network to the Cortex-M33
  (2026-10-22), so the M7 application's table has none.
- **The transport thread** is the one thread of §4. It drains the UART
  channels, then the `udp:` ones, one socket per channel, one datagram per
  message with the payload verbatim. A send that finds no buffer keeps its
  message and tries it again on the next pass, so the ring is what fills,
  and a full ring is the producer's `put` returning 0. Any other send
  failure drops that message and counts it in `spc_transport_udp_errors`;
  a run with a non-zero count is not a passing run. There is no other loss.
- **Not yet implemented:** a verification build (§10) with a `udp:` channel
  is refused, since the trace records the UART transport only; and the
  attested reserves of the network path (§9) are not written yet, so a
  production build with a `udp:` channel does not yet pass step 8.
- **Open: a random source.** A trial build for `frdm_imxrt1186_cm7` with
  the network enabled (2026-10-22, before the network went to the M33)
  configured and compiled, and its link stopped at an undefined
  `z_impl_sys_rand_get`. Two callers need it: the network stack's choice
  of a local port (`find_available_port` in `subsys/net/ip/net_context.c`)
  and the NETC switch driver's random MAC
  (`dsa_netc_port_generate_random_mac`). Both are in any image with this
  network stack and driver, so the question stands for the M33's. Three
  ways are open:
  - `CONFIG_TEST_RANDOM_GENERATOR=y`, as Zephyr's DSA sample does. Its
    numbers are not random, and Zephyr's help keeps it to tests and
    samples, so taking it needs a written reason.
  - Need no random number at run time. The board's devicetree already
    gives each switch port a `local-mac-address`, and the random MAC is
    generated only for a port marked `zephyr,random-mac-address`. A socket
    bound to a fixed source port never asks for a port. The symbol is
    still referenced, so the link still needs a provider.
  - A hardware source. At the pin Zephyr has an ELE TRNG driver
    (`nxp,ele-trng`, `entropy_nxp_ele.c`), but the only devicetree that
    declares its node is the MCX W7x one (`nxp_mcxw7x_common.dtsi`); the
    RT118x devicetree has none, so it is not wired up for this SoC at the
    pin. Whether the driver would run on the RT1180 is not checked.

## Clarification (2026-09-23): the owner's decisions D4 and D5

Both were proposed while implementing and decided by the owner on
2026-09-23. They fix names this record left open; they change no behaviour it
describes.

- **D4. The channel methods are `put` and `get`, and that is final.** This
  record named them `send` and `recv` in §5. `send` cannot be the name: it is
  `Object#send`. The pinned analyser expands `X.send(...)` into candidate
  calls named by every string literal of the calling method, which the reader
  then refuses as a dangling reference; and at the CRuby host
  `Telemetry.send(buf, n)` reaches `Object#send` unless the generated module
  shadows it. The symbols are `spc_channel_<name>_put` and `_get`; the trace
  kinds `ENQ`/`DEQ` are unchanged. Every occurrence above is read with these
  names: §5's two method definitions carry the note in place, and §9's
  mutation controls and the Validation section were rewritten to `put`/`get`
  (and "sends" to "enqueues") without a note on each line, since this
  paragraph governs them.
- **D5. A board constant is `Mod::NAME`.** One level: `Mod` is a module of the
  packed root and `NAME` an integer literal written in its body. The generated
  board package carries each class's count, aliases, labels and node names
  inside that class's module, so an application writes `Led::LED0` and
  `Led::COUNT` with no prefix anywhere. A generated name that would collide
  inside a module is refused by name. The checked boundary resolves this form
  and no other: a deeper path, an unknown module, a name the module does not
  carry, and a value that is not an integer literal are each refused, and a
  bare name never reaches a module's constant.

## Clarification (2026-09-22): decisions taken while planning

These complete interfaces that the accepted text leaves open. They do not
change its direction. The implementation plan,
[0014 plan](0014-core-applications-on-zephyr-plan.md), carries the detail.

- **Compiler runtime helpers on 32-bit targets.** The owner approved this for
  now, with "Approved for now" (the owner's words, translated). On Cortex-M33, 64-bit division lowers to AEABI helpers
  such as `__aeabi_ldivmod`.
  - A fixed list of helpers, established by measurement, is admitted as
    board-package externs.
  - Their effects and stack are attested, and they are supplied by the Zephyr
    SDK's libgcc.
  - "The undefined set equals the declared externs" still holds, because these
    helpers are declared externs.
  - Admission is by name, never by prefix.
- **An out-of-range device index is `BOUNDS`.** The owner approved this for
  now. The kernel establishes it before the adapter call, as it does for a
  buffer index.
- **Target facts that the design must respect** were found in the
  predecessor's records at spinel-llvm `463d49dd` and confirmed in part on the
  Mac:
  - ARM objects without `nounwind` reference `__aeabi_unwind_cpp_pr0`;
  - Clang stamps an FP build attribute for Cortex-M33 even in soft-float code;
  - `mps2/an521/cpu0` builds a secure image (`-mcmse`) with soft-float, picolibc
    and libgcc;
  - QEMU under `west` does not exit by itself;
  - CMake's SDK registry can override `ZEPHYR_SDK_INSTALL_DIR`.

  The plan's "Target facts" section assigns each to a task.
- **A 32-bit integer mode** was suggested by the owner the same day, and
  deferred by the owner on the same day to a later stage: this milestone
  computes in 64 bits. The plan records the proposal, and Task 11 records the
  measurement that stage will decide on: instructions per invocation, and
  how many of them inside `__aeabi_ldivmod`, per entry of the acceptance
  sample.
