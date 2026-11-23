# 0009: A structured test harness for the DOOM CORE migration

- Date: 2026-09-15
- Status: Accepted
- Scope: How the checks under `tests/doom-core/` are declared, selected, run
  and reported on native Debian x86_64 and macOS arm64, and which checks a
  commit, a milestone and a macOS review must run. No CORE semantics, ABI,
  status, poison rule or acceptance meaning of an existing check changes.

## Authorization and status

On 2026-09-15 the owner took two steps:

- approved tiered validation, which is recorded below and was already applied
  as a coordination rule;
- asked for a proposal for a small in-repo harness layer.

The owner then reviewed the written proposal and accepted it with one change:
Python is not used. That rules out option 3 below, so the runner and every
tool of the layer are Ruby.

Acceptance approves the direction, not a delivery. Nothing described under
Decision is delivered, and every new path, file format and option below is
planned.

This record changes how [0008](0008-doom-core-migration.md)'s checks are
organized and run, not what they must show. 0008's validation and exit
criteria remain the acceptance contract.

## Context and evidence

Measured at `7a1df0b` unless stated otherwise.

**Size and duplication.** `tests/doom-core/` holds 8 shell suites and 25 Ruby
programs, 10,676 lines. `tick.sh` alone has 1,139 lines, 196 `ok` and 33
`want` call sites, and reports 232 checks at run time. Across `tests/`, 17 of
33 shell scripts define their own `ok`/`want`-style helpers. Every lane
repeats the same shapes: one comparison over the Ruby, compiled, session and
adapter routes; a list of negative controls; last-valid/first-invalid edge
pairs; and pinned output text.

**Growth.** `tick.sh`'s run-time checks went 192 (`1bed3e6`), 202
(`b25f9cd`), 216 (`f3211f6`), 224 (`44a7d4b`), 232 (`7a1df0b`): each bounded
capability adds a control list multiplied by routes.

**Cost.** The seven Debian suites took 54 minutes at `44a7d4b` and 58 minutes
at `7a1df0b`. `tick.sh` alone took 36.5 and 39.7 minutes on macOS arm64. No
per-lane breakdown has been measured. Every capability commit ran everything
on both hosts, including a commit that changed only the harness and docs. The
Ruby route's nominal 600-frame run of `source-port.rb` takes about 23 seconds
and 325-365 MB peak RSS on the macOS host; `tick.sh` runs it and its compiled,
session and adapter counterparts once per control.

**Scale required by 0008.** Stage 2 exit requires DEMO1, DEMO2 and DEMO3
(5,026, 3,836 and 2,134 tics) compared on every route, with negative controls
that reach their intended comparison. The current lanes compare 600 frames of
DEMO1. Running every control over every demo on every route in the current
structure would multiply the cost above roughly eighteenfold.

**Failure modes observed in this structure.**

1. *Whole-string pins churn.* 59 `tick.sh` checks filter output through
   `fctl` and compare the remaining text, which includes counters unrelated
   to the control (push totals, check statistics, executor runs). Relabelling
   one control required regenerating many pins, and one full-suite attempt
   failed four checks only because pins were not regenerated.
2. *Filtering hides evidence.* `fctl` drops the `clears` line, so the
   per-field `clear_planes` mismatch counts of the clear controls, and the
   session/adapter observability counts, are carried only in ledger prose.
   One such count was first reported without being read and then corrected.
3. *A comparison can be vacuous without failing.* At `44a7d4b`, deleting
   `dc_clear_planes`' writes to `lastvisplane` and `lastopening` left the
   600-frame output byte-identical to the pinned nominal string, because the
   port's cells started at the written value. It was found by applying the
   deletion to a private copy on the macOS host, not by any control, and was
   fixed in `7a1df0b`.
4. *Controls run longer than detection needs.* The frame lane runs 14
   controls on the Ruby route and 15 on the compiled route over 600 frames
   each, and about 15 each on the session and adapter routes over 200
   frames. All but two first fail at frame 0 or 1; the fuzz-phase control
   first fails at frame 137 and the wrong-bank control at frame 6.
5. *Interruption looks like failure.* A host low-memory event killed a
   `tick.sh` run; five adapter checks reported `FAIL ... got ''` and the exit
   status was never written. Nothing distinguished a killed case from a
   wrong result.
6. *Reports are transcribed by hand* from logs into commit reports and ledger
   evidence.
7. *Tool overrides are discovered by failure.* A run with prebuilt tools also
   needed `ADAPTER`, which was then undocumented.

**Constraints.** The project's working rules forbid dependencies on
unrecorded local artifacts, require independent reference checks, and
reject tests that mirror implementation details.
[docs/building.md](../building.md) notes that a compiler cache replays stored
objects and weakens a claim about which toolchain produced them. The
oracle, `source-port.rb`, patches the Full Ruby renderer in process and must
stay Ruby.

## Options

The following layer is needed under every option, because no general test
framework provides it:

- structured result records;
- expectations per case and key;
- a reviewed update workflow;
- an input-addressed artifact cache;
- a comparison between host results.

The options differ in the runner that schedules the cases.

1. **Keep the shell suites and tune them.** Shorten controls and grep single
   keys. It is cheap, but duplication, pins in prose and transcribed reports
   remain, and it does not scale to three demos.
2. **Ruby runner: minitest plus the in-repo layer.** minitest ships as a
   bundled gem with the Ruby that already runs these suites on both hosts, so
   no new dependency is added. The versions differ by host:

   | Host | Ruby | Ruby source | minitest | JSON |
   |---|---|---|---|---|
   | Debian x86_64 | 3.3.8 | Debian package `ruby3.3` (gem shipped in `libruby3.3`) | 5.20.0 | 2.7.2 |
   | macOS arm64 | 3.4.1 | user-level Ruby install | 5.25.5 | 2.12.2 |

   The layer may use only what both versions provide. The oracle and the
   runner share one language. Case parameterization, fixture lifetime and
   JUnit output must be written in the layer.
3. **pytest plus the in-repo layer.** Parametrized cases, session-scoped
   fixtures for built artifacts, markers for selection, parallel workers and
   JUnit output come ready-made. The Debian host has `python3` 3.13.5, but
   pytest was not checked there. On the macOS host, the `python3` on `PATH`
   belongs to an unrelated project environment, so it is not a recorded test
   dependency. Python, pytest and a worker plugin would therefore become new,
   pinned and recorded dependencies on both hosts. The runner (Python) and
   the oracle (Ruby) would also split across two languages. **Rejected by the
   owner:** this project takes no Python dependency, for the harness or for
   its tools.
4. **RSpec plus the in-repo layer.** Tags and shared examples come with it;
   it is an external gem, and it leaves the same gaps as option 2.

## Decision

### Validation tiers

Applied as a coordination rule since 2026-09-15; this record makes it durable.

- **Commit tier (Debian).** Each capability commit runs `tick.sh`, plus
  every other suite whose inputs the commit touches. The report names the
  suites run and why the others are unaffected. It also records: the tested
  tree hash equal to the commit's tree; exact commands; each exit status;
  counts; control detections; edge cases plain and under AddressSanitizer;
  the ledger.
- **Milestone tier.** All suites run at every third capability commit, or
  before any merge request, whichever comes first.
- **macOS review.** A commit that changes compiled entries, contracts,
  relocation handling or other ABI-relevant code is reviewed on macOS
  individually. A harness- or documentation-only commit is reviewed in the
  next milestone batch.

Once lanes can be selected, "`tick.sh` in full" in the commit tier becomes
"the lanes the commit touches".

### The harness layer

1. **Result records.** Each harness program (first `source-port.rb`, then
   `source-edges.rb`, then others) also writes one versioned JSON document
   per case. It records:
   - route, mode, control and frame count;
   - every named counter;
   - faults by kind;
   - the first failure of each kind (frame, site, field, port value, original
     value);
   - per-field tables;
   - wall time and peak RSS.

   The existing text output stays unchanged during migration.
2. **Expectations as data.** Tracked files under
   `tests/doom-core/expect/` assert only the keys that matter for each case:
   - a **nominal** case asserts every fault kind equal to 0 and each coverage
     count exactly, so coverage loss cannot pass;
   - a **control** case asserts, for each fault kind it must raise, a count
     above 0 and the first failure's frame, site and field.

   Keys that are not asserted are still recorded. A failure prints the
   differing keys, not two joined strings.
3. **Reviewed updates.** A separate command writes a proposed expectation
   diff from a result set. Checks never rewrite expectations. The diff
   calls out every decreased coverage count and every removed assertion. A
   commit that changes expectations lists them in its report.
4. **Declared case matrix.** Cases are declared as data: lane, route,
   control, demo, frames and tier tags. The runner selects by any of these
   and runs cases under a concurrency cap that the caller sets per host.
5. **Controls stop at detection.** A control case runs until every required
   fault kind has been observed, plus a bounded window, with a hard frame
   limit. It must still reach its intended comparison and report the
   intended first failure, as 0008 requires. The window and limit are fixed
   after the timing measurement in migration stage 0. Nominal cases keep
   their full declared frame or tic counts, and a truncated run fails.
6. **Input-addressed artifacts.** Compiled entries, shared objects, session
   and adapter outputs are built once per run into a cache. The cache key
   hashes:
   - the packed source and contracts;
   - the kernel, adapter and reader binaries;
   - the compiler's version string;
   - flags.

   Each artifact records its key. Commit-tier runs may reuse the cache on
   the same host. Milestone and macOS-review runs start from an empty cache.
7. **Four verdicts.** Every case ends as pass, fail, error or skip:
   - **error** is a missing result document, a signal, or an absent output,
     and is never counted as pass or fail;
   - **skip** names its missing prerequisite, and `REQUIRE_ALL=1` turns a
     skip into a failure, as 0008 specifies.
8. **Mutation cases test the harness itself.** Known source mutations become
   tracked cases, for example deleting `dc_clear_planes`' counter writes or
   clip writes. Each applies to a private copy of the tree, runs the named
   route, and requires detection. A lane whose comparisons could be vacuous
   gets such a case.
9. **Runner.** The first implementation uses minitest. Its job is limited to
   scheduling cases, enforcing the concurrency cap, and emitting a summary as
   JSON and JUnit XML. Items 1-8 do not depend on minitest's API, so the
   runner can be replaced by another Ruby runner without changing
   expectations. The layer, its tools and its reports use no Python.
10. **Reports from records.** Numbers in commit reports, macOS review
    reports and ledger evidence come from the summary document. A host
    comparison tool diffs two summaries for the same revision.

### Migration

Each stage is its own reviewable commit, started only after the capability
in progress is committed.

- **Stage 0: timing.** `tick.sh` records wall-clock time per section on both
  hosts. No check changes.
- **Stage 1: frame lanes.** `source-port.rb` frame mode writes result
  records. The runner and expectations cover the frame lane's nominal and
  control cases on all four routes. On one revision, the existing `tick.sh`
  pins and the new expectations must reach the same verdict for every
  migrated check on both hosts. Only then are those `fctl` pins removed from
  `tick.sh`.
- **Stage 2: controls and mutations.** Controls stop at detection, and the
  mutation cases (item 8) are added.
- **Stage 3: edges and artifacts.** `source-edges.rb` and `edges.c` produce
  records, and the compiled, AddressSanitizer, session and adapter builds
  move into the artifact cache.
- **Stage 4: other suites.** Considered one at a time, and only where
  measured cost or duplication justifies it.

## Validation

- **Equivalence.** At a fixed revision, every migrated check reaches the
  verdict the replaced `tick.sh` check reached, on Debian x86_64 and macOS
  arm64. Any check retired rather than migrated is listed with its reason.
- **Sensitivity.** Every migrated control still detects with its intended
  first failure, and every mutation case detects. A deliberately changed
  expected value fails with a key-level diff. A case killed by a signal
  reports error, not pass or fail. A nominal run shortened by one frame
  fails.
- **Cost.** Commit-tier and milestone-tier wall time is recorded before and
  after each stage on both hosts. Targets are set from the stage 0
  measurement and recorded in a clarification to this record.
- **Dependencies.** Each run's summary records its Ruby, minitest and JSON
  versions. The layer and its tests run on both recorded Ruby lines (3.3 on
  Debian, 3.4 on macOS). If a later host installation lacks minitest, work
  stops for a decision; nothing is installed ad hoc.
- **Limits.** The layer does not replace the original-versus-port comparison
  as the oracle. It is not continuous integration. It adds no GPU or job
  mode 4 coverage.

## Consequences

- `tick.sh` shrinks as lanes migrate, and ledger evidence cites case
  identifiers and expectation files instead of pinned prose.
- The layer is new maintained test code. It must stay narrow: records,
  expectations, cache, verdicts and a thin runner. It must not grow into a
  general framework.
- Left open by this acceptance, to be settled at the stage that needs them
  and recorded in a dated clarification:
  - the expectation file format, TSV or JSON;
  - the control window and frame limit;
  - the cache location;
  - whether stage 4 happens.

## Clarification (2026-09-15): parallel lines of work on one host

The owner approved running implementation and verification in parallel on
one host, as separate lines of work. This clarification fixes how the
validation tiers and items 4 and 6 operate under that arrangement. It does not
change what any check must show, and like the rest of this record it
describes planned behavior unless a stage has delivered it.

- **One worktree per line of work.** Each concurrent line of work uses its own
  git worktree of one base checkout; no two share a working tree. Worktrees
  share the stash, refs and configuration. Therefore:
  - no line of work uses `git stash`;
  - no line of work rewrites or prunes shared history (`gc`, `worktree
    prune`, force push, deleting another line's branch);
  - only the verification line merges into main, and only with the owner's
    approval.
- **Independent verification.** A verification run checks out the exact
  commit fresh, in a detached worktree or an archive, never in the
  implementer's worktree. It confirms that the commit's tree hash equals the
  tree the implementer reports having tested.
- **Shared tools, built once.** The kernel, adapter and reader are built once
  per host for each tool revision, outside every worktree. A manifest beside
  them records:
  - the revision and build commands;
  - the compiler version string;
  - the sha256 of each binary.

  Suites select these tools through `KERNEL`, `ADAPTER` and
  `SPINEL_TYPEDUMP`. A branch that changes `tools/mlir` or `tools/contract`
  builds its own tools inside its worktree. Because item 6 keys artifacts by
  the tool binaries' hashes, its artifacts never mix with the shared build's.
- **Shared artifact cache.** Item 6's cache is shared by the worktrees on a
  host. An entry is written once, to a temporary name and then renamed into
  place, and is never modified afterwards. Milestone and macOS-review runs
  still start from an empty cache.
- **Heavy runs are serialized.** A host-wide exclusive lock covers full-suite
  runs, tool builds and timing measurements. A timing measurement (stage 0,
  and the cost validation of later stages) holds the lock while no other
  heavy process runs, following AGENTS.md's rule against competing
  measurements. Item 4's concurrency cap becomes a host-wide slot budget
  divided among the lines of work. The budget is set from the stage 0
  measurement and revised after stage 1's parallel runs.
- **Locations through the environment.** The shared tools, cache, IWAD, lock
  and per-line temporary directories live outside the repository. Tracked
  files name them only through environment variables, never through a host
  or home-directory path.
- **Ledger rows per entry.** Before a second implementation line starts, the
  migration ledger's rows move from the single table
  `tools/doom/core-migrated.tsv` to one file per entry inventory (step,
  render, input). The ledger tool reads all of them, so two lines of work do
  not edit one table.

## Clarification (2026-09-15): Stage 1 as delivered

Stage 1 is delivered for the frame lane. On revision `0af8ba0`, the
verification line passed it on Debian x86_64 and the macOS review passed it
on arm64 (evidence below). The owner decided, during implementation, to narrow
the Stage 1 validation to what speeds up the migration. This section records
those decisions and what now carries the checks. It does not change any CORE
semantics, ABI, status or poison rule.

**Cost targets.** No dedicated stage 0 measurement is required. Targets start
from the observed suite times and from each case's recorded wall time and peak
RSS, and are improved heuristically. This replaces "Targets are set from the
stage 0 measurement". Stage 0 still added per-section timing to `tick.sh`.

**Expectations come from invariants.**

- A nominal case asserts all of the following:
  - every fault kind of its route equal to 0;
  - its coverage counts exactly;
  - `run.frames` equal to its declared frame count;
  - `rc` equal to 0.
- Session nominals also assert that no other `core_state` slot and no
  read-only field changed. Adapter nominals also assert that every id was
  released exactly once and that a second release is refused.
- The nominal invariants (`rc`, the zeros, the second release) come from the
  declaration, never from a run, so a leaking run cannot write its own result
  in as the expectation.
- A control case asserts exactly three things:
  - its intended fault kind is above 0;
  - that kind's first-failure text;
  - the set of fault kinds it raised, compared by name only.

  The kind set is what tells apart controls that share an intended kind and a
  first failure, such as `clear-skip` and `clear-drop-counters`. Collateral
  counts are not asserted.
- A key that no Stage 1 control reaches on a route is still asserted equal to
  0 on that route's nominals. It is marked relaxed only to record that it has
  no detection evidence.
- `tests/doom-core/expect/keys.tsv` declares which keys a record may carry.
  `tests/doom-core/expect/frame.tsv` holds the assertions, each marked
  `origin=pin` (derived mechanically from the frozen pins at `e2f5676`) or
  `origin=run` (no pin holds the value). An `origin=run` value is either a
  declared invariant or filled from a record through
  `expect/frame-fills.tsv`.

**Equivalence was checked once and is not an exhaustive replay.**

- For every claimed control pin at `e2f5676`, the new control detects the
  same intended kind with the same first failure. The claimed control pins
  are the 15 compiled control pins.
- The adapter `push-kind` pin is retired as a route duplicate. Its intended
  kind, first failure and raised set were nevertheless checked against the new
  case `frame.adapter.push-kind.60`.
- Every other control pin is retired as a route duplicate rather than
  re-detected. The retirement is checked after normalizing status formatting,
  for example Ruby `push-capacity` against compiled native-status CAPACITY.
- Of the 64 frame-lane pins, 20 are claimed by cases and 44 are retired in
  `tests/doom-core/cases/frame.tsv`. Each retired row names its reason.
  `harness/cases.rb` fails on a pin that is neither claimed nor retired.
- Controls run on one route per defect class:
  - the compiled route carries the 15 frame-lane controls;
  - the session route carries a wrong-slot field-map case;
  - the adapter route carries `push-kind`, which ends the session with a
    native refusal and releases every id, and an untracked-result case, which
    must fail on the id it leaks.
- The other session and adapter control pins are retired as route
  duplicates. Adapter `push-cap-low` is also retired: the CAPACITY
  session-end class stays covered by the queued refused-step check in
  `tick.sh` (`tick.sh:1078@e2f5676`).
- The intended kind of each control is recorded in
  `expect/frame-controls.tsv`. It is chosen from what the control changes, not
  from what it happens to raise.
- The frame-mode refusals of the former composite check are refusal cases. Its
  queued-mode refusals stay in `tick.sh`.
- At `a96c00e`, all 16 controls matched their pins on intended kind, first
  failure, raised set and counts.

**Harness self-tests.** Four cases are tiered `selftest` and are selected only
by `--tier selftest`. Each encodes its expected verdict, so a passing
self-test run exits 0:

- two mutations delete `dc_clear_planes`' counter writes and its clip writes
  in a private copy of the tree, and must be detected;
- a nominal shortened by one frame must fail;
- a killed run must end as error.

**Tiers and routes.**

- `cases/frame.tsv` has tiers `commit` (24 cases), `milestone` (26), `macos`
  (24), `selftest` (4) and `retired` (44).
- `harness/run.rb` never runs a retired row.
- `harness/build-artifacts.sh DIR` builds the compiled, session and adapter
  prerequisites through `harness/artifacts.sh`, which `tick.sh` also sources.
  Its exit status must be checked before its output is evaluated.
- The frame-lane pins are removed from `tick.sh`. Its direct-mode and
  queued-mode checks stay.

**Gate runs.**

- The implementer runs what a change touches.
- The verification line runs the full gate on the exact commit, on a fresh
  checkout, with `REQUIRE_ALL=1`.
- A milestone adds the macOS review.

**Updates after a legitimate port change** (ruled for loop and sky; planned,
not yet implemented). When a port change moves a value derived from a pin, the
update goes through item 3's reviewed path as an override row:

- The row names the case, the key, the new value, `origin=run@<revision>` and
  a reason naming the port change. The generator refuses a row without a
  revision or a reason.
- An override may move coverage counts, route invariants, and control
  first-failure texts or raised sets. It never moves a nominal fault-kind row
  equal to 0.
- A count that would become a constant no regression can move is dropped with
  a reason instead of being overridden.
- The frozen pins are never edited. Equivalence stays recorded as established
  at `a96c00e`.

**Evidence at `0af8ba0`.**

- Debian x86_64 `tick.sh` with the IWAD: 169 checked, 169 pass, 0 fail, and
  the known red line that 228 of the step entry's 238 definitions remain. It
  took 620 s, against 2182 s with the frame-lane pins.
- At `a96c00e`, with `REQUIRE_ALL=1`: commit 24/24, milestone 26/26, and
  selftest 4/4 as designed.
- macOS arm64, with `REQUIRE_ALL=1`: the build entry exited 0; `macos` 24/24
  and `selftest` 4/4 as designed; `tick.sh` with the IWAD 169/169, with the
  same known red line; `cases.rb` found 74 rows, 64 pins, 0 unaccounted; and
  there were no macOS-only differences.

**Open, not blocking.**

- Both mutation self-tests are detected through a single key.
- The untracked-result case does not assert `ids_released_once`.
- The generated session schema is not compared with the committed `state.tsv`
  and `access.tsv`.
- The ledger split per entry is still pending.
- A second implementation line waits for that split.

## Clarification (2026-09-16): what an override may move

This corrects one sentence of the Stage 1 clarification above. That sentence
says an override may move "coverage counts, route invariants, and control
first-failure texts or raised sets". "Route invariants" contradicted the same
section's rule that declared nominal invariants never come from a run.
Implementing that sentence would have let an override write a leaking adapter
run's `rc` and `second_release` in as passing. The corrected rule is below;
the sentence above stays as written and is superseded by this section.

Every expectation row carries a class, set where the row is generated, and a
row without a class is refused.

- **Declared** values can never be overridden:
  - `rc` and `run.frames`;
  - every fault kind that must equal 0;
  - `session.other_slots_changed` and `session.readonly_changed`;
  - `adapter.second_release`, on every case;
  - the outcome and `rc` of refusal and control cases.

  Overriding any of these would let a run redefine what it must equal.
- **Measured** values may be overridden, each with a revision and a reason:
  - coverage counts;
  - measured route counts, such as `adapter.ids_allocated` and
    `adapter.ids_released_once`;
  - control first-failure texts and raised-kind sets;
  - `adapter.session_failed`, the site at which a refusing adapter case ends
    its session;
  - the ended message of a refusal case.
- **Revision.** It must be a hexadecimal commit id of 7 to 40 characters that
  names an existing commit, checked when expectations are generated.
  Generating therefore needs a git checkout. Running `harness/run.rb` against
  the tracked `expect/frame.tsv` does not, so a verification line working from
  an archive can still run every case.
- **Numbers.** Every movable numeric value must be an integer.
  - A coverage count must be greater than 0. A count that becomes 0 is
    dropped with a reason instead, because a constant no regression can move
    is not coverage.
  - A measured route count must be at least 0.
  - Negative values are refused everywhere.

## Clarification (2026-09-16): a coverage count of zero

An expectation may assert a coverage count equal to 0 when a run legitimately
produces 0 and a plausible defect would move it. The two 200-frame nominals
assert `planes.sky_columns eq 0` on that basis: DEMO1 draws its first sky
column at frame 572, so a 200-frame run reaches none, and a defect drawing one
earlier moves the count off 0 and fails the case. The reason is recorded with
the expectation, in the matrix's `origin` prose, so regenerating carries it.

An **override** may still never set a coverage count to 0. There the 0 would
come from a change to the port rather than from a run, and nothing could move
it again. The number is the same and the meaning is opposite; what separates
them is where the value came from.

This does not weaken the sentence in the override clarification above — "A
coverage count must be greater than 0. A count that becomes 0 is dropped with
a reason instead, because a constant no regression can move is not coverage."
That sentence constrains what an **override may write**, and it stands
unchanged. This one permits what a **run may assert**. Both are in force; they
differ on provenance, not on the number.

## Clarification (2026-09-16): the loop+sky expectations

The plane walk and the sky plane moved ten expectation values that were
previously pin-derived. Each is a measured key under the rule above and carries
`origin=run@cde713f` and a reason. The equivalence the pins recorded is
superseded at that revision; the pins themselves are unchanged.

Each host's evidence is named rather than merged, under the rule below.

- The **Debian commit tier at `0f55da5`**: 28 cases, 28 pass, 0 fail, 0 error,
  0 skip, under `REQUIRE_ALL=1`, across the ruby, compiled, session and
  adapter routes.
- The **macOS review of `feat/doom-core-loop-sky` at `628edab`**: all ten
  override values reproduced, the three control first-failure texts byte for
  byte, and `tick.sh` 170 checked, 170 pass, no SKIP. Relayed from that host's
  gate and recorded here as relayed; this record's line holds no log of it.

## Clarification (2026-09-16): numbers measured on another host

A record written on one host does not state a number measured on another as
though it were observed there. A relayed figure is labelled with the host and
the gate that produced it, or it is left out. A verification line with no log
for a result on its own host writes no result.

## Clarification (2026-09-16): writes into the shared area

A write into the shared tools area announces **and waits for an
acknowledgement**. A notice nobody has replied to is a log line written in
advance, not a check. A request is an acknowledgement for exactly what was
requested, from the party that requested it; anything outside that scope
announces and waits again.

No write into shared state is queued or deferred behind a lock. A job that
fires when the lock drops, while a gate reads that directory and nobody is
watching, records a clean successful copy whichever way it went. A hold must
not quietly become a decision: a line that is waiting says so.

## Clarification (2026-09-16): the accounting runs inside a tier

The pins are TRACKED, at `tests/doom-core/expect/pins.tsv`, and the accounting
is split along the line `expect.rb` already draws between generating and
running. Nothing crosses it: the generator stays on the generating side, the
runner stays runnable from an archive, and the archive line gains a real check
rather than a named skip.

- **`selftest.pins-tracked`** is a RUN. It asserts that the tracked pins name
  the frozen revision and the `tick.sh` blob the runner holds as its own
  constants -- so a stale or substituted file fails from its own header, before
  any comparison -- and then runs `cases.rb` against it, passing only when that
  exits 0 and reports 0 problems. It needs no git and works from an archive.
- **`selftest.pins-regenerate`** is a GENERATE. It regenerates the pins
  from the frozen revision and requires the result to be byte-identical to
  the tracked file. It is guarded on RESOLVING THAT REVISION, not on `git`
  being present: `pins.rb` refuses to fall back to the working tree, so the
  failing case is a clone that HAS git and LACKS the revision, and a guard
  on `git` would be satisfied while the step could not run -- a pass that
  could not have failed, wearing the clothes of a guard.

The two have different powers and neither is redundant: the run side proves the
tracked file is the one it should be, the generate side proves it is what the
frozen revision still produces. A stale generated artefact is not hypothetical
for this lane -- the context above records a full-suite attempt that failed
four checks only because pins were not regenerated.

THEY ARE NOT CASES IN THE MATRIX; THEY ARE RESULTS IN THE REPORT. Nothing
selects them by column, they have no expectations, they are not rows of
`cases/frame.tsv` -- and they produce result rows carrying the same four
verdicts, so the totals, the JUnit file and the "no fail or error" gate pick
them up with no new vocabulary, and no gate can be green while they failed.
"Four cases are tiered `selftest`" above and the tier count of 4 both stay
true, and the tier is no longer only cases.

THE SKIP SAYS WHAT IS MISSING, WHAT IS NOT KNOWN WITHOUT IT, AND -- under
`REQUIRE_ALL=1` -- WHAT NOT TO DO. The fix that makes the message go away is
unsetting the variable, and that is the one fix that must not be taken, so the
sentence is in the message rather than in a document nobody is reading while
looking for a green run.

**The tie-off.** If `run.rb` ever acquires a git dependency of its own,
`expect.rb`'s paragraph and this record's revision rule change IN THE SAME
COMMIT. A contract sentence and the code it describes that can drift apart by
one commit will.

`harness/pins.rb` and `harness/cases.rb` run in the `selftest` tier and must
report 0 problems. Until that lands they run nowhere: `cases.rb` is the only
checker of the case matrix's provenance column, and no suite, script or tier
invoked it. A checker reachable by no gate is a document, not a check. **A
gate that does not run `selftest` under `REQUIRE_ALL=1` is not a gate.**

They join the tier as a **non-case step**, not as cases. The four selftest
cases each encode an expected verdict; `pins.rb` and `cases.rb` are programs
with an exit status and a problem count and encode none. So "Four cases are
tiered `selftest`" above and the tier count of 4 both stay true, and the tier
is no longer only cases. The step passes when both exit 0 and `cases.rb`
reports 0 problems.

**The tier counts earlier in this record are stale and are corrected here.**
They read as current design rather than as evidence at a revision, which makes
them the same true-looking sentence this record keeps warning about. Measured
at `92382cc` by `cases.rb` itself, against `pins.rb`'s 64 frame-lane pins at
`e2f5676`: 78 rows, 0 problems, tiers `commit` 28, `milestone` 30, `macos` 28,
`selftest` 4, `retired` 44 — where the record says 24, 26, 24, 4, 44. The
Stage 1 evidence block further down is correctly labelled as evidence at its
own revision and is left as it is.

## Clarification (2026-09-16): two columns named `origin`

The harness has two fields with this name and they do not share a type.

- The **case matrix** column, read by `harness/cases.rb`, is
  `tick:LINE@REV`, `tick:LINE@REV part N`, `tick:LINE@REV retired: REASON`, or
  `new: REASON`. The `new:` arm *requires* its reason: an empty tail is the
  diagnosed problem "origin new with no reason". Prose is the specified value
  of this field, not a misuse of it.
- The **expectation** column, read by `harness/run.rb`, is `pin` or
  `run@<7-40 hex>`. The override rule above applies to this one only.

The expectation reader ALREADY rejects a matrix-shaped origin, at the check in
`harness/run.rb` that applies its `ORIGIN` pattern to every expectation row.
The other direction is ruled and **not yet implemented at `92382cc`**:
`cases.rb` is to diagnose a matrix cell holding an expectation-shaped origin —
a bare `pin`, or `run@<hex>` with nothing else — so that the confusion is
caught by code in both directions rather than by a reader remembering which
column is which. **This sentence's label is removed by the commit that adds
that diagnosis**, which is checkable in `cases.rb` rather than remembered.

Renaming one of the two is future work, to be done when the ledger is split
per entry and the matrix is open anyway.

## Clarification (2026-09-16): reporting an absence

Before reporting that something does not exist, state the scope that was
searched. "It is not there" is the one claim that cannot be verified by
looking harder in the same place.

Two instances, both from 2026-09-16, and both are recorded because one reads
as a story about a careless person while two show the shape of the mistake.

- A listing of `docs/decisions/` in a worktree on `feat/doom-core-loop-sky`
  does not show `0010-core-resource-contract.md`, because that record is on
  `main` and is not an ancestor of `0f55da5`. Same repository, same machine,
  same second — and the absence was a fact about the branch.
- A search for the IWAD on the macOS host reported that the file was not
  there. The search ran at `-maxdepth 6`; the file is eight levels deep and
  exists. The absence was a fact about a depth limit that the report did not
  state. Relayed from that host; this line holds no log of it, and records it
  under the rule two sections above rather than as something observed here.

Neither scope was wrong to use. What was wrong was reporting the result
without it.

## Clarification (2026-09-16): how a rule goes wrong, and which rules to write

Two sentences head this section because they are what someone who was not here
can use. The instances underneath are how each is recognised.

**FORM ASSERTS, INDEPENDENTLY OF INTENT.** The present tense asserts that a
thing exists. The second person asserts who is being addressed. An answer
asserts that the answerer has standing. In each case the author supplied the
content and the grammar supplied a claim, and the claim was the part that was
wrong. Three instances, all from 2026-09-16: a ruling written in the present
tense, in the section introducing the rule against it; one message body sent to
two parties in the second person, which credited one reader's review to the
other; and a recommendation phrased as an answer to another line's agent, which
left that agent holding two instructions.

**A RULE NEEDS ITS BOUNDARY STATED, NOT ONLY ITS CONTENT.** Broadcast every
finding so that no correction sits in one thread, and never spend a cold
reading, are both right, and they collide when the content is the instrument.
Neither said where it ended. Two right rules with no statement of where one
stops is the same shape as the defects they were written against, applied to
the rules themselves.

**AND A RULE IS WORTH WRITING DOWN WHEN ITS VIOLATION IS INVISIBLE.** A visible
failure is caught by anyone paying attention and needs no record. The ones that
earn a sentence are the ones where nothing goes wrong on screen: a pass that
could not have failed, a golden that only ever ran where it was written, a
message delivered with a word removed, an exit code with two causes, a
diagnostic never printed, a claim that spread across hosts through a summary.
Not one of them looked like a failure at the moment it happened. That is also
why this list is not longer.

### Reporting

**A CLAIM ABOUT A STATE NAMES WHAT WAS INSPECTED TO ESTABLISH IT**, the twin of
the absence rule above. A progress signal and a state read the same in a
transcript. Four instances, four holders, one countermeasure every time -- the
holder of the fact went and looked, and said what it had looked at: three
signals relayed as states (an intention as a state, elapsed time as completion,
a search depth as a repository); a smoke test that confirmed a timer on two
payloads that were not identical; a both-hosts claim resting on one host; and
an absence measured at a depth the report did not state.

**A RELAY LOSES THE SUBJECT, NOT THE FIGURE.** Compared item by item against
its source, a day's relayed measurements agreed on every number and had
dropped two details -- one of them the binary a 49-byte difference was measured
on. The subject is obvious to whoever holds the measurement and invisible to
everyone downstream, which is why this is not a rule about carelessness. One
level up, the same mechanism is INHERITANCE: a summary with no room for the
difference promotes one host's result to cover both, and nobody has to assert
anything for the claim to spread.

**A COLD READING IS SINGLE-USE AND NON-RENEWABLE.** A finding about a BEHAVIOUR
costs nothing to circulate; a finding about WHAT A TEXT SAYS spends every
recipient's cold reading. Contamination travels to whoever receives the
content. A finding of the second kind names at the top whose reading it spends,
and where a cold reading is wanted the content is withheld from the candidate
reader. Two readings test two different properties: a TEXT reading asks whether
the words do their job; an ENCOUNTER reading hands a fresh reader the run's
output alone and asks what is wrong and what to do next.

**AND AN ACKNOWLEDGEMENT COVERS THE EDIT AS DESCRIBED**, including a correction
to a line that edit itself invited. A fresh announcement is needed for a change
to what a row ASSERTS that nobody has heard yet -- a new measurement, a widened
claim, a row that begins covering something it did not cover. Any touch of a
digest, an environment line or a file's bytes announces every time, with no
continuity from a previous acknowledgement.

## Clarification (2026-09-17): the Stage-1 mixed lanes, retired

The owner decided to freeze the Stage-1 mixed lanes at their green revision,
record them as retired, and stop running them against the new port. These are
the lanes in which `tests/doom-core/source-port.rb` runs ported code beside the
running original:

- the frame lane's cases (`tests/doom-core/harness/run.rb` over
  `tests/doom-core/cases/frame.tsv`);
- the source-port sections of `tests/doom-core/tick.sh`;
- the route comparisons, the boundary-copy checks and the leaf checks of
  `tests/doom-core/screens.sh`.

**They are superseded and refunded, not abandoned.**

- The lanes asked whether the ported code agrees with the original. That
  question is now answered by `tests/doom-core/verify.sh`. It runs
  `step-diff.rb` and `render-diff.rb` over every tic of DEMO1, DEMO2 and DEMO3,
  and `input-diff.rb` over the input step, each against the original loop.
  All three drive decision 0008's entries
  (`examples/doom/core/src/doomentry.rb`). The same lane builds those entries
  with the kernel.
- The mechanism the lanes exercised was the boundary copy
  (`tests/doom-core/fixtures/source/copy.tsv`, `tests/doom-core/copy-check.rb`).
  It sequenced a ported side against an unported one. It is refunded, because
  both real entries take the one allocation of each shared field.

**The evidence is kept at its revision.** The lanes are frozen at `0af8ba0`,
the revision this record's Stage-1 clarification names as green on both
hosts. Checking out that revision and running the same scripts reproduces
that evidence.

**The retirement is visible where the lanes run:**

- `tests/doom-core/harness/retired.sh` prints a `RETIRED` line naming the
  revision and what supersedes it.
- `tick.sh` and `screens.sh` print that line in place of the retired sections.
- `run.rb` prints it and exits.

A retired section is neither a skip nor a failure. `STAGE1_LANES=run` runs the
sections against the current tree anyway. They are then expected to fail, and
that is not a path to fixing them. The other sections of `screens.sh` are not
retired:

- the recorded screens of the original;
- the duplicated-helper check;
- the status bar's rare branches;
- the one-closure build;
- the HUD offsets.

## Clarification (2026-09-17): Full's route, and a reference that built what it should observe

**The route lane.** `tests/doom-core/verify.sh` now runs Full's job-mode-1
route (`examples/doom/core/full/route.rb`). It runs the three built entries
through their generated 0007 adapter, over every tic of each demo, and compares
two things:

- the screens, against the original's recordings;
- the state at checkpoints, against the original's state, played in job mode 1
  by `tests/doom-core/route-reference.rb`.

The two checks Full makes between calls are part of the route:

- the render entry's job-mode cell, read back before every frame;
- the pending-rebirth refusal, on the live registry cell.

Each check has a planted control that asserts its own message.

**Compared at session open only.** This is a category of the state lane that
the macOS coordinator approved on 2026-09-17, with three conditions:

- the claim is stated with its measurement;
- the cells are named, not a mode;
- a wrong value at session open fails.

The cells are `renderer_dc_srcres`, `renderer_ds_srcres` and
`renderer_ds_srcbase`. `tests/doom-core/route-lane.rb` lists them, with each
one's reason and the measurement they were named from:

- `render-diff.rb --exclude-only core_frame`, over the 10996 frames of
  DEMO1-3;
- `renderer_dc_srcres` differed on 38 frames;
- `renderer_ds_srcres` changed in the original on 743 frames;
- `renderer_dc_srcofs` and `renderer_dc_srcbase` differed on none, so both are
  compared after session open too. `render-diff.rb` no longer excludes
  `renderer_dc_srcofs`.

At every checkpoint after session open, each run of the lane prints both
sides' values of the three cells, marking the pairs that differ. This is a
record, not a check. At session open the cells are compared like any other
field, and the lane plants a wrong one there to show it fails.

One persistent field is compared only partly. `core_command` is written by
Full from the demo on both sides, so it catches a step entry that writes the
command buffer, and nothing else.

**A reference observes the program; it does not build its own.**

The defect. `build-prepared.rb` and `build-reference.rb` each constructed a
`Jobs` and a `JobExecutor` sized by the screen. The program has only the
renderer's own pair, sized by the view (`render.rb:465`), and
`tools/doom/core-counts.tsv` had transcribed the screen size. So both sides of
`state.sh` read an object the program does not have, and agreed.

Three lanes were green while the bound was wrong:

- `state.sh`, at 251 of 251, with both sides fabricated;
- `render-diff.rb`, which reads the renderer's own `@jobs`;
- the route's screens.

The fourth lane, the route's checkpoint comparison, found it
(`jobs_height`: route 200, original 168). It could, because its reference read
the renderer's objects.

The fix. The macOS coordinator ruled it a mis-transcription, not a design change:

- the catalog now measures `viewheight` and `viewpixels`;
- the Jobs rows count by them, so `jobs_ycount`, `jobs_yx1` and `jobs_yx2` are
  sized by the view;
- the builders read the renderer's pair.

The guard. `Doom::Core::Reference.check_graph` takes as roots the classes
`examples/doom/bin/doom.rb` constructs in its `main`. It refuses any other
object a reference is handed, unless a root holds that very object.
Each object must be handed over under its own class's name, so there is one
object per class. `tests/doom-core/graph-guard.rb` checks three things:

- the builders' old construction is refused by name;
- a second Renderer handed over under another key is refused;
- the program's own objects pass.

`tests/doom-core/mode-one.rb` checks where the job-mode-1 source conversion
stops, and asserts each refusal's message.

**What the guard does not catch.** It checks where an object came from, not the
arguments a root was built with. A root built with the wrong arguments still
passes, and so does everything it holds. For example, a Renderer at
setblocks 11, handed over as the Renderer, carries a screen-sized Jobs
through the guard. That is a narrower form of the same defect, and nothing
here catches it.

## Clarification (2026-09-18): one corpus, two executions

**The principle. Two hosts is not two coverages, and compiler confidence is not
a substitute for executing the code under test.** `AGENTS.md` already says that
agreement between two outputs from one generator is not an independent semantic
oracle; that is about WHAT a comparison is made against. This is about WHERE it
is made. Playing DEMO1-3 on Debian x86_64 and on macOS arm64 covers two hosts
and one corpus. A definition no demo enters is entered by neither host's
compiled objects, however green both runs are, and "the kernel compiles what the
source says" is a claim about the compiler rather than evidence about that
definition.

**The corpus, and its edges.** The differential corpus is

- three recorded demos: DEMO1 (E1M5), DEMO2 (E1M3), DEMO3 (E1M7);
- the 19 synthesised scenarios of `tests/doom-core/scenarios.rb`, over E1M1
  (4), E1M2 (5), E1M3 (1), E1M5 (6) and E1M8 (3).

Outside it entirely: E1M4, E1M6, E1M9, and E1M7 beyond DEMO3's path. Nothing
here is a claim about those.

**What was compared where, before this.** `step-diff.rb` and `render-diff.rb`
run the port as plain Ruby: CORE-source execution. The route lane
(`route-demo.rb`) and the playable program (`native.sh`) run the compiled
objects, and both play demos. So every definition only the scenarios reach --
the melee attacks, the powerups, the teleports, the switch, the boss death, and
the six scenarios that witness the port stopping where the original stops --
was compared in CORE-source execution only.

**The lane.** `tests/doom-core/native-scenario-diff.sh` runs the same corpus,
scenario for scenario, against the COMPILED step entry through Full's route,
and `verify.sh` runs it after the route part, over the same linked library.
Every definition exercised by the differential corpus is exercised and compared
in both CORE-source and compiled-object execution.

For each scenario, `native-scenario-diff.rb` builds the original's objects as
`step-diff.rb` does -- the scenario's setup first, because the state it writes
is the start the scenario is about -- prepares a session from those post-setup
objects, binds the compiled entry, and runs the scenario's commands. The two
sides then EVOLVE INDEPENDENTLY from that one prepared start, which
`step-diff.rb` does not do: `step-diff` copies the original's state into the
port's layout every tic, and copying tens of megabytes into the adapter's
registry every tic is not something a lane can do. A difference therefore
persists instead of being overwritten, which suits a regression lane and does
not suit locating a cause -- the source lane locates causes.

**The cadence, and what it leaves.** The macOS coordinator chose it on 2026-09-18:

- after EVERY tic, the gametic the entry answers and every scalar (the fields
  sharing `core_state`, read back from the registry);
- after the FIRST tic and after the LAST, every field of the generated layout,
  the buffers included.

An ARRAY-ONLY DIVERGENCE -- a buffer cell the compiled side writes differently
in a tic whose scalars all agree, and which no later tic reads back into a
scalar -- is therefore located by the full comparisons alone: at the end of the
run, not at the tic that caused it. The lane prints that sentence itself, in
every run, and a control witnesses it: a planted cell of a free mobj slot, which
no thinker list holds, passes every tic and is caught by the final comparison.
The other control plants a scalar and is caught in its own tic.

A scenario that stops ends the run: nothing is read back from a route whose
call the adapter refused. The lane then runs that scenario a SECOND time and
takes the full comparison after the last tic that completed -- or, when the
first tic is the one that stops, at session open, which is then the only state
the two sides ever shared. Both runs must stop in the same tic.

**The acceptance items, and where each is met.** The lane's own output is the
record; `verify.sh` prints it in full.

1. *All 19 scenarios supplied to the compiled step path.* The corpus comes from
   `scenarios.rb` itself (`native-scenario-diff.rb --corpus`), and the lane
   checks that every name it defines has a run on disk and no other. A scenario
   added there and not run here fails the lane.
2. *Compared against the same reference state the source differential uses.*
   Both read the original's own ivars: `step-diff.rb` directly,
   `native-scenario-diff.rb` through `Doom::Core::Reference`, which is what
   `route-reference.rb` reads the original with.
3. *The source-only definitions exercised in compiled execution.*
   `step-coverage.rb` prints them by name, with the scenarios that enter each,
   and every one of those scenarios is in this lane's corpus. See the limit
   below.
4. *No state disagreement.* Every scenario: 0 over every compared tic and every
   full comparison.
5. *Retained as a permanent regression test.* It is a part of `verify.sh`, with
   its own summary line and its own controls.
6. *Coverage stated in terms of the shared corpus.* The lane prints the corpus
   it ran -- the scenario count, the tic count and the maps -- and its cadence,
   before any result.

**What this lane does not establish.**

- ENTRY INTO A DEFINITION IS NOT OBSERVABLE IN THE COMPILED OBJECT. There is no
  tracer over compiled code here. What the lane establishes is that the
  scenario which enters a definition in CORE-source execution -- `step-diff.rb`
  asserts that with a `TracePoint`, and refuses a scenario that misses its
  target -- is run against the compiled entry and agrees with the original at
  every compared tic. The six scenarios that stop are the exception: the
  compiled side's refusal is raised inside the definition under test, so that it
  refuses in the same tic as the original's raise is evidence it got there. It
  names no site, and the lane does not claim one.
- PACING IS NOT CHECKED, here or in any compiled lane. `native.sh` plays with
  `-nopace` by design and this lane calls the entry as fast as it can: what is
  compared is frames and state, never when a tic happens.
- A SCENARIO THAT STOPS IN ITS FIRST TIC compares no tic at all. `exit-11` is
  one: what it witnesses is that both sides stop in tic 0, over a session whose
  state equals the original's at session open.
