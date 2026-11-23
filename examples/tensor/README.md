# examples/tensor — the Ruby tensor surface on the CPU and the Apple GPU

Programs written in Ruby, built into a single binary that carries its `.vmfb`
and runs on the CPU (`local-sync`) or the Apple GPU (`metal`). They use the
surface in [tools/tensor](../../tools/tensor/README.md) (`tensor_def`,
`tensor_extern`, `assign!`). **`vendor/spinel` needs no change.**

| Example | Surface | What it shows |
|---|---|---|
| `dense-relu/` | `tensor_def` | declaring your own kernels and running them on both devices; `reduction: :default` against `:fixed_tree` |
| `fusion/` | `assign!` fusion | one host statement becomes one dispatch |
| `mnist/` | `tensor_extern` | a model trained in JAX, brought in as StableHLO, classifying MNIST |

Each runs with `./build.sh && ./run.sh`; `run.sh` uses both devices by default.

## Prerequisites

- The Spinel compiler: `make -C vendor/spinel deps && make -C vendor/spinel -j8`.
- The native importer: `tools/mlir/native/build.sh`.
- IREE 3.11.0: `IREE_SRC`, `IREE_BUILD` (a runtime-only build) and
  `IREE_COMPILE`, all from the same commit. The installation, including how to
  get `iree-compile` without Python, is in
  [the installation record](../../docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md).
- For `metal`, nothing more: the Metal kernels embed their shader source, so no
  Metal toolchain is needed on the build machine.
- For `mnist`, the MNIST test set (about 11 MB), which `run.sh` downloads and
  checks by sha256.

`env.sh` reads these and fails loudly when one is missing; an optional
`iree.env` (gitignored) can hold local values.

## Devices

`local-sync` is the CPU, synchronously; `local-task` is the CPU with a task
pool; `metal` is the Apple GPU. The device name is the only place a GPU is named
in a program.

## dense-relu

Three `tensor_def`s: `dense_relu` (matvec, add and relu in one dispatch),
`sumsq` with the default reduction order, and `sumsq_ft`, the same body declared
`reduction: :fixed_tree`. The fixed tree is bitwise identical on CPU and Metal;
the default order is not expected to be, and `dense_relu`'s hash differs too,
because a matvec is a reduction and is always `:default`.

## fusion

`y.assign!(x * alpha + y)` in the program is rewritten into one kernel
(`app.fused.rb` is what gets compiled). The run reports one invocation fused
against two for the same computation as a chain. On CPU and Metal the hashes are
the same, since the expression uses only `*`, `+` and `relu`. Fusing changes some
f32 bits (an FMA forms in the fused kernel and not across two dispatches); both
answers are correct f32.

## mnist

A 784-128-10 MLP (`model/mnist_mlp.mlir`, weights included) and a preprocessing
module (`model/mnist_scale.mlir`), both StableHLO exported from JAX, are
compiled by `iree-compile` and called through `tensor_extern`, with
`--extern-check` comparing each declaration with the real module. The program
classifies the 10,000-image test set in batches of 100 on each device. No JAX
and no Python are needed to build or run it.

The scripts that trained and exported the model are Python and are not in this
repository; provenance names them in spinel-llvm.

## Checked

`tests/tensor/run.sh` builds and runs each example on both devices. It checks
the claims above: the fixed tree's cross-device equality, fusion's invocation
counts and cross-device hashes, and mnist's full test set on each device with
an accuracy floor of 0.9 against a pipeline broken to chance.

Each program's comparison with a second implementation (an f64 reference
written in plain Ruby) is an oracle. It runs only with `SPINEL_ORACLE=1`, and
the test never sets it.
