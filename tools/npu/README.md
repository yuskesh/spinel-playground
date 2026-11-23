# spinel-npu: Ruby to IREE to the Neutron NPU

`tools/npu/spinel-npu` builds a hosted Spinel program for the FRDM-MCXN947. The
program calls a quantized model on the eIQ Neutron NPU through the existing
`Tensor` surface and IREE. See [decision 0032](../../docs/decisions/0032-neutron-npu-route.md).

```ruby
require_relative "spinel/tensor"
npu_extern :classify, tflite: "model.tflite",
           input: [:i8, 1, 32, 32, 3], output: [:i8, 1, 12], partial: true
require_relative "npu.gen"

Tensor.device("local-sync", "@npu") do
  x = Tensor.ten4(:i8, 1, 32, 32, 3)
  y = Tensor.mat(:i8, 1, 12)
  x.store_bytes(pixels)
  classify(x, y)
  puts y.to_bytes.getbyte(0)
end
```

```sh
tools/npu/spinel-npu app.rb -o build            # build/zephyr/zephyr/zephyr.bin
tools/npu/spinel-npu app.rb -o build --check-only
```

A program holds exactly one `npu_extern` or `npu_def`. `tflite:` is a quantized int8 model,
or one already converted. `partial: true` accepts that operators outside the
NeutronGraph are not run: the function returns the NeutronGraph's own output.
`classify` then needs the post-processing written in Ruby.

## Writing the model in Ruby

`npu_def` replaces `npu_extern`. Its block names the operators, and the tool
writes the int8 TFLite model and gives it to the converter:

```ruby
W1 = Array.new(8) { Array.new(9, 100) }

npu_def :sides, input: [:i8, 1, 8, 8, 1], quant: [1.0 / 256, -128] do
  conv2d 8, kernel: 3, weights: W1, weight_scale: 0.01, bias: [0] * 8,
            quant: [0.08, -128], activation: :relu
  max_pool 2
  flatten
  fully_connected 2, weights: W2, weight_scale: 0.01, bias: [0, 0], quant: [0.1, 0]
end
require_relative "npu.gen"
```

The operators are `conv2d`, `max_pool`, `avg_pool`, `flatten` and
`fully_connected`. Padding is `VALID`. `input:` is `[:i8, 1, height, width,
channels]`. `quant:` is `[scale, zero point]` of an operator's output, and a pool
or `flatten` keeps its input's. Weights are integers from -127 to 127 with zero
point 0, in TFLite's order: `conv2d` is output channel, row, column, input
channel, and `fully_connected` is unit, then input. Nested arrays are flattened.
`bias:` is one int32 for each output channel or unit, in steps of input scale
times `weight_scale`.

The declaration is evaluated by CRuby when the program is built, so weights can
be any expression. Constants it reads must be assigned at the top level before
it, each on its own line and not as a heredoc. A constant only the declaration
reads does not reach the image. Training
and reading weights from a file are out of scope.

The converter decides what reaches the NPU. `npu_def` has no `partial:`: if any
operator stays outside the NeutronGraph, the tool stops.

## What it refuses

The tool stops, and never falls back to the CPU, when the model has no
NeutronGraph or more than one, the graph has more than one input or output,
an `npu_def` names another operator or gives weights, biases or quantization
that do not fit, the declared shapes or types differ from the model's, the NPU's scratch, profile
and debug tensors are not the expected layout, operators are left
outside the graph without `partial: true`, or the converter, Zephyr, hal_nxp, the
blobs or the SDK differ from `tools/app/zephyr/v4.5.0/npu.tsv`. It also stops
when `-o` is inside this repository and git does not ignore that path.

An already converted model skips the converter, so the converter's version is
not checked for it. Nothing in such a file says which converter produced it;
the person supplying it must make sure it matches the pinned blobs.

## What it needs

NXP's converter and blobs are closed and are not in this repository. Neither
are converted models. Everything comes from the environment:

| Variable | Contents |
|---|---|
| `NEUTRON_SDK_PYTHON` | Python of a venv with `eiq-neutron-sdk==3.0.0` from `https://eiq.nxp.com/repository`. Its wheels need Linux x86_64 and Python 3.10 to 3.12 |
| `ZEPHYR_WORKSPACE` | A west workspace at v4.5.0 with `tflite-micro` and `west blobs fetch hal_nxp` |
| `ZEPHYR_SDK_INSTALL_DIR` | Zephyr SDK 1.0.1 |
| `IREE_COMPILE`, `IREE_SRC` | iree-compile and the IREE 3.11.0 source tree |
| `IREE_M33_BUILD` | The output of `tools/npu/build-iree-m33.sh`, which also needs `IREE_HOST_BIN_DIR` |

Ruby 3.3 or newer runs the tool, which uses its bundled Prism.
`vendor/spinel/bin/spinel` must be built first. The converter's licence
(LA_OPT_NXP_Software_License) limits use to development for NXP products, and
section 3.8 limits reports about its use. For that reason this repository
records how to run the lane and does not record NPU results.

## STM32MP257F-DK

`--board stm32mp257f-dk` builds the same Ruby program as an aarch64 Linux
executable. The IREE dispatch calls TFLite 2.18 with the VX delegate, and the
delegate drives the GCNano NPU through TIM-VX and OpenVX. See
[decision 0034](../../docs/decisions/0034-stm32mp257-vx-route.md).

```sh
tools/npu/spinel-npu --board stm32mp257f-dk tests/npu/sides.rb -o build   # build/app
```

There is no converter on this route. The tool checks the declaration against the
model. The rest is checked when the program starts, on the board: it stops if
the delegate cannot be loaded, or if it leaves any operator to TFLite, so a model
that does not fit never falls back to TFLite's CPU kernels. What runs inside the
delegate is the driver's choice and is not checked. `partial:` is refused. The delegate is
`libvx_delegate.so.2` from the library path, or the file named by
`SPINEL_NPU_DELEGATE`.

| Variable | Contents |
|---|---|
| `IREE_COMPILE`, `IREE_SRC` | iree-compile and the IREE 3.11.0 source tree |
| `IREE_STM32MP2_BUILD` | The output of `tools/npu/stm32mp2/build-iree.sh`, which also needs `IREE_HOST_BIN_DIR` |
| `STM32MP2_CROSS` | The OpenSTLinux cross tools' prefix, ending in `aarch64-ostl-linux-` |
| `STM32MP2_SYSROOT` | A sysroot with glibc, libstdc++ and the TFLite 2.18 headers and library |

The board needs TFLite, the delegate and TIM-VX on its library path, as X-LINUX-AI
builds them, and ST's OpenVX libraries. The OpenVX libraries are under ST's and
Vivante's terms and are not in this repository.

`ruby tests/npu/stm32mp2/run.rb` checks the refusals and builds the program. To
check a board run, run `tests/npu/stm32mp2/board.sh` there next to the built `app`,
`nodelegate.so` and `onenode.so`, and give the capture as `NPU_STM32_CONSOLE_LOG`, keeping the
same `NPU_WORK` as the build.

## Limitations

- One model per program, one input and one output tensor.
- The hosted runtime refuses nothing at build time for the FRDM-MCXN947. Files,
  sockets, processes and fibers fail at run time on this board.
- A driver error stops the program with a kernel panic, because a static import
  has no error path into IREE.
- `clock_gettime` answers the board's uptime for every clock, so `Time.now` is
  time since boot, not the date.
- A full GC table falls back: minor collections become full ones, or the table
  grows on the heap. That behaviour is read from the runtime source and is not
  exercised by the tests.

## Tests

`sh tests/npu/run.sh` checks every refusal and builds an image. It takes Zephyr's
sample model and picture from `ZEPHYR_WORKSPACE`. Set `NPU_CONSOLE_LOG` to the
board's console capture of that image to check the run, and `NPU_DEF_CONSOLE_LOG`
to the capture of the image built from `tests/npu/sides.rb`; the image prints a hash
of its program and model, and the check stops on a capture of another one. Expected values are by
hand: the picture is a ship, and class 8 of CIFAR-10 is a ship.
