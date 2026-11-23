# 0013: Naming the shared semantic layer, and the conditions that would reopen a Core IR

- Date: 2026-09-17
- Status: Proposed
- Scope: The architecture names and rules for the shared semantic layer, where target legality belongs, the migration that gives allocation legality one owner, the design of a stack bound, and the normative triggers that reopen [0011](0011-core-ir-and-ir-framework-evaluation.md). Follows [0012](0012-shared-semantic-layer-and-the-second-consumer.md). No code change is proposed here.

## Correction to 0012

0012 stated that `UndefGate` "pins the frozen Python `undef-check.py` and `spinel_alloc_free.py` by sha256 so the gate goes red if the Python side moves." **That mechanism is not in this repository.** `UndefGate.cpp`'s comment instructs a maintainer to "also revisit the `cp4/identity.tsv` Python-side pin in the same commit", but no `identity.tsv` exists in the tree, and neither does any of `undef-check.py`, `spinel_alloc_free.py` or `spinel-mlirgen.py`. The only `identity.tsv` in the tree is an unrelated *generated output* that `tests/doom-core/loop-reports.sh` writes to an OUTDIR. So the pin is a predecessor mechanism described in an imported comment, not an in-tree guard, and 0012 described documentation as implementation.

What actually guards these components here is different and weaker in scope but real: a **`static_assert` cardinality lock** over the symbol sets in `UndefGate.cpp` ("fix the cardinality with `static_assert`, because silently widening turns a form that was refused into one that is accepted"), and **refusal fixtures** (`MlirGen.cpp`: "pinned by refusal fixtures rather than trusted to stay in step"). Item 3 below is rewritten around that, and its conclusion is stronger rather than weaker: there is no Python red-gate to preserve, so the question is not how to keep it but how to replace what it was standing in for.

The error is the same class as 0012's own correction of 0011 — treating a description as a fact about this tree. Both times the phrase came from an imported comment that was true where it was written. 0012 has been amended in place to say this, so the wrong claim does not survive in the record that made it.

## The decisive new finding

`SubsetTables.cpp` declares itself generated: "**generated**: `docs/experiments/results/E175/mk_fs_tables.rb` copies FS_ALLOC_NODES / FS_ALLOC_CALLS mechanically from the frozen Python `tools/mlir/spinel-mlirgen.py`. Do not hand-edit — to fix it, look at the Python side and regenerate."

Neither `mk_fs_tables.rb` nor `docs/experiments` nor the frozen Python exists in this repository. **The instruction the file gives cannot be followed here.** The 36 node entries and 46 call entries are therefore frozen artifacts with no regeneration path and no editable source, and the same is true in kind of `MlirGen.cpp`, which carries 94 references to the frozen generator it mirrors (`grep -c '凍結\|frozen'`).

This reframes 0012's conclusion. 0012 said the duplication is a port boundary rather than a missing IR, and recommended waiting for stage 3. The stronger statement is: **the port boundary is not a transitional state that will resolve itself, because the far side of it is not in the repository.** Ownership has to be taken deliberately, and that is a decision, not a cleanup.

## Items

### 1. Name for the shared semantic layer

Recommend **Admitted Semantic Model**, abbreviated ASM in prose, for the pair-plus-derivations; and keep `Contract::Model` as the name of the *snapshot* alone.

Reasoning against the alternatives, on existing-term grounds. "Shared Semantic Layer" describes a position in a diagram rather than a thing, and the tree has no other "…Layer". "Semantic Snapshot Layer" conflicts with the existing and precise use of *snapshot*, which `architecture.md` already applies to the frontend analysis result ("a coherent analysis snapshot with explicit ownership") — the snapshot is one member of the pair, not the pair. "Contract Semantic Layer" overloads *contract*, which in this tree already means three specific things: `spinel_contract.h`, the core tier contract, and the boundary status ABI. **Admitted** is the term `Eligibility` already uses for exactly the fact that distinguishes the pair from the snapshot (`EligibilityReport`, `admitted.methods`, "the answer the checker admitted"), so the name is drawn from the code rather than imposed on it.

Minimal documentation patch: one subsection in `docs/architecture.md` under **Boundaries**, naming the ASM as the boundary between frontend support and the lane compiler, listing its members (`Contract::Model`; `EligibilityReport`; the derived reports `LoopBounds`, `BorrowFacts`, `Boundary`), and stating that it carries no target information. No table row changes; the existing "Frontend support" and "Lane compiler" rows already describe the two sides.

### 2. Promoting the no-re-derivation rule

Recommend placing it in **`docs/architecture.md`, as an Architecture rule**, not in `AGENTS.md`. `AGENTS.md`'s architecture rules govern how agents may change the project; this is a property of the program's construction, and `architecture.md` is where "Boundaries" and "Memory tiers" already live. Proposed wording:

> **A semantic fact has one owner.** Where an analysis establishes a fact, every downstream consumer receives that analysis's result. No consumer re-derives the same meaning from the source or the AST. Where a consumer may rely on a fact having been established without receiving it, the assumption is stated at the point of reliance.

The second sentence matters more than it looks. `MlirGen.cpp` already relies on admission implicitly — "the eligibility checker has already refused anything but a single…", "two writes: refused upstream" — which is correct behaviour resting on an unstated contract. Naming assumption-without-receipt as a third case makes those comments into the rule's evidence rather than exceptions to it.

Owned facts to list under it: the admitted closure; resolved call targets (once item 7 lands); allocation legality; loop and work bounds; buffer mode and element count; overlap/alias refusal; the scalar ABI verdict.

### 3. Moving ownership off the frozen Python

The premise has to change first: there is no red-gate property to preserve, because the pin, the generator and the Python are all outside this repository (see the correction above). The independence that exists in-tree is the refusal fixtures and the cardinality `static_assert`s. So the proposal is not "replace the pin" but "make the in-tree guard carry the weight the pin was described as carrying."

Proposed condition sequence, each step observable:

1. **Freeze what is frozen, visibly.** Add a check that `SubsetTables.cpp` has not been hand-edited — its own instruction forbids it and cannot be honoured, so the current state is that the prohibition is unenforced. A content digest recorded in `tests/` and compared is enough; this replaces an absent pin with a present one and costs nothing.
2. **Establish equivalence in-tree, on fixtures rather than against the Python.** The independent oracle for allocation legality cannot be the frozen Python, since it is not here. It can be CRuby behaviour plus the object gate: a program the tables refuse either allocates under CRuby observation or leaves an allocation symbol in the object. Build that corpus from the existing refusal fixtures, and record which table entries it actually exercises. **This is the gate: ownership moves for the entries the corpus covers.**
3. **Move those entries into `Eligibility`** as refusals in its own vocabulary, and reduce `SubsetTables` to whatever the corpus did not cover — which is then an explicit, shrinking list of unverified inherited refusals rather than an opaque generated table.
4. **Keep the object gates unchanged throughout.** `UndefGate` and `core-artifact-gate` remain the independent verification, and they are independent in the sense `AGENTS.md` requires because they read the emitted object rather than the analysis that produced it.

The honest limitation: step 2 cannot establish equivalence for entries the corpus does not reach, and those entries' authority will remain "inherited from a reference this repository cannot consult." Stating that in the record is better than implying a completed port.

### 4. Where freestanding's target legality belongs

`FreestandingSubset`'s refusal mechanism is, in full, two table lookups over the LIFO subtree:

```
fsAllocNodes().find(n->kind)        -> 36 entries, refuse with the table's reason
fsAllocCalls().find(str(n,"name"))  -> 46 entries, refuse with the table's reason
```

Both are predicates over node kind and call name — exactly the vocabulary `Eligibility` already walks and resolves in. **So every one of these refusals is expressible on the ASM; expressiveness is not the obstacle, provenance is.** Nothing here needs target policy at all: "this construct allocates" is a target-neutral fact, and the target-specific part is only whether allocation is permitted, which `FreestandingProfile` already decides.

Proposed placement:

| Concern | Belongs | Why |
|---|---|---|
| "does this construct allocate" | `Eligibility`, as an owned fact | target-neutral; already its subject matter |
| "is allocation permitted here" | target policy (`FreestandingProfile`) | the only genuinely target-specific half |
| "did the object import a forbidden symbol" | `UndefGate` / artifact gate | independent, post-lowering |

Can `Scalar::Importer` stop knowing about freestanding? **Partly, and the limit is worth naming.** The `freestandingTypes` option is not a legality switch — it selects a type spelling, because "a freestanding local has ONE type (there is no boxed…)". That is a lowering difference, and lowering differences are the importer's business. What can leave is the *refusal* at `MlirGen.cpp:766` ("is outside the freestanding subset"), which is legality inside lowering. So: legality and lowering can be separated; lowering and target *representation* cannot, and should not be.

### 5. Stack upper bound design

Recommend a **separate `Core/ResourceBounds`**, not an addition to `LoopBounds`, while reusing `LoopBounds`' machinery. Reason: 0010 fixed `LoopBounds` as the *loop and work* bound with a versioned digest (`kLoopDigestVersion`) and a documented grammar; a stack bound composes differently (maximum over a path, not product over nesting) and would change what that digest covers. A sibling analysis consuming the same admitted closure keeps 0010's contract intact.

What it can compute at source level: maximum call depth over the acyclic closure — available because admission refuses call cycles — plus declared local and aggregate sizes, and the count of temporaries the lowering is known to materialise. What it cannot: actual frame size, spill, callee-saved registers, and compiler-generated helper calls.

### 6. Two-stage stack bound

This follows directly and is the right shape, because it is the shape the project already uses for allocation:

```
source admission  (Eligibility)        ~  semantic bound   (ResourceBounds)
object gate       (artifact gate)      ~  artifact bound   (frame sizes from the object)
```

Proposed split: the semantic stage derives a symbolic bound in the same mathematical-integer grammar `LoopBounds` uses — depth and declared sizes, with reason codes where unknown — and **refuses nothing**, per 0010's precedent. The artifact stage reads actual frame sizes from the emitted object and compares the total against the profile's budget. Conservative bounds are sufficient and preferable: the semantic stage's job is to fail early and explain, and the object stage is what actually holds the guarantee, exactly as with GC-freedom where the proof is at the object. The one thing to decide before implementing is where the budget is declared, and `FreestandingProfile` is the obvious home since it already carries `libc`/`libm`/`compilerRt` and `allowedSymbols`.

### 7. Resolved call graph as a shared fact — recommended

The two predicates are **not** the same logic:

```
Eligibility::isInferenceCall   kind=="CallNode" && receiver==-1 && block==-1
                               && call_operator=="." && closure-reports(name)
LoopBounds::callsClosure       kind=="CallNode" && receiver<0 && closure.count(name)
```

LoopBounds' is weaker by two conditions: it does not exclude a call with a block, and does not require the `.` call operator. It is presumably safe because admission refuses those forms upstream — but that is precisely an assumption without receipt, and it is unstated. `Eligibility`'s own comment shows the project already reached this conclusion internally: the predicate was "extracted from the inline test it replaces so the admitted output form applies exactly the same rule to its operand, **rather than a copy that could drift**."

Recommend adding **call edges to `EligibilityReport`** rather than a separate `ResolvedCallGraph`. The report already carries the closure, derived types, read parameters, constants and entry buffer facts; call edges are the same kind of fact about the same admitted closure, and a separate structure would need the closure passed alongside it anyway. After admission the target is unique — admission requires a direct, receiverless, block-free `.` call to a named closure member, which is why `Eligibility` can resolve by name at all. Consumers: `LoopBounds` (composition), `ResourceBounds` (depth), and any future verifier-constrained lane. Coupling concern: this adds no vendor coupling, because the edges are derived from nodes the snapshot already carries.

### 8. `Scalar::Importer` / `MlirGen` audit

Classified by the requested categories, with counts over `MlirGen.cpp` (3365 lines) and `Importer.cpp` (757 lines):

| Category | Evidence | Verdict |
|---|---|---|
| **A** structural lowering | 55 node-kind string comparisons | correct here |
| **B** type lookup | 12 type-face references in MlirGen; 4 in Importer | correct here, and strikingly thin |
| **C** semantic re-derivation | no independent re-derivation found; instead **reliance by assumption** — "already refused anything but a single…", "two writes: refused upstream" | not duplication; needs the stated-assumption rule from item 2 |
| **D** target legality | `MlirGen.cpp:766` refuses "outside the freestanding subset"; `FreestandingSubset` invoked under `--freestanding` | **move out** (item 4) |
| **E** backend policy | `freestandingTypes` option, 31 freestanding references; overflow mode 3-valued with the frozen 4th (`trap`) deliberately excluded | **keep** — type spelling and overflow are lowering representation, not legality |
| **F** MLIR construction | "every join and loop header carries the whole local environment as arguments" | correct here |

So the audit's result is milder than 0012 implied on one axis and sharper on another. Milder: there is no category-C duplication to remove — the importer does not recompute what the analyses decided, it assumes it. Sharper: the importer is thin on B (16 type lookups across 4100 lines) because it is a **transliteration of a Python generator** rather than a consumer of the ASM, and that, not re-derivation, is what makes it hard to share with a third lane.

### 9. `MlirGen` second-copy trigger, made concrete

Not a branch count, because the current branching is a legitimate parameterisation: one option (`freestandingTypes`) selecting a type spelling is not the beginning of a second copy. The trigger is **a second target axis multiplying inside one generator**, which is observable as any of:

- a second `options_.<target>` flag whose arms are read in the same functions as `freestandingTypes` — i.e. two target axes interacting rather than one axis parameterising;
- any duplicated visitor for the same node kind, distinguished only by target;
- a target that needs the lowering but not MLIR, which would require re-implementing the walk rather than parameterising it;
- **a hand-edit to `SubsetTables.cpp`**, because it signals that the frozen artifact has been adopted without the ownership move of item 3.

### 10. Core IR re-evaluation triggers — worth recording, and here they are

Recording them is worth it, for a reason specific to this project: 0011 and 0012 both concluded "not now" on grounds a later reader could mistake for "not ever", and the triggers are the part that keeps the conclusion falsifiable. Proposed normative form, refining the request's A–E:

- **A.** Two or more semantic facts are needed that cannot be derived over the ASM — specifically, facts requiring a CFG, SSA or dataflow that the snapshot cannot supply and a pass cannot cheaply rebuild. Count of such facts ≥ 2.
- **B.** A second divergent copy of the importer is required, by any signal in item 9.
- **C.** A third consumer arrives while allocation legality still has more than one source-level owner.
- **D.** A Rust-hosted frontend or target enters scope, which changes Pliron's cost model.
- **E.** Pliron publishes an API-stability guarantee together with an LLVM dialect complete enough for the pinned LLVM.

Explicitly **not** triggers: a percentage of duplicated analysis lines (the existing duplication is a port artifact and would read as a false positive), and a count of supported backends.

### Rejection telemetry (request item 10)

The ingredients exist and are uneven: `Freestanding::Category` is a closed 13-value enum with a closed 8-value `Stage`; `EligibilityReport` carries `verdict`, `reason` and `detail` as **strings**; `MlirGen` emits `fail(node, "unsupported-node", detail)` — a category plus free text; `LoopBounds` carries reason codes. So grouping is possible today on `(stage, category)` for freestanding and on `reason` for eligibility, and is coarse for the importer because its category is a single value with the information in the detail.

Proposed measurement, needing no new analysis: run the existing corpus — `examples/doom` plus the `tests/*/fixtures` — through admission, and record a table of `reason` counts. The two figures that decide escape-analysis value are then (a) how many distinct refusals cite a local aggregate, and (b) how many of those are the fixed-size, non-escaping shape. **Implement it in shell or Ruby, not Python** — the two existing `.py` files are imported test harnesses and new Python is not to be added here. The smallest honest first step is to give `MlirGen`'s `unsupported-node` a second category field so its refusals become groupable, since that is where the importer's refusals currently collapse into one bucket.

## The final question

> Can the current architecture extend soundly to the next backend after freestanding, without a universal Core IR, by separating shared semantic facts from target policy?

**Yes — and the separation is already real rather than aspirational.** The evidence is that `LoopBounds` consumes `EligibilityReport` instead of re-expanding the call graph, and that `FreestandingProfile` is pure policy data with no analysis in it. Those are the two halves the question asks about, and they already work.

**How far it holds.** Through freestanding, and through further *analysis* consumers without strain: `ResourceBounds` (item 5), a verifier-constrained lane's bound admission, and a third target's legality can all be added as new consumers of the ASM plus a new policy table. The layering supports that because the facts are target-neutral by construction — the snapshot carries no target information and the bounds are mathematical integers rather than machine words.

**Where it breaks first — and it is not the analysis layer or the missing IR.** It breaks at `Scalar::Importer` / `MlirGen`, for a reason that has nothing to do with representation adequacy: that layer is a 3365-line transliteration of a frozen Python generator (94 references to it), and both the generator and its regeneration script are outside this repository. A third lane must either extend a mirror whose reference nobody here can consult, or copy it. The same holds for `SubsetTables.cpp`, whose "regenerate from the Python" instruction is unexecutable here. The first thing to break is therefore **the lowering layer's provenance, not the semantic layer's expressiveness** — and a Core IR would not fix it, because the missing thing is ownership of the generator, not a better intermediate form.

**Observable signals, all countable in-tree today.** Record these as a baseline and watch them:

**Name the revision in every one of these.** `git grep -- <path>` without a revision reads the *working tree*, so on any checkout that is not current these commands silently measure the wrong thing — while writing this record they reported the refusal at line 693 instead of 766 and missed `LoopBounds` entirely, because the checkout was on an older branch.

```sh
# 1. target axes inside the generator
#    baseline: ONE axis -- 13 occurrences of the freestandingTypes option
#    (31 mentions of "freestanding" in all, most of them commentary)
git grep -c 'freestandingTypes' origin/main -- tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp
# 2. legality still inside lowering (baseline: 1 site, MlirGen.cpp:766)
git grep -n 'outside the freestanding subset' origin/main -- tools/mlir/native/lib/Frontend/Scalar/
# 3. subset files, and how many TARGETS they serve
#    baseline: 3 files -- FreestandingSubset.{h,cpp} + the generated
#    SubsetTables.cpp -- all serving ONE target. The signal is a second
#    target's name appearing here, not the file count.
git ls-tree -r --name-only origin/main -- tools/mlir/native/lib/Frontend/Scalar/ | grep Subset
# 4. predicates answering "is this a call into the closure"
#    baseline: 2 distinct predicates, differing by 2 conditions --
#    Eligibility.cpp:1647 isInferenceCall, LoopBounds.cpp:511 callsClosure
git grep -n 'closure.count(str\|isInferenceCall' origin/main -- tools/mlir/native/lib/Core/
# 5. source-level owners of allocation legality (baseline: 2 — Eligibility and SubsetTables)
# 6. hand-edits to the generated table (baseline: none; currently unenforced)
git log --oneline origin/main -- tools/mlir/native/lib/Frontend/Scalar/SubsetTables.cpp
```

Signal 1 rising above one axis, or signal 3 naming a second target, is trigger B. Signal 5 staying at 2 when a third consumer arrives is trigger C. Signal 6 becoming non-empty means the frozen artifact was adopted without the ownership move, which is the quiet failure and the one worth a guard.

## Validation

Read from `origin/main` at `d19957c` on 2026-09-17:

```sh
git grep -ril identity.tsv origin/main                       # only comments + an unrelated generated output
git ls-tree -r --name-only origin/main | grep -cE 'undef-check.py|spinel_alloc_free.py|spinel-mlirgen.py'  # 0
git ls-tree -r --name-only origin/main | grep -cE 'mk_fs_tables|^docs/experiments'                          # 0
git show origin/main:tools/mlir/native/lib/Frontend/Scalar/SubsetTables.cpp | sed -n '1,14p'
git show origin/main:tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp | grep -c '凍結\|frozen'              # 94
git show origin/main:tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp | grep -cE '"[A-Za-z]+Node"'          # 55
git show origin/main:tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp | grep -ciE 'freestanding'            # 31
git show origin/main:tools/mlir/native/lib/Core/Eligibility.cpp | sed -n '1643,1651p'                        # isInferenceCall
git show origin/main:tools/mlir/native/lib/Core/LoopBounds.cpp | sed -n '507,513p'                           # callsClosure
git show origin/main:tools/mlir/native/include/spinel-mlir/Core/Eligibility.h | sed -n '13p'                 # report fields
git show origin/main:tools/mlir/native/include/spinel-mlir/Freestanding/Diagnostics.h                        # Stage, Category
```

**Limits.** Nothing was built or run. The classification in item 8 is from node-kind, option and reference counts plus the files' own statements of intent, not from tracing execution, so "no category-C duplication found" is bounded by what those counts and comments reveal. Line and reference counts are proxies for effort. Not examined: `MlirGen.cpp` function by function, whether admission in fact refuses every call form `LoopBounds`' weaker predicate would admit (item 7 assumes it and says so), `Core/Boundary`'s overlap algorithm, and the `GradPipeline`/`GradShim` differentiation path.

## Consequences

- No code change proposed. Items 1, 2 and 10 are documentation; items 3–7 are implementation proposals for later decision; items 8–9 are findings and thresholds.
- If accepted, items 1 and 2 amend `docs/architecture.md`, which is an established boundary document, so they need the owner's decision rather than an incidental edit.
- Item 3 changes what authority the freestanding allocation refusals rest on, and must not be read as completing the port: it moves the covered entries and makes the uncovered remainder explicit.
- The correction above is also **applied to 0012 in place**, at the owner's direction, in the same change that adds this record. 0012 is Proposed, so the decisions README's rule that an approved record keeps its original wording does not apply; its corrected paragraph carries a dated note saying what the first draft claimed, so the amendment is visible rather than silent.
