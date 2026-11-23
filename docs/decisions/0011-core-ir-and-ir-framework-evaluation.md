# 0011: Core IR and IR-framework evaluation (cuda-oxide / Pliron)

- Date: 2026-09-17
- Status: Proposed
- Scope: Whether to introduce a backend-neutral Spinel Core IR, and whether to adopt an external IR framework (Pliron) to carry it. Governs the boundary that `docs/architecture.md` currently states as "without sharing one universal intermediate representation or runtime ABI".

## Context

A proposal asked whether Spinel should gain a backend-neutral Core IR before backend divergence, whether Pliron should be its substrate, and how that relates to the existing MLIR, LLVM, eBPF and WASM routes. It is motivated by a diagram in which six lowering lanes each re-interpret Ruby semantics, types, control flow, effects, allocation, lifetime, loop bounds and backend legality.

Two premises were checked before evaluating the proposal. One holds and one does not.

**The cuda-oxide premise holds.** `cuda-oxide` is NVlabs' Rust-to-CUDA compiler, v0.1.0 released 2026-05-07, and its pipeline is `Rust -> rustc MIR -> Pliron IR -> LLVM IR -> PTX`: it intercepts at MIR, routes device code through Pliron, and emits PTX through a `rustc-codegen-cuda` backend. The project describes itself as alpha and expects API breakage. The architectural reading in the proposal — keep target semantics in a typed IR rather than collapsing to LLVM primitives early, and verify a launch contract statically — is a fair description of it.

**The premise about this repository does not hold**, in three ways that change the question.

1. **A `spinel` dialect already exists.** `tools/mlir/native/include/spinel-mlir/Dialect/Spinel/IR/SpinelOps.td` defines it. It is deliberately narrow: 120 lines, three operations — `spinel.checked_add`, `checked_sub`, `checked_mul` — carrying an overflow policy, which is the semantics MLIR's standard dialects cannot express. Everything else in the lane uses MLIR's existing dialects, with `Conversion/SpinelToLLVM` lowering to LLVM.

2. **Only one lowering lane is implemented.** Tracked evidence: test suites are `core`, `core-boundary`, `core-eligibility`, `core-report`, `native-core`, `doom`, `doom-core`, `gc-arena` — no GPU, eBPF, WASM or tensor suite. StableHLO appears in zero files under `tools`, `tests` and `examples`. The DOOM GPU path is a declared-but-stubbed interface: `examples/doom/native/sp_rg_stub.c` answers `sp_rg_available() == 0` and states that it "pulls in no IREE, no GPU kernels and no MLIR", because "Spinel Extended has no such recipe". `docs/architecture.md` already says LLVM, MLIR, IREE and libbpf are *potential* dependencies "not installed by this repository". The six-lane diagram describes the predecessor projects' combined ambition, not this tree.

   The duplication a Core IR would remove therefore does not exist here yet. This is the decisive fact: `AGENTS.md` requires that a new general-purpose Ruby IR not be created "without a demonstrated need", and the need is currently projected rather than observed.

3. **The semantic layer the proposal asks for largely exists — as analyses over one shared snapshot, not as an IR.** The pipeline is:

   ```
   Ruby source
     -> vendor/spinel compiler (Prism parse + type inference)
     -> read in process through tools/contract/spinel_contract.h
     -> Contract::Model            (typed AST by node id, method signatures, local slot types)
        |-- Core/Eligibility       (decision 0004: core admissibility, GC independence)
        |-- Core/LoopBounds        (decision 0010: loop and work bounds, report-only)
        |-- Core/BorrowFacts       (borrow/aliasing facts at the buffer boundary)
        |-- Core/Boundary          (decision 0007: in/inout, overlap refusal, status ABI)
        |-- Freestanding/UndefGate, PlatformLedger, Profile
        `-- Scalar/Importer        (Contract::Model -> MLIR module)
                -> MLIR (standard dialects + spinel dialect)
                -> SpinelToLLVM -> LLVM -> object
   ```

   `Core/LoopBounds.h` states that it "runs over the same analysed source the eligibility checker walked". Sharing between analyses is already achieved, by a common typed snapshot rather than by a common IR.

Two further constraints bear on the substrate question. `docs/architecture.md` already records the decision that the later lanes "may share frontend information and build infrastructure without sharing one universal intermediate representation or runtime ABI", and that MLIR is to be introduced "where its transformations, validation, or multiple lowering routes provide demonstrated value", not for uniformity. And the tree contains **no Rust at all** — zero `.rs` files and no `Cargo.toml` — so Pliron would add a language toolchain as well as a second IR framework beside MLIR.

## Options

**A. Keep the current shape; name and document the layer that already exists.** `Contract::Model` plus its analyses is the backend-neutral semantic layer, and is not currently described as one. Cost: documentation and, where useful, a stable header boundary. Risk: none to existing behaviour.

**B. Build an independent Spinel Core IR (Ruby-side or C++-side) above the existing analyses.** Gains a single explicit representation. Costs a second representation of facts `Contract::Model` already carries, and duplicates what MLIR's standard dialects provide (`arith`, `scf`, `func`, `memref` cover essentially all twenty operations the proposal lists as a minimum set).

**C. Adopt Pliron as the Core IR substrate.** Gains SSA, dialects, verifier and pass infrastructure without building them. Costs a Rust toolchain, a second IR framework whose role overlaps MLIR's, and re-implementation of four working analyses. Pliron's own status: "under active development", no API-stability guarantee, LLVM dialect explicitly "not complete" though able to compile bzip2 and Lua, roughly 484 stars and 649 commits, known users `cuda-oxide` and `cubecl`. It does provide textual IR and bidirectional LLVM bitcode via `llvm-opt`.

**D. Add a Core IR as an MLIR dialect.** Extends what is already in use rather than adding a framework. This is the cheapest route to a Core IR *if* one is later shown to be needed, and it is what the existing three-operation dialect already is, at minimum size.

**E. Use LLVM IR as the common IR.** Rejected by the proposal's own reasoning and by cuda-oxide's: LLVM primitives cannot carry checked-arithmetic policy, loop-bound provenance, borrow facts or buffer modes, which are exactly the semantics the core contract refuses on.

## Decision

Proposed, awaiting the owner's decision.

1. **Do not adopt Pliron now.** Not on technical demerit — it is a credible project and the right choice for cuda-oxide, where the frontend is already Rust. Here it would add a language boundary and a second IR framework to carry semantics that MLIR is currently carrying, against a need that this tree does not yet exhibit.
2. **Do not create a general-purpose Spinel Core IR now.** `AGENTS.md` forbids it absent a demonstrated need; the need is projected from a six-lane diagram that does not describe this repository.
3. **Take option A now, and keep D as the route if a Core IR is later justified.** Document `Contract::Model` and its analyses as the backend-neutral semantic layer they already are, and keep the `spinel` dialect minimal — an operation is added only when a standard dialect cannot express a semantics the contract refuses on.
4. **Let stage 3 (freestanding preparation) be the measurement.** It is the next lane on the roadmap and the first real second consumer of the analyses. The question "is a Core IR needed" becomes answerable there as a number: how much of `Eligibility`, `LoopBounds`, `Boundary` and `MayAllocate` had to be re-implemented rather than reused. That measurement, not this document, should decide options B and D.

Answers to the fifteen requested outputs, in order:

| # | Question | Answer |
|---|---|---|
| 1 | Pliron adoption | No, not now. Revisit only on the triggers below. |
| 2 | Role if adopted | None as Core IR. The only coherent role is a Rust-side lane if a Rust frontend or a Rust-hosted target ever appears; not applicable today. |
| 3 | Core IR as Pliron dialect or independent | Neither yet. If justified later, option D (MLIR dialect) is cheapest, because the lowering and the pinned LLVM are already there. |
| 4 | Prism -> Core IR minimal lowering spec | Not the right shape for this tree. Prism is reached through the vendor compiler, and the lowering that exists is `Contract::Model -> Scalar/Importer -> MLIR`. Specify that, rather than introduce a Prism-to-IR path that would bypass the type inference the contract header exists to read. |
| 5 | Core IR minimum operation set | Already answered by the existing split. Standard MLIR dialects cover the proposal's twenty operations; the Spinel-specific set is the three checked-arithmetic operations plus whatever future refusals require. |
| 6 | Type system minimal design | Already present: vendor type inference read per node id through `spinel_contract.h` (`ntype[id]`, which also distinguishes "no inferred type" from "not an int"), materialised as MLIR builtin types. |
| 7 | Effect representation | The one effect the core contract needs is allocation, and it is decided by `Core/Eligibility` at the source and by the artifact gate at the object. (`Realtime/MayAllocate.h` and `WholeModule.h` are present but **dead** — no `lib/Realtime` is built and nothing includes them; corrected 2026-09-17, see 0012.) Defer `pure/read/write/io/async/gpu` until a lane refuses on them; an unused effect lattice is a contract nobody checks. |
| 8 | Allocation / GC / ownership model | Already the proposal's own design. Decision 0003 governs GC and arena build modes; 0004 governs core admissibility; `BorrowFacts` carries borrow and aliasing; core is proven allocation- and GC-free *at the object* (0 undefined symbols, checked by the artifact gate). Scoped arena is Milestone 2, deferred. Ownership inference beyond borrow facts is not needed for the accepted subset. |
| 9 | Loop / work bound representation | Already decided and merged: decision 0010, bounds as expressions over mathematical integers with reason codes where no bound is established, report-only, over the snapshot. The proposal would relocate a solved problem. |
| 10 | Event / async representation | Nothing in the tree requires it. Premature; no lane can refuse on it yet. |
| 11 | Connection to LLVM / MLIR / StableHLO / eBPF / WASM | Today: MLIR -> LLVM only, and that is the whole implemented set. Pliron would sit *beside* MLIR, not above it, and no Pliron-to-MLIR bridge exists to be relied on. |
| 12 | Minimal PoC plan | Recommend against the proposed differential PoC: it would build a second path to the one backend that already works, and its success would not measure the thing in question. The honest PoC is the stage-3 measurement in decision item 4. |
| 13 | Change scope for existing Spinel | Large for option C: a Rust toolchain on both hosts, a second IR framework, re-implementation of four analyses, and new build recipes under the macOS constraint of official LLVM 23.1.1 selected through `LLVM_PREFIX`. Small for option A: documentation and a named boundary. |
| 14 | Migration risk | For C: Pliron's self-declared API instability; an incomplete LLVM dialect against a pinned LLVM; two IR frameworks that must agree about the same semantics, which is a second copy of one fact; and `AGENTS.md`'s independent-oracle rule — a Pliron lane validated only against the MLIR lane shares a generator with it. |
| 15 | Alternative if not adopted | Option A now, D later if measured. Extend the existing verifier over `Contract::Model` for new lane legality, which is the proposal's strongest idea and needs no new IR. |

### The five hypotheses, against evidence

- **H1 (a semantic IR removes duplicated Ruby semantics):** unproven and currently untestable — there is one lane. Partly already satisfied: the analyses share one typed snapshot.
- **H2 (Pliron is light enough to hold Spinel semantics backend-independently):** plausible as a statement about Pliron, but the cost here is not the IR's weight, it is the language boundary and the overlap with MLIR.
- **H3 (Spinel IR -> Pliron -> MLIR is simpler overall):** not supported. It adds a layer and a framework; MLIR already reaches LLVM, and the Pliron-to-MLIR bridge is hypothetical.
- **H4 (GC is not required; escape/ownership/lifetime analysis can bound it):** **already the implemented design**, not a hypothesis — decisions 0003 and 0004, proven at the object rather than argued.
- **H5 (unifying eBPF/freestanding constraints in a Core IR verifier shares the safety proofs):** the genuinely valuable idea in the proposal. It argues for extending the existing verifier over the shared snapshot, not for a new IR, and stage 3 is where it pays.

### What would change this decision

- A second lane demonstrably re-implementing the analyses (measure at stage 3).
- A required verifier that MLIR cannot express, where Pliron can.
- A Rust frontend or Rust-hosted target entering scope.
- Pliron reaching a stated API-stability guarantee with a complete LLVM dialect.

## Validation

Everything asserted about this repository above was read from `origin/main` at `665f514`:

```sh
git show origin/main:docs/architecture.md                    # the no-universal-IR decision
git show origin/main:tools/mlir/native/include/spinel-mlir/Dialect/Spinel/IR/SpinelOps.td | wc -l   # 120
git ls-tree --name-only origin/main tests/                   # no gpu/ebpf/wasm/tensor suite
git grep -il stablehlo origin/main -- tools tests examples | wc -l   # 0
git show origin/main:examples/doom/native/sp_rg_stub.c       # the GPU path is a stub
git ls-tree -r --name-only origin/main | grep -cE '\.rs$|Cargo\.toml'   # 0
```

External facts are from the projects' own documentation, retrieved 2026-09-17: the cuda-oxide book and repository for the pipeline and alpha status, and Pliron's repository and LLVM discourse thread for its status, dialects and LLVM-dialect completeness.

**Limits of this evaluation, stated rather than implied.** The request listed thirty code-level questions; this record answers the subset that the decision turns on and does not claim the rest. Not examined: cuda-oxide's GPU dialect operation list, its launch-contract implementation, its `rustc` codegen wiring, its ownership and race-safety placement, and its unsupported-Rust-feature set; and, for Pliron, the IR ownership model, SSA construction, region/block model internals, dataflow and alias analysis support, type-inference support, debug-location and metadata support, release cadence, and maintainer count beyond public star and commit totals. None of those would move items 1–3 while the demonstrated-need finding stands, which is why they were not pursued; all of them become relevant if a trigger above fires.

## Consequences

- No change to any existing contract, ABI or build recipe if adopted as proposed.
- `docs/architecture.md`'s "Later integration" section is reaffirmed rather than amended. Adopting a universal Core IR would have required amending it, with the owner's decision, under `AGENTS.md`.
- Follow-up if accepted: document `Contract::Model` and its analyses as the backend-neutral semantic layer, and record the stage-3 measurement as the evidence that decides options B and D.
- Nothing here authorises advertising GPU, tensor, eBPF or WASM support; the stub and the absent suites are why.
