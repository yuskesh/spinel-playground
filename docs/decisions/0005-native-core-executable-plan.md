# Native Core Executable Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to execute this plan
> task by task. Do not delegate without user authorization. Contract checkpoints
> below must be resolved before their dependent implementation begins.

**Goal:** Compile an ordinary Ruby program with one CLI-selected core method
into a working macOS arm64 executable.

**Architecture:** Keep hosted C generation and runtime packaging. Check the
selected method over the shared frontend contract, lower that checked closure
through MLIR, and connect it through a compiler-owned internal call boundary.

**Tech Stack:** Pinned Spinel, C/C++, Ruby, LLVM/MLIR/Clang 23.1.1, macOS SDK.

**Spec:** [Decision 0005](0005-native-core-executable.md).

## Global constraints

- This is a staged plan, not approval of an unmeasured ABI or vendor patch.
- Preserve the normal hosted and arena paths and existing exported emitter.
- No predecessor dependency, synthetic inference calls, user FFI or new DSL.
- Arithmetic, buffers and runtime failure policies are outside the first slice.
- Keep comments, documentation, commits and diagnostic descriptions in English.
- Use an isolated implementation branch; do not rebuild shared dependencies in
  parallel. Commit each reviewed capability with its checks and provenance.

## Task 1: Establish the macOS generation baseline

**Files:** `tools/mlir/native/lib/Freestanding/{ProfileReader,Emit}.cpp`,
`tools/freestanding/profiles/`, new `tests/native-core/` fixtures and runner,
`docs/building.md`, `docs/provenance.md`.

**Consumes:** Existing declaration-oriented emitter and LLVM 23.1.1.
**Produces:** A measured native object/link path, not the final source interface.

- [ ] Build in a fresh output directory using the LLVM 23.1.1 prefix and SDK.
  Keep the existing LLVM 22 build separate. Run the 32 eligibility checks with
  the newly built checker and matching contract reader.
- [ ] Use an isolated comparison kernel and C harness to test native Mach-O
  emission, exact target/data layout, linkage and execution. A freestanding
  declaration is allowed only in this infrastructure probe.
- [ ] Exercise `lower(7,3)`, equal operands, negative operands and representable
  signed limits. Assert object architecture and actual execution, not existence.
- [ ] Check the object using `llvm-nm` and relocation/disassembly output;
  inject a runtime dependency and require the gate to fail.
- [ ] Correct only measured target/packaging issues and record exact commands,
  tool versions and failures. Do not infer macOS support from Debian evidence.

## Task 2: Resolve binding and the internal call contract

**Files:** Read `vendor/spinel/src/` analysis, code generation and FFI paths;
`lib/sp_types.h`; `tools/contract/spinel_typedump.c`; contract `Model.h`;
update decision 0005 with source locations and measured prototypes.

**Consumes:** The accepted ordinary-source example and pinned compiler.
**Produces:** A concrete reviewed mapping from source method/call identities to
internal parameters, returns and symbols, plus the exact integration seam.

- [ ] Inspect generated C and contract rows for the example, helper calls,
  nullable inputs, floats and inconsistent call sites. Preserve the actual
  source as inference input.
- [ ] Trace the complete admitted value domain, nil representation and return
  path. Test the minimum reserved hosted value separately from valid limits.
- [ ] Determine whether all admitted callers can be proved non-null integers;
  record precisely how insufficient evidence becomes a build refusal.
- [ ] Compare a narrow hosted codegen seam with existing external-call support.
  Choose by binding fidelity and compatibility, not by avoiding vendor edits at
  any cost. Do not grow a Ruby/generated-C regex rewriter.
- [ ] Present the exact prototype and seam for review. If vendor changes or
  runtime type/failure semantics are required, obtain that decision before
  proceeding. No fork branch or pin movement is implicit in this task.

## Task 3: Admit a bounded hosted context safely

**Files:** `tools/mlir/native/lib/Core/Eligibility.cpp`, its public header,
`tests/core-eligibility/run.py`, `tools/core/README.md`.

**Consumes:** Task 2's binding contract and the sealed `ContractModule`.
**Produces:** Eligibility for the accepted hosted example with preserved method
identity and evidence for every selected call, not blanket hosted permission.

- [ ] Add the `puts lower(7,3)` positive fixture; confirm the current checker
  refuses it before changing the source-envelope rules.
- [ ] Keep negative cases for `Integer.prepend`, reopening, setup helper calls,
  reflective dispatch and unknown dependencies. Add mutation through a hosted
  helper before the selected call.
- [ ] Extend the envelope with explicit evidence rules for only the admitted
  output/call forms. Do not ignore arbitrary top-level execution.
- [ ] Run all eligibility tests. Remove the new binding protection temporarily
  in an isolated mutation build and verify its negative control fails.

## Task 4: Lower the checked closure without exported declarations

**Files:** New focused `tools/mlir/native/lib/Core/` emission adapter and header;
`lib/Frontend/Scalar/Importer.cpp` where a narrow shared entry is justified;
associated CMake targets; `tests/native-core/`.

**Consumes:** Task 3's checked contract snapshot and Task 2's internal signature.
**Produces:** Core object, internal declaration and build evidence tied to the
same source, methods, flags, compiler pin and target.

- [ ] First test the ordinary comparison/helper source without any `_def`, RBS
  or inserted inference call; emission is expected to be unavailable initially.
- [ ] Reuse lowering for comparisons, selection and direct calls with matching
  semantics. Do not route through exported declaration defaults that add traps.
- [ ] Require agreement between checked and emitted method closures. Verify
  source changes, missing methods and target mismatches fail before publication.
- [ ] Check undefined dependencies, referenced data and relocations; reject an
  injected allocator, unknown extern and silently omitted helper.
- [ ] Re-run the existing freestanding emitter acceptance relevant to this host
  if shared importer/lowering behavior changes.

## Task 5: Integrate hosted calls and package the executable

**Files:** Task 2's approved hosted seam; a focused product driver under
`tools/core/`; `tests/native-core/`; build documentation and provenance.

**Consumes:** Original hosted source, selected root and Task 4's checked object.
**Produces:** One native executable or a failed build with no newly published
partial executable. The proposed command name must be documented as implemented
only after this task passes.

- [ ] Add end-to-end tests for the decision's ordinary Ruby example, helper
  closure and signed/equality cases, comparing CRuby and ordinary Spinel.
- [ ] Connect selected calls using the approved seam and one generated internal
  signature. Reject nil/type/domain mismatches before lossy conversions.
- [ ] Delete the generated core implementation in a controlled build and
  require failure. Use a separate instrumented core object/link probe to verify
  actual call routing; never count a hosted fallback as successful integration.
- [ ] Add malformed boundary and injected-dependency controls that would
  otherwise link successfully. Check failed builds do not replace a previous
  valid output, and tool failures name the failing stage.
- [ ] Coordinate analysis, lowering, artifact checks and linking with explicit
  subprocess arguments and isolated intermediates. Preserve snapshot identity.
- [ ] If the approved seam changes vendor code, validate on its dedicated fork
  branch, run affected upstream/default/arena checks, and document the patch
  before proposing the Extended pin update.

## Task 6: Reproduce and record the supported capability

**Files:** `tests/native-core/`, `docs/building.md`, `docs/provenance.md`,
`README.md`, `docs/architecture.md`, `docs/roadmap.md`, decision 0005.

- [ ] Reproduce from a fresh checkout with LLVM 23.1.1 and the documented SDK,
  with no predecessor checkout or existing build products available.
- [ ] Record native acceptance, prior checker regression and affected hosted
  checks separately. Keep Debian and macOS results distinct.
- [ ] Update stale arena/tier status in README, architecture and roadmap;
  distinguish process arena from future scoped arena/GC coexistence.
- [ ] Publish exact implemented commands, supported source envelope, refusal
  examples and runtime presence in the combined executable. Do not claim all
  Ruby, arbitrary i64 inputs or a GC-free executable.
- [ ] Review the milestone criteria individually. Commit the tested result;
  merge and push only under the user's integration authorization.

## Execution order and approval boundary

Execute tasks 1 and 2 first. They establish the facts needed for a precise
hosted-boundary implementation; tasks 3–5 depend on the reviewed result. Their
file locations are assigned here, while the call-seam API must come from task 2
rather than be invented before inspecting the producer. This plan does not
resume the stopped full-to-core branch or authorize new failure semantics.
