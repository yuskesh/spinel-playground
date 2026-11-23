# 0003: Choosing between a collected heap and a process-lifetime arena

- Date: 2026-09-09
- Status: Accepted (2026-09-09); revised 2026-11-01, see [the revision](#revision-2026-11-01-no-collector-through-upstream---gcnone)
- Scope: A whole-program build setting that selects, for an ordinary Ruby program, either the default collected heap or a heap that is never collected during the process. It governs runtime behaviour and what the compiler must refuse; it does not change Ruby's integer types, method dispatch, or any external ABI.

## Context

The goal is a build-time choice, not a language feature. The same ordinary Ruby
source is built one way and runs on the collector, or built the other way and
runs on an arena that lives as long as the process. Allocation is still
allowed. Nothing is reclaimed while the program runs, and the process exit
reclaims everything at once.

This is not the freestanding work: no declaration surface, no separate object,
no foreign ABI. It is also not a prohibition on allocating.

### What the pinned runtime actually looks like

Measured in `vendor/spinel` at `d9eb84566eac0fce8b50cd4096e8594d6f303643`.

- **Collection has one funnel.** `sp_gc_collect` is defined at `lib/sp_gc.c:479`
  and called from exactly four places: `lib/sp_alloc.c:360,365,368` and
  `lib/sp_sched.c:388`. Mark, object sweep, string sweep, finalizers and the
  retune hooks all run inside it.
- **Allocation has two funnels**, `sp_gc_alloc` and `sp_gc_alloc_nogc`
  (`lib/sp_alloc.c:397,434`), plus the inline string allocators in
  `lib/sp_alloc.h`. Everything else is a typed wrapper over those.
- **The root machinery is header-resident.** `SP_GC_SAVE` and the `SP_GC_ROOT*`
  macros, and `sp_str_alloc`, live in `lib/sp_gc.h` and `lib/sp_alloc.h`, which
  the generated translation unit includes.
- **Nothing collects or frees the heap at exit.** `at_exit` hooks and `END`
  blocks run through `sp_at_exit_run`, and the process then relies on the
  operating system. There is no final collection in either configuration.
- **There is already a loud capacity failure.** `sp_gc_enforce_mem_limit`
  (`lib/sp_gc.c:671`) reads `SPINEL_MAX_HEAP_MB`, and on breach prints
  `unhandled exception: out of memory (RSS ... exceeded ...)` and exits 1. It is
  Linux-only and off by default.
- **Threads and fibers are real.** Collection under `SP_THREADS` is
  stop-the-world through `sp_stw_collect` (`lib/sp_sched.c:376`), young lists
  are per worker, and a suspended fiber is reached only through a hook that
  marks its saved root snapshot. A fiber's C stack is `mmap`ed and released by
  its finalizer (`lib/sp_fiber.c:254`).
- **A variant archive is an established pattern.** `libspinel_rt_mt.a` is the
  same members compiled with `-DSP_THREADS` (`Makefile:449`), and the driver
  picks it by scanning the generated C for a marker comment
  (`src/main.c:630-639`).

### What the predecessor already established

`spinel-llvm` at `f8ad13c6d9dc990b116ba1c842c7881232f29585` carries this as
`SP_REQUEST_ARENA`, recorded in its E064 and E093. Recorded here as evidence
tied to that revision; the parts this repository relies on are re-measured
above or below.

Its central judgement is the one worth importing, and it is about where safety
comes from:

> Stopping collection is what makes the mode safe, not moving every allocation
> into the arena. If safety rested on capturing every allocation site, one
> missed site is fatal: a mark would run with an empty root set and free live
> objects. If it rests on there being no collection, a missed site merely means
> that object is not reclaimed, which is the arena's contract anyway.

That is why the patch's core is a `return;` at the top of `sp_gc_collect`. The
four call sites above are what makes this a single edit rather than a sweep
through the runtime.

Its second judgement is that the runtime archive must carry the same define as
the generated translation unit, because `sp_str_alloc` and the root macros are
header-resident. A translation unit that allocates from the arena, linked
against an archive whose collector still sweeps, is a use-after-free by
construction.

### How this differs from the predecessor's model

The predecessor scoped the mode to one request per process and refused
long-lived processes, because a bump pointer with no reset eventually exhausts.
This decision takes the *process* as the arena's unit rather than the request.

That is a statement about where the arena begins and ends, and it is not a
claim that long-running programs are a supported use. The agreed initial use is
short-lived work. A process being *able* to live a long time is a different
thing from being *suitable* for long-running use: with nothing reclaimed, a
program that keeps allocating exhausts the limit, and the length of time before
it does is a property of that program rather than something this mode provides
for. Long-running suitability is out of scope and is not claimed anywhere here.

Two consequences do follow from the change of unit:

- **No request reset.** There is nothing to reset to.
- **No escape check.** The predecessor's E093 refused storing arena references
  in scopes outliving a request. With the process as the arena, a global living
  for the whole process is exactly as long-lived as the arena, so the check has
  no violation to find. Retaining is not the hazard here; exhausting is.

## Options

### A. What the build setting switches

1. **Stop collection; leave allocation as it is.** One gated `return` in
   `sp_gc_collect`, and the allocators keep their present shape.
2. **Replace the allocator with a bump allocator as well.** The predecessor did
   both, for speed and size. It makes the change larger and, by the reasoning
   above, does not make it safer.

### B. How the configuration reaches the runtime

1. **A variant archive**, `libspinel_rt_arena.a`, built from the same members
   with one added define, selected by the driver together with the define on the
   generated translation unit. Follows the `SP_THREADS` precedent exactly.
2. **A define on the generated translation unit only.** Rejected: the header
   residency above makes this a use-after-free, not a configuration.

### C. What to do about GC-dependent operations

Measured on the pinned tree: `GC.start`, `GC.compact` and `GC.stat` are the only
GC methods with codegen, dispatched on a `ConstantReadNode` named `GC`
(`src/codegen_call.c:23519-23526`). `GC.start` and `GC.compact` emit
`sp_gc_collect_request()`; `GC.stat` emits `sp_gc_stat()`. `ObjectSpace` is
already refused at compile time (`src/codegen_call.c:1293`).

**Refusing on the spelling is not enough, and this was measured rather than
assumed.** Four ways of reaching the collector were compiled and the generated C
inspected:

| written as | generated C |
|---|---|
| `GC.start` | `(sp_gc_collect_request(), (sp_int)0)` |
| `GC.send(:start)` | the same call |
| `GC.start` inside a `def` that is called | the same call |
| `GCX = GC` then `GCX.start` | the same call, at line 222, after the assignment on 221 compiles to a `NameError` raise |

The alias case is the instructive one. The receiver node is named `GCX`, not
`GC`, so a check keyed on the constant's name in the AST does not see it, yet
the call still reaches the collector in the emitted C. `send` with a symbol
literal is resolved statically too. A refusal written against the spelling would
have to chase every way of writing the receiver and the method, and would still
be behind the next one.

1. **Refuse on what the compiler emitted, not on how it was written.** Every
   spelling above converges on the same runtime symbols, so the check reads the
   generated translation unit for calls into the collector and refuses with a
   diagnostic naming the symbol. This is the same mechanism the driver already
   uses to pick a runtime archive, which keys on a marker in the generated C
   (`src/main.c:630-639`).
2. **Refuse on the spelling**, as the predecessor's ledger did by keying on the
   constant name. Rejected on the measurement above: it misses the alias.
3. **Let them through as no-ops.** Rejected by the requirement, and by the
   measurement: a program that calls `GC.start` to bound its footprint would
   keep running and then exhaust, with nothing pointing at the cause.

Whatever list the check carries is a list of runtime entry points rather than of
Ruby spellings, and it has a second line behind it: if the arena archive does not
define the collector's entry points, a call that the check missed fails to link
against a named symbol rather than silently doing nothing. That is the
fail-closed direction, and it is also what makes "the artifact does not depend on
the collector" checkable rather than asserted.

### D. What to do about threads and fibers

1. **Refuse the combination for now.** The threaded runtime's collection path
   is stop-the-world with per-worker heaps, and this decision has not
   established what an arena means for a worker's young list. The driver
   already distinguishes the two archives, so refusing is one condition in the
   place that already chooses.
2. **Claim support.** Rejected: it would be unverified, and the requirement is
   that an unverifiable GC-dependent feature is refused with a reason rather
   than presented as handled.

Fibers are a separate matter from threads. A fiber's stack is released by a
finalizer, and no finalizer runs under an arena, so a program that creates and
abandons many fibers grows its address space. That is a limit to record, not a
reason to refuse a program that uses a bounded number of fibers.

## Decision

Proposal awaiting approval. Recommended: **A-1**, **B-1**, **C-1**, **D-1**.

Status note, 2026-09-09: the owner approved this configuration, and it is
implemented on a branch of the fork with the acceptance checks in
`tests/gc-arena/`. Two things changed during implementation and are recorded in
[provenance](../provenance.md): the root machinery is kept rather than disabled,
because disabling it changed observable behaviour around `longjmp`; and the
capacity limit is stated as a bound on what the arena hands out rather than on
process memory. The branch has since been reviewed; see Status: Accepted at the
end of this record for the terms it was accepted on.

The capacity policy is a loud failure: when the arena cannot satisfy a request
within its limit, print what was asked for, what is in use, what the limit is
and how to change it, and exit non-zero. No recoverable capacity error is
proposed.

**What the limit covers has to be stated precisely, because it is not process
memory.** Measured on the pinned tree: the runtime calls `malloc` 127 times,
`realloc` 138 times and `calloc` 44 times across `lib/`, and only 27 sites feed
`sp_gc_bytes_add`. A container's header comes from `sp_gc_alloc` but its storage
comes from `malloc` and grows by `realloc` (`lib/sp_array.h:29`,
`lib/sp_alloc.h:707`); regexp buffers, bigint limbs, marshal and pack scratch,
IO buffers and fiber stacks are outside the GC heap entirely. An arena that
replaces the GC allocators therefore bounds *what the arena hands out*, not what
the process holds. This record claims the former and not the latter.

The existing process-level ceiling must not be silently lost either.
`SPINEL_MAX_HEAP_MB` is enforced by `sp_gc_enforce_mem_limit`, which is called
from `sp_gc_collect_retune` and `sp_gc_collect_retune_all`
(`lib/sp_alloc.c:361,369`) and reached only when an allocator trips its
threshold. An arena that returns before that threshold check never reaches it,
so the ceiling would quietly stop working. The mechanism is the allocator
bypass, not the gated return in `sp_gc_collect`. Keeping it reachable from the
arena path is part of the work, and it stays what it is: opt-in, Linux-only, and
measured against RSS rather than against the arena. A recoverable error would need a Ruby-visible exception at an
arbitrary allocation point, which is a semantics change beyond what has been
agreed, and it would need an ownership story for the memory already handed out.
If that is wanted it should be its own decision.

Nothing here changes Ruby's integer types, method dispatch, or any external
ABI, and the default configuration is untouched: the arena is opt-in, the
default build graph and its artifacts stay as they are.

## Validation

Before this record can move to Accepted:

- A clean checkout of this repository builds both configurations with the
  documented commands.
- The same ordinary Ruby source, built both ways, produces the same output as
  each other and as an independent reference interpreter over the range where
  they are meant to agree.
- Under the arena: allocation and retention work, and no collection happens
  during the run. "No collection" must be established on the artifact, not
  inferred from the flag.
- Under the arena, the artifact must not depend on, link, or start the
  collector. Checked on the real artifact by its symbols, not by reading the
  build recipe.
- Capacity exhaustion fails loudly, with a negative control showing the same
  program inside the limit succeeding.
- A GC-dependent operation is refused, with a negative control showing the same
  program accepted under the default configuration.
- The generated translation unit and the runtime archive are shown to carry the
  same configuration. A mixed build is the failure this must not permit, and the
  predecessor recorded walking into exactly that during its own validation.
- The default configuration is unchanged: its output and its artifacts must be
  compared against the current ones, not merely re-run.
- Because this changes the runtime, the affected upstream suite runs on
  Debian with LLVM 23.1.1, and the existing core checks are run to the extent
  the change can reach them.
- Every check above is shown to be capable of failing. A check that has never
  been made to fail has not been shown to test anything, and two of these were
  reading a failure as the answer they wanted: a `nm` that could not run
  produced no symbols, which is exactly what "the collector is absent" looks
  like, and a comparison that discarded exit status let a program print the
  right answer and then die.

### What the corpus gate is measured against

"No failures" is not the standard for the arena leg, because it is not the
standard the collector meets on the same path. The gate runs the whole upstream
corpus through the product driver twice -- once with the collector, once with
`--arena` -- and compares the second to the first. The product path is not the
compile line `make test` uses (that target compiles the generated C itself, with
a precompiled header and its own flags), and 96 build errors and 30 failures are
already present on the collector leg before `--arena` is mentioned:
`int_arg_into_bigint_param` is PASS under `make test` and segfaults through
`bin/spinel` in both configurations. Gating on an absolute zero would mostly
measure that gap, which belongs to the pinned base revision and not to this
change.

So every case whose (collector, arena) verdict pair is not (pass, pass) is
declared, and the declared set is compared in both directions. A new failure, a
new refusal, a new capacity case, a changed kind of failure, and a refusal that
quietly stopped happening are all equally loud; nothing is treated as success
for being an expected *kind* of error, because the declaration names the case
rather than the category.

The gap between the product path and `make test` is recorded here as an observed
property of the base revision. It is not addressed by this decision.

The two legs on this Debian baseline, counted from the recorded TSVs rather than
transcribed (`cut -f1 ... | sort | uniq -c`), 3543 cases each and 3543 distinct
case names in each:

| verdict  | collector (ARENA=0) | arena |
|----------|--------------------:|------:|
| pass     | 3413 | 3276 |
| rejected |    - |  140 |
| capacity |    - |    5 |
| fail     |   30 |   28 |
| error    |   96 |   91 |
| noexp    |    4 |    3 |
| timeout  |    0 |    0 |
| **total**| **3543** | **3543** |

and the transitions, which account for every case:

| collector -> arena | count |
|--------------------|------:|
| pass -> pass       | 3276 |
| pass -> rejected   |  132 |
| pass -> capacity   |    5 |
| error -> error     |   91 |
| error -> rejected  |    5 |
| fail -> fail       |   28 |
| fail -> rejected   |    2 |
| noexp -> noexp     |    3 |
| noexp -> rejected  |    1 |
| **total**          | **3543** |

267 of these are declared (everything but `pass -> pass`). No case improved.

The `fail` column is 28, not 33. An earlier report of this table said 33, which
was the figure from the run BEFORE `capacity` became its own verdict, when the
five capacity cases were still counted as failures; carrying it forward left a
column that summed to 3548 for a 3543-case corpus. The runner, the TSVs and the
declaration were consistent throughout -- only the prose was wrong.

## Implementation plan

Staged so that each stage can be stopped at, and so that the default
configuration is provably untouched before anything selects the new one.

Measured starting point for the port. The predecessor's runtime patch was
written against an older fork; against this repository's pin, `patch --dry-run`
reports every hunk of the runtime part applying, with offsets, and two hunks in
`lib/sp_gc.c` applying at fuzz 2. The driver part applies to `src/main.c` in
full, and one `Makefile` hunk fails because upstream has since added targets to
the line it anchors on. So the port is small, but the two fuzzy hunks have to be
read rather than trusted: fuzz means the surrounding context moved.

1. **A branch on the fork, not the pin.** The runtime change goes to a dedicated
   branch of `yuskesh/spinel`. `master`, the older `spinel-fork`, and every
   existing project pin stay where they are. This repository's work branch is
   where the new revision is validated.
2. **The runtime gate.** The `return` in `sp_gc_collect`, and whatever the
   allocators need in order to keep working with nothing ever reclaimed,
   confined to `lib/`. Additive and gated, so that with the define absent the
   preprocessed output is what it is today. The two fuzzy hunks are re-derived
   against the current source rather than applied blind.
3. **The variant archive.** `libspinel_rt_arena.a`, same members, same flags,
   one define, built on demand so `make all` and its artifacts do not move.
4. **Driver selection.** One flag that puts the define on the generated
   translation unit and selects the matching archive, refusing the combination
   with the threaded runtime. The two must be impossible to select apart.
5. **The refusal.** GC-dependent spellings refused when the arena is selected,
   keyed on the constant rather than on a list of method names, so that a method
   the pinned compiler gains later does not pass silently. The predecessor kept
   the policy in a data file and out of the checker's code; that is worth
   copying.
6. **Acceptance checks** under `tests/`, covering the Validation section above,
   each with the negative control named there.
7. **Non-regression.** The default configuration's artifacts and outputs
   compared against the current ones, and the affected upstream suite run on
   this host with LLVM 23.1.1.

Stages 1 to 4 are mechanical enough to hand to a lighter model with the
measurements above in hand; stage 2's fuzzy hunks and stage 5's refusal policy
are where the judgement is, and those stay with a full reading of the source.

## Consequences

- Under the arena nothing is reclaimed, so a program that keeps allocating
  exhausts the limit. The failure is intended and the message has to make the
  cause obvious rather than looking like a leak, but this does not make
  long-running work a supported use of the mode. It is not.
- No finalizer runs. Re-measured on this pin rather than inherited: twenty
  distinct finalizers are passed to the two allocators, and forty-three
  allocations pass none. Of the twenty, all but three release memory only. The
  three are `sp_File_fin`, which calls `fclose` (`lib/sp_io.c:39`);
  `sp_Dir_fin`, which calls `closedir` (`lib/sp_cold.c:2151`); and
  `sp_Fiber_fin`, which `munmap`s the fiber's stack and also removes it from the
  live-fiber list (`lib/sp_fiber.c:254`).
- Explicit release is a different thing from collection and survives untouched.
  `File#close` is `sp_File_close` (`lib/sp_io.c:345`), and the block form calls
  it directly (`lib/sp_cold.c:1642`); neither goes through the finalizer. So a
  program that closes explicitly, or uses the block forms, is unaffected. What
  is lost is only the implicit close that the collector used to perform for a
  handle nobody closed.
- `free` and `realloc` on container storage also survive, and must. That storage
  is `malloc`ed, not arena memory, so growing an array still `realloc`s and the
  arena never sees a pointer it did not hand out. The consistency requirement is
  that the arena replaces the GC allocators only; anything that is freed or
  realloced today must keep coming from the same place it comes from today.
- Buffers that hang off a collected header, such as an array's storage, are
  freed today by that header's finalizer. Under the arena they are never freed,
  so a program that grows and discards many containers holds their storage until
  exit. This follows from the same fact as the finalizer limit.
- `GC.stat` becomes unavailable rather than misleading, which removes a way for
  a program to observe its own footprint. Nothing in this decision replaces it.
- Threads are refused, so a program that uses `Thread` cannot select the arena
  until a later decision says what an arena means per worker.

## Status: Accepted

Accepted on 2026-09-09 for the scope stated at the top and no more: a
**short-running, single-threaded** program, built once for the arena, that runs
and exits. Long-running work is not a supported use of the mode, and saying so
is not a caveat on the acceptance but part of it.

### What was verified, in the terms it was verified in

- The **default** configuration is unchanged. Its runtime archives are
  byte-identical to a pristine build of the base revision, and so is its
  generated C across all 3543 upstream cases (`--no-line-map -S`: 3539
  identical, 4 refused by both drivers, 0 differing).
- The upstream suite passes **3543 pass / 0 fail / 0 error** under `make test`.
  That is the **default, collected** configuration. It is not a statement about
  the arena, and it must not be read as one.
- The **arena** configuration was measured on the same 3543 cases through the
  product driver, against the same corpus through the same driver on the
  collector. The table above is that measurement, and it accounts for every
  case: 3276 give the same answer as the collector leg, 132 are refused
  outright, 5 exhaust the arena, 122 were already failing or unbuildable on the
  collector leg and still are, and 8 more that were already failing there are
  now refused instead. 3276 + 132 + 5 + 122 + 8 = 3543. Nothing improved.

### What was NOT verified, and must not be claimed

- **Ruby has not been verified under the arena.** 3276 cases agreeing is not
  "all of Ruby works"; it is 3276 programs from one suite giving the same answer
  as the collector gave them. Nothing here characterises the language, the
  library, or a program outside that corpus.
- The three outcomes below are different things and are not to be added together
  or traded off against one another:
  - **refused** (132): the compiler declined to build the program at all. This
    is the configuration working as designed, not a passing case and not a
    failing one.
  - **capacity** (5): the program built and ran and hit the arena limit. This is
    the arena's own contract coming due. It says nothing about correctness.
  - **already failing on the product path** (122): these fail with the
    collector too. They belong to the gap between the product driver and
    `make test`, which is a property of the pinned base revision and is not
    addressed here.
- Whether a long-running program can use this mode. It cannot, and no
  measurement here bears on making it able to.
- What an arena means for a worker's own heap. `Thread`, `Mutex` and `Queue` are
  refused for that reason, so the combination is unmeasured by construction.
- `GC.stat` is refused rather than answered, so a program has no supported way
  to observe its own footprint under the arena. Nothing replaces it.

### Known differences carried forward

- One acceptance fixture (`control_flow`, an inner `ensure`) differs from the
  reference interpreter in **both** configurations. It is a compiler difference,
  not the arena's, and it is pinned byte for byte in
  `tests/gc-arena/expected/control_flow.ref-diff` so that a *new* shared
  difference fails rather than joining it.
- The product driver and `make test` disagree on 126 of 3543 cases with the
  collector alone (96 that fail to build, 30 that build and answer differently);
  4 more have no expectation file to compare against at all. Recorded above as
  an observed property of the base revision; not addressed by this decision.

## Revision, 2026-11-01: no collector through upstream `--gc=none`

Decided by the owner on 2026-11-01. The text above is the decision as accepted
on 2026-09-09 and is kept as history. Where it describes the arena's mechanism,
this section replaces it.

**What changed.** The fork's process-lifetime arena (`--arena`,
`SP_PROCESS_ARENA`, the variant archive and its limit) is removed from the
pin. Upstream's `--gc=none` (upstream `ba5891e0a`, backported) takes its place:
the program has no collector, nothing is reclaimed while it runs, and the
process exit reclaims everything. The record of the replacement is in
[provenance](../provenance.md#the-arena-replaced-by-upstream---gcnone-2026-11-01).

**What stays.** Option A's answer is unchanged. The switch is the collector,
not the allocator: a build either has the collector or has none. So does the
scope: a short-running program that runs and exits. Long-running work is still
not a supported use.

**What is no longer refused.** The driver refuses none of the following under
`--gc=none`. For each, the wording rule is: **upstream accepts this; it is not
verified in this repository**, unless a check is named.

- GC operations. `GC.start` is a no-op. This repository checks one program
  that calls it (`tests/gc-arena/run.sh`, `use_gc.rb`).
- Threads. This repository checks one Thread program (`use_thread.rb`), and
  claims nothing beyond it.
- C extensions.
- `--target=wasm32-wasi`, upstream's own target. Extended's WASM
  `--request-arena` build is `--gc=none` and is checked by
  `tests/edge/arena.sh`.
- `--exceptions=abort`.

**What there is no longer.** A limit: `SPINEL_ARENA_MAX_MB` is gone, and
`SPINEL_MAX_HEAP_MB` is not checked under `--gc=none`, because the runtime
enforces it only after a collection. Memory grows until the host refuses it.

**The checks.**
- `tests/gc-arena/run.sh` is now the collector / `--gc=none` pair. That pair is
  a routine check. Its comparison with a reference interpreter stays an oracle
  ([tests/ORACLES.tsv](../../tests/ORACLES.tsv)).
- The corpus gate of the sections above (`make test-arena` and
  `arena-expected.tsv`) is gone with the arena. The upstream corpus is not run
  under `--gc=none` here. The fork carries upstream's `gc-none-test`, one
  program.
- The "verified" and "not verified" lists above describe the arena at
  2026-09-09 and are not claims about `--gc=none`.
