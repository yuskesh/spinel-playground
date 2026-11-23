# 0010: A resource and realtime contract for CORE entries

- Date: 2026-09-16
- Status: Accepted
- Scope: How a CORE entry states and proves four things: how many times its
  loops can run, how much stack it can use, what an external call it makes may
  do, and the evidence for each. It also covers how these properties join the
  existing recursion, allocation and undefined-symbol guarantees in one
  per-entry, per-target build report, and the order of work. It does not change
  the 0007 status ABI, the buffer contract or the admitted language beyond the
  contract fields proposed below.

## Authorization and status

On 2026-09-16 the owner asked for this record, approved its direction and made
the following decisions. They are incorporated below.

- **Purpose.** Strengthen CORE's guarantees toward Stage 3: freestanding and
  realtime-safe execution. In Stage 2, existing code is affected as little as
  possible.
- **Loop bounds start as observation.** Bounds are derived and reported
  first. Strict refusal is designed only after the loops reported unknown have
  been collected.
- **Failure status.** A runtime loop-bound excess uses the existing
  `CAPACITY`, consistent with 0008's explicit-stack exhaustion. A status that
  monitors a realtime deadline itself, such as `DEADLINE`, is left for a later
  decision.
- **Order of work.**
  1. Derive and report loop bounds.
  2. Measure stack budget as a proof of concept.
  3. Define the extern effect contract.
  4. Enforce loop bounds strictly.
- **Verdict and evidence are two separate axes** (see "Verdicts and evidence").
  A bound enforced by a runtime counter is `runtime_guard` evidence, not a
  declaration.
- **Loop identity** is `method + ordinal + digest`, with no Ruby source
  annotation. A contract may carry an optional human label. A contract whose
  digest does not match is stale and refused.
- **Extern manifests** use one manifest for the shared semantics, and a
  per-target overlay for the target-dependent parts only: stack and provider
  evidence.
- **Bound unit.** Loop and work bounds count iterations for now. Abstract
  operation cost and WCET are separate properties, added later. The contract
  says what a bound is over rather than relying on a `bounded` boolean.
- **Interrupt stack reserve** lives in the target profile. The report shows
  that kernel stack plus interrupt reserve is at most the provisioned stack,
  and records the interrupt nesting assumption as evidence.
- **Build reports for DOOM** are not tracked in Git. They are regenerated
  evidence artifacts. The repository holds the schema, a few golden fixtures
  and, if needed, an aggregate baseline.
- **Stack.** The `realtime` profile admits no dynamic `alloca` and no
  variable-length array. The stack verdict is built from target codegen frame
  sizes, the final call graph and extern stack contracts.
- **Extern provenance.** `derived` and `attested` provenance are kept. Derived
  evidence composes from another CORE entry's report.

The owner reviewed this revision and accepted it on 2026-09-16, and
authorized implementation to begin with step 1. Acceptance approves the
decision, not a delivery: every contract field, report key, profile and mode
below is planned until a step delivers it with its validation. Step 1 was
delivered by merge `4e1db3f` and step 2 by merge `b47d89b`; steps 3 and 4 have
not been started.

## Context

What CORE guarantees today, and where each guarantee comes from:

- **No allocation, no GC, no Spinel runtime.**
  - The checker admits a closed subset: integer scalars, borrowed buffers with
    declared counts, direct helper calls, `while`, statement conditionals,
    early return, short-circuit logic, `break`/`next` and integer constants.
  - Forms needing objects, strings, arrays, blocks, exceptions, Bignum or
    dynamic dispatch are refused ([0004](0004-core-eligibility-checker.md),
    [0007](0007-doom-core-preparation.md)).
  - A built object must have an empty undefined-symbol set and one export.
    Loop-idiom recognition is disabled so a loop cannot become an undefined
    `memset` ([buffer-boundary](../core/buffer-boundary.md)).
- **No recursion.** A direct or indirect call cycle is refused
  (`recursive-call` in `tools/mlir/native/lib/Core/Eligibility.cpp`). An
  entry's call graph is closed and statically resolved.
- **Failure.** An entry reports failure through its status: `OK 0`,
  `ARGUMENT 1`, `ARITHMETIC 2`, `BOUNDS 3`, `CAPACITY 4`. 0008 preserves
  these, adds no status, and uses `CAPACITY` for explicit-stack exhaustion.

What CORE does not state:

- **Loops.** A `while` is admitted by its form alone. Nothing records how many
  times it runs.
- **Stack.** Recursion is refused, so worst-case stack is finite, but it is
  neither measured nor compared with anything. Frame sizes come from target
  codegen. The kernel emits IR and invokes clang
  (`tools/mlir/native/lib/Core/Kernel.cpp`), so they differ between Debian
  x86_64 and macOS arm64.
- **External calls.** Nothing outside an entry's own closure can be called.
  The project's working rules require an explicit contract for platform
  calls, and keep allocation policy separate from platform capability. 0008
  refuses callbacks into Full. Stage 3 needs platform services.

Constraints carried forward:

- **No arbitrary step quotas.** 0008 forbids a small fixed step quota that
  could truncate a valid game. A bound comes from data (counts, validated
  structure sizes), not from a guess.
- **A tier declaration is a claim to check,** not a licence to change
  semantics.
- **Call graph evidence.**
  - Intra-object calls on Debian x86_64 are resolved at assembly time and
    leave no relocation. macOS arm64 keeps an `ARM64_RELOC_BRANCH26` (noted in
    `tests/doom-core/tick.sh`).
  - A relocation scan alone is therefore not a call graph.
- **Freestanding coverage.** `tests/core/run.sh` exercises the freestanding
  leg with an x86_64-linux profile only, and no macOS arm64 freestanding
  profile exists ([stage-1 capability](../core/stage1-capability.md)).
- **No CI yet.** The repository has no CI configuration.

## Options

1. **Three separate features.** Each has its own flags, diagnostics and
   report. This duplicates identity and provenance, and scatters an entry's
   guarantee across three outputs.
2. **One resource and realtime contract per entry and target.** Each property
   has a verdict and evidence, and the profile selects a mode per property.
   This needs a schema first. The four-step order then becomes a sequence of
   mode and evidence changes rather than new mechanisms.
3. **An external verifier model** (for example, eBPF-style verification on a
   separate IR). It duplicates the existing checker and conflicts with the
   rule against a new general-purpose IR without a demonstrated need.

## Decision

Adopt option 2.

### Verdicts and evidence

Every property of every entry, on every target, has one **verdict** and a
list of **evidence** items.

- **Verdict:**
  - `pass`: the evidence the profile requires is present and satisfies the
    property;
  - `fail`: a violation was found;
  - `unknown`: the required evidence is missing.
- **Evidence kinds:**
  - `static_proof`: established by analysis of the source, the final IR or
    the object, with no execution;
  - `runtime_guard`: enforced during execution by generated code that returns
    a status when the bound is exceeded;
  - `measurement`: a value read from the artifact that target code generation
    produced, such as a frame size;
  - `declaration`: a stated value that nothing in the build checks, such as a
    profile's interrupt nesting depth. It is recorded but proves nothing on its
    own;
  - `attestation`: an external provider's claim, backed by named artifacts
    and tests for a specific target.

Each evidence item records its kind, its subject (loop, function, extern,
path), its value and the artifact it came from: file, revision and sha256.
**Derived** evidence is not a sixth kind. It is an item whose artifact is
another CORE entry's report, carrying that report's own evidence kinds (see
"Composition").

A profile states, per property, the mode and the evidence kinds that can make
it `pass`:

- **Mode `observe`:** the verdict is reported and never fails the build.
- **Mode `enforce`:** a verdict other than `pass` fails the build.

| property | evidence that can make it pass | `hosted-stage2` | `realtime` |
|---|---|---|---|
| recursion | `static_proof` (acyclic call graph) | enforce | enforce |
| allocation | `static_proof` (admitted subset plus undefined-symbol gate) | enforce | enforce |
| loop bound | `static_proof` (derived), or `runtime_guard` (counter) | observe | enforce |
| stack budget | `measurement` of frames, composed with extern stack evidence and the profile reserve | observe | enforce |
| extern effects | use-site `static_proof`, plus provider `attestation` or derived composition; `max_calls` by `static_proof` or `runtime_guard` | enforce, with no externs admitted, as today | enforce |
| undefined symbols | `static_proof` over the object's symbol table: the undefined set equals the declared externs | enforce | enforce |

`hosted-stage2` reproduces today's rules exactly and adds only reports. The
profile is an explicit kernel input recorded in the report. Existing contracts
get no implicit default change.

A runtime guard introduced by this record, for an exceeded loop bound or
`max_calls`, returns `CAPACITY`. The existing 0007 partial-write semantics and
adapter poison rules are unchanged. Stack and undefined-symbol failures are
build-time only.

### Loop bounds

**Identity.**

- A loop is identified by its method, its source-order ordinal within that
  method, and a digest of the loop header and condition text.
- Ruby source gets no annotation.
- A contract line may add a free-text `label` for humans. Labels never take
  part in matching.
- If the digest in a contract does not match the loop at that method and
  ordinal, the contract is stale and refused. It is never applied to whatever
  loop is now at that position.

**Bounds are typed by what they count.**

- The only bound kind in this record is `iterations`: how many times a loop
  body runs.
- Abstract operation cost and WCET are separate properties with their own
  kinds, added by a later decision.
- Contract and report always write a bound as `kind` plus expression, never
  as a boolean.

**Derivation** (step 1, observe). The checker classifies every loop.

A loop's bound is `static_proof` when all of the following hold:

- its condition compares one integer local (the induction variable) against
  a bound with `<`, `<=`, `>` or `>=`;
- the bound is loop-invariant: an entry scalar, a buffer count, an integer
  constant, or a local not assigned in the loop;
- on every path to the back edge the induction variable is changed exactly
  once, by a constant step toward the bound;
- no other assignment to the induction variable exists in the loop;
- `next` cannot skip the step.

`break` and early return are permitted, since they only shorten a run. Checked
arithmetic already rejects induction overflow, so no wraparound is assumed.

The derived bound is an `iterations` expression over entry parameters, counts
and constants. Nested loops, and loops in callees reached from inside a loop,
multiply. An entry's **work bound** (kind `iterations`) is the sum over its
loop nests.

Any other loop has verdict `unknown`, with a reason code:

- `condition-not-induction`
- `step-not-constant`
- `step-skipped-by-next`
- `bound-varies`
- `bound-from-buffer-element`
- `no-exit-condition` (a `while true` left by `break`)

Observation must not change code generation: objects are byte-identical with
and without reporting. Step 1 reports every DOOM CORE entry on both hosts and
publishes the catalogue of unknown loops, from which the strict rules are
designed.

**Declared bounds** (step 4, enforce). A contract (version 2) may give a loop
the derivation cannot bound:

```
loop <method>#<ordinal> digest <hex> bound iterations <expression> [label "<text>"]
```

- **Expression.** Only entry parameters, counts and constants may appear. A
  bare small literal is refused unless it is a structural constant of the
  algorithm (0008).
- **Guard.** The kernel lowers the bound to an iteration counter. The loop's
  evidence is then `runtime_guard`, never `declaration`, and exceeding it
  returns `CAPACITY`.
- **Proven loops.** A declaration on a loop that already has `static_proof`
  is checked against the derived bound. A declared bound below the derived
  one is refused. Otherwise the `static_proof` stands and no counter is
  emitted.
- **Strict mode.** In `enforce` mode, a loop with neither `static_proof` nor
  a guard has verdict `unknown` and fails the build.

### Stack budget

**Admission.**

- The `realtime` profile admits no dynamic stack allocation: no dynamic
  `alloca` and no variable-length array in the final IR.
- An entry that needs one gets verdict `fail` under `realtime`.
- Frame layout must be fixed at code generation.

**The verdict** is built from three inputs, all taken from the artifacts that
produced the object being reported:

1. **Frame sizes** (`measurement`): the frame size of each function as target
   code generation laid it out, with the same compiler, target, optimisation
   flags and inlining as the object.
2. **The final call graph** (`static_proof`): the calls that remain after
   optimisation and inlining, taken from the IR that code generation consumed.
   Neither the source call graph nor a relocation scan counts, because an
   inlined call has no frame and a resolved call has no relocation. The PoC
   must show that this IR is exactly what produced the object, for example by
   generating the object from that saved IR in a separate step with no further
   optimisation.
3. **Extern stack evidence:** each called extern's `stack` for this target,
   from its overlay. It is either `attestation`, or composed from a derived
   extern entry's own stack verdict.

The report records every function's frame size, the worst path through the
final call graph, and:

```
kernel_stack        = max over paths of (sum of frame sizes + per-target call overhead
                                          + extern stack on that path)
interrupt_reserve   = from the target profile
provisioned_stack   = from the target profile (or the caller's contract)
pass  iff  kernel_stack + interrupt_reserve <= provisioned_stack
```

The target profile states `interrupt_reserve` together with the assumption it
rests on, including the interrupt nesting depth and per-level cost. Both are
recorded in the report as `declaration` evidence, so a later change of IRQ
nesting assumptions is visible in the evidence rather than hidden in one
number.

**Candidate methods for frame sizes.** The step 2 proof of concept decides
between them by measurement on both hosts.

- **A. Frame-size diagnostics from frame layout.** A per-function
  `warn-stack-size` attribute with threshold 0 in the IR handed to clang, and
  the resulting stack-size diagnostic parsed. It is object-format independent.
  Whether it survives clang's IR input path, and what the reported size
  includes, is unverified.
- **B. ELF `.llvm_stack_sizes`** (`-fstack-size-section`). It is exact per
  function but ELF only. It is an independent cross-check of A on Debian.
- **C. Prologue decoding** of the emitted object, per architecture. It is the
  fallback if A fails.

**Proof-of-concept acceptance.**

- On Debian, A equals B per function.
- On both hosts, a runtime high-water measurement on a painted stack stays
  within the static `kernel_stack`. The measurement is a lower bound, and
  exceeding the static value is a defect in the method.
- A deliberately large frame and a deep acyclic call chain are reported
  correctly.
- A dynamic `alloca` is refused under `realtime`.

**Contract** (after the PoC): `stack_budget <target> <bytes>` per entry, or a
`provisioned_stack` taken from the target profile. Without either, the verdict
is `unknown`.

### Extern effects

**Structure.** One semantic manifest per extern set, plus one overlay per
target.

- **The manifest** holds the meaning, shared by every target:
  - `symbol <name>` and a signature in the existing contract domains: scalars
    `i32`/`u32`/`i64`/`u64`, and buffers with element, mode and count.
  - `no_alloc` is required on every extern. CORE cannot call something that
    allocates, and this keeps allocation policy from being widened through a
    platform capability.
  - `no_block` means no waiting on I/O, locks, time or scheduling. It is
    required in the `realtime` profile.
  - `no_reentry` means no call back into CORE or Full. It is required on every
    extern, matching 0008's refusal of callbacks.
  - `reads <params>` and `writes <params>`: the call site treats them as reads
    and writes for the existing in/inout and aliasing rules. `writes` on an
    `in` parameter is refused.
  - `bound iterations <expression>`: the extern's own worst-case iterations,
    over its parameters and counts. Later cost or WCET kinds are added as
    further `bound <kind>` lines, not as a boolean.
  - `max_calls <expression>`: the most times one entry invocation may call the
    extern.
  - `status <statuses>`: which existing statuses it may return. They propagate
    unchanged.
- **A target overlay** holds only what differs per target:
  - `stack <bytes>`;
  - `provider`, one of:
    - `derived <entry> <contract>`: the extern is itself a CORE entry;
    - `attested <artifact>`: an external implementation, with the object's
      sha256, its undefined-symbol set, a stack measurement by the step 2
      method, and tests exercising the declared bounds.

  An overlay that sets a semantic key is refused.

**Trust boundary.**

- **CORE proves the use-site obligations** with `static_proof`:
  - the declared signature matches each call;
  - reads and writes respect parameter modes and aliasing;
  - `max_calls` is covered by the derived loop bounds around the call sites,
    or by a counter returning `CAPACITY`, which is `runtime_guard` evidence;
  - extern stack is included in the worst path;
  - the undefined-symbol set equals the declared externs.
- **CORE cannot see inside an extern.** `no_alloc`, `no_block`,
  `no_reentry`, the bound, the stack and the accuracy of `reads`/`writes`
  come from one of two provenances:
  - **derived:** the extern's own CORE report. It is composed as below, so
    nothing beyond CORE is trusted.
  - **attested:** `attestation` evidence for that target, never
    `static_proof`.

An undeclared symbol, a missing overlay for the target, or evidence for
another target gives verdict `fail`. A profile may restrict which provenances
it accepts.

### Composition

A derived extern, or any property of one entry that depends on another entry,
references that entry's report by entry, target, object sha256 and report
sha256.

- The dependent property takes the referenced verdicts and evidence items
  unchanged, marked as derived, never upgraded.
- A referenced report whose object sha256 no longer matches the built object
  makes the dependent property `unknown`.
- Composition follows the acyclic call graph, so it terminates.

### Build report

For every entry and target, the kernel writes one versioned JSON document. It
holds:

- the entry, target triple, profile, each property's mode, tool revisions and
  the object's sha256;
- each property's verdict and evidence items: the call graph, the loops (id,
  digest, label, bound or reason), the work bound, the frame sizes, worst path
  and stack inequality, the externs with provenance and per-obligation
  verdicts, and the undefined set against the declared externs.

The build fails only on an enforced property whose verdict is not `pass`.

**Where reports live.**

- Reports for DOOM CORE entries are not tracked in Git. They are regenerated
  evidence artifacts, retained by the run that produced them.
- Until CI exists, the verification line regenerates them and keeps them
  outside the repository.
- The repository holds the report schema, a small set of golden fixture
  reports for the checker's own tests and, if useful, an aggregate baseline
  such as counts of verdicts per property.
- Build-time reports are separate from 0009's run-time result records. A
  harness case may assert on a report.

## Validation

- **Step 1: loop derivation and report.**
  - Fixtures cover each `static_proof` form and each `unknown` reason,
    including nested loops, loops in callees, `break` and `next`.
  - Objects are byte-identical with and without reporting.
  - Reports are produced for every DOOM CORE entry on both hosts, and the
    catalogue of unknown loops is published.
  - Golden fixture reports validate against the schema.
- **Step 2: stack proof of concept.**
  - The cross-checks and negative controls above pass on Debian x86_64 and
    macOS arm64.
  - The final call graph is shown to be the one code generation consumed.
  - The inequality `kernel_stack + interrupt_reserve <= provisioned_stack` is
    reported with the profile's nesting assumption as evidence.
- **Step 3: extern effects.** Manifest and overlay fixtures are required, with
  negative controls for each of:
  - an undeclared symbol;
  - `writes` on an `in` parameter;
  - `max_calls` exceeded, both statically and at runtime through `CAPACITY`;
  - a missing `no_alloc` or `no_reentry`;
  - an overlay setting a semantic key;
  - an attestation for the other target;
  - a derived provider whose referenced object sha256 is stale.

  A derived extern must reproduce its entry's verdicts and evidence unchanged.
- **Step 4: strict loop bounds.**
  - An `unknown` loop without a guard fails under `enforce`.
  - A guarded bound is tested at its last admitted and first refused
    iteration counts.
  - A declared bound below the derived one is refused.
  - A contract with a stale digest is refused.
  - A guarded loop reports `runtime_guard`, not `declaration`.
- **Throughout.** Under `hosted-stage2`, every existing Stage 2 object and
  suite result is unchanged.

## Consequences

- Contract version 2 adds `loop`, `stack_budget` and `externs`. Version 1
  contracts stay valid and are reported under `hosted-stage2`.
- Stage 2 gains reports only. The catalogue of unknown loops will shape how
  loops such as 0008's explicit-stack traversals are written.
- Stage 3 target profiles build on `realtime`. They supply `interrupt_reserve`
  with its nesting assumption and `provisioned_stack`, and the extern
  manifests and overlays begin the platform ABI contract.
- Abstract operation cost, WCET and a deadline status (`DEADLINE`) each need
  their own decision. They add bound kinds or properties, not changes to the
  verdict and evidence axes.
- CI, when introduced, owns regeneration and retention of DOOM build reports.

## Clarification (2026-09-16): step 1 interface

- **Digest**: a versioned canonical rendering of the loop predicate, with
  `digest_version`.
- **Work bound**: the sum over all occurrences of a loop, outer loops
  included. The `loop_bound` verdict and evidence are the work bound;
  `work_bound` holds `{expression, terms}` and carries no separate verdict.
- A bound may be any expression over locals, parameters and constants.
- **Reason codes**, provisional: `step-conditional`, `step-away-from-bound`,
  `induction-reassigned`, `start-not-expressible` (with a sub-reason when the
  start depends on an enclosing induction variable), `bound-from-call`,
  `argument-not-expressible`, `enclosing-unknown`, `bound-not-expressible`
  (`enclosing-induction`, `after-loop`).
- **Conjunctions**: in `A && B` the bound comes from the first qualifying
  conjunct, and which one it was is recorded.
- Properties step 1 does not fill are written `evaluated: false`.
- **CLI**: `--report`, `--profile hosted-stage2`, `--report-revision`.
- Goldens use schema-valid placeholders for host-varying fields.
- DOOM build reports are regenerated evidence and are never tracked.

## Clarification (2026-09-16): canonical JSON

Report JSON compared as bytes is written by the harness's own canonical
emitter, not by `JSON.pretty_generate`. The rendering of an empty collection
depends on the json version, and the two container kinds break *differently*.
Measured on Debian with ruby 3.3.8 and json 2.7.2,
`JSON.pretty_generate({"a" => [], "b" => {}})` yields
`{\n  "a": [\n\n  ],\n  "b": {\n  }\n}` — an empty array with a blank line
between the brackets, an empty object with a newline and an indent. On json
2.12.2 both are `[]` and `{}`; that half is the macOS line's measurement and is
recorded here as relayed. An emitter patched for whichever shape was caught
first would have shipped still wrong for the other.

**This contract describes what the EMITTER DOES, not what the goldens happen
to contain.** The two are easy to confuse here, because the three committed
goldens did not change when the emitter did — see below — and a reader meeting
an unchanged golden beside a new contract could reasonably conclude the
contract was written to describe the old bytes. It was not. It states the
producer's behaviour, and the goldens are what that behaviour must yield.

The canonical form: standard library only, two-space indent, compact `[]` and
`{}`, insertion order preserved *because the kernel is the source of the
order*, the emitter's own string escaping, raw UTF-8 with binary write and
binary read so byte identity does not depend on a host's locale or default
external encoding, invalid UTF-8 refused, `Integer#to_s`, one trailing
newline. `Float` and `NaN` are **refused**: a future float is to be decided,
not discovered.

A fixture pins every rendering a json version has changed or could change, and
is the cross-host contract. Any newly byte-compared JSON uses this emitter;
per-run records and summaries that are parsed and judged by key are
unaffected.

The three committed goldens did not change: they always held the canonical
bytes. What was wrong was the producer, delegating its formatting to a library
that agreed with the canonical form on one host by coincidence — a defect
invisible to the host that wrote the file.

## Clarification (2026-09-16): provenance evidence

**The unit of provenance evidence is the object, not the binary.** An object
carries only its own producer and reproduces from its own line; a link mixes in
system startup and runtime objects nobody in this project built. Measured on
Debian: a two-line program compiled with `/opt/llvm-23.1.1/bin/clang` links to
a binary carrying one clang marker *and* one `GCC: (Debian 14.2.0-19) 14.2.0`,
while its own object carries only the clang marker. So "it contains a GCC
marker" discriminates nothing. In the other direction the *absence* of any
clang marker in a binary linked from dozens of clang-compiled objects is a
real signal, since each contributes one — but that argument depends on the
markers not having been stripped, and `-s` or a strip step erases them.

Two mechanisms with two coverages, never collapsed into one conclusion:

- **Reproduction** — rebuild from the recorded line and compare — reaches the
  object *and* the binary. Measured on Debian at `0f55da5`: four vendor
  objects, each recompiled twice from the line the build itself prints, with
  the tree's own object matching both repeats; and `vendor/spinel/bin/spinel`
  linked twice, both links matching the tree's binary. Two repeats rather than
  one, so determinism is separated from a chance match, and the tree artefact
  included, so the claim is that the recorded line produced what is there.
  On macOS, linking reproduces *modulo* `LC_UUID` and the ad-hoc signature
  covering its page — 49 bytes of 4294416 in three ranges — with SDK and
  linker held fixed; that figure is relayed from the macOS line's measurement
  and is recorded here as relayed. The asymmetry is an argument for the
  object-level rule, not a softening of it.
- **Marker inspection** reaches only the object, and only where it has been
  shown to discriminate. On Mach-O it has not been: there is no `.comment`
  section, no DWARF producer without `-g`, `LC_BUILD_VERSION`'s tool entry is
  the *linker* and both toolchains drive Apple `ld`, no toolchain string
  appears in the binary, and the `__chkstk_darwin` and `_*_chk` undefined
  symbols are emitted by upstream and Apple clang alike on arm64 Darwin —
  five methods ruled out by measurement on that host, relayed. A marker check
  therefore lands Debian-only and labelled Debian-only. One that passed on
  Debian and vacuously passed on macOS would reproduce, in the tool meant to
  close the hole, the hole it closes.

**A recorded artefact carries the environment that produced it** — compiler,
SDK and linker versions beside the digest, and whether those values were
captured at build time or measured afterwards. A digest without its
environment cannot be reproduced later, only attested to. This is not caution:
the comparison that would have settled which compiler built the shared
`spinel-typedump` contract reader is unrecoverable, because it was built
against an SDK and linker version that a host update replaced, and neither had
been written down. Named here so that a reader arriving with that question
about that binary meets this paragraph.

**A plausible value in a provenance column is worse than an empty one.** An
empty column asks a question; a plausible one answers it wrongly forever.
Where the build environment was not captured at build time, the field says so.

## Clarification (2026-09-16): what makes a check a check

**A check lands with the input that makes it fail, demonstrated — and that
input is kept.** A check that passes on a clean input and has never been shown
to reject a dirty one cannot be told apart from a check that does nothing; a
rejection demonstrated once against an input nobody preserved decays into an
unverifiable claim as soon as the reviewer leaves. The control must match the
subject: a check shown to reject an archive member has not been shown to
reject a free-standing object, and those are two checks written on two
different days.

Two corollaries:

- **A two-arm agreement is evidence only if both arms reached the thing under
  test.** A comparison report states what the arms executed, not merely that
  they matched.
- **A measurement whose every outcome leads to the same action should be named
  as such and skipped** — decided before running it, not after.

The species these guard against, all found on 2026-09-16: a self-comparison
reporting a pass; a ledger row saying "not measured at this revision" after it
had been measured; two comparison arms agreeing at a precondition before
either reached the compiler; a golden that only ever ran on the host that
wrote it; a green lane blind to which compiler built the seam it was handed;
and a message reporting successful delivery with a word silently removed by
the shell that composed it.

One more was found while fixing this record itself, and it is a *different*
failure mode from the rest of that list. Every entry above is a statement that
stopped corresponding to the system. This one never fully did: a sentence
joining a true clause and a false one — "the expectation reader already
rejects a matrix-shaped origin; `cases.rb` diagnoses the reverse" — where the
first half was implemented, the second was not, and the word "already" lent
its credibility across the semicolon. **A plainly false sentence gets
challenged; a half-true one gets skimmed.** Where two clauses have different
evidence, they are written as two sentences with their evidence each.

THE DELIVERY DEFECT IN THAT LIST — the message whose word the shell removed —
generalises: **a transport that reports success while silently altering its
payload is the same defect species as a vacuous check.** The
composition fix — write the message to a file, send it as the contents of that
file, never assemble it inline — is not the exposure fix.

A second transport defect, found the same day and harder to see because
nothing is missing and every word arrives: **one message body addressed to two
parties cannot use the second person.** A shared body containing "you" changes
meaning per recipient, and a report of one reader's findings reaches the other
as a report of their own — which, in an exchange about attribution, credits a
finding to whoever did not make it. Address each party by name inside the
text, or send two bodies. A record that misattributes is worse than one that
omits: an omission can be discovered, while a misattribution reads as settled.

THAT IS A THIRD SHAPE, and naming it is what keeps it from being filed as one
of the first two. The delivery defect damaged its payload and left a trace.
This one delivers every word intact and leaves no trace anywhere: it is a
correct message whose truth depends on who is reading it. The harness already
forbids the same thing in data — an expectation row that would read correctly
against whichever record it was handed, because it named no case, is refused
by requiring `case_id` on every row and `judged_against` to name a case that
exists. The rule above is that requirement applied to prose.

Neither fix is the exposure fix. The exposure is that findings which live only
in a message channel have no integrity check, no review and no reader in six
months. They belong in tracked artifacts, which is why these clarifications
were written before the branches they describe.

## Clarification (2026-09-16): measured, derived, historical

Evidence prose uses this record's own vocabulary rather than a second one.
`measurement` is a value read from the artifact; `declaration` is a stated
value nothing in the build checks; `attestation` is an external provider's
claim backed by named artifacts; derived evidence is not a further kind but an
item whose artifact is elsewhere.

**A derived value written as a measured one is a defect even when the number
is right.** The DOOM ledger's "the walk pushed 1296 sky columns from 28 of
them" attributes the 28 to the walk, and that count is taken from the
original's plane records: `tests/doom-core/source-port.rb` counts it as the
original's sky planes whose wall range grew, while `planes.sky_columns` is the
port's own wall-job range. There is no port-side count of sky planes that
pushed columns at all, so the sentence states about the walk a quantity the
harness deliberately does not measure. It is nonetheless correct on a nominal,
because `plane-disagree` is 0 there and the walk's planes therefore match the
original's — which makes it derived, not unsupported. The fix is to say how
the value is known, not to remove it.

Sentences scoped to an earlier revision keep that label and their own figures.
A measurement taken through an entry that no longer exists is a fact about the
revision that took it, and stays recorded as one.

**A decision record says what is decided. Where the implementation does not
exist yet, it says so, and names a checkable condition that retires the
label.** Writing a ruling in the present tense is how a ruling becomes a
description of a system that does not do it — a general defect in decision
records, not a slip in one section.

THE CONDITION IS CHECKED IN THE TREE, NOT IN A BRANCH'S HISTORY. "Removed by
the commit that makes `run.rb` run them" is settled by grepping the checkout
in front of the reader. A branch name is weaker: branches are renamed, merged,
abandoned, or carry a change in an order nobody predicted, and the reader is
left proving a negative about history. It can also be false on the day it is
written, when no branch carries the change yet. Name a branch only where
someone holds that merge and carries the removal as an item on it.

## Clarification (2026-09-16): demonstrating a check, continued

Three additions to "what makes a check a check", each from a defect found after
that section was written.

**AN INVARIANT RELIED ON IS STATED WHERE IT CAN BE BROKEN.** `run.rb` decides
its status once, after every result exists, so a step that skipped and became a
failure is reported beside whatever else failed rather than suppressed by it.
That held because of where the lines sat and nothing claimed it. The same
property did NOT hold in `tests/core-report/run.sh`, where the exit on any
failure precedes the `REQUIRE_ALL` block, so the diagnostic naming the check
that did not run is unreachable on any run that is red for another reason. A
property that holds because of where something sits, with no sentence claiming
it, is one edit from not holding -- the same shape as a referent that points at
its neighbour until a paragraph is inserted between them.

**A DIAGNOSTIC IS DEMONSTRATED IN THE STATE WHERE IT WOULD BE SUPPRESSED**, not
only where it is obviously reachable. The block above says exactly the right
things, and reading it would have produced a confident report that it works;
only running the case in the state that matters showed it never prints. So a
diagnostic lands with its message captured AS EMITTED from a run that also
contains an unrelated failure, because that is the state in which suppression
hides. And whatever supplies that unrelated failure is KEPT: if it comes from a
defect that is later fixed, the suppression path stops being exercised and
nobody sees it stop.

**AN EXIT CODE IS A ONE-BIT SUMMARY OF A RUN, AND TWO RUNS AGREEING ON ONE BIT
IS THE WEAKEST AGREEMENT AVAILABLE.** Two hosts reported the same 675 checks
and a totals comparison would have found nothing; both of that day's findings
came from comparing what the arms EXECUTED, and one of them from asking what a
run PRINTED rather than what it exited with. The same defect appeared inside a
single line's own report: two runs of one suite exited 2, one because no
compiler was present and one because a compiler was present and lacked a
property. One bit, two causes.

### Identification, the third mechanism

**IT MATCHES A RECORDED FIGURE, AND IT RANKS BELOW THE OTHER TWO.** A vendor
tree was settled as the required build by one object measuring 142600 bytes
against the figure [provenance](../provenance.md) recorded when it resolved an
earlier incident, where the wrong compiler's build of the same file came to
150872. That IDENTIFIES a build; it does not REPRODUCE one. It shows the
artefact is consistent with a build someone characterised, not that the
recorded line produces it. It is named here because it did real work on the
host where reproduction had not yet been run and marker inspection does not
work at all -- and because a size match, left unlabelled, is read afterwards as
a reproduction.

### A property carries its environment, as an artefact does

**A RECORDED PROPERTY CARRIES THE ENVIRONMENT IT WAS MEASURED UNDER.** "Linking
reproduces modulo `LC_UUID` and the signature covering its page" is not a fact
about macOS; it is a fact about macOS with one linker, and the linker that
would test the other half is gone from that host. A property measured in one
environment is a fact about that environment until someone measures a second.
The rule arrived for digests, where an artefact cannot be reproduced without
the environment that made it; a measured property has the same shape and
travels no better.

## Clarification (2026-09-16): a hole in the keep-the-failing-input rule

**A CASE DESIGNED TO ERROR PASSES BY ERRORING**, so the cases that look like a
ready-made failure cannot supply one. The rule above says a check lands with
the input that makes it fail and that input is kept; this is a family of inputs
that LOOK like they would fail and cannot, because their failure is their
expected verdict. Anyone reaching for a convenient failing row -- to prove a
diagnostic is not suppressed by one, for instance -- will reach for those
first, and get a green row that counts as a pass. It is the vacuous-check
problem with its polarity inverted: not a check that cannot fail, but a failure
that is not one.

Three sentences from the same day's measurements, each of which earns its place
by being a thing reading would not have found.

**A CONTROL-FLOW DEFECT IS INVISIBLE TO THE READING THAT WOULD CATCH A CONTENT
DEFECT.** One diagnostic block read perfectly and never printed, because an
exit preceded it; one parent script read perfectly and died before reading its
child's output. Both were found by running, and a careful reading of either
would have reported that it works.

**WHAT A SIMULATION REPRODUCES IS ONE'S OWN MODEL OF THE DEFECT.** That is
exactly where a subtly wrong model produces a confident green. It is the
strongest evidence obtainable where the failing input does not exist on the
host, and it is not the measurement -- so it is labelled as a simulation and
the measurement is taken where the input is real.

**THE SAME ENVIRONMENT CHANGE MOVES 2 BYTES IN AN OBJECT AND 72852 IN A LINKED
BINARY.** Measured across one toolchain update on one host: the object carries
the environment in a version field, and the link carries everything the linker
brings with it. That is the object-level rule as a ratio rather than as a
principle, and it arrives from the host whose link reproduction is the weaker
of the two, which is what makes it an argument rather than a preference.

## Clarification (2026-09-18): what a CORE object may reference

The owner's decision, on macOS arm64 evidence. The rule for a built CORE
object is:

> CORE objects must not contain data references whose resolution depends on
> another object.

It is a rule about the **target**, not about the kind of instruction. An object
may reference data — a constant pool is data — as long as the data is its own.
So a relocation is admitted when it is either

- a branch to a symbol defined in that object, or
- an address-materialisation pair whose halves both resolve to the same symbol
  defined in that object;

and refused when the target is undefined or external, or when it is reached
indirectly through a GOT entry, a stub or a thread-local variable, because the
resolution then depends on another object by construction. The pair is
**matched, not counted**: a half with no partner, or halves naming different
targets, is not the admitted shape.

**Why the rule moved.** The check had been "a branch and nothing else", which
held on x86-64 only because that target can encode a local constant's address
without a relocation. The same source on arm64 materialises a constant-pool
label in its own object as an ADRP/ADD pair, and the old rule refused an object
for a reference that never leaves it. That was the check being narrower than
the invariant it existed to enforce. The alternative — changing the port so the
compiler stops emitting the pair — was rejected: it would make the source
depend on which instructions a compiler happens to choose.

`tests/doom-core/object-relocs.rb` implements this, and
`tests/doom-core/object-relocs.sh` demonstrates it against arm64 objects built
where the lane runs: the admitted shapes pass, and an external target, a GOT
load, a half with no partner and a mismatched pair are each refused by their own
message.

## Clarification (2026-09-18): a finite capacity is a contract, not a claimed maximum

The owner's decision. It is stated here because it is about CORE's contract
with its caller and not about any one program:

> Static resource bounds need not always be semantic maxima. A finite execution
> capacity is valid when exhaustion is explicit, safe, and part of the contract.

For a work stack, a queue or any preallocated execution resource of declared
capacity `N`, what must be true is:

```
required depth <= N  ->  CORE execution is equivalent to the reference execution
required depth  > N  ->  CORE refuses deterministically, without writing past
                         the capacity
```

So three obligations replace "N is big enough":

1. **No write past the capacity.** Every site that consumes the resource checks
   it first. The strongest form of this is by construction: the check and the
   consumption are emitted together by one generator, which then refuses to
   write if anything it generated lacks its check.
2. **Below the capacity, semantics are unchanged**, evidenced by comparison
   with the reference implementation.
3. **At the capacity, failure is explicit and deterministic**, evidenced by
   running at a capacity the workload exceeds and showing the refusal — at the
   same point every time, with nothing written past the end.

**Then `N` is a deployment and resource configuration, not a correctness
invariant.** 0008's rule against an invented quota forbids a number with no
justification being used as a *correctness claim*; a capacity whose exhaustion
behaviour is defined, checked and observed is not that. A measurement of
observed usage motivates the configuration and proves nothing about a global
bound, and a record must say exactly that.

This matters beyond DOOM. In freestanding, RTOS and eBPF settings a queue of 64
is a contract with backpressure, not a proof that a 65th packet never arrives.
The obligation there is the same: refuse at the boundary, deterministically,
without corruption.
