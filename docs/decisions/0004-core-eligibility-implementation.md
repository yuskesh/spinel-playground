# Core Eligibility Implementation Plan

> Execute inline with the executing-plans skill. Do not delegate this work.

**Goal:** Check a selected ordinary Ruby method and its reachable direct callees
without exporting an ABI or changing its arithmetic.

**Architecture:** Reuse `ContractModule` and `readContract`. A separate analysis
library owns eligibility rules and reports; a small driver obtains the four
reader faces and prints TSV. Existing freestanding emitters remain unchanged.

**Tech stack:** C++17, the existing LLVM support library, CMake, Python 3 for
black-box acceptance checks. No new production dependencies.

**Spec:** [Decision 0004](0004-core-eligibility-checker.md).

## Constraints

- Keep Spinel pinned at `5bc45ec19a372c6f4da29485a7ce35c81b9751cc`.
- Do not modify the vendor or predecessor sources, integer policy, or ABI.
- Unknown evidence cannot pass. Select one uniquely identified top-level method.
- No extern contracts, recursion, source annotations or automatic type seeding.
- Debian LLVM/Clang 23.1.1 is the primary validation environment; local checks
  with another toolchain must be recorded separately.

## Task 1: End-to-end source admission

Files: `include/spinel-mlir/Core/Eligibility.h`, `lib/Core/Eligibility.cpp`,
`lib/Core/CMakeLists.txt`, `tools/spinel-core-check/{main.cpp,CMakeLists.txt}`
under `tools/mlir/native/`; `tests/core-eligibility/run.py` and fixtures.

Interface: `checkEligibility(const ContractModule &, StringRef)` returns a
report containing diagnostics, checked-method counts and a success predicate.
The driver accepts `SOURCE --method NAME [--typedump PATH]`, runs the reader,
seals its output and prints the report. Usage/reader failures exit 2, analysis
refusals or unknown evidence exit 1, complete admission exits 0.

- [x] Add a black-box test for `def pick(a,b); a < b ? a : b; end; pick(1,2)`.
  Assert a CHECKED row and a nonempty coverage summary, not merely exit zero.
- [x] Run `python3 tests/core-eligibility/run.py`; observe the missing checker
  failure before adding the driver.
- [x] Implement contract loading and scalar rules: non-null integer parameters
  and locals, representable integer literals, local read/write, comparisons,
  and conditional selection. Require evidence for types and parameter shape.
- [x] Wire the new targets into existing CMake and build.sh. Build with
  `LLVM_PREFIX=/path/to/llvm tools/mlir/native/build.sh` and rerun the test.

## Task 2: Reachability and closed-world refusal

- [x] Extend fixtures with a helper chain, an allocating helper, an unrelated
  allocating method, arithmetic, an unresolved call, a cycle, duplicate methods,
  optional arguments, heap arguments, captured/global state and missing types.
- [x] Before adding each rule, assert its intended reason and path in the
  failing test. A generic failure is not sufficient for these assertions.
- [x] Index actual top-level definitions and bind them through scope identity;
  reject ambiguity. Traverse all syntactic branches. Track the active call path
  and visited methods; terminate cycles with UNKNOWN.
- [x] Treat arithmetic with unproved overflow/failure behavior as UNKNOWN,
  explicit heap/state operations as REFUSED, and unsupported forms as UNKNOWN.
  Do not reuse the predecessor external-function allow-list.
- [x] Include empty/broken reader output and nonexistent roots. Check every
  subprocess exit and reject partial reports.
- [x] Rerun acceptance and targeted mutations: replacing the violating helper
  by a conforming helper must break the negative assertion; disabling callee
  traversal must break its closure and coverage assertions.

## Task 3: Documentation and compatibility

- [x] Add `tools/core/README.md` documenting the exact primitive rules, TSV
  columns, source-analysis scope, UNKNOWN behavior, and reproducible commands.
- [x] Update `docs/building.md` and `docs/provenance.md` with the new tool and
  validation actually performed. Record that object emission is not added.
- [ ] Run the existing core and GC/arena acceptance checks when the configured
  toolchain/runtime are available; do not substitute another host for Debian.
- [x] Check whitespace, local documentation links and the final source diff.
  Preserve the paused bridge, original checkout and dependency pin.

No merge or push is part of this plan.

## Execution record

Tasks 1 and 2 are implemented and locally verified with 32 black-box tests.
Targeted mutations detected callee traversal and heap-refusal removal. Independent
review found primitive rebinding through top-level setup and missing fields on
unrelated definitions; both have regression controls and are fixed.
Task 3 documentation and local validation are complete; its Debian/LLVM 23.1.1
compatibility checks remain pending. No merge or push was performed.
