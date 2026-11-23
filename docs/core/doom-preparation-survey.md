# Source survey for DOOM CORE preparation

Date: 2026-09-11. This is source inspection for a proposal, not a fresh compiler
or game execution. The proposed contract is [decision 0007](../decisions/0007-doom-core-preparation.md).

## Revisions and evidence boundaries

- Extended: `4ff087b2d6e232798423f37390e44d085f318637`.
- Pinned Spinel: `cad0ad148af00b98a3de8a384c18a3cabe15bc1a`.
- Predecessor `spinel-llvm`: `f8ad13c6d9dc990b116ba1c842c7881232f29585`;
  its vendor is `ecbd0f2a7cd134d5affc2bd705f0f0e83aa82101`.

The predecessor was inspected read-only. No code or experiment archive is
imported by this survey. Its historical tests are useful fixture candidates,
not current acceptance evidence. This document states the relevant findings so
builds and readers do not need a sibling checkout.

## What DOOM actually needs

| current source | requirement exposed | proposed treatment |
|---|---|---|
| `examples/doom/lib/doom/fixed.rb` | widened multiplication, shifts, masks, signed normalization and explicit truncating division | preserve the helper's Ruby operations; validate overflow and divisor edges independently |
| `examples/doom/lib/doom/executor.rb` | indexed resource reads, framebuffer writes, sequential wall/span/masked dispatch | kernels over native buffers; preserve scheduling and fuzz read-after-write order |
| `examples/doom/lib/doom/jobs.rb` | packed wall/span/masked banks, resource offsets, capacity checks and schedule indices | explicit typed buffers and checked offsets; no inferred ownership from an integer offset |
| `examples/doom/lib/doom/game.rb` | many state arrays, thinker links, object slot allocation/reuse, mutable state across ticks | Full-owned fixed storage, CORE updates indices; pool exhaustion is explicit |
| `examples/doom/lib/doom/wad.rb` | file loading, strings, parsed metadata and resource preparation | keep loading/preparation in Full for stage 2; pass prepared immutable bytes/tables |
| `examples/doom/lib/doom/input.rb` | input state to tic command, integer turn history | explicit state buffers/scalars; keyboard and clock remain platform-side |

This table identifies required mechanisms, not a proof that every reachable
method fits the proposed subset. Stage 2 must inventory the actual selected game
and rendering closure. Object methods, temporary arrays, recursive paths and
message creation require refactoring or explicit exclusion; they are not made
CORE by the presence of fixed-capacity arrays elsewhere.

`fixed.rb` already expresses 32-bit normalization with `& 0xffffffff` and signed
adjustment. For signed i32 inputs, its product fits signed i64 before the fixed
point shift. That observation supports a representative kernel; it does not
justify wrapping all Ruby arithmetic or accepting every intermediate in the game.

`JobExecutor` separates resource/job execution from renderer state, but still
uses Ruby objects and storage. It is a useful extraction boundary, not an existing
runtime-free implementation. Fuzz and schedule ordering prevent treating all
pixel work as interchangeable independent parallel jobs.

## Existing Extended machinery

| implementation | reuse opportunity | obligation before reuse |
|---|---|---|
| `tools/mlir/native/lib/Core/Eligibility.cpp` | closure and eligibility diagnostics | admit new nodes only with actual numeric/memory rules; absence of runtime symbols alone is insufficient |
| `tools/mlir/native/lib/Core/Input.cpp` | per-face input ledger and contract loading | preserve complete input validation and refusal of unfulfilled loads |
| `tools/mlir/native/lib/Frontend/Scalar/FreestandingSubset.cpp` | buffer indexing recognition and allocation refusals | this recognition is declaration-based; it does not establish capacity, lifetime or aliasing |
| `tools/mlir/native/lib/Frontend/Scalar/MlirGen.cpp` | arithmetic, control flow and typed buffer lowering | existing hosted raise and freestanding trap branches have different semantics; add no implicit policy substitution |
| `tools/mlir/native/lib/Freestanding/Declaration.cpp` | explicit declaration validation | current positional parameter/length rules are not the proposed named contract |
| `tools/mlir/native/lib/Freestanding/UndefGate.cpp` | target artifact inspection | retain exact dependency policy for the new CORE boundary, not broad symbol prefixes |

Inspection of `MlirGen.cpp` finds explicit separate arithmetic modes and buffer
metadata including `lenIndex`. The existence of those implementations reduces
the need for new lowering infrastructure. It does not show that the new status
ABI, full i64 domain or host bridge are implemented. They are not claimed here.

## Predecessor lessons to preserve or improve

These paths are provenance identifiers at the predecessor revision above, not
local links or build inputs:

- `tools/freestanding/README.md`: explicit widths, buffer direction, a positional
  `:len` (C `int32_t`), trap/unchecked bounds and platform declarations. Keep the
  separation of boundary types from Ruby inference. Improve length association
  and address-width validation; omit unchecked access from the first boundary.
- `docs/experiments/E077_freestanding_data_abi.md`: buffer kernels and independent
  C harnesses exercise more than scalar inference. Recreate small behavioral
  fixtures here rather than importing that research directory.
- `docs/experiments/E095_extern_buffer_views.md`: subview and external buffer
  composition expands lifetime, overflow and aliasing obligations. Defer that
  surface until complete-buffer borrows work; offsets do not grant pointer escape.
- `docs/experiments/E162_mlir_freestanding_importer.md`: recorded narrow-integer
  ABI extension defects, export/internal symbol collisions and hosted nil-raise
  leakage into freestanding. Include corresponding ABI and dependency controls
  when adapting code; historical fixes are not evidence at Extended's pin.

The most valuable reuse is lowering and adversarial fixtures behind a checked
contract. Copying a frontend switch would also copy assumptions about errors,
foreign memory and the caller that the hosted CORE bridge must establish itself.

## Implementation order after contract approval

The owner approved decision 0007 on 2026-09-11. Execute this sequence through the
[implementation plan](../decisions/0007-doom-core-preparation-plan.md):

1. Freeze the contract schema and generated C header with positive and negative
   schema/ABI fixtures. Specify version, parameter-name binding and status layout.
2. Implement checked scalar arithmetic/control flow and direct helper closure;
   verify successful results against CRuby and failures with the C harness.
3. Implement native buffer entry checks, access checks and failure propagation;
   validate aliasing, lengths, result storage and partial-write behavior.
4. Connect a copying Full adapter and package the object/header/contract from one
   snapshot. Reject mismatched artifacts before link or execution.
5. Deliver the three representative capabilities in decision 0007, each with
   executable reference fixtures and rejection cases. Record the remaining DOOM
   closure gaps instead of expanding the milestone without review.
6. Validate independently on macOS, retain existing CORE/DOOM checks, and document
   supported usage. Only then start the complete CORE DOOM migration design.

Debian owns implementation; Mac owns review and host validation. The linked file-level execution plan follows the approved numeric, memory and
failure contracts. No compiler patch or pin movement is assumed by this sequence.

## Future game acceptance

The existing Full DOOM is a regression reference for the extraction. The fixed
C reference provides an independent game oracle with explicitly recorded limits;
see [frame baseline](../doom/frame-divergence-baseline.md) and
[Mac acceptance](../doom/mac-acceptance.md). First require CORE extraction to agree
with Full on every selected state and framebuffer byte. Then retain the existing
independent comparison and its exact declared differences. Do not broaden a
C-reference allowance to hide a new CORE-versus-Full discrepancy.

## Review corrections to the proposal

Source review after the first draft confirmed the existing CORE checker lacks
contracts for bitwise operators and `abs`, refuses parentheses, and selects
unconditional top-level methods rather than `Doom::Fixed` singleton methods.
The proposed workload therefore uses complete extracted helpers with explicit
adaptations, and the new checker must admit the listed forms deliberately.
Existing scalar refusal behavior is not silently changed.

A reviewer reported `p mul(2, 3)` was rejected and inferred that inference
witnesses could not be supplied at all. That broader conclusion does not follow:
`Core/Eligibility.cpp` has `isInferenceCall` and `admittedOutputCall`, admitting
direct closure calls and a restricted `puts` form. Caller-free kernels and
foreign memory facts still motivate explicit contracts, but the proposal does
not rely on a general inference catch-22.

The predecessor's numeric trap categories differ from the proposed statuses;
its signed i32 positional lengths differ from the proposed per-buffer u64
counts. The proposal now explicitly requires category mapping, checked narrowing,
unsigned buffer load extension and a separate status path without nil tests or
external trap calls. These are implementation obligations, not existing support.

Historical DOOM arithmetic comparison counts reported in review were not rerun
for this design and are not stage-1 acceptance results.
