# DOOM CORE migration implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` task by task.
> Debian implements sequentially; Mac reviews and independently validates.
> Do not create additional agents or rebuild shared dependencies concurrently.

**Goal:** Run the existing supported DOOM game tick and complete CPU frame
computation through allocation-free CORE entries on both native hosts.

**Architecture:** Preserve the 0007 public ABI and registry. Refactor computation
into top-level Ruby functions over resident typed storage, package their source
into a verified single root, and propagate borrowed-buffer facts through direct
helpers. Keep the old Full game as a fixed independent regression reference.

**Tech stack:** pinned Spinel, existing contract reader, LLVM/MLIR 23.1.1,
CRuby with Prism, C harnesses and the existing Full SDL shim.

**Spec:** [0008](0008-doom-core-migration.md), including its authorization section;
[fork review](../core/doom-stage2-fork-review.md).

## Global constraints and execution

- Base: Extended `5ee37630663d3ad66a9b45f43bf84a09e42132b7`; read the design
  branch's later documentation commits before beginning.
- Initial pin: `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`. Do not bulk import
  `spinel-fork`, alter predecessor checkouts, or silently repin.
- Use a separate `feat/doom-core-stage2` branch/worktree based on this design.
  Do not merge main, force-push or delete branches during this assignment.
- English source comments, maintained documentation and commit messages;
  retain GPL-derived notices and exact source provenance.
- Preserve 0007 statuses, arithmetic, borrow, alias, registry and poison rules.
  No callback to Full from CORE, no allocation/runtime symbol in a CORE object.
- Ordinary 0005 and freestanding semantics remain unchanged. New checked forms
  need named execution/refusal fixtures; a changed public contract needs a
  separate concrete owner decision. Keep such questions from blocking unrelated
  audit/source-packaging work.
- Implement Tasks 1–9 in order. Each task ends with its focused checks, a commit
  and a report containing the exact SHA, commands, counts, skips and remaining
  work. Start the next independent step without waiting for a receipt. Before
  depending on an interface review finding, resolve it; do not stack work on a
  known unsound boundary.
- The commands below name planned files. Until a task delivers them they are
  not implemented commands, and missing execution is not a passing test.
- Keep reusable facts/algorithms in small modules; do not add another general
  IR, another Ruby parser or a universal visitor.

The initial environment for each new shell follows [building](../building.md).
The host selects its installed official prefix and Ruby executable first:

```sh
export LLVM_PREFIX=/opt/llvm-23.1.1       # Debian; select the official Mac prefix there
export CLANG="$LLVM_PREFIX/bin/clang"
export CC="$CLANG"
export NM="$LLVM_PREFIX/bin/llvm-nm"
export RUBY=ruby                         # must be able to require prism
umask 022
export SPINEL_CORE_BUILD="$PWD/tools/mlir/native/build"
export SPINEL_TYPEDUMP="$PWD/tools/contract/build/spinel-typedump"
export SPINEL_SEAM="$PWD/vendor/spinel"
"$CLANG" --version
"$RUBY" -rprism -e 'puts RUBY_VERSION'
```

For a clean dependency build, make `cc` resolve to that clang in a temporary
process-local shim as documented. Use an empty compiler cache, and run every
vendor make with explicit CC (including deps/clean):

```sh
SHIM_DIR=$(mktemp -d)
CCACHE_DIR=$(mktemp -d)
export CCACHE_DIR
ln -s "$CLANG" "$SHIM_DIR/cc"
ln -s "$LLVM_PREFIX/bin/clang++" "$SHIM_DIR/c++"
export PATH="$SHIM_DIR:$LLVM_PREFIX/bin:$PATH"
git submodule update --init --recursive
make -C vendor/spinel clean CC="$CC" NO_CCACHE=1
make -C vendor/spinel deps CC="$CC" NO_CCACHE=1
make -C vendor/spinel -j8 CC="$CC" NO_CCACHE=1
sh tools/contract/build.sh
sh tools/mlir/native/build.sh
```

Keep the shim for suites that invoke `cc`, then remove only those two temporary
directories. A version banner does not identify the compiler that built all
vendor objects: retain build commands/logs and inspect representative compiler
and runtime objects. Record upstream suite command/flags if a compiler changes.

## Task 1: Close the implementation scope and fork-patch audit

**Files**

- Create `tools/doom/audit-core.rb`, `tests/doom-core/fork-compat.sh`,
  `tests/doom-core/fork/ledger.tsv`, and necessary attributed reproducers there.
- Create `docs/core/doom-stage2-scope.md`; update the fork review with fresh
  execution evidence, without overwriting its initial historical classification.
- Read the original `examples/doom/lib/doom/`, `examples/doom/bin/doom.rb`,
  existing `tests/doom/manifest.tsv`, and the fixed fork patch ledgers.

**Interfaces:** `audit-core.rb --output DIR` produces `closure.tsv`,
`state-use.tsv`, `cycles.tsv` and `configurations.tsv`. The first records
caller/callee/source location/resolution/domain; state-use records each ivar
and all consumers/writers; cycles records every recursive component and its
source edges; configurations records the existing CLI mode and its reference
command. Missing/ambiguous classification is an audit failure.

- [ ] Pin reference source hashes and enumerate the roots in 0008, including
  post-tick random/HUD/status-bar work, all frame composition, key/ticcmd history
  and recording quantization. Distinguish runtime branches from setup-only
  methods. Do not use the 571-method syntax census as the call graph.
- [ ] Use existing parser information and a DOOM-specific resolution catalog.
  Give each unresolved receiver/call an explicit resolution or an exclusion
  supported by the boundary. Test a removed edge, an unclassified ivar and an
  added reachable helper: each must fail the audit rather than shrink the set.
- [ ] Find all recursive components, including BSP, sight, sound propagation
  and action/state cycles. Record valid-input termination rules and the proposed
  iterative frame representation for each before source conversion.
- [ ] Populate every patch ledger row, including all six batch-1 defects,
  opt-in patches and instrumentation entries. Import only the necessary
  self-contained reproducer sources, expected results and notices.
- [ ] Run `sh tests/doom-core/fork-compat.sh` on the actual pin, with the
  documented compiler. Require exact output/exit and controls, including GC
  stress where relevant. Print source evidence separately from execution.
  An unexecuted row is not counted as a pass. The audit is complete only when
  each relevant row is measured and every deferred row has a scoped reason.
- [ ] For each required reproduced blocker, prepare a minimal compiler fix
  candidate in isolation, retaining an unpatched failing control. Report the
  exact candidate SHA and compatibility checks for review before a pin move.
  Do not carry optimization or analysis hooks along with a bug fix by accident.
- [ ] Commit the scope/audit deliverable. Report which fixes are required by
  this migration, which remain general Full defects and which are unnecessary
  on the two native hosts. Continue source packaging while a pin is reviewed.

An example audit assertion is executable data rather than a success guess:

```text
gc-program-name  99a5fc49  program_name.rb  Full  absent-verified  reproduced  prepare-fix  global string is not marked
```

The real ledger uses tabs and actual measured statuses. No row may retain this
sample's verdict merely because the old checkpoint reported it.

## Task 2: Reproducible application source packaging

**Files**

- Create `tools/doom/pack-core.rb`, `tests/doom-core/source-pack.sh` and
  `tests/doom-core/fixtures/source-pack/`.
- Create `examples/doom/core/README.md`, `NOTICE.md`, `sources.tsv` and the
  first attributed `src/fixed.rb` source unit, using the Stage-1 extraction's
  proven adaptations and the original revision.
- Reuse `Core/Boundary.cpp` and the existing reader for semantic source checks.

**Interface:** `pack-core.rb --manifest FILE --root DIR --output FILE
--map FILE` writes the packed source and origin map atomically after validation.
The manifest columns are `path`, `sha256`; order is meaningful. Each map row is
`packed_start_line`, `packed_end_line`, `path`, `source_sha256`. Return nonzero
without replacing prior outputs on any error. Generated files live under build/.

- [ ] Write fixtures with two source units and a direct helper, duplicate
  methods/constants, a missing file, bad digest, traversal path, unlisted unit,
  `require_relative`, top-level execution, `__END__`, incomplete unit syntax,
  encoding conflicts and source mutation after capture.
- [ ] Implement read-once capture and newline-only assembly; feed the assembled
  bytes and each captured unit to the existing parser/checker; compare their
  definition inventories. Never use a regex to decide whether a
  Ruby definition is unconditional, or merge separate AST node-ID namespaces.
- [ ] Verify deterministic bytes/maps, origin-correct diagnostics, refusal
  categories and preservation of previous artifacts on failure. A mutation
  after capture may not change that build's output.
- [ ] Compile and execute the two-unit fixed helper via the existing kernel
  tool, compare with the original CRuby helper, and bind the map/manifest digest
  to package provenance. No production compile may read a sibling checkout.
- [ ] Run `sh tests/doom-core/source-pack.sh` and Stage-1 schema/capabilities
  suites; commit the independently working source packager.

Example maintained units used by the positive fixture:

```ruby
# first.rb
def dc_twice(a)
  a * 2
end
# second.rb
def dc_pick(a)
  dc_twice(a) + 1
end
```

The native result for `dc_pick(3)` must be 7; a source-order/digest mismatch is
a packaging failure, not an arithmetic disagreement.

## Task 3: Checked borrowed-buffer calls

**Files**

- Add `tools/mlir/native/include/spinel-mlir/Core/BorrowFacts.h` and
  `tools/mlir/native/lib/Core/BorrowFacts.cpp`; update the Core CMakeLists when
  introduced.
- Modify `Core/Eligibility.h/.cpp`, `Core/Kernel.cpp`,
  `Frontend/Scalar/Importer.cpp`, `ScalarAst.h` and `MlirGen.cpp` as required.
- Create `tests/doom-core/borrowed-calls.sh` and its fixture directory.

**Interface:** expose one derived borrow/effect result to checker, selector and
lowering. A private buffer argument carries pointer plus immutable u64 count;
the source's scalar arguments remain separate. Exported contracts do not change.

- [ ] Write and run the presently refused positive fixture below before
  implementing. Add a nested helper variant and two calls with different live
  buffers/counts in the same entry.

```ruby
def dc_at(data, i)
  data[i]
end
def dc_pick(data, n_data, i)
  n_data = n_data + 100
  dc_at(data, i)
end
```

With descriptor count 1 and data `[11,99]`, index 0 returns OK/11; index 1
returns BOUNDS and leaves result 123 unchanged. The scalar reassignment must
not enlarge the helper's bound; the guard element 99 must remain untouched.

- [ ] Derive private buffer/scalar/boolean signatures and effects to convergence;
  retain monotonic conflict handling and explicit nonconvergence refusal.
  Propagate source count reads through calls for the existing u64-to-source-i64
  checks. Do not paint unknown values as integers.
- [ ] Lower hidden counts from descriptors at every call. Verify negative
  indices against descriptors larger than INT64_MAX without dereferencing
  synthetic storage. Add differing-element load/store cases including i64
  INT64_MIN and failed narrowing before a write.
- [ ] Add named refusals for readonly writes in a callee, mutable duplicate
  arguments, buffer escape/rebinding, arithmetic on a buffer, unknown calls
  and recursive call cycles. Add a repeated-readonly positive control.
- [ ] Add internal boolean-result helpers and branch consumers; refuse a bool
  exported under an integer contract. Failed callees preserve entry results.
- [ ] Run `borrowed-calls.sh`, arithmetic/buffers/adapter and ordinary eligibility
  suites. Check emitted symbols and ASan behavior, commit, and send Mac the
  smallest positive and negative call fixtures with the exact build command.

## Task 4: Control flow needed by the measured closure

**Files**

- Create `tests/doom-core/control-flow.sh` and its fixtures; document the exact
  surface in `docs/core/doom-stage2-language.md`.
- Modify the same checked selector/derivation/importer/lowering boundaries as
  Task 3; ordinary and freestanding modes retain their own admission rules.

**Interface:** the new forms obey 0008's control-flow section and retain the
existing status channel. The document lists each syntax with value/statement
position and exact refusal rules before implementation of that syntax.

- [ ] Start with statement-only missing-else branches, early returns and loop
  control. Test both executed paths and nil-producing value-position refusals.
- [ ] Add short-circuit boolean logical operations only after declaring their
  operand/result rules. Test side effects and an unreachable fault, not only
  constant true/false arithmetic. General integer/nullable operands stay refused.

```ruby
def dc_bump(count, n_count)
  count[0] += 1
  true
end
def dc_short(count, n_count, flag)
  if (flag != 0) && dc_bump(count, n_count)
    return 1
  end
  0
end
```

For flag 0 the count is unchanged and result 0; for flag 1 it increments once
and result is 1. With a zero-length count buffer, flag 0 succeeds and flag 1
returns BOUNDS with unchanged result.

- [ ] For index operator assignment, use an index helper that increments a
  counter and verify a single evaluation, the original load/check/compute/store
  order and no store on overflow. Nested-loop break/next must target the nearest
  loop; valued or out-of-loop forms have named refusals.
- [ ] Update the existing closure survey's expected verdicts only when the new
  execution/refusal fixtures establish the change. Keep the old source census
  labeled by revision rather than silently changing its historical denominator.
- [ ] Run `control-flow.sh`, Stage-1 arithmetic/closure and ordinary eligibility
  checks; commit. Any additional semantic domain or error category is a concrete
  decision request, not a way to make a difficult fixture pass.

## Task 5: Resident game storage and the reference route

**Files**

- Create `examples/doom/core/state.tsv`, `access.tsv`, `src/state.rb`,
  `full/session.rb`, `full/resources.rb` and `full/reference.rb`.
- Create `tools/doom/state-schema.rb`, `tests/doom-core/state.sh`,
  `tests/doom-core/fixtures/state/` and `tests/doom-core/compare-state.rb`.

**Interface:** `state-schema.rb --schema FILE --access FILE --output DIR`
generates scalar-slot constants, contract/binding data and a canonical snapshot
layout. Its input grammar is fixed by 0008. The session wrapper allocates the
declared buffers once, exposes their IDs to generated adapters, and releases
each once. Reference execution uses corresponding integer arrays/byte resources.

- [ ] Fill the complete schema from Task 1's state-use inventory. Account for
  every reachable field and source alias. Review widths, negative sentinels,
  count origins and each subsystem's writes before generating native contracts.
- [ ] Test unknown/duplicate/unbound fields, overflowed count products, wrong
  prepared lengths, invalid initial values and disallowed overlap. Verify two
  sessions do not share mutable state.
- [ ] Build the old Full setup and the new prepared state from the same WAD and
  configuration. Compare all defined initialized cells before the first tick.
  Preserve original source digests and source notices; do not relax the old
  `tests/doom/manifest.tsv` to absorb new implementation files.
- [ ] Port slot/link operations using the new borrowed helpers. Use the existing
  independent ordered-list/stack model and the original implementation, not a
  second copy of the pointer assignments, as independent checks.
- [ ] Test insertion/removal/reuse order, original capacity exhaustion, stale
  slots, full-list traversal and invalid links. Failed adapter calls poison all
  mutable participants and leave the result live/unchanged as specified.
- [ ] Run `state.sh`, existing slots/artifacts and adapter suites; commit the
  resident state/reference route independently of the complete game tick.

The canonical snapshot is schema-ordered, fixed-width little-endian data with
field name/type/count metadata. It excludes C padding, addresses and undefined
scratch bytes. The comparator reports the first field/index/tic difference and
rejects missing, duplicate or extra records.

## Task 6: Close the complete game tick

**Files**

- Add computational units under `examples/doom/core/src/` for tick, player,
  movement, sight, enemies, specials, interactions, weapons, random state and
  input/history. Update only the new source/access manifests.
- Create `tests/doom-core/tick.sh`, operation traces and recursion fixtures.
- Extend the session/reference wrappers and canonical comparator.

**Interfaces:** `doom_core_input` converts a 256-byte key buffer plus recording
flag/history to the five-element i32 command buffer defined in 0008.
`doom_core_step` consumes that command buffer and the reviewed flat state
contract, returning status and publishing completed gametic on success.
Private procedures write explicit state and return zero; named boolean helpers
may feed control flow. No hosted method is a runtime callee.

- [ ] Refactor one subsystem at a time and compare original Full, new CRuby,
  new hosted Spinel, direct CORE and adapter CORE after each operation. Include
  a call-site inventory proving every original tick edge was migrated.
- [ ] Replace each recursive component using the frame/state-machine design
  recorded in Task 1. Test one-child/two-child traversal, short-circuit sight,
  revisited sound sectors, maximal validated depth and stack exhaustion.
  An arbitrary instruction budget is not the proof of a valid-input bound.
- [ ] Preserve tag dispatch, random call order, thinker additions/removals,
  state actions and post-tick HUD/status-bar updates. Prepare immutable message
  bytes in Full and pass IDs/offsets instead of constructing Ruby strings in CORE.
- [ ] Test combinations of keys, held-key history and recording quantization
  against the existing controls. Keep demo decode and platform polling in Full.
- [ ] Execute complete DEMO1/2/3 ticks against the original game: 5026, 3836,
  2134 commands respectively. Compare state and random streams with zero new
  allowances. Record full expected and observed counts, not selected matches.
- [ ] Inject omitted/reordered random calls and swapped state fields; require
  the corresponding comparator diagnostic. Remove the adapter at link time and
  require the native route to fail to link. Gate every new CORE object.
- [ ] Run `tick.sh` and affected Stage-1/source/control suites; commit and send
  the exact native tick candidate for Mac review before claiming game closure.

## Task 7: Close CPU rendering and complete-frame composition

**Files**

- Add source units for BSP traversal, clipping, planes, walls, sprites, masked/
  fuzz columns, job scheduling, HUD/status bar and scaling under core/src/.
- Create `tests/doom-core/render.sh` and its synthetic scenes/frame comparator.
- Extend state/resource preparation and the native render entry contract.

**Interface:** `doom_core_render` writes the complete indexed framebuffer and
palette selection from resident state and scratch. Its scalar result is the
completed frame number. Job generation and CPU execution both occur in CORE.

- [ ] Reuse the Stage-1 fixed-point and raster work with its original-source
  provenance. Replace Render's recursive traversal with a stack preserving
  post-child visibility tests. Keep explicit Ruby masks and integer semantics.
- [ ] Compare the original direct CPU and Job IR CPU paths, then the refactored
  CRuby/hosted/native paths. Preserve schedule order and fuzz read-after-write
  dependencies. No GPU fallback or unsupported native path may answer as CORE.
- [ ] Test asymmetric viewwindow coordinates, multiple resource offsets,
  nontrivial span stepping, empty/one-pixel jobs, partial overlap and all resource
  end boundaries. Include last-valid/first-invalid pairs on every buffer face.
- [ ] Move status-bar/HUD updates and pixels, weapon sprites, scaling and
  palette selection into the defined CORE step/render split. Test all supported
  dimensions/modes in configurations.tsv, with checked allocation sizing.
- [ ] Compare every complete-frame byte for all three demos, with the existing
  reference-key alignment. Retain the separate doomgeneric comparison and its
  exact build-scoped allowances; CORE-versus-Full has no allowances.
- [ ] Verify result publication, poisoned session handling and resident buffer
  reuse; gate optimized objects and run functional ASan controls. Run `render.sh`,
  existing framebuffer/artifacts and comparison-control suites; commit.

## Task 8: Full integration, binary transport and failure lifecycle

**Files**

- Create `examples/doom/core/full/driver.rb`,
  `examples/doom/core/native/bridge.c`,
  `tools/doom/build-core.sh`, `tests/doom-core/session.sh` and its fixtures.
- Reuse the existing `examples/doom/native/sp_sdl_shim.c` and native adapter
  registry. Add a checked internal lock/borrow operation if the current API
  cannot distinguish acquisition failure; do not expose native pointers to Ruby.

**Interfaces:** the build tool accepts `--mode hosted|native --output FILE`.
Both modes consume the same packed computational source; native links the
generated CORE objects/Full adapters and hosted compiles the refactored Ruby.
The original `examples/doom/build.sh` remains the frozen-reference build path.
The new driver follows the existing supported game CLI. The Full C bridge
offers synchronous presentation and length-aware snapshot output over registry
IDs; it is never part of a CORE object.

- [ ] Test a lifecycle trace `prepared -> running -> failed -> closed`, plus
  normal close, double close/release rejection and a fresh independent session.
  After any nonzero CORE status, require no additional step/render/present call.
  No poisoned-state inspection or silent fallback to hosted is permitted.
- [ ] Before computation, reject missing/invalid resources and unsupported
  configurations. Handle an unsupported rebirth request at the documented
  pre-step boundary. Never turn a general application error into CAPACITY.
- [ ] Implement checked native presentation over resident frame/palette IDs;
  verify wrong type/count, released/poisoned ID, lock failure and concurrent
  release cannot cause an unchecked dereference. Reuse staging storage if needed.
- [ ] Serialize replay/state output with explicit lengths and endianness. The
  fixture bytes `00 41 00 ff` must round-trip intact; negative controls through
  a truncating writer must fail by length/content, not by a missing file.
- [ ] Compile one common harness in direct/adapter modes and establish actual
  adapter dependence by a link-without-adapter failure naming its symbols.
  Verify packaging refuses an adapter object in a CORE slot and stale manifests.
- [ ] Measure computation, adapter/lock, transfer and total times plus byte and
  allocation counts after setup. Run multiple fixed-input repetitions with
  trace disabled, and separate traced correctness runs. Do not invent a speedup
  gate or claim zero allocation for the entire hosted executable.
- [ ] Run `session.sh`, the new interactive native binary with synthetic
  controls, and existing DOOM checks; commit. Mac real-key acceptance is still
  required in Task 9 and is not inferred from this run.

## Task 9: Native acceptance and handoff

**Files:** create `tests/doom-core/run.sh`, `docs/core/doom-core-usage.md` and
`docs/core/doom-core-validation.md`; update roadmap/building/provenance/README
only to the behavior and measurements actually delivered.

**Interface:** the runner enumerates fork-compat, source-pack, borrowed-calls,
control-flow, state, tick, render and session lanes. Each lane reports checked,
pass, fail and executed/unmeasured counts. `REQUIRE_ALL=1` rejects missing
required execution; documented nonapplicable fork rows are not passes.

- [ ] Run all new lanes and compare the lane manifest with actual runner files.
  Break an oracle executable and remove a lane to prove neither is reported as
  success. Require the intended failure diagnostic in mutation controls.
- [ ] From a clean checkout with its own dependencies, run the documented
  official LLVM build, then execute the exact commands below and record SHAs,
  host, compiler evidence, Ruby version, WAD digest and skip reasons.

```sh
REQUIRE_ALL=1 sh tests/doom-core/run.sh
REQUIRE_ALL=1 sh tests/core-boundary/run.sh
python3 tests/core-eligibility/run.py
sh tests/native-core/driver.sh
sh tests/native-core/ledger.sh
sh tests/native-core/run.sh
sh tests/doom/run.sh
```

On Debian also run `sh tests/core/run.sh`. On Mac additionally run the existing
Mach-O probe with the selected Ruby and the real-key native DOOM interaction.
If the pin changes, add the upstream corpus, arena/GC gates and selected-core
compatibility checks required by that patch's boundary; old results do not
count for a new compiler.

- [ ] Have Mac independently execute the new suites and complete replay on the
  exact candidate revision. Retain positive execution reports for both hosts;
  a Debian result does not close the Mac criterion.
- [ ] Check required notices, source digests, local Markdown links and whitespace.
  Track no WAD, generated compiler output, binary, build log or local-machine
  dependency. Keep only reproducible fixtures and scoped validation summaries.
- [ ] Present a reviewable integration candidate with the supported configuration
  matrix, counts, performance components and remaining restrictions. The branch
  is not merged by this plan; main integration and any unresolved contract/pin
  decision remain explicit actions for the owner.

## Completion boundary

Tasks 1–5 alone are infrastructure, not CORE DOOM. Task 6 alone is a game tick,
not a complete playable CPU renderer. Task 7 without actual native application
routing is not the end-to-end milestone. Mark Stage 2 complete only after all
Task 9 acceptance evidence exists. The old Stage-1 work remains accepted
throughout and its regression suites continue to run independently.
