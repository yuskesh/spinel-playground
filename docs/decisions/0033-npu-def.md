# 0033: Writing the Neutron NPU's model in Ruby

- Date: 2026-11-10
- Status: Accepted by the owner on 2026-11-10.
- Scope: `npu_def` in `tools/npu/spinel-npu`, `tools/npu/tflite_write.rb`,
  `tests/npu/`. It extends [decision 0032](0032-neutron-npu-route.md).

## Decision

A program may declare its model with `npu_def` instead of `npu_extern`. The block
names int8 operators, weights and quantization. The tool writes a TFLite file
from it, and the rest of the route is the one in decision 0032: NXP's converter,
the same model checks, and the same image.

## Choices

- **TFLite is still the format.** NXP's converter is the only entry to the NPU and
  it reads TFLite, so the declaration becomes that file. No other format is added.
- **Five operators.** `conv2d`, `max_pool`, `avg_pool`, `flatten` and
  `fully_connected`, with `VALID` padding. Anything else, and weights, biases or
  quantization that do not fit, stop before the converter runs.
- **Weights are Ruby values, evaluated at build time.** CRuby runs the declaration
  and the top-level constants it reads. Training and weight files are out of scope.
- **Quantization is written, not inferred,** including `weight_scale:`, because the
  bias scale depends on it.
- **The whole model runs on the NPU.** `npu_def` has no `partial:`. If the converter
  leaves an operator outside the NeutronGraph, the tool stops.

## Acceptance

`tests/npu/run.sh`: the refusals, the model read back through the lane's reader,
an image build, and a board capture of `tests/npu/sides.rb`. Its expected values
are by hand, with the arithmetic in the file, and its output changes with the
input. No oracle is used. The converter and the blobs stay outside this
repository, and the checks that need them skip without them.
