# DOOM CORE Preparation Implementation Plan

> For agentic workers: use the executing-plans workflow task by task. Debian owns
> implementation; Mac owns review and independent native validation. Do not spawn
> additional workers without authorization. Checkboxes record actual completion.

**Goal:** Deliver the three allocation-free numeric/buffer capabilities specified
in decision 0007, callable through a generated Full adapter.

**Architecture:** Extend the native contract/importer route with an explicit
checked-entry contract and status propagation. Generate the C header and Full FFI
adapter from that contract. Keep adapter allocation/synchronization outside the
CORE object and keep the existing ordinary scalar route unchanged.

**Tech stack:** Pinned Spinel, native C++/MLIR, LLVM/Clang 23.1.1, generated C and
Ruby, shell test runners and CRuby reference fixtures.

**Spec:** [Accepted decision 0007](0007-doom-core-preparation.md). Read it in full;
this plan does not replace its numeric, memory or failure rules.

## Global constraints

- Start an isolated Debian implementation branch `feat/doom-core-preparation`
  from the main commit containing this plan. Record the exact base and pin.
- Pin: `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`; vendor stays read-only.
- Native targets: Debian x86_64 and macOS arm64; Clang/LLVM 23.1.1.
- No predecessor checkout, home path or unrecorded scratch artifact in build/tests.
- No automatic fallback to Full execution, trap or unchecked memory access.
- Commit and push coherent implementation checkpoints on the implementation
  branch for review. Main integration is separate; do not move main or the pin.
- Report actual task, execution ID, state, command/result and revision. Continue
  authorized work without waiting for acknowledgment; a real contract change
  requires a concrete proposal, not an unrecorded implementation choice.
- Read `docs/building.md` for existing builds. Do not rebuild shared dependencies
  concurrently. Run relevant tests after each change, not the whole upstream
  suite for every edit. Never claim predecessor results as fresh executions.

## File ownership and test interface

New contract model/parser/header generation belongs under
`tools/mlir/native/{include/spinel-mlir,lib}/Core/` as `Boundary.h` and
`Boundary.cpp`. Keep eligibility in `Core/Eligibility.cpp`, object emission in
`Core/Emit.cpp`, and input validation in `Core/Input.cpp`. Adapt scalar lowering
in `lib/Frontend/Scalar/{Importer,MlirGen}.cpp` only where semantics match; factor
the new failure path rather than duplicating a universal frontend.

Place generated-adapter construction in `Core/Adapter.cpp` with its interface in
`Core/Adapter.h`; it generates Full C/Ruby output, not CORE runtime helpers.
Wire new sources through the applicable native `CMakeLists.txt` files. Extend
`tools/core/spinel-core-build` with an explicit contract-file mode; retain the
legacy scalar mode and its tests.

**Deviation recorded (2026-09-12).** The contract-file mode was delivered as a
separate tool, `spinel-core-kernel`, rather than as a mode of
`tools/core/spinel-core-build`. What the bullet above protects is met: the
legacy scalar mode of `spinel-core-build` and its tests are unchanged, and the
new route is reached by its own command rather than by a flag that changes what
an existing one means. The two also take different inputs — the legacy driver
takes a source file and a method name and links a hosted executable, while the
contract route takes a validated contract file and emits an object and a header
— so they share a name and nothing else. Usage for the delivered route is in
[the CORE buffer boundary](../core/buffer-boundary.md).

Create `tests/core-boundary/` with `schema.sh`, `arithmetic.sh`, `buffers.sh`,
`adapter.sh`, `capabilities.sh`, `run.sh`, and required `fixtures/`. Runners take
explicit tool/build-directory overrides, reject missing prerequisites and empty
case discovery, preserve exit statuses and name the failing invariant. Each task
adds its runner when it has observable behavior, not a file-existence placeholder.
Public usage belongs in `docs/core/buffer-boundary.md`, added with working examples.

## Task 1: Contract-to-header boundary

**Accepted.** Mac review of `02ca6c5` after four source-review defects were
fixed (AST-based entry resolution, unbound `u64`, the owned snapshot, reserved
names); `26d20c5` replaced the read-compare snapshot with an owned copy.
`tests/core-boundary/schema.sh` 73/73.


- [x] Define and document the version-1 contract-file encoding in the new boundary
  module. Bind parameter names, explicit per-buffer counts, modes, scalar domains,
  result type and root identity exactly as specified. Encoding is a routine
  implementation choice; it may not broaden the accepted contract.
- [x] Add schema refusal fixtures first: unknown/version/duplicate fields, missing
  or duplicate parameters, unsupported modes, unresolved roots and invalid types.
- [x] Produce a canonical boundary model and C header from the same validated
  source snapshot. Include target layout and content identity in generated metadata.
- [x] Compile an independent C consumer of the header. Test width/signature and
  header/contract mismatch refusals. Run `tests/core-boundary/schema.sh`.
- [x] Commit the parser/header capability and publish exact artifact examples for
  Mac review. Do not describe an emitted header as an executable CORE boundary.

## Task 2: Checked scalar execution

**Accepted** at `5a16f7f`, in the scope of the bullets below and no wider.
Measured on macOS arm64 with clang 23.1.1 and CRuby 3.4.1, in a detached
worktree with no tracked changes: `arithmetic.sh` 166/166 with 64/64 cases
executed (96 oracle checks), `schema.sh` 73/73, core-eligibility 50,
`native-core` 9 native fixtures with their export, stub-routing, missing-body
and sentinel-refusal checks. INT64_MIN through both the named-constant and the
direct-literal kernels, called from an independent C consumer, returning status
0 and the value.

**What that evidence is not.** It was an incremental native build reusing the
existing contract reader and the pinned hosted binary, not a clean dependency
build. `docs/core/buffer-boundary.md` records the paths that are covered
statically only. The figures above are the acceptance snapshot at `5a16f7f` and
are not the current counts: the lane grew afterwards, and the final stage-1
numbers recorded in [provenance](../provenance.md) are `arithmetic.sh` 171 with
66 of 66 executed.

Consumes Task 1's validated model. Produces a callable CORE object using the
specified status/result-pointer ABI with no sentinel or trap dependency.

- [x] Add arithmetic reference/refusal tests before enabling the new operations:
  floor division, remainder, abs, shifts, bitwise operators, narrowing, INT64_MIN
  edges and untaken failure branches. Include `% -1` versus `/ -1` at INT64_MIN.
- [x] Implement the new status path independently of hosted raise and freestanding
  trap paths. Propagate failure through direct callees and `core_fail(:capacity)`.
- [x] Admit parentheses, loops and literal scalar constants in the new mode.
  Test definitions as well as reads; reject rebinding, dynamic initialization,
  conflicting intrinsic definitions and unsupported calls/cycles.
- [x] Compare successful values with CRuby and use a direct C harness for full i64
  inputs. Ensure legacy scalar mode still refuses its previously unsupported forms.
- [x] Run `tests/core-boundary/arithmetic.sh` and the affected native CORE tests;
  inspect the optimized object's symbols/relocations. Commit with scoped results.

## Task 3: Checked native buffers

**Accepted** for the bullets below, at `d4e7b42` plus the three store-edge
cases Mac's independent harness measured and this table now carries.
`tests/core-boundary/buffers.sh` on macOS arm64, detached worktree, no tracked
changes: 88/88 with 38/38 cases executed, ASan's kernel control firing and 38
cases clean under it, 18 objects with no undefined symbols and one export each.

**Two limits recorded rather than implied.** UndefinedBehaviorSanitizer covers
the runtime and the harness and **not the kernel**: its checks are emitted by
the frontend while compiling C, and no function attribute adds them to
pre-existing IR, so the suite prints NOT SHOWN with that reason. And the
macOS evidence is an incremental native build reusing the existing contract
reader and the pinned hosted binary, not a clean dependency build. The figures
above are the acceptance snapshot at `d4e7b42` and are not the current counts:
the final stage-1 numbers recorded in [provenance](../provenance.md) are
`buffers.sh` 115 with 53 of 53 executed.

Consumes the boundary model and status lowering. Produces direct-C-callable
buffer kernels; it does not yet establish Full storage safety.

- [x] Add descriptor and access controls: NULL/count zero, nonzero NULL, alignment,
  size/address overflow, negative/out-of-range indices, readonly writes, mutable
  overlap, result overlap and narrowing before stores.
- [x] Implement per-buffer u64 counts without legacy i32 truncation. Preserve
  pointer validity obligations and distinguish entry checks from executed accesses.
- [x] Test unsigned/signed extension, exact failure categories, untouched outputs
  on entry failure and deliberate partial writes on later failure.
- [x] Add clear/copy loop fixtures at the production optimization level. Suppress
  unwanted libc-call synthesis and keep the final CORE object's undefined set empty.
- [x] Run `tests/core-boundary/buffers.sh`, including C canaries and available
  sanitizer runs. Record any unavailable sanitizer separately. Commit the capability.

## Task 4: Full adapter and packaged invocation

**Accepted** at `8a350a9`. `tests/core-boundary/adapter.sh` on macOS arm64,
detached worktree, no tracked changes: 62 checked, 62 pass, 45 of 45 cases
executed, 0 unmeasured. Every lane — the registry and its operations, the
generated Ruby module through the pinned compiler, the eight-thread
concurrency harness with ThreadSanitizer, and packaging identity with its four
refusals — passed.

**No vendor change was needed.** The adapter is reached from pinned Spinel
through `ffi_func`, and the pin's one relevant limitation (an `:int64` return
cannot carry INT64_MIN) is why `load` answers with an encoded value or a
negative status and why i64 travels as two words.

**Limits recorded rather than implied.** The macOS evidence is an incremental
native build reusing the existing contract reader and the pinned hosted binary,
not a clean dependency build; and the packaging manifest is an integrity check
between artefacts of one build, not a signature.

Consumes Tasks 1–3's header/object/model. Produces explicit generated Full FFI
operations and a package whose producer and consumer identities are checked.

- [x] Implement typed storage registry, non-reused positive IDs, mutex ownership,
  zero-count allocations and checked copy operations. Specify concrete generated
  FFI signatures and wrapper return shapes in the usage document.
- [x] Implement encoded small-integer loads, i64 word transport, caller-provided
  word/result destinations, invalidation and release according to 0007.
- [x] Bring the scratch FFI findings into self-contained fixtures with provenance;
  do not copy the incorrect earlier status fixture. Adapter index failure is
  ARGUMENT, while executed kernel bounds failure is BOUNDS.
- [x] Test stale/invalid IDs, wrong types, ID exhaustion using a controlled test
  limit, double release, both output indices equal, result ID aliasing (including
  zero-length participants), allocation failure and poisoned-state rejection.
- [x] Test invocation/release serialization with a C concurrency harness and verify
  multi-call word reads retain the documented caller obligation. Do not claim that
  an individually locked load makes two Ruby reads atomic.
- [x] Build and invoke from pinned Full without changing vendor. Keep allocation
  and pthread dependencies in the adapter; gate the CORE object independently.
- [x] Alter contract/header/object identities and require packaging refusal.
  Run `tests/core-boundary/adapter.sh`; commit working generated examples and docs.

## Task 5: Three DOOM preparation capabilities

Consumes the complete boundary/adapter. Produces the stage-1 acceptance evidence.

- [x] Extract complete fixed-point helpers, recording original revision/path and
  each adaptation. Compare with original Full/CRuby helpers, including saturation.
- [x] Add wall-column, span and fuzz-style framebuffer operations with deterministic
  resource fixtures. Compare every output byte, preserve schedule order and test
  neighbor access. No new C-reference allowance may hide a Full/CORE discrepancy.
- [x] Add fixed-capacity slot/link state with insertion, removal, reuse and
  exhaustion. Compare with an independent reference model and test invalid indices.
- [x] Run each capability through the Full adapter and direct C harness; check the
  resulting CORE artifacts. Run `tests/core-boundary/capabilities.sh`.
- [x] Record remaining whole-DOOM closure gaps. These are stage-2 design input,
  not permission to call the existing object-oriented game CORE-ready.

## Task 6: Native acceptance and handoff

- [x] Make `tests/core-boundary/run.sh` run every lane with explicit counts and
  statuses. Nine were delivered: `schema`, `arithmetic`, `buffers`, `adapter`,
  `capabilities`, `framebuffer`, `slots`, `artifacts` and `closure`. Reproduce
  the documented build from a clean checkout.
- [x] On Debian run the new suite and affected existing checks: core eligibility,
  native CORE run/driver/ledger and hosted DOOM tests. Use the current documented
  commands, record actual revisions and do not aggregate old and new results.
- [x] Send Mac the exact commit and commands. Mac independently builds/tests the
  new suite and relevant legacy checks; distinguish reused dependencies from a
  clean dependency build. Debian results do not close the Mac criterion.
  Sent at `e75ce75`, and re-measured at `20e6b79` from a clean checkout built
  with the documented `CC="$LLVM_PREFIX/bin/clang"`, which the earlier worktree
  run had not used. macOS passed all nine new lanes under `REQUIRE_ALL=1`, plus
  `tests/doom/run.sh`, core eligibility 50, the product driver 43/0, the input
  ledger 23/0 and the Mach-O probe. At that revision, two suites did not pass
  there: `tests/native-core/run.sh` still assumed ELF, while
  `tests/core/run.sh` had no arm64 freestanding profile to run against.
  Subsequent review hardening added Darwin support to `native-core/run.sh`,
  which now passes 18/0 on macOS. The freestanding profile remains absent. The
  driver and ledger failures seen earlier were `LLVM_PREFIX`/`NM` and `CLANG`
  not being exported, not a platform disagreement. `docs/provenance.md` carries
  the commands, the numbers and the compiler evidence;
  `docs/native-core/macos-validation.md` stays historical because its numbers
  are tied to the 2026-09-11 run.
- [x] Check provenance/notices, local links, whitespace and absence of tracked
  generated binaries/WADs. Report copying/locking cost separately if measured;
  performance numbers are not required to claim correctness.
- [x] Present the validated stage-1 capability for integration. Acceptance of this
  design is not evidence that these tasks have completed, nor approval to migrate
  the whole game or move the dependency pin without further scope review.
  `docs/core/stage1-capability.md` states what was built and measured, and at
  the same length what it does not establish: the absent freestanding leg on
  macOS, the unmeasured performance and copying
  cost, how far the rest of DOOM is, the one adaptation that is not a spelling
  change, and the poison asymmetry.

## Open after stage 1

Every bullet above is done. The one question that was open here — three macOS
legacy checks disagreeing with this repository's own record of them — has been
answered, and is recorded below so that a reader does not go looking for it.

**Closed: the three macOS legacy checks.** `tests/native-core/driver.sh` and
`ledger.sh` failed because required environment variables were not exported.
`tools/core/core-artifact-gate` requires `NM` or `LLVM_PREFIX` on Darwin and
refuses to start without them; at that revision, `tests/native-core/ledger.sh`
fell back to a Debian clang path that does not exist on macOS. On one clean checkout
of `20e6b79`, built with the documented `CC="$LLVM_PREFIX/bin/clang"`, the two
answer 39/4 and 22/1 with the variables unset and 43/0 and 23/0 with them set —
same commit, same build, same machine. The third suite,
`tests/native-core/run.sh`, then assumed Linux libraries and ELF symbol names;
the historical macOS result belonged to `tests/native-core/macos-probe.py`,
which passes. Review hardening removed those assumptions, and `run.sh` now
passes 18/0 on macOS. The ledger also now explicitly refuses a missing compiler
selection instead of falling back to a Debian path. Separately, the 2026-09-12
worktree run that produced the disagreement
had built `vendor/spinel` with Apple clang rather than the LLVM 23.1.1 clang
`docs/building.md` requires; that did not cause the failures, but it is why the
evidence was re-measured rather than merely re-explained. `docs/provenance.md`
carries the commands, the numbers and the byte-exact compiler evidence.

**Stage-2 input: there is no arm64 freestanding profile.**
`tests/core/run.sh` hard-codes `tools/freestanding/profiles/x86_64-linux-host.yaml`
and `tools/freestanding/profiles/` holds only that and a Cortex-M33 profile, so
the declared freestanding leg cannot be exercised on macOS at all. That predates
this work and remains stage-2 design input rather than an open question.
