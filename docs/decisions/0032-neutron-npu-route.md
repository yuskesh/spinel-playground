# 0032: Ruby to the Neutron NPU through IREE on the FRDM-MCXN947

- Date: 2026-11-10
- Status: Accepted by the owner on 2026-11-10.
- Scope: `tools/npu/`, `tools/app/zephyr/v4.5.0/npu.tsv`, `tests/npu/`, and one
  build-time hook in `tools/tensor/sp_tensor_shim.c`.

## Decision

A hosted Spinel program declares one quantized model with `npu_extern`, and calls
it inside `Tensor.device`. `tools/npu/spinel-npu` runs NXP's converter, takes the
microcode, weights and kernels from the NeutronGraph as C arrays, generates an
IREE module whose dispatch calls `neutronRunBlocking` through a static import,
and builds a Zephyr image.

```
app.rb -> npu_extern -> tflite -> neutron-converter -> NeutronGraph
                                                        |- microcode, weights, kernels (C arrays)
app.rb -> spinel -c -> runtime (hosted, GC) ------------+
          iree-compile (static dispatch) ---------------+-> Zephyr image -> IREE -> neutronRunBlocking -> NPU
```

## Choices

- **Hosted, not core.** The owner chose the hosted runtime on the MCU, with the
  existing `Tensor` surface. It builds without a vendor change, following
  `tools/wasm`. Decision 0021 (DOOM is core only on its board) is unaffected.
- **GC on, with smaller tables.** Long-running programs need the collector, and
  the runtime's default tables do not fit 320 KB. The table sizes are build
  defines. The first collection threshold is set through `getenv`.
- **No new IREE backend.** The NPU is reached from a dispatch through
  `hal.import.static`. The converter stays NXP's, and is the only entry to the
  NPU, which has no public instruction set.
- **Quantized TFLite is the input now.** Writing the model in Ruby came later, in
  [decision 0033](0033-npu-def.md).
- **Zephyr v4.5.0 for this lane only.** Version 4.4.2 has no Neutron support, and
  the RT1186 lanes stay on it. `tools/app/zephyr/v4.5.0/npu.tsv` pins the pair of
  converter and blobs, and the tool stops on any difference.
- **The rest of a model is not run silently.** Operators outside the NeutronGraph
  need `partial: true`, and the function then returns the graph's own output.
- **The shim gets one hook.** `SP_T_STATIC_DEVICE` replaces the driver registry
  with a device the program builds. Without the define nothing changes.
- **The tensor table is written by the tool.** The importer accepts only `:mat`
  for `tensor_extern`, and an NPU input is rank 4. Widening the importer was not
  needed for one generated row.

## What this repository holds

Code and instructions only. The blobs, the converter and converted models are
closed, and are taken from the environment. The converter's licence
(LA_OPT_NXP_Software_License v63, section 3.8) restricts publishing reports on
its use, so by the owner's decision NPU results, such as conversion statistics
and speed, are not recorded here.

## Acceptance

`tests/npu/run.sh`: the refusals, an accepted control, an image build, and a
console capture of that image from the board. The expected values are by hand: a
picture of a ship is class 8, and the output changes with the input. 2000
inferences run under the collector. No oracle is used.
