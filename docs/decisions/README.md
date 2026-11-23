# Design decisions

Record decisions that establish or change user-visible semantics, an ABI, dependency ownership, or a long-lived architectural boundary. Do not create a decision record for routine edits or copy every predecessor experiment into this directory.

Use `NNNN-short-title.md`, beginning with `0001`. Check both tracked and untracked files before choosing a number.

A record should contain:

```markdown
# NNNN: Decision title

- Date: YYYY-MM-DD
- Status: Proposed | Accepted | Superseded
- Scope: The behavior or boundary this decision governs

## Context

The concrete problem and constraints.

## Options

The relevant alternatives and their tradeoffs.

## Decision

The selected contract, or the proposal awaiting approval.

## Validation

Evidence required to establish the decision and its known limits.

## Consequences

Compatibility effects, follow-up work, and superseded decisions.
```

Mark a record Accepted only after the project owner has approved the decision. Approval of a design does not itself mean its implementation or validation is complete.

An Accepted record may gain a dated, clearly labelled clarification section appended at the end when implementation narrows or completes an interface without changing the accepted direction — a delivered tool name, a spelling the record left open, a limit found while building it. Anything that changes what was accepted needs a new record instead, and the original stays as it was approved.

Link imported design rationale to a recorded source revision and include enough explanation here to avoid requiring access to a private repository.

## Index

Implementation plans sit beside the record they belong to.

- [0001: Core boundary declaration, failure policy, and the route to a standalone object](0001-core-boundary-declaration-and-failure.md)
- [0003: Choosing between a collected heap and a process-lifetime arena](0003-gc-and-arena-build-modes.md), revised 2026-11-01: no collector through upstream `--gc=none`
- [0004: Check core eligibility independently of an exported ABI](0004-core-eligibility-checker.md)
- [Core Eligibility Implementation Plan](0004-core-eligibility-implementation.md)
- [0005: Connect selected core methods to a native hosted executable](0005-native-core-executable.md)
- [Native Core Executable Implementation Plan](0005-native-core-executable-plan.md)
- [0006: Import the CPU DOOM application on the hosted path](0006-doom-hosted-import.md)
- [Hosted CPU DOOM Import Implementation Plan](0006-doom-hosted-import-plan.md)
- [0007: Prepare allocation-free CORE computation for DOOM](0007-doom-core-preparation.md)
- [DOOM CORE Preparation Implementation Plan](0007-doom-core-preparation-plan.md)
- [0008: Move the existing DOOM computation into CORE](0008-doom-core-migration.md)
- [DOOM CORE migration implementation plan](0008-doom-core-migration-plan.md)
- [0009: A structured test harness for the DOOM CORE migration](0009-doom-core-test-harness.md)
- [0010: A resource and realtime contract for CORE entries](0010-core-resource-contract.md)
- [0011: Core IR and IR-framework evaluation (cuda-oxide / Pliron)](0011-core-ir-and-ir-framework-evaluation.md)
- [0012: The shared semantic layer, and freestanding as its second consumer](0012-shared-semantic-layer-and-the-second-consumer.md)
- [0013: Naming the shared semantic layer, and the conditions that would reopen a Core IR](0013-semantic-layer-followup-and-core-ir-triggers.md)
- [0014: CORE applications on Zephyr](0014-core-applications-on-zephyr.md)
- [CORE applications on Zephyr: implementation plan](0014-core-applications-on-zephyr-plan.md)
- [0015: Integer arithmetic in the native scalar core slice](0015-core-scalar-arithmetic.md)
- [0016: Call-duration mutable String borrowing through FFI](0016-ffi-mutable-string-borrow.md)
- [0017: The compiler runtime of the bare-metal Cortex-M33 lane](0017-baremetal-compiler-runtime.md)
- [0018: Narrow buffer elements for DOOM's CORE storage](0018-narrow-buffer-elements.md)
- [0019: The integer width of freestanding and CORE code follows the target](0019-target-integer-width.md)
- [0020: Oracles run only with ALLOW_ORACLE=1, as tests/ORACLES.tsv lists them](0020-oracle-gate.md)
- [0021: DOOM's CORE entries on FRDM-IMXRT1186](0021-doom-core-on-frdm-imxrt1186.md)
- [0022: Explicit 32-bit word arithmetic in CORE, and DOOM at 32 bits](0022-core-word-arithmetic.md)
- [0023: DOOM's board lane on the FRDM-IMXRT1186's Cortex-M7](0023-doom-on-the-cortex-m7.md)
- [0024: DOOM's frames from the FRDM-IMXRT1186 over the network](0024-doom-frames-over-the-network.md)
- [0025: Playing DOOM on the FRDM-IMXRT1186 from a host keyboard](0025-doom-play-over-the-network.md)
- [0026: Owning the CORE lowering, and the shared facts it reads](0026-owning-the-core-lowering.md)
- [0027: Both FRDM-IMXRT1186 cores from Spinel, and a declared channel between them](0027-amp-two-core-channel.md)
- [0028: A doorbell over the MU for the channels between the FRDM-IMXRT1186's cores](0028-mu-doorbell.md)
- [0029: Texture sampling and a varying alpha in tools/shader](0029-shader-textures.md)
- [0030: Passing an attribute through as a varying in tools/shader](0030-shader-attribute-pass-through.md)
- [0031: Ruby compute kernels to WebGPU and CUDA through MLIR](0031-gpu-compute-route.md)
- [0032: Ruby to the Neutron NPU through IREE on the FRDM-MCXN947](0032-neutron-npu-route.md)
- [0033: Writing the Neutron NPU's model in Ruby](0033-npu-def.md)
- [0034: The STM32MP257 NPU through TFLite and the VX delegate](0034-stm32mp257-vx-route.md)
- [0036: A per-slot record of the collector, for watching it work](0036-gc-event-record.md)
- [0037: Full on a Cortex-M33 with no RTOS](0037-bare-metal-full.md)
- [0038: Full on Zephyr's POSIX layer, and why not in user mode](0038-zephyr-posix-full.md)
- [0039: One arena instance per isolate, written back before each request](0039-arena-instance-reuse.md)
- [0041: Ideas from Goose for CORE: inlined blocks, a bounded data stack, slot pools](0041-goose-ideas-for-core.md)
- [0041: results, stage by stage](0041-results.md)
- [0042: Bitwise, shift, `abs` and `**` operators in every CORE route, with explicit wrapping and unsigned forms](0042-core-bit-and-power-operators.md)
- [0043: Buffers that live across calls in an MPC plugin: owned by the plugin instance](0043-mpc-instance-buffers.md)
- [0044: A freestanding helper that takes a buffer lent by its caller](0044-freestanding-helper-buffers.md)
- [0045: Dedicated buffer classes in place of the Array spelling](0045-buffer-classes.md)
- [0047: The bpf-mlir commit comes from SOURCE_VERSION, in a release and in a clone](0047-bpf-mlir-commit-from-source-version.md)
- [0048: The project licence is Apache-2.0 WITH LLVM-exception](0048-project-licence.md)
