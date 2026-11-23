# 0004: Check core eligibility independently of an exported ABI

- Status: Design accepted (2026-09-10); primary-environment implementation validation remains pending.
- Date: 2026-09-10
- Baseline: Extended `9913c3a70e1ec05f209bb7a3d16a45226661bf3b`, with Spinel `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`.

## Purpose and resulting capability

A developer should be able to select an ordinary Ruby method and check whether
its body and reachable callees satisfy the supported core constraints, without
declaring an exported function or choosing a foreign integer width. A diagnostic
must identify the offending source location and the call path that reaches it.

Core prohibits allocation and dependence on the Spinel runtime or GC. This is
stronger than disabling collection, and stronger than finding no allocator call.
Borrowing a Ruby heap object, reaching an exception helper, or reading runtime
state can violate the contract without allocating in the selected method.

This phase produces an analysis report. It does not produce a new object file,
connect hosted and core code, or establish that an existing hosted object is
runtime independent. Artifact validation remains necessary when emitting code.

## Evidence inspected for this proposal

At the baseline revision:

- `tools/contract/spinel_typedump.c` exposes AST nodes, inferred node and local
  types, method information, and a per-node gate. Its `no-evidence` result must
  not become an accepted result merely because no refusal was encountered.
- `tools/mlir/native/include/spinel-mlir/Contract/Model.h` provides a shared
  analysis model, including nullable integer and captured-cell information.
  It depends on LLVM utilities but not on MLIR IR.
- `tools/mlir/native/lib/Frontend/Scalar/Importer.cpp` discovers a reachable
  method closure. Its freestanding path also validates declarations and imports
  operations for a particular lowering contract; that whole path is not a
  declaration-independent checker.
- `tools/mlir/native/lib/Frontend/Scalar/FreestandingSubset.cpp` is an early
  refusal pass, with exceptions for declared buffers. Passing it alone does not
  prove the core contract.

The predecessor was inspected read-only at
`f8ad13c6d9dc990b116ba1c842c7881232f29585`:
`tools/mlir/native/lib/Realtime/MayAllocate.cpp` implements allocation
reachability but explicitly preserves an overly broad external allowance regex.
Its no-allocation conclusion is not a substitute for runtime independence.
`WholeModule.cpp` constructs LLVM input through the hosted compiler and runtime;
that is a different analysis route with build configuration obligations.
No predecessor code or test result has been imported by this proposal.

## Alternatives

1. **Separate a conservative source checker over the existing contract model.**
   Recommended. It preserves source identity and avoids choosing an exported
   ABI. It must explicitly account for missing type, call-target and operation
   semantics evidence rather than infer them from syntax.
2. **Reuse the freestanding importer as the checker.** It already has closure
   checks, but would carry declaration requirements and lowering-specific
   numerical assumptions into this task. Not selected.
3. **Port the whole-module LLVM allocation analyzer first.** It can inspect
   generated call dependencies, but no-allocation is insufficient, and porting
   runtime bitcode construction would expand this first phase substantially.
   Keep this as a possible later complementary artifact analysis.

## Interface and analysis boundary

Use an explicit command-line method selector rather than a source annotation.
Implemented usage (the executable is in the native build's `bin` directory):

```sh
spinel-core-check app.rb --method clamp
```

The selector names an existing method; it does not seed parameter types or
publish an ABI. Initial support is limited to uniquely identified top-level
methods and statically resolved direct calls within the analyzed source.
Duplicate definitions, ambiguous dispatch and missing targets are not resolved
by taking the first matching name. They produce an unsupported/unknown result.

Implementation refinement: the initial source envelope admits only ordinary
unconditional method definitions and integer-literal calls into the selected
closure at top level. Other executable setup is `UNKNOWN`, even a benign local
assignment or printing. Review demonstrated that ignoring such setup admits a
program that changes `Integer#<` through `Integer.prepend(Module.new { ... })`.
This conservative restriction establishes the primitive-binding assumption; it
does not change Ruby behavior. Every admitted top-level definition's required
shape is validated, including definitions outside the selected closure.

Reuse the contract reader and model. Add a focused checker and command-line
driver, without creating a general Ruby IR, a universal visitor, or a new type
inference engine. Share closure logic with the importer only where its binding
rules and failure behavior are actually the same. Preserve existing emitter
behavior and diagnostics when extracting shared code.

Use the inferred types from the actual source analysis. If an uncalled method
has insufficient parameter information, report that limitation. Do not insert
synthetic callers, assume every argument is an integer, or require RBS as a
hidden prerequisite.

## Soundness and failure rules

- Check the selected body and every statically reachable callee. Unrelated
  method bodies do not cause rejection solely because they allocate.
- Treat all syntactic branches in the reachable bodies as potentially executed;
  this phase does not prove a branch unreachable from a sample input.
- Reject allocation, access to GC-managed values or storage, and known runtime
  dependencies. Reject captured cells and mutable global state in the initial
  subset. Do not infer ownership from an integer-looking or pointer-like type.
- Unknown types, unsupported nodes, unresolved/indirect calls and missing
  contracts never count as success. Initially reject recursive call cycles as
  unsupported, while reporting the cycle and terminating the analysis.
- No external function is permitted by its name or prefix alone. Initially
  support no user externs; an effects contract can be designed separately.
- Each accepted primitive needs an explicit rule covering operand types,
  nullability, allocation, runtime dependencies and failure behavior under the
  configuration being checked. A syntax allow-list is not such a rule.
- In particular, integer addition is not automatically core: possible overflow,
  promotion, nil checks and exceptions must be accounted for. Do not switch to
  trap or wrap, erase checks, or infer an i32/i64 boundary to obtain acceptance.
  If the current evidence cannot establish the primitive's contract, report it
  as unknown or reject its known dependency.

## Verdicts

Produce deterministic structured rows with method identity, source location,
reason code and reachable call path, plus coverage counts.

- `CHECKED`: all reachable operations satisfy explicit supported rules for the
  reported analysis configuration. This is a source-analysis conclusion, not a
  claim about an emitted object or arbitrary callers with different types.
- `REFUSED`: a known operation violates a core constraint.
- `UNKNOWN`: analysis evidence or a supported rule is missing.

Exit zero only when the requested method exists and its complete reachable
closure is checked. Refused or unknown results exit nonzero; malformed input or
tool failure must also exit nonzero and remain distinguishable from a semantic
refusal. Empty reports and partial reader output cannot pass.

## Acceptance criteria for this phase

1. A typed, supported scalar method passes without `freestanding_def`, a target
   profile, an FFI declaration or an exported width. Its accepted primitive
   rules are documented and reviewed before implementation claims success.
2. A direct helper call passes under the same rules; an allocating helper fails
   with a root-to-helper path and a source location.
3. An unrelated allocating method does not poison an otherwise checked root.
4. Direct heap use, runtime-dependent failure, unknown types, indirect calls,
   ambiguous methods, unsupported nodes and a recursive cycle cannot pass.
5. A method containing potentially overflowing arithmetic cannot gain a pass
   merely because a small test input does not overflow.
6. Missing roots, missing reader output and malformed analysis data fail. Every
   selected root and reachable callee is accounted for in the report.
7. Paired positive/negative fixtures and targeted mutations demonstrate that
   the call-closure and refusal checks can fail for the intended reasons.
8. Existing core emission and GC/arena checks retain their behavior. Do not rerun
   the entire upstream suite unless vendor or hosted compilation changes.
9. Build and usage work without a predecessor checkout; imported portions have
   revision-pinned provenance and required notices. Documentation is English.

The first verification environment remains Debian with LLVM/Clang 23.1.1.
No tests were run while preparing the original design. The implementation's
actual validation is recorded separately in [provenance](../provenance.md).

## Deferred work

External ABI design, source tier annotations, buffers and ownership, integration
with hosted calls, artifact emission, automatic method selection, additional
targets and arbitrary arena/GC coexistence remain outside this phase. The
paused full-to-core bridge is not resumed by this decision.
