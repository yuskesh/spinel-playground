# 0001: Core boundary declaration, failure policy, and the route to a standalone object

- Date: 2026-09-09
- Status: Proposed
- Scope: How a `core` function's boundary is declared, what happens when a core operation fails, and which implementation route produces the standalone object. This governs a user-visible ABI and is not a routine implementation choice.

## Context

Milestone 1 requires a core function to produce a standalone object that links without the Spinel runtime or GC, reached through a checked ABI. Two bodies of evidence bear on how to get there.

### Measured on the pinned Spinel (`d9eb845`), Debian 13, Clang 23.1.1

- `--ext-init` / `--ext-entry` already emits a library without `main`, exports selected module methods non-static, writes a `.h` contract, and refuses some boundary violations with a reason.
- Without declared types the exported entry is polymorphic and boxed: `sp_RbVal sp_Kern_s_add(sp_RbVal, sp_RbVal)` with GC root registration, and the object carries 142 undefined `sp_*` symbols reaching GC, bigint, regexp, JSON, Time and IO.
- Seeding the analyzer through `--rbs` collapses that to `sp_int sp_Kern_s_add(sp_int, sp_int)` with no GC roots, where `sp_int` is `intptr_t`. Existing inference already produces the shape core needs.
- For these two samples the remaining undefined symbols at that point (116) are not referenced from the exported function bodies. This says nothing about other functions: allocation, indirect calls, access to GC-managed storage and reachable callees are not excluded by a type signature, and no general claim that core reachability reduces to translation-unit structure follows from this sample.
- The `sp_int` ABI reserves a value. `SP_INT_NIL` is `INTPTR_MIN`, and `SP_INT_NIL_CK` compares operands against it. The usable range of an `sp_int` parameter is therefore `INTPTR_MIN + 1 .. INTPTR_MAX`, not the full machine range, and a host passing `INT64_MIN` as an ordinary integer would be read as `nil`. Under `raise` that reaches `sp_raise_nil_int_op`; under `wrap` the guard is gone and the value is silently treated as an ordinary integer.
- Per function, with types pinned: under the default `--int-overflow=raise`, `add` calls `sp_raise_cls` and `sp_raise_nil_int_op`; `clamp`, which only compares, calls nothing. Under `--int-overflow=wrap` neither calls anything. Measured two ways that agree: disassembly with interleaved relocations, and presence of a `.rela.text.<fn>` section.
- `--int-overflow=wrap` expands `sp_int_add(a, b)` to `((a) + (b))` on a signed `intptr_t`, and the build passes neither `-fwrapv` nor `-fno-strict-overflow`. Signed overflow there is undefined behavior, not wraparound. Confirmed by compiling the same shape at `-O2`: `r = a + b; return r < a;` is optimized to `return b < 0;`, deleting the wraparound test. `wrap` therefore buys symbol-level cleanliness at the cost of a defined result.

### Measured against the predecessor checkout `spinel-llvm` at `f8ad13c6d9dc990b116ba1c842c7881232f29585`

A checkout at that revision is present on the same host, on branch `e189-upstream-sync` with a clean working tree. It is the same revision the predecessor's own report cites, so there is no revision difference to reconcile. Its `vendor/spinel` submodule points at `spinel-fork` branch `c-emit-ir` at `ecbd0f2a`, which is not the revision this repository pins; its documented lineage is upstream plus gated patches and non-gated batches, with upstream sync deliberately deferred. Nothing in that checkout was modified, and no branch or pin was moved.

The following was measured here, not taken on report:

- The contract reader builds against **this repository's clean upstream pin** with no adaptation. Copying `spinel_contract.h` and `spinel_typedump.c` out of that checkout and compiling them against `d9eb845`'s vendor objects, using the same command its `build.sh` uses, produced zero errors and zero warnings and linked.
- It also runs correctly there. Against a two-method integer program it produced the method table with `abi_scalar` yes, the local slot table including the `nullable_int` column, and per-node gate verdicts with a summary line.
- Its `build.sh` already carries an adaptation for a 2026-09 upstream that links the regexp engine into the compiler, taking those objects only when `re_lit_check.o` exists. That seam is present in this repository's pin and was exercised by the build above.

The remainder of this section is recorded as reported at that revision and not re-verified here.

- Core is not produced by trimming the hosted C translation unit. An external `tools/contract` in-process reader links the vendor compiler objects (excluding `main.o`) together with libprism, reads the vendor's analysis results, and a native MLIR freestanding importer lowers them to an independent object. Core needs no core-specific codegen branch inside the vendor tree.
- That reader concentrates every dependency on vendor internals into one header: 60 struct fields, about 25 functions, 7 type constants and 3 parser field names. A rename or removal upstream becomes a compile error rather than a silent misread. The sister project using the same technique is recorded as having absorbed 865 upstream commits with no adaptation.
- The declaration surface is a plain Ruby method call, `freestanding_def`, recorded at compile time and read back from the AST dump. It was deliberately not made new Ruby syntax, because that would have required changing the read-only vendor tree.
- Its stated reason for declaring types at all is that inference answers a different question: it establishes that a method computes on `Integer`, while the boundary width is a fact about the foreign C side that no amount of reading the Ruby can recover.
- The local slot model already carries `nullable_int`, meaning an unboxed scalar that may hold the nil sentinel. The sentinel this repository measured is therefore a modelled property in that design, not an oversight.
- Arena, unlike core, does carry vendor patches: `SP_REQUEST_ARENA` branches in `lib/sp_gc.{h,c}` and `lib/sp_alloc.{h,c}` (+218/-0), plus `--request-arena` and an arena archive option in `src/main.c` and the Makefile (+45/-1).
- The boundary is declared in `tools/freestanding/spinel/freestanding.rb`, in the shape `freestanding_def :add, params: [:i32, :i32], returns: :i32, overflow: :trap`. It separates the inferred Ruby `Integer` from the boundary width, keeps `i64` internally, and generates entry widening and exit checks. Buffer direction, length and bounds are declared too, because typing alone does not establish ownership or effects.
- The declaration names the boundary width explicitly from `i8`, `i16`, `i32`, `i64` and the unsigned forms, keeps `i64` internally, widens at entry, and range-checks at exit, trapping on a non-conforming value. It is not a boxed Ruby value ABI, so it does not reproduce a nil sentinel inside the integer range.
- Buffers carry a statically checked direction, and dynamically checked index bounds (code 4), NULL buffer (5) and negative length (6) at entry. Declaring `bounds: unchecked` still keeps the NULL and negative-length entry checks. None of this establishes the caller's actual memory capacity or the lifetime of what it passed.
- The failure policy is already decided there: trap by default, `wrap` only as an explicit opt-in, `raise` refused, using a non-returning `spinel_trap(code, a, b, detail)` platform hook.
- Core is not judged from the artifact alone. A static check over a typed subset and the call closure is combined with an undef gate on the emitted object. Declarations are not taken on trust.
- Existing validation assets: reject and gate runners with `undef_gate.tsv` and `trap.tsv` under two experiment result sets, an arena escape check, and a pass that scans every `def` for core declarations. The current native implementation lives in a freestanding subset frontend and `Declaration`, `Emit` and `UndefGate` components with lit tests for the undef gate and the trap policy.

## Options

### A. Declaration form

1. **A declaration DSL matching the predecessor's `freestanding_def`.** Expresses boundary width separately from the inferred Ruby type, and carries overflow policy, buffer direction, length and bounds.
2. **RBS.** Already read by the pinned compiler and measured sufficient to monomorphize. But RBS names `Integer`, not `i32` versus `i64`; it cannot state an overflow policy, a buffer's direction, its length source, or bounds. It would have to be paired with a second declaration channel for everything it cannot say.
3. **A comment pragma in Ruby source.** Requires an Extended-side parser over source text and adds a second syntax to maintain.

### B. Failure policy for core arithmetic

1. **Trap by default, `wrap` as an explicit opt-in, `raise` refused.** Matches the predecessor contract, and is independently supported by the measurement above: `raise` needs the runtime, and `wrap` is undefined behavior unless the build also guarantees wraparound.
2. **`wrap` by default.** Rejected: not a defined result on this toolchain, and it silently removes the nil guard as well.
3. **Status-returning ABI**, such as `int f(args, sp_int *out)`. Recoverable and runtime-free, but widens the first slice and complicates every entry.

### C. Route to the standalone object

1. **Port the predecessor's external reader plus MLIR freestanding lowering.** Reuses a design that already produces independent objects and already has reject and gate fixtures. Requires MLIR, which is now available at `/opt/llvm-23.1.1`. The first stage of it is measured above to build and run against this repository's pin with no adaptation, which removes the main risk that made this option look expensive. The MLIR importer and lowering stages have not been built or exercised here and remain unmeasured.
2. **Build a new route on the pinned C path** using `--rbs` and `--ext-entry`, with Extended supplying a static check over the accepted subset and its call closure plus a gate over the emitted object. Smaller, and no vendor patch. Two obligations are specific to this route. Its integer ABI reserves `INTPTR_MIN` for `nil`, so the boundary contract must either exclude that value, define its meaning, or introduce a width narrower than the sentinel-bearing type. And extracting a function from the emitted translation unit must preserve the closure of its callees, constant data and relocation targets rather than a single text section.

## Decision

Proposal awaiting approval. Recommended: **A-1**, **B-1**, and **C-1**.

Status note, 2026-09-09: the project owner approved proceeding with C-1, and the
first slice of that import has landed alongside this record. The record stays
Proposed rather than Accepted because the imported slice has not been reviewed
yet, and because A-1 and B-1 were carried in with the import rather than decided
separately: the import keeps `freestanding_def` and the trap default unchanged,
which is what those two options describe. Nothing here has been re-decided.

A-2 is attractive because it works today with no new syntax, but the measurement shows it can only carry the parts of the contract that are ordinary Ruby types. The boundary width, the overflow policy and every buffer rule would need a second channel, which is a worse outcome than one declaration form that states all of them.

B-1 needs no further argument from preference: on this toolchain `raise` is runtime-dependent and `wrap` is undefined behavior, so trap is the only option that is both defined and runtime-free.

What the measurement settles and what it does not is worth stating plainly, because the two are easy to conflate. Settled: the pinned compiler can emit an unboxed monomorphic entry from an RBS signature; `raise` is runtime-dependent; `wrap` is undefined behavior here; the `sp_int` ABI reserves `INTPTR_MIN`. Not settled by any measurement so far: that a declared function's reachable callees allocate nothing, that it makes no indirect call, that it touches no GC-managed storage, or that the scaffolding observation generalizes past the two sampled functions. Those need a static check over the accepted subset and the call closure, with the artifact gate as a second, independent check rather than the only one.

C is the open question, but the evidence has moved. The reason to fear C-1 was that importing the predecessor's route might drag in its forked Spinel. Measurement says the first stage does not: the reader is deliberately isolated behind one header and builds unchanged against the clean pin this repository already uses. What remains unmeasured for C-1 is the MLIR importer and lowering, and whether the reject and gate fixtures run against their current runners. C-2 is cheaper to start and stays within AGENTS.md's preference for keeping vendor code read-only, but it is a new design rather than a migration, and the predecessor's validation assets would not transfer to it directly. C-1 imports a working contract together with its evidence, which is what the migration rules ask for, at the cost of a larger first step.

## Validation

Required before this record moves to Accepted, and before any claim that a core object is runtime-free:

- A negative control: a function that violates the contract must be rejected with an actionable diagnostic, and the check must be shown to fail when the violation is present.
- Object-level evidence is necessary but not sufficient. Undefined symbols and relocations must be checked, and so must reachable callees, indirect calls, memory operations, and the permitted extern set. No claim of an allocation-free contract may rest on `nm` and relocation output alone.
- The translation-unit scaffolding must be accounted for, not just the exported function bodies.
- Behavior must be compared against a reference for supported scalar forms, including boundary values and the agreed failure cases.
- Any predecessor script adopted here must be re-run against its current runner and dependencies before its result is cited.

## Consequences

- Choosing A-1 means Extended owns a declaration format and must document it before implementation depends on it.
- Choosing B-1 makes trapping the observable behavior of a core arithmetic failure. That is a deliberate divergence from hosted Ruby semantics, where `Integer` promotes, and it must be documented as a boundary rather than presented as Ruby behavior.
- Choosing C-1 adds MLIR to the toolchain expectations for building core artifacts, though not for the hosted path, which [Building and testing](../building.md) keeps unchanged.
- Choosing C-2 makes the reserved `INTPTR_MIN` an ABI-visible fact that must be documented, or designed out by declaring a narrower boundary width.
- Whichever route is chosen, core status is established by a static check plus an artifact gate. A gate over the emitted object is never on its own a proof of the contract.
- This record does not decide the buffer boundary. Scalars come first; buffers need their own record covering ownership, mutability, length, aliasing and lifetime.
- Arena stays out of scope. The predecessor's arena work carries vendor patches and is a separate decision.

Status note, 2026-09-11: [decision 0007](0007-doom-core-preparation.md) proposes
B-3, a status-return ABI, for a separate numeric/buffer CORE boundary. This record's
B-1 recommendation is not an accepted mandate for that new boundary. The imported
`freestanding_def` trap behavior remains unchanged. The owner subsequently
approved 0007 on 2026-09-11; that record is Accepted for implementation.
