# 0005: Connect selected core methods to a native hosted executable

- Date: 2026-09-10
- Status: Accepted for the initial scalar native slice (2026-09-11).
- Scope: CLI-selected core methods in a macOS arm64 hosted executable.
- Baseline: Extended `7cacc8fb00da941d48814b5d5ca33994b0ad7ace`.

## Result and source interface

Build ordinary Ruby source into one native executable. A command-line selector
chooses an existing method for core compilation; the source needs no new tier
syntax, `freestanding_def`, RBS requirement, or hand-written FFI declaration.
The user approved this direction on 2026-09-10, not a new numeric or failure ABI.

The first acceptance program is:

```ruby
def lower(a, b)
  a < b ? a : b
end

puts lower(7, 3)
```

Implemented product command:

```sh
tools/core/spinel-core-build --source app.rb --core lower -o app
./app
# 3
```

The first version selects one root and its statically resolved helper closure.
The resulting Mach-O arm64 executable includes the normal hosted runtime for
startup and output. Only the core implementation is independent of Spinel
allocation, runtime and GC. This is not a collector-free executable as a whole.

## Components at the proposal baseline

- `tools/mlir/native/lib/Core/Eligibility.cpp` checks a sealed contract model.
  Its current source envelope refuses even the top-level `puts` above. Simply
  removing that restriction would reopen primitive-rebinding false positives.
- `tools/mlir/native/lib/Frontend/Scalar/Importer.cpp` and the freestanding
  emitter provide a declaration-oriented MLIR generation path. Their fixed-width
  boundary and trap policy must not become ordinary Ruby semantics implicitly.
- The pinned hosted compiler emits C and provides FFI/link support. Existing
  FFI casts can lose nil and width information before entering a core function.
  Successful linkage alone cannot establish a valid boundary.
- The current eligibility report identifies checked methods but is not an
  emission authorization tied to all build inputs and the selected target.

## Alternatives and chosen direction

1. Connect the existing analysis contract to MLIR emission and a compiler-owned
   hosted boundary. Selected direction: reuse existing generation while keeping
   the source free of foreign-interface declarations.
2. Emit runtime-independent C first. Possible, but requires another validated
   output path and does not remove the hosted binding and value-boundary work.
3. Require hand-written `freestanding_def` and FFI. Useful as an isolated tool
   probe, but does not meet this feature's ordinary-source acceptance condition.

The CLI selector is a checked requirement: failed eligibility or unsupported
generation fails the build. Never silently run a hosted fallback for a selected
root. Keep the existing C-only full and arena paths available without MLIR.

## Analysis and source-context contract

Use actual inference evidence from the input, not synthetic integer callers.
Inspect every reachable helper and branch, not just the sample execution.
Start with the existing integer comparisons, local scalar assignments and
explicit conditional branches. Arithmetic remains unsupported until its
overflow, promotion and failure contract is separately established.

Extend the admitted hosted envelope narrowly enough to accept the example and
its output operation. Establish binding assumptions for the entire admitted
program, including setup and calls that execute before the root. Unknown setup,
method reopening, reflective dispatch and primitive rebinding fail closed.
Do not classify arbitrary hosted calls as harmless because they are outside
the selected closure. Arbitrary Ruby hosting is not promised by this slice.

Checking, lowering and hosted call selection must consume the same source and
dependency snapshot, compiler revision, flags, target and method identities.
A change between stages invalidates the build. Generated text is not a second
authority for method identity, and source rewriting with regular expressions
is not an integration strategy.

## Call boundary: required investigation before adoption

The first implementation must trace the pinned compiler's inferred integer,
nullable and boxed paths at actual call sites and method returns on arm64.
Do not equate hosted `sp_int` with every legal MLIR i64 bit pattern: the hosted
representation reserves a nil value. An identical width does not prove an
identical value domain.

Preferred first slice: accept only call sites whose analysis proves the admitted
non-null integer domain. Reject nil, floats, strings, unknown and incompatible
call sites at build time. This intentionally avoids inventing a new runtime
raise/trap policy. Whether all required evidence exists is a checkpoint, not an
assumption. If it does not, propose the missing contract before implementation.

Document the exact internal prototype, value domain, symbol identity, call
redirection and return conversion after inspecting the producer. A machine-width
interface derived for this target is internal, not a stable public i64 API.
No i32 narrowing, full-domain i64 claim, trap insertion, or Ruby exception
recovery is authorized by this direction. If a narrow vendor seam is necessary,
propose its exact changes and compatibility checks before moving any pin.

## Artifact and toolchain contract

Use LLVM/Clang/MLIR 23.1.1 with the selected macOS SDK. Record the actual target
triple, data layout and deployment target. The installed toolchain's smoke tests
are not evidence that Spinel code generation works on this host.

The core object must be Mach-O arm64 and retain the complete selected closure
and referenced data. Check undefined symbols and relocations with Mach-O-aware
tools; do not use ELF section assumptions. For the initial scalar slice, expect
no external core dependencies. Any compiler support dependency requires an
explicitly reviewed contract, not a broad symbol-prefix allowance.

Prove that the hosted call reaches the generated core body and that the source
body is not also available as a fallback. A whole executable containing hosted
GC symbols is expected; measure core independence at the core artifact boundary.

## Acceptance and limits

- Clean checkout, documented toolchain and SDK, no predecessor build dependency.
- The ordinary-source example emits a native executable and prints `3`.
- Helper closure, equality and signed boundary selection agree with both the
  default hosted compiler and CRuby over the admitted domain.
- An allocating helper, nil/Float input, unknown binding, primitive rebinding,
  malformed analysis and source changes cannot produce an accepted artifact.
- A missing or deliberately incompatible core implementation fails the build;
  an instrumented link probe confirms the actual selected call path.
- Deliberately injected runtime/allocation dependencies fail the artifact gate.
- Existing eligibility tests, the relevant emission tests, and affected hosted
  and arena behavior remain valid. Run the upstream suite if vendor or hosted
  code generation changes; keep per-host results distinct.

Deferred: arithmetic expansion, buffers, unsigned/floating interfaces, arbitrary
hosted setup, multiple roots, external public APIs, all-core startup, arena/core
composition, other targets and automatic tier inference. The paused bridge is
reference evidence only; this decision does not authorize merging it wholesale.

## Delivery

See the [staged implementation plan](0005-native-core-executable-plan.md).
Milestone 1 is not complete merely because the first executable works. Update
its criteria with measured coverage and explicit remaining limits.

## Adoption record

The user approved pinning and integration after the call-boundary and input
ledger reviews. Spinel is pinned at
`cad0ad148af00b98a3de8a384c18a3cabe15bc1a`. The internal linkage mapping
preserves inferred machine-integer signatures, redirects selected calls and
omits hosted bodies. It is not a public numeric ABI. The admitted integer
domain excludes `INTPTR_MIN`; arithmetic and unknown input producers remain
outside the envelope. The default hosted overflow mode is fixed at `raise`.

The first product supports native Debian x86_64 and macOS arm64. See
[reproduction](../native-core/reproducing.md),
[Mac validation](../native-core/macos-validation.md), and the
[criterion review](../native-core/milestone-1-review.md) for measured coverage.
The accepted subset and deferred work above are unchanged; this status does
not accept all Ruby programs, buffers or a collector-free whole executable.
