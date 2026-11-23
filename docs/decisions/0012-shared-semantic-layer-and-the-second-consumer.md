# 0012: The shared semantic layer, and freestanding as its second consumer

- Date: 2026-09-17
- Status: Proposed
- Scope: What `Contract::Model` and the analyses above it are, what a second lane can reuse, and the measurable condition under which a Core IR would be reconsidered. Follows [0011](0011-core-ir-and-ir-framework-evaluation.md).

## Context

0011 concluded that no Core IR and no external IR framework should be adopted now, and that the question should be settled by measuring re-implementation when a second lane arrives. This record does that measurement, because **the second lane is already in the tree** — and the measurement changes the recommendation's emphasis.

### Correction to 0011

0011's pipeline diagram listed `Realtime/MayAllocate` and `Realtime/WholeModule` as part of the live analysis set, and its answer to the effect question said allocation is "modelled by" them. That is wrong. Both headers exist under `include/spinel-mlir/Realtime/`, but **`lib/Realtime` does not exist, nothing includes either header, and `lib/CMakeLists.txt` states that the predecessor's `Tensor`, `Target` and `Realtime` subtrees are "not reached by this slice."** They are dead imported headers. The error came from reading a header listing and treating presence as liveness; a header existing is not an analysis running. 0011 has been corrected in place, as it was never committed or accepted.

A liveness inventory was run over every analysis named in the request. All are live (library built and header included by something) **except** `Realtime/MayAllocate.h` and `Realtime/WholeModule.h`, which are dead on both counts.

## What the layer actually is

### `Contract::Model` is a typed AST snapshot, not a semantic IR

It holds five record types across four "faces", and the model exists only after all four parse and their cross-references validate:

| Record | Carries |
|---|---|
| `Source` | file id, path |
| `Node` | node id (unique per face), node kind, named fields (String / Integer / FloatSpelling / Reference / Array) with `producerOrder` |
| `NodeType` | node id, scope, **inferred type**, line, column, kind, scopeName, detail |
| `Local` | scope, slot, name, type, `isParam`, `isCell`, `nullableInt` |
| `Method` | scope, name, className, returnType, parameters (name+type), `scalarAbi` verdict |

Against the requested checklist: **present** — AST node identity, inferred type per node id, method signature with an ABI verdict, local/slot information, source location (on the types face, not the AST face), file identity. **Absent** — control-flow information, SSA, resolved call targets, allocation information, buffer/borrow information, loop information, and any backend-specific information.

So the snapshot is backend-neutral by construction, and is deliberately faithful rather than semantic: ordering is canonical and the model is immutable. Every consumer that needs control flow or a call graph derives it.

### The real shared layer is `Contract::Model` **plus the admitted closure**

This is the finding that matters most, and it corrects the framing of both the request and 0011. The reused artifact is not the snapshot alone. `Core/Eligibility` (1927 lines, 20 commits) computes an `EligibilityReport` containing the admitted closure and the entry facts, and `Core/LoopBounds` consumes it:

```
Core/LoopBounds.h:28      #include "spinel-mlir/Core/Eligibility.h"
Core/LoopBounds.h:92      ... const EligibilityReport &admitted ...
Core/LoopBounds.cpp:1312  closure.insert(admitted.methods.begin(), admitted.methods.end());
```

`Eligibility.h` states the discipline explicitly: a consumer takes "the answer the checker admitted, not from a second derivation". So **sharing between independent consumers is already demonstrated, not hypothetical** — one analysis computes the closure, a second consumes it rather than re-expanding it, and a third (`Core/Report`) composes both.

Measured dependency edges among the live analyses:

```
Contract/Reader -> Core/Input -> ContractModule
    Core/BorrowFacts      (facts carrier: BorrowFacts.cpp is 20 lines)
        -> Core/Eligibility  (admits the closure; resolves calls; walks once)
             |-> Core/Kernel, Core/Emit -> Scalar/Importer, Scalar/HostEmit
             |                               -> MLIR -> Conversion/SpinelToLLVM -> LLVM
             `-> Core/LoopBounds  (consumes EligibilityReport)
                   -> Core/Report  (composes Kernel + LoopBounds)
    Core/Boundary (746 lines) + Core/Input   (decision 0007 buffer modes, overlap refusal)
```

No duplicated closure expansion was found. `Eligibility` and `LoopBounds` each walk the closure once, for different purposes — admission and loop classification — which is two passes over one shared closure, not one fact computed twice.

## The measurement: freestanding is already the second consumer

`lib/Freestanding` is **one commit, dated 2026-09-09**, an import recorded in `docs/provenance.md`. `lib/Core` is **33 commits from 2026-09-10 to 2026-09-16** — built here, after it. So the freestanding lane predates the analyses it might have reused, and what it does instead is evidence about the port, not about whether reuse is possible.

**What it reuses.** `Freestanding/Emit.cpp` includes `Contract/Reader.h`, `Scalar/Importer.h`, `Scalar/HostEmit.h` and `Conversion/SpinelToLLVM/Passes.h`. The entire lowering spine — snapshot reading, MLIR construction, LLVM conversion — is shared verbatim with the native lane. That is the expensive half, and it is already common.

**What it does not reuse, and this is the duplication.** Nothing under `lib/Freestanding` includes any `Core/*` analysis. Allocation legality is decided independently, and in fact "does this allocate?" is currently answered in **four places by three strategies**:

| # | Mechanism | Kind | Size | When |
|---|---|---|---|---|
| 1 | `Core/Eligibility` | source analysis over the snapshot (decision 0004) | 1927 lines | core lane admission |
| 2 | `Frontend/Scalar/FreestandingSubset` | **name tables** — reject syntax by node kind and call name | 209 lines + 116 generated (36 alloc nodes, 46 alloc calls) | `--freestanding` only |
| 3 | `Freestanding/UndefGate` | **symbol vocabulary** over the emitted object | uses `tools/realtime/alloc_vocabulary.tsv`, 173 rows | freestanding object gate (Stage G) |
| 4 | `tools/core/core-artifact-gate` | `nm` predicates A/B/C on the object | shell | core lane artifact gate |

Mechanisms 1 and 4 are the core lane's source/object pair and are intended as a pair. Mechanisms 2 and 3 are the freestanding lane's, and they duplicate 1 rather than extend it.

**The cause is not the absence of an IR.** `UndefGate.h` documents the duplication as a deliberate exception, and names its reason:

> the same set ends up written in two places — an intentional exception to the "close it in one place" discipline. It cannot be shared because one side is a Python module variable and the other a C++ static table.

The mitigation it describes is to pin the sha256 of the frozen Python `undef-check.py` and `spinel_alloc_free.py` in `cp4/identity.tsv`, so that the gate goes red if the Python side moves rather than pretending to track it. **That mitigation is not in this repository** (corrected 2026-09-17, first draft of this record said it was): no `identity.tsv` exists in the tree, and neither does any of `undef-check.py`, `spinel_alloc_free.py` or `spinel-mlirgen.py`. The comment instructs a maintainer to revisit a pin that lives in the predecessor. What guards these components *here* is a `static_assert` cardinality lock over the symbol sets in `UndefGate.cpp`, and refusal fixtures.

`SubsetTables.cpp` is likewise **generated** — its header says `mk_fs_tables.rb` copies the tables out of the frozen Python verbatim and that it must not be hand-edited. Neither that script nor `docs/experiments` nor the Python is in this repository either, so **the instruction the file gives cannot be followed here.**

So the duplication in this tree is a **frozen-Python port boundary**, not a missing intermediate representation. A Core IR would not remove it. But the boundary is not a transitional state that resolves itself, because the far side of it is absent: there is no reference to consult and no regeneration path. Ownership has to be taken deliberately, which makes it a decision rather than a cleanup — see [0013](0013-semantic-layer-followup-and-core-ir-triggers.md), which sets out the conditions.

## Answers

**1. Is `Contract::Model` sufficient as a backend-neutral semantic layer?** Sufficient as a *snapshot*, and it is genuinely neutral — it contains no backend information. Insufficient on its own as the shared layer, because it has no CFG, no SSA and no resolved call targets. In practice the shared layer is the snapshot **plus** `EligibilityReport`, and that pair has already served two independent consumers.

**2. What is missing?** (a) A named, documented boundary: the pair is load-bearing but is not described anywhere as *the* semantic layer. (b) Resolved call targets — both `Eligibility` and `LoopBounds` resolve calls from AST names (5 and 12 sites); a resolved call graph on the shared layer would remove the second implementation. (c) One owner for allocation legality. (d) Nothing else. Notably *not* missing: types, locals, source locations, method ABI verdicts, loop bounds, buffer modes, overlap refusal, target policy.

**3. Reuse fraction for a freestanding lane.** Measured, not estimated, and split because one number would mislead:

- **Lowering spine: ~100% reused already.** `Contract/Reader`, `Scalar/Importer`, `Scalar/HostEmit`, `Conversion/SpinelToLLVM` are shared verbatim today.
- **Target policy: ~100% present, 0% shared with core.** `FreestandingProfile` + 8-stage/10-category diagnostics exist and are freestanding-only by nature; nothing in the core lane wants them.
- **Semantic legality: ~0% reused, and this is the whole gap.** Allocation legality is re-decided by mechanisms 2 and 3 instead of reusing `Eligibility`. Loop and work bounds, borrow facts and boundary overlap are **not consumed by the freestanding lane at all** — they were not available when it was imported.

So the honest headline is: the expensive part is already shared, and the duplicated part is one semantic question decided three ways for a documented historical reason.

**4. New analyses freestanding genuinely needs.** Most of what the request lists already exists in imported form; the profile carries it as data rather than as analysis.

| Item | Verdict |
|---|---|
| dynamic allocation prohibition | **extend** — unify onto `Eligibility` (mechanisms 2 and 3 are the duplication) |
| undefined symbol / unsupported runtime dependency | **exists** — `UndefGate` Stage G, against `profile.allowedSymbols` |
| libc / libm / compiler-rt dependency | **exists** — `FreestandingProfile` fields, as policy data |
| external call legality and ABI | **exists** — `FsExtern` (symbol, returns, typed params, buffer direction, length pairing) |
| static/global storage, TLS, exceptions, indirect calls, function pointers | **backend-specific, mostly already refused** by the subset check reaching them by node kind; audit rather than build |
| recursion prohibition | **extend** — `Eligibility`'s closure already refuses call cycles (0010's termination argument depends on an acyclic graph); state it as a freestanding refusal |
| **stack upper bound** | **new** — nothing computes it. This is the one genuinely missing analysis, and `LoopBounds` is the natural place: a frame-size × call-depth composition over the same acyclic expansion it already performs |
| floating-point runtime helpers | **new, small** — a profile question (`compilerRt`) crossed with which helpers the emitted module references |

**5. Concrete Core IR trigger.** Not a percentage of duplicated lines — that number would be dominated by the historical port. Propose instead three conditions, any one of which reopens 0011:

- A semantic fact that a second lane needs and that **cannot be expressed as a derivation over `Contract::Model` + `EligibilityReport`** — i.e. the fact requires control flow or SSA that the snapshot cannot supply and a pass cannot cheaply rebuild. Count these; **two or more** is the trigger.
- `Scalar/Importer` + `MlirGen` requiring a **second, divergent copy** rather than a parameter — see item 12.
- A third consumer arriving while allocation legality still has more than one owner, i.e. the port cleanup below did not happen.

**6. `spinel` dialect growth rule.** Add a `spinel.*` operation only when a standard MLIR dialect cannot express a semantics **that something refuses on** — the existing three checked-arithmetic operations are exactly that, since the overflow policy changes which programs are admitted. Everything else that is a *fact about* code rather than a *change to* its meaning belongs in an attribute or a side table, not an operation. On the request's candidate list: checked-arithmetic policy is already an operation and should stay one; proof/bound provenance, allocation legality, boundary mode, borrow semantics, target contract and realtime constraint are all facts, so attribute or side table.

**7. Widening the GC-free subset.** The chain today is source admission (`Eligibility`) plus an object gate (`core-artifact-gate` A/B/C, or `UndefGate` Stage G for freestanding). GC-free is proven at the object, which is why it holds regardless of what optimization did to an allocation. Two clarifications the request asks for: **GC-free is not the same as freestanding-safe** — the profile's `libc`/`libm`/`compilerRt` and `allowedSymbols` fields exist precisely because a GC-free object can still depend on a runtime the target lacks. And a GC-free-but-heap-using state is expressible in principle (an external `malloc` declared with a contract), which is why `architecture.md` warns that GC inactivity is weaker than GC independence.

**8. Escape analysis.** **None exists** — the only `escape` occurrences in the tree are string escaping in the contract parser. It would widen the accepted subset, but it is not the highest-value next step, because the subset is currently limited by the *port* and by `Eligibility`'s admitted grammar rather than by an inability to prove non-escape. Cost-effectiveness order, if pursued later: (i) scalar replacement of fixed-size local aggregates — smallest, and covers the `a = [1,2,3]; a[0]` case the request names; (ii) escape analysis proper; (iii) region inference; (iv) ownership inference. Do not start at (iv).

**9. `BorrowFacts` versus ownership inference.** `BorrowFacts.cpp` is **20 lines** — it is a facts carrier, not an analysis. The capability lives in `Core/Eligibility` (which includes it) and `Core/Boundary` (746 lines), which implement decision 0007: `in`/`inout` modes, a named per-buffer element count, and refusal of any aliasing that involves a written buffer. That is overlap detection and a mutable/immutable distinction, enforced by refusal rather than by inference. Not present: lifetime, nested borrow, interprocedural borrow propagation, pointer alias. For the accepted subset, **no new ownership mechanism is needed** — refusing aliasing is strictly simpler than inferring it, and nothing yet asks to admit a program that refusal rejects.

**10. Generalising `MayAllocate` into an effect system.** Not available: `MayAllocate` is dead code. The live allocation facts are `Eligibility`'s admission and the two object gates. So the question becomes whether to *build* an effect lattice, and the answer is no — build the one effect a lane refuses on, which is allocation, and give it one owner. `MayBlock`/`MayIO`/`MaySyscall`/`ReadsMemory`/`WritesMemory`/`MayThrow`/`MaySuspend`/`MayLaunchGPU` have no consumer in this tree.

**11. Are `LoopBounds` shareable across lanes?** Yes, and by explicit design. Decision 0010 step 1 is "derive and REPORT. Nothing here refuses anything, and nothing here reaches code generation", and bounds are "expressions over mathematical integers, not over i64". That is exactly the separation the request asks for: **bound proof is target-neutral, and target admissibility is a separate consumer of the report.** A native lane can ignore a bound, a freestanding lane can compare it against a resource limit, and a future verifier-constrained lane can require one — all from the same `iterations` expression and `reason` code, with no change to the derivation.

**12. Is `Scalar/Importer` a future duplication source?** Yes, and it is the most likely trigger. `MlirGen.cpp` is **3365 lines**, the largest file in the set, and `Importer.cpp` references the snapshot's type face only **4 times in 757 lines** — the lowering is largely structural re-walking of the AST rather than consumption of analysis results. More tellingly, `FreestandingSubset` already puts **backend-specific legality inside the frontend**: a `--freestanding`-only, name-table allocation check sitting in `lib/Frontend/Scalar`. That is a backend concern in a shared component, and it is the shape that produces a copy when a third lane arrives. **Recommended cleanup: move the freestanding subset decision out of the importer and onto the shared closure**, leaving the importer to lower what has already been admitted.

**13. Architecture without a universal IR.** It already exists in the freestanding lane, and naming its four layers is most of the work:

```
Ruby -> vendor compiler (Prism + type inference)
  -> [boundary: tools/contract/spinel_contract.h]
SHARED FACTS      Contract::Model (typed snapshot) + EligibilityReport (admitted closure, entry facts)
                  + derived reports: LoopBounds, BorrowFacts, Boundary
TARGET POLICY     FreestandingProfile (triple, dataLayout, intWidth, overflow, trapHook,
                  libc/libm/compilerRt, allowedSymbols, typed externs) + Stage/Category refusals
LOWERING          Scalar::Importer -> MLIR (standard dialects + spinel) -> SpinelToLLVM -> LLVM
RUNTIME ABI       FsExtern / boundary status ABI / core artifact gate
```

This scales by adding a policy table and a legality stage per target while the facts and the lowering stay shared. It stops scaling when a target needs a *fact* the snapshot cannot express — which is trigger 5, and is the honest limit to state rather than a backend count.

**14. Do the facts need to reach MLIR?** Only where an assumption must survive optimization. Loop-bound provenance and borrow facts are consumed before lowering and need no representation in the IR. The one candidate is the **non-overlap** fact, because it is an aliasing premise that later passes could exploit or invalidate; if it is ever relied on for optimization rather than only for refusal, it belongs on the operation as an attribute. Until then a side table is correct, and 0010's report-only stance is the precedent.

**15. The next minimal change.** Not an IR, not a dialect operation, not a new analysis:

1. Document the shared layer — `Contract::Model` + `EligibilityReport` — as the named boundary, with the rule `Eligibility.h` already states: consume the admitted answer, never re-derive it.
2. At stage 3, give allocation legality **one owner**: retire `FreestandingSubset`'s name tables in favour of `Eligibility`, keeping `UndefGate` as the object-level gate. The frozen Python is already not a reference this repository can consult, so what has to be established first is an in-tree equivalence gate; 0013 item 3 proposes one.
3. Add the **stack upper bound** to `LoopBounds`, reusing the acyclic expansion it already performs. It is the one genuinely missing analysis and freestanding needs it.
4. Move the freestanding subset decision out of `Scalar/Importer`.

**Pliron re-evaluation triggers, in implementable terms** (refining 0011): two or more semantic facts that cannot be derived over the shared pair; or a divergent second copy of `MlirGen`; or a Rust-hosted target entering scope; or Pliron publishing an API-stability guarantee with a complete LLVM dialect. Analysis-duplication percentage is explicitly **not** a trigger, because the duplication that exists is a port artifact and would produce a false positive.

**From cuda-oxide, still worth borrowing.** Directly applicable: the launch contract, whose analogue is already here — `FreestandingProfile` + `FsExtern` is a target contract verified before emission, and the closest gap is that the core lane's contract is regenerated per build while freestanding's is declared in YAML. The proof-token idea maps onto `EligibilityReport` and should stay a value a consumer must be handed rather than a fact it can recompute. Keeping target semantics out of LLVM primitives until lowering is already the `spinel` dialect's rationale. Not applicable: MIR interception (no equivalent stage), ownership-aware device APIs (they rest on Rust's borrow checker, which is the mechanism Spinel deliberately replaces with refusal), and Rust trait-based device abstractions.

## Validation

Read from `origin/main` at `665f514` on 2026-09-17:

```sh
# liveness: lib/Realtime absent, nothing includes MayAllocate/WholeModule
git ls-tree --name-only origin/main tools/mlir/native/lib/
git grep -l 'Realtime/MayAllocate.h\|Realtime/WholeModule.h' origin/main -- tools    # empty
git show origin/main:tools/mlir/native/lib/CMakeLists.txt

# the shared pair, and that LoopBounds consumes rather than rebuilds
git show origin/main:tools/mlir/native/include/spinel-mlir/Core/LoopBounds.h   # :28, :92
git show origin/main:tools/mlir/native/lib/Core/LoopBounds.cpp | sed -n '1312p'

# chronology: freestanding is one imported commit, Core is later work
git log --format=%ad --date=short origin/main -- tools/mlir/native/lib/Freestanding   # 1, 2026-09-09
git log --oneline origin/main -- tools/mlir/native/lib/Core | wc -l                   # 33

# the four allocation-legality mechanisms
git show origin/main:tools/mlir/native/lib/Frontend/Scalar/FreestandingSubset.h
git show origin/main:tools/mlir/native/include/spinel-mlir/Freestanding/UndefGate.h
git show origin/main:tools/realtime/alloc_vocabulary.tsv | grep -vc '^#'              # 173
git show origin/main:tools/core/core-artifact-gate

# no escape analysis
git grep -ci escape origin/main -- tools/mlir/native/lib/Core                         # 1, string escaping
```

**Limits.** This record answers the request's twenty-one sections from headers, sizes, include edges, commit history and the projects' own comments. It does **not** rest on building or running either lane, so the reuse figures in item 3 are structural (what is included and by what) rather than behavioural. Line counts and include counts are proxies for effort, not measurements of it; the stage-3 measurement table in the request remains the way to get real numbers, and this record's value is that it identifies *what to measure* — the allocation-legality owner and the importer copy — rather than waiting to discover them. Not examined: `MlirGen.cpp`'s 3365 lines in detail, `Core/Boundary`'s overlap algorithm, the `GradPipeline`/`GradShim` differentiation path, and whether `Eligibility`'s admitted grammar could accept more without new analysis.

## Consequences

- No contract, ABI or build change proposed. Items 1 and 4 of the minimal change are documentation and a code move; items 2 and 3 are stage-3 work.
- 0011's conclusion stands and is strengthened: the duplication that motivated a Core IR is present in this tree, is measurable, and is caused by a port boundary that an IR would not remove.
- The correction above supersedes 0011's claim about `Realtime/MayAllocate`; 0011 was amended in place because it is Proposed and uncommitted.
- Item 2 touches decision 0004's checker. `UndefGate.cpp` names a `cp4/identity.tsv` pin as its protection, but that file is not in this repository, so there is no red-gate property here to drop — the protection to preserve and strengthen is the in-tree one: the `static_assert` cardinality lock and the refusal fixtures.
