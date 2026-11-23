# 0008: Move the existing DOOM computation into CORE

- Date: 2026-09-12
- Status: Accepted
- Scope: Stage 2; native Debian x86_64 and macOS arm64. Stage 1 remains accepted.

## Authorization and status

The owner approved proceeding with the state/call-boundary design and a review
of the predecessor compiler patches, then explicitly requested a finished
design followed by implementation instructions to Debian. This document is
that implementation design. The owner accepted it on 2026-09-16 as the
Stage 2 design that implementation already follows. Acceptance approves the
design, not a delivery: Stage 2 is not complete, and its exit criteria below
still apply. Work within the accepted contracts of
[0007](0007-doom-core-preparation.md) can proceed under that instruction.
Any change to its public numeric, ownership, aliasing or failure contract must
be presented as a separate concrete decision before implementation. In
particular, this design does not remove poison or introduce a new CORE status.

The [execution plan](0008-doom-core-migration-plan.md) separates the initial
audit and compatible implementation from any such decision. All new commands,
paths and interfaces described below are planned, not delivered capabilities.

## Context and evidence

The integration base is Extended `5ee37630663d3ad66a9b45f43bf84a09e42132b7`.
The initial compiler pin is `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`.
Stage 1's nine suites pass on both hosts with the documented LLVM 23.1.1
toolchain. That proves thirteen extracted entries, not a whole game closure.

The [closure survey](../core/doom-closure-gaps.md) reports source constructs,
not the reachable tick/render graph: its 571 definitions include setup and
other Full-only work. Its clean count is not an implementation estimate.
Current source gives more concrete boundaries:

- `Game#g_ticker` calls player, thinker and special processing in a fixed order.
- Mobj, thinker, sector and renderer state already use parallel arrays, but
  those are hosted Ruby arrays reached through instance variables.
- `Game#run_thinkers`, `dispatch_action` and `dispatch_psp_action` select named
  functions by integer tags. A generic Ruby `send` mechanism is unnecessary.
- `Render#render_bsp_node`, sight's `cross_bsp_node` and enemy's
  `recursive_sound` recurse. Other call cycles must be inventoried too.
- The interactive loop also updates status-bar/HUD state, consumes `M_Random`,
  chooses a palette and composites the complete screen. Moving only the 3D
  view would leave CPU rendering and game-visible state outside CORE.
- The CORE tool accepts one source snapshot; helpers cannot yet borrow buffers.
- A failed adapter invocation poisons mutable participants, even on CAPACITY.

## Options

1. Compile the existing classes transparently. This requires hosted object
   representation, general dispatch and lifetime machinery in CORE, beyond
   the allocation-free contract and the owner's selected direction.
2. Keep the compiler fixed and inline all computation into one buffer entry.
   This retains the ABI but makes the application unmaintainable and obscures
   independent testing of the game subsystems.
3. Preserve 0007's public ABI, complete checked direct helper calls, and
   refactor the computation into named Ruby functions over explicit storage.
   Package those functions into a verified single source snapshot. Extend only
   the control forms actually needed by the selected closure.

Use option 3. It keeps one maintained computational implementation for the new
hosted and CORE routes, with the pre-refactor Full game as a fixed reference.

## Delivered behavior and exclusions

The final native route computes the same supported game as the existing CPU
example: demo playback and interactive input, game ticks, CPU view rendering,
weapon sprites, status bar, HUD and existing scaling/palette behavior. Preserve
the supported CLI configurations and the exact meaning of their flags. A
configuration not yet migrated must be rejected explicitly by the new route;
it is not covered by final acceptance until migrated or separately scoped out
by the owner.

Full performs WAD/file loading, initial storage allocation, SDL event polling,
clock/pacing, file output and presentation. It may prepare immutable resource
tables before the session starts. It performs no game-state update or pixel
rasterization after initialization on behalf of a native CORE invocation.

No new menus, audio, networking, level transitions, GPU support, WASM or
freestanding target is introduced. Existing unsupported rebirth/level-reload
behavior remains an explicit failure, not a silently continued game.

## Storage and application boundaries

Use four storage roles. All allocations and releases belong to Full.

| role | examples | lifetime and writes |
|---|---|---|
| resource | level geometry, textures, flats, colormaps, lookup tables, glyphs and message bytes | prepared before play; CORE reads only |
| persistent | player/mobj/thinker/sector state, free-list heads, random indices, input history, HUD/status-bar state | session lifetime; CORE updates |
| scratch | clip/plane/drawseg/sprite banks, job schedule, traversal stacks | allocated before play; logical lengths reset by CORE |
| output | indexed framebuffer, selected palette, bounded trace/event records | persistent allocation; CORE writes, Full consumes after success |

Keep a distinct allocation for each buffer, including scratch: 0007 disallows
overlap involving an `inout` range. Do not hide several overlapping views inside
a raw address or weaken the gate. Multiple instances have disjoint mutable
storage; immutable sharing follows the existing `in` rules.

`examples/doom/core/state.tsv` will enumerate every stored field. Its seven
tab-separated columns are `name`, `role`, `element`, `count`, `initial`,
`origin`, `writers`. Names are globally unique. `origin` names the original
class/ivar or explains an added traversal stack; `writers` names the owning
subsystem. No field may disappear from migration through an unlisted accessor.
The audit must classify every ivar reachable from the selected roots as a
stored field, immutable prepared value, eliminated reference-only trace field,
or Full-only value with a reason.

The `count` grammar is `fixed:N`, `level:NAME`, `screen:NAME`, `limit:NAME` or
`table:NAME`. NAME must resolve in the prepared resource/configuration catalog;
there is no evaluation of Ruby expressions from the manifest. Counts remain
u64 at the boundary. Full checks byte-size/address overflow before allocation.
Screen dimensions and products are checked before a session is made live.
The `initial` field is an integer fill or `prepared:NAME`; prepared data must
have exactly the declared length and values fitting its element domain.

Use u8 for byte resources/framebuffers and i64 for general mutable numeric
state initially. Preserve an existing i32/u32 layout where its complete domain
is documented and tested. Do not narrow state merely because its reference
values happened to be small. Flags stored numerically use 0/1 and explicit
comparisons when consumed as Ruby booleans. Scalar fields may share a named
i64 state buffer with generated constant indices; each array keeps a separate
buffer. This is a data layout, not a new Ruby object or pointer type.

Full owns a session wrapper containing registry IDs and configuration. CORE
receives only 0007 scalars and buffers. The wrapper may group state for callers;
the generated native signatures remain flat, named, version-1 signatures.

Three top-level entry names are fixed here; their buffer/parameter lists are
generated from the reviewed state and access manifests:

- `doom_core_input`: consume the 256-byte key-state buffer and a 0/1 recording
  flag, update held-key history, and write a five-element i32 command buffer:
  forward movement, side movement, angle turn, buttons and encoded angle byte.
  Preserve recording's angle quantization before publishing the command;
  success result is zero. For demo playback Full supplies the decoded command
  buffer instead, through checked stores.
- `doom_core_step`: consume that canonical command buffer
  and update game plus post-tick HUD/status-bar state, including random draws
  in the existing interactive-loop order. Success result is the completed
  gametic; no frame is implied by this entry alone.
- `doom_core_render`: render the view, weapon sprites, status bar and HUD into
  the resident indexed framebuffer and produce palette selection. Success
  result is the frame sequence number.

Full polls keys or decodes the demo tuple, selects the input path, and writes
recording bytes after a successful input call. The encoded angle byte is an
unsigned value carried in i32; it never travels through a NUL-terminated string
writer. Tests include held-key history and the quantized command consumed by
the game, not just the recorded file. This keeps input computation reusable for
the later freestanding route while SDL and file handling stay in Full.

`access.tsv` has three columns, `entry`, `buffer`, `mode` (`in` or `inout`).
It lists each participating buffer once. The generator supplies that buffer's
own count and checks every source access against the manifest. Do not replace
these facts with type-based ownership inference.

## Direct calls and source packaging

### Borrowed buffers in helpers

An entry descriptor creates a borrow carrying pointer, immutable count,
element type and access permission. Passing its buffer parameter to a direct
callee forwards that borrow. A callee's ordinary scalar length parameter is
not its access bound; reassigning a length or passing `n + 1` cannot enlarge
the borrow. The existing captured-bound rule holds at every call depth.

Compute helper effects and facts to a checked fixed point and use the same
result in eligibility, selection and lowering. Private functions may specialize
on scalar kind, element type and access mode. A private buffer argument lowers
to pointer plus count; this private signature is not a new exported ABI.
Independent calls with different buffer lengths must not share a stale count.

Read-only permissions can be weakened from `inout` to `in`, never strengthened.
Reject a helper write reached through a read-only entry and any simultaneous
duplicate borrow involving a mutable argument. Repeated read-only arguments
are allowed. Forwarding between sequential calls does not transfer ownership.
Buffers cannot become integers, results, globals, captured values or retained
pointers; rebinding/alias locals remain refused initially. Helper results may
be integer or boolean where derived; exported results stay 0007 integers.
Use explicit integer zero returns for procedures without a meaningful result.
Propagate failure unchanged and publish the entry result only on success.

### Multiple maintained files, one analyzed snapshot

Keep manually maintained, prefixed, top-level functions under
`examples/doom/core/src/`. A source manifest names relative files and exact
SHA-256 digests in deterministic order. A packager reads each file once into a
private snapshot, verifies its digest, joins the bytes with newline boundaries,
and writes a packed Ruby root plus a line-to-origin map and manifest digest.
It adds no caller, evaluates no initializer and changes no expression.

The existing Spinel parser/contract reader validates each captured source unit
and the packed program. The packed definition/constant inventory must equal the
ordered union of the individual inventories; a unit cannot disappear behind an
earlier unit's data section or incomplete syntax. Reject `__END__` data sections
and conflicting source encodings. Accept UTF-8 units for this packager.
Only functions and accepted literal constant definitions may occur at top
level. Reject `require`, `require_relative`, classes/modules, executable
top-level calls, duplicate definitions/constants, escaping paths and unlisted
files. No new Ruby parser or universal AST visitor is introduced. CORE tools
still receive a single immutable root; packaging records both that root's
digest and its source-set provenance. A file changed after capture cannot
change any generated header, object or adapter in the same build.

This avoids merging independently numbered AST dumps or adding a general
module linker. Source locations in diagnostics must map back to maintained
files. Prefix global function/constant names with `dc_` / `DC_`; retain the
existing generated-name and C-identifier checks.

## Control flow, dispatch and recursion

Complete the forms already required by 0007 first: direct helpers, while,
statement conditionals and early return. Admit a missing else only in statement
position. A value-producing missing branch still introduces nil and is refused.
Retain a distinction between an unreachable path and a reachable nil value.

For additional forms needed by the actual closure, use Ruby evaluation rules:
boolean `&&`, `||`, `!` with real short circuiting; nearest-loop `break` and
`next` without values; and buffer operator assignment whose receiver/index
are evaluated once. Begin with statically boolean logical operands. Do not
silently coerce integer zero to false, generalize nullable unions, or change
arithmetic/check ordering. Side-effecting index and random-call controls are
required. Record the extension's exact admitted/refused forms before coding;
if it needs a different domain/failure contract, return that concrete decision
instead of broadening 0007. Unsupported `case`/blocks can be refactored into
explicit integer-tag branches/loops with an adaptation record.

Dispatch uses closed integer-tag sets and direct named calls. Preserve the
existing unknown/no-action behavior for each tag family. Do not route through
Ruby `send`, function pointers or a callback to Full. The literal-symbol `send`
reader defect stays outside this route and is recorded in the patch audit.

All recursive strongly connected components must be listed, including
indirect action/state calls and sound propagation, not only BSP and sight.
Replace each with an explicit, preallocated work stack/state machine; CORE's
general recursion refusal remains. A traversal frame contains its node,
continuation and required local values. Preserve front/back visitation and
the point at which post-child tests execute; reversing a push order can change
the image even when all nodes are visited.

For validated trees a stack sized from node count is a conservative depth
bound. Validate structural cycles and indices during Full resource preparation.
For graph/state-machine algorithms derive the work bound from their existing
visited/state rules. Do not invent a small fixed step quota that truncates a
valid game. Stack exhaustion uses CAPACITY; bounds failures retain BOUNDS.
Document any behavior change for malformed data separately from normal-game
equivalence and test the last admitted capacity and first rejected capacity.

## Failure and session lifecycle

Preserve statuses 0 OK, 1 ARGUMENT, 2 ARITHMETIC, 3 BOUNDS, 4 CAPACITY and
application intrinsic `core_fail(:capacity)` only. All numeric semantics,
descriptor checks, result publication, registry ID lifetime and poison rules
remain those of 0007. Checked arithmetic must not become global wrapping.

Session states are `prepared`, `running`, `failed`, `closed`:

1. Full loads and validates resources/configuration, allocates and initializes
   every buffer, then moves prepared to running.
2. Only running sessions invoke computation. On any nonzero CORE status,
   mark the session failed, preserve the reported numeric status, and do not
   present the incomplete frame or retry against the same state.
3. A failed session can only report failure using already available scalar
   metadata and release storage. It cannot inspect poisoned mutable arrays.
4. A fresh session may be created from the original setup inputs. There is no
   rollback, successful continuation or transparent fallback after failure.

Capacity failure can leave partial writes before poison; preflight checks are
useful but are not permission to claim transactional ticks. The existing CPU
example has no rescue sites in its main computation route. The new session's
explicit fatal failure preserves the supported route's termination behavior,
not a general promise about callers that catch a hosted exception.

Resource-format errors, missing assets and unsupported configurations are Full
setup errors before invocation. Runtime application checks without a matching
CORE category must either be proven by setup validation or be returned for a
separate decision. Do not label an arbitrary error CAPACITY. The unsupported
rebirth request can be rejected by Full using an explicit pre-step scalar
session condition; no partially executed tick may be reported as complete.

## Presentation, copies and runtime independence

Keep resident state and resources between calls. Do not allocate/release per
pixel, column, job or tic. Core computation uses no registry operations itself.

The Full presentation bridge accepts a video handle and framebuffer/palette
registry IDs, validates their type, length and live/non-poisoned state, and
accesses them only under a checked registry lock. Native pointers never become
Ruby integers. A synchronous call to the existing SDL C shim is permitted on
this Full side; there is no callback into Ruby while holding the lock. Any
required staging allocation is made during setup and reused. Separate this
Full I/O result from the CORE status ABI and leave storage unchanged on an
invalid presentation request.

For replay, a Full native writer serializes snapshots with explicit byte
lengths and endianness to an already opened output stream. Do not route binary
data through `puts`, `print` or pointer-sized FFI results. Trace buffers are
bounded and optional; trace-disabled execution must not rely on them.

Gate every optimized CORE object: zero undefined symbols and exactly its
declared entry export. Only the separately linked Full bridge may depend on
malloc, mutexes, libc, SDL or Spinel. Packaging must reject swapping a bridge
object into a CORE slot. Keep ASan functional controls that fault inside an
instrumented kernel; do not claim UBSan covers existing LLVM IR when it does
not.

Report native computation, adapter/validation/locking, transfers and total
step/render time separately. Record copy bytes and allocation counts after
setup, resolution, trace mode and repetitions. Correctness has no speedup
threshold, and kernel-only timing cannot stand in for end-to-end performance.

## Compiler fork patches

The [patch review](../core/doom-stage2-fork-review.md) is part of Stage 2.
Compare the predecessor `spinel-fork` pin `ecbd0f2a` with the actual Extended
pin, using exact reproducers and source evidence. "Not reproduced" is not
"fixed upstream", and successful DOOM tests do not cover all compiler defects.

Keep bug fixes, boundary support and optional optimizations/instruments
separate. A relevant reproduced blocker requires a minimal fix candidate and
controls. Prepare it in an isolated compiler branch; do not edit the checked-out
vendor or bulk merge the predecessor fork. Record changed semantics, upstream
status and both-host compatibility before proposing an exact new pin. The
owner's patch-review approval is not an instruction to select an arbitrary
fork head. Continue unrelated migration tasks while a pin decision is pending.

## Validation and exit criteria

Use three computation routes: fixed pre-refactor Full; refactored Ruby executed
by CRuby and by pinned hosted Spinel; and the same refactored source lowered to
CORE through direct C and Full adapter paths. The old Full source remains an
immutable regression reference, not a second actively edited game. Its existing
manifest and all GPL-derived notices must be retained.

The hosted/reference wrapper supplies `core_fail(:capacity)` as an exception
outside the packed computational source. No conflicting definition is added to
the CORE snapshot. Plain CRuby's growing arrays and arbitrary-size integers are
not failure oracles for CORE bounds/overflow; use the existing checked arithmetic
oracle and native failure harnesses for those rules. Successful game execution
must still agree with unmodified reference behavior.

For each subsystem, compare state after every operation/tic, including random
indices/call order, links/free-list heads and all fields that affect later
behavior. Include deleted slots and unused initialized cells where their bytes
are part of the declared storage model; never compare C padding or unspecified
scratch bytes. Scratch is checked through initialization/access invariants and
outputs. Compare every indexed framebuffer byte, including HUD/status-bar
regions, at every selected frame. Declare exact command/frame counts so empty
or truncated runs cannot pass.

Run DEMO1 5026, DEMO2 3836 and DEMO3 2134 tics, preserving the existing reference
frame-key rules. Keep the independent doomgeneric comparison and its existing
exact, build-scoped allowances. There are no allowances between CORE and the
fixed Full reference. A new mismatch must be resolved or returned as a scope
decision; never expand the C-reference allowance to hide it.

Required controls include: swapped state fields with different values, distinct
per-buffer counts, changed random evaluation order, skipped/duplicated ticks,
wrong traversal order, full/empty pools, last valid/first invalid indices,
overflow with unchanged result, partial-write failure plus poison, two live
sessions, repeated calls without ID growth, missing source/object/adapter,
and a native build that cannot link without the adapter. Negative controls
must reach their intended comparison and match the intended diagnostic.

Both hosts must run the new and affected existing suites with official LLVM
23.1.1, explicit compiler selection and reported skips. `REQUIRE_ALL=1` makes
missing required execution fail. macOS additionally requires real-key
interactive acceptance; do not infer it from synthetic input. Debian runs the
declared freestanding tests; their missing macOS profile remains a Stage 3
target issue, not a failure of this native milestone.

Stage 2 is complete only when tick and full CPU rendering are reached through
the native entries in the playable program, the reference comparisons pass,
CORE artifact gates pass, both hosts accept the exact candidate revision, and
the remaining limitations and performance measurements are recorded. A set of
new helpers or a successful renderer alone is not the milestone.

## Consequences

The source refactor is substantial but uses the existing parallel-array design.
Helper borrowing and source packaging are reusable compiler/product capabilities;
the game schema, resource preparation and explicit traversal stacks are
application work. No public state-object ABI or general-purpose IR is added.
Failed sessions remain unrecoverable under 0007. General exception recovery,
recursive CORE functions, shared writable views and a different poison policy
need separate decisions. Stage 1 results remain valid and independently tested.

## Clarification (2026-09-16): acceptance and later records

The owner accepted this record on 2026-09-16. Two later decisions govern how
its work is carried out, without changing this design:

- [0009](0009-doom-core-test-harness.md) organizes the validation of this
  record's work: validation tiers, the frame-lane harness delivered as its
  Stage 1, and the rules for parallel lines of work on one host. The execution
  plan's line "Do not create additional agents or rebuild shared dependencies
  concurrently" is superseded for agents by 0009's clarification on parallel
  lines of work. Shared dependencies are still not rebuilt concurrently.
- [0010](0010-core-resource-contract.md) adds a resource and realtime contract
  for CORE entries: loop bounds, stack budget, extern effects and a per-entry
  build report. Under its `hosted-stage2` profile, this record's entries gain
  reports only, and the rules this record relies on are unchanged.

## Clarification (2026-09-17): decisions taken during the migration

The owner took these decisions on 2026-09-17, relayed through the supervising
session. They apply this record; they do not change its design.

- **Native rendering runs in job mode 1** (`-jobs`), not the direct path,
  under three conditions:
  - the direct path is not removed until interactive acceptance passes on
    both hosts;
  - the native route asserts that its mode matches the classification;
  - the recording check runs mode 1.

  The ledger therefore names the direct path's code in the render entry as
  unreached in the `direct` configuration (`tools/doom/core-unreached.tsv`).
  Superseded on 2026-10-21: see "Clarification (2026-10-21): rendering in
  job mode 0" above.
- **Fields only an unshipped configuration writes** are listed in
  `tools/doom/core-unreached.tsv`, carried into `state.tsv` as `#unreached`
  lines, and checked by the audit's writer rule. The renderer's trace record is
  the `trace` configuration.
- **Code no demo reaches**, the owner's option (c):
  - Definitions a player reaches in the shipped content are compared from
    synthesised starts (`tests/doom-core/scenarios.rb`).
  - Definitions no shipped content reaches are claimed so in the ledger and
    checked against the IWAD (`tests/doom-core/content-scan.rb`).
  - Which is which was measured by scanning `doom1.wad`.
  - Branches inside definitions that did run are outside that decision and
    remain a stated limit (`tests/doom-core/step-coverage.rb` prints them).
- **An original raise may be ported as `core_fail(:capacity)`.** The original
  (`examples/doom/lib/doom`) stops with `LevelError` where it meets something
  it does not implement, and CORE has no other failure. This is the separate
  decision the previous section requires for a runtime check without a
  matching CORE category. The approval is narrow: an original raise,
  transmitted faithfully, at the same call. Two conditions apply:
  - The reason is written at each port site.
  - A check shows that the port stops where the original stops.

  `tools/doom/core-refusals.tsv` lists every such raise and what stands behind
  each: a stop scenario, a content claim, a setup-time raise, or a stated
  limit. Through the 0007 adapter a refused entry's mutable participants are
  poisoned, so a caller that ignores the status reads obviously broken values.
  Any other use of CAPACITY for a failure that fits no category is still a new
  question.
- **Full refuses the unsupported rebirth before the step**, in the form the
  previous section names. `Doom::Core::Session#before_step!` reads
  `game_pl_playerstate` between tics and raises `RebirthRefused` when it is
  `PST_REBORN`, so `doom_core_step` is not called. This is the only change to
  Full authorised on this date. The port's own refusal inside the step
  (`dc_st_kp_g_ticker`) stays as a backstop the shipped program does not
  reach; the ledger names it `guarded-by-full:rebirth`. With Full's check, a
  rebirth at tic 2 is refused before the wipe's M_Random draws; the backstop
  would refuse after them. The session fails either way. The scenario
  `reborn` shows Full refusing at the tic the original raises. Run with
  `--no-full-guard`, it shows only that the backstop refuses if reached.

## Clarification (2026-09-18): the knot stack's capacity

The owner's decision, after the analysis of the action knot's cycles. This
applies [0010's finite-capacity
clarification](0010-core-resource-contract.md#clarification-2026-09-18-a-finite-capacity-is-a-contract-not-a-claimed-maximum)
to this port; the rule is stated there and is not restated here.

> The CORE semantics do not claim that 256 bounds all legal DOOM executions.
> The work-stack implementation is safe for any declared capacity N: execution
> agrees with the reference while the required depth remains <= N, and
> deterministically refuses before writing past the capacity otherwise. The
> shipping configuration uses N=256. Across 4,509,048 observed pushes the
> maximum required depth was 21. This measurement motivates the configuration;
> it does not prove a global bound.

**The acceptance criteria for this item are therefore:**

- no tested, reference-equivalent execution exceeds the capacity;
- exhaustion is checked and deterministic;
- exhaustion cannot corrupt state;
- 256 is explicitly a configured operational limit, not a derived semantic
  bound.

**Why no derived bound was adopted.** The knot's call graph has one strongly
connected component of 62 definitions, and every cycle passes through one of 14
cycle-closing edges. Of the three cycle families:

- **damage and kill is already bounded** by the port's own flags: `damage_mobj`
  returns unless the target is shootable and alive, and `kill_mobj` clears
  `MF_SHOOTABLE` before entering the death state, so each nested kill consumes
  a shootable thing;
- **chase and look is not bounded structurally**: the shipped state table holds
  spawn-state/see-state 2-cycles, so closing it needs an argument about a
  branch condition (`look_for_players` with `allaround` false being a strict
  subset of the search that already failed) and about the single-player
  configuration;
- **the weapon sprites are not bounded structurally**: three weapon states have
  zero tics and refire, so closing it needs "each nested fire consumes ammo".

A conservative derived bound would multiply the shootable-thing count by the
state-driven and weapon nesting, which is far above any observed depth and too
loose to be a practical allocation target. Nothing has proved that such a depth
is unreachable; what is recorded is that the analysis did not produce a usable
bound and that the capacity contract does not need one.

`tests/doom-core/capacity.sh` is the evidence: the generator refuses to write a
push without its check, and the demo is run at capacities it exceeds, refusing
at the same tic every time with the stack no longer than it was declared.

## Clarification (2026-10-21): rendering in job mode 0

The owner changed the 2026-09-17 decision: the native program and the board
render in job mode 0, the direct path, not job mode 1.

- **Why.** The jobs and the executor were added for the GPU route and are
  not needed here.
  - On the FRDM-IMXRT1186's Cortex-M7, over DEMO1's first 500 tics, mode 0
    took a median of 30.1 ms against 32.6 ms for mode 1. The render stage
    alone fell from 14.9 to 12.0 ms.
  - Every frame matched the recording in both modes.
- **The direct path.** The CORE source's mode 0 drew walls and masked
  columns directly, but always pushed floor, ceiling and sky spans as jobs.
  Those now draw directly, as the original Ruby port's mode 0 does. The
  render entry's contract is unchanged.
- **Checks.** The native route's and the board application's mode
  assertions expect 0, and the recording check runs mode 0.
- **Mode 1 is kept.** It stays in the source for the GPU route and for the
  CRuby comparisons. The ledger's unreached lists name the configuration
  each mode belongs to: every job mode other than 0 is the `jobs`
  configuration (`tools/doom/core-unreached.tsv`), which replaces `direct`.
- **A field the port looks up elsewhere.** The owner added the kind
  `derived:FIELD` to `examples/doom/core/entries/not-taken.tsv`: the entry
  takes FIELD, the same value can be looked up from it at every read, and the
  port does so instead of keeping the field; `tests/doom-core/entry-fields.rb`
  checks that the entry takes FIELD and that the port's source reads it.
