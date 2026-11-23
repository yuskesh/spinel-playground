# tools/tensor — the Ruby tensor surface

The surface and the seam that turn a program written only in Ruby into one
binary that carries its generated `.vmfb` and runs on the CPU or the Apple GPU.
Ported from spinel-llvm `463d49dd`; see [provenance](../../docs/provenance.md).

- **The surface**: `spinel/tensor.rb`, the `tensor_def` / `tensor_extern`
  declaration DSL and the `Tensor` class, loaded with
  `require_relative "spinel/tensor"`.
- **The seam**: `sp_tensor_shim.c`, the bridge to the IREE runtime's C API.
  Dispatch goes through a **generated table of N entries** (`sp_tensor_table.h`).
- **The front**: `spinel-tensor`, which runs the native importer
  (`tools/mlir/native/build/bin/spinel-tensor-import`) and then `iree-compile`
  once per backend. It stands in for spinel-llvm's `spinel-mlirgen --tensor`.
- **IREE**: 3.11.0, compiler and runtime from the same commit. See
  [the installation record](../../docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md).

## Two worlds

**The kernel world** is a `tensor_def` declaration and the one `def` it marks.
The body is **a declaration, not code that runs**: the importer reads it from
the AST and turns it into `linalg` ops.

```ruby
# nn_kernels.rb -- the importer's input; the program does not require it
require_relative "spinel/tensor"

tensor_def :dense_relu, dtype: :f32, params: [:mat, :vec, :vec, :vec], dest: 3
def dense_relu(w, b, x, y)
  y.assign((w.matvec(x) + b).relu)      # matvec + add + relu = 1 dispatch
end
```

**The host world** is everything else: ordinary Ruby.

```ruby
# nn_prog.rb
require_relative "spinel/tensor"
require_relative "nn_kernels.gen"        # the generated dispatch defs

Tensor.device("metal", "nn_kernels_metal.vmfb") do
  w = Tensor.of_mat(:f32, rows, cols, wflat)   # the shape is declared; data is always flat
  b = Tensor.of(:f32, rows, bflat)
  x = Tensor.of(:f32, cols, xflat)
  y = Tensor.vec(:f32, rows)
  dense_relu(w, b, x, y)
  y.to_f32_a                                   # the only device-to-host copy
end
```

The kernel file and the program are separate files. The program reads the
generated dispatch, never the declarations; requiring the kernel file by
mistake makes `Tensor#*` and friends raise `TensorError`, so nothing is
computed silently on the host.

## Building

```sh
tools/tensor/spinel-tensor nn_kernels.rb --tensor \
    -o nn_kernels.mlir \
    --emit-table sp_tensor_table.h \
    --emit-ruby  nn_kernels.gen.rb \
    --iree-compile "$IREE_COMPILE" --vmfb nn_kernels     # nn_kernels_{cpu,metal}.vmfb

"$CC" -O2 -c tools/tensor/sp_tensor_shim.c -o sp_tensor_shim.o $IREE_CFLAGS -I.
spinel nn_prog.rb -o nn_prog --link sp_tensor_shim.o $IREE_LINK
```

`examples/tensor/env.sh` defines `$IREE_CFLAGS` and `$IREE_LINK`. The shim has
to be compiled with the same defines as the runtime.

Metal kernels are compiled with `--iree-metal-compile-to-metallib=false`: the
shader source is embedded and compiled on the device at load time, so the build
machine needs no Metal toolchain. A program whose lowering depends on the
device (`pad_via: :auto`) gets one module per device from the importer
(`OUT.cpu.mlir`, `OUT.metal.mlir`), and each backend is compiled from its own.

`NAME_cuda.vmfb` is written too when `iree-compile` has the `cuda` backend, from
the GPU profile's module. It runs with `Tensor.device("cuda", ...)` on an IREE
runtime built with the CUDA driver; the
[installation record](../../docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md)
has the build. The importer emits `fastmath<contract>`, which on CUDA contracts
a multiply and an add within one kernel into `fma.rn`. A fused statement, or a
resample at a non-dyadic size, can then round differently from the CPU (by at
most 1 in a byte in `tests/tensor`'s 1620x911 case). The two-kernel chain and
`reduction: :fixed_tree` stay bitwise identical.

## The surface's vocabulary

### Declarations

| Spelling | Meaning |
|---|---|
| `tensor_def :name, dtype: :f32, params: [...], dest: N` | destination-passing: writes argument N and returns it |
| `tensor_def :name, dtype: :f32, params: [...], returns: :scalar` | a reduction returning one f32 |
| elements of `params:` | `:scalar` (f32), `:vec` (`tensor<?xf32>`), `:mat` (`tensor<?x?xf32>`) |
| `dtype:` | **required, with no default** |
| `reduction: :default` | **the backend chooses the order of additions**; see the contract below |
| `reduction: :fixed_tree` | **a device-independent fixed order**: more dispatches, and CPU and Metal agree bitwise |
| `tree_arity: B` | the fixed tree's branching factor (a power of 2, 2..16, default 2). **Anything but 2 breaks on Metal** |

### External modules (`tensor_extern`)

`tensor_def` generates MLIR from a declaration. `tensor_extern` places an entry
the importer did **not** generate — a function inside a `.vmfb` built elsewhere,
such as a StableHLO model exported from JAX — under the same table, shim and
refusals.

```ruby
tensor_extern :mnist_mlp, dtype: :f32,
              vm_module: :jit_infer, entry: :main,       # the fully qualified name in the .vmfb
              params: [:mat], shapes: [[:batch, 784]],   # arguments
              returns: :mat, returns_shape: [:batch, 10] # the result (not an argument)
```

A transcribed signature can lie, so there is a check:
`--extern-check <name>=<module.mlir>` reads the real module back and compares
module name, function name and every dimension. A `tensor_extern` without it
warns.

### What a kernel body may say

| Kind | Ops |
|---|---|
| elementwise binary | `*` `+` `-` `/` `**` (`fastmath<contract>`) |
| elementwise unary | `relu` `abs` `sqrt` |
| comparison | `ge` (a 1.0/0.0 mask) |
| per tensor | `matvec` (`:mat` receiver, `:vec` argument, `:vec` result) |
| windows | `conv2d(:name)` / `depthwise(:name)`, with coefficients declared in `windows:` |
| resampling | `tap_mul(:d0\|:d1, idx, wgt)` (banded taps, recommended), `mode_mul(:d0\|:d1, W)` (general, O(N·√N)), `bilinear` (one dispatch, but it divides, so devices differ) |
| global | `hist` |
| roots | `dest.assign(expr)`, or `expr.sum` / `expr.max` / `expr.min` |

A body is **exactly one expression**; an intermediate local is a fusion
boundary and is refused.

### The host API

| | |
|---|---|
| `Tensor.device(uri, vmfb) { }` | the residency scope; tensors live only inside it |
| `Tensor.vec(:f32, n)` / `Tensor.of(:f32, n, flat)` | rank 1. **Shape and dtype are always named** |
| `Tensor.mat(:f32, rows, cols)` / `Tensor.of_mat(:f32, rows, cols, flat)` | rank 2. **Data is always flat, row-major**; nested Arrays appear nowhere |
| `t.to_f32_a` | **the only device-to-host copy** of f32 data. There is no bare `.to_a`: the values are f32 results widened to f64, not f64 answers |
| `t.to_bytes` | the device-to-host copy of a `:u8`/`:i8` tensor as a String |
| `t.length` / `t.rank` / `t.rows` / `t.cols` | size and shape |
| `t.fill(v)` / `t.store(flat)` / `t.free!` / `t.handle` | writing, explicit release, the opaque device handle |

## The contract on the order of additions

**The order is fixed at compile time, never by a run-time argument**: the
`.vmfb` is baked at build time, and the binary carries no compiler.

| Mode | Order | What may be required |
|---|---|---|
| `:default` | the backend's choice (IREE may tile, split and vectorize) | a normwise tolerance; **CPU and Metal are not expected to agree** |
| `:fixed_tree` | a fixed tree of branching B; with B=2 each output element is one `arith.addf`, leaving nothing to reassociate | **the CPU `.vmfb` and the Metal `.vmfb` agree bitwise, for every N** |

With `tree_arity:` above 2, Apple's Metal shader compiler reassociates the
additions (IREE builds its Metal library with fast math on), after every
compiler this project calls. `max` and `min` are exact and agree on every
device in every mode. `matvec` contains a reduction and is always `:default`;
`:fixed_tree` refuses to cover it.

## The fixed ABI

- **`fastmath<contract>`** on elementwise arithmetic, and never `reassoc`:
  reassociation is exactly the freedom `:fixed_tree` takes away.
- Readback staging uses `IREE_HAL_MEMORY_TYPE_HOST_CACHED`, allocated once and
  reused. Without it, a 16M-element readback is 56 times slower, with the same
  answer and no warning.
- **Dynamic shapes** (`tensor<?xf32>`): static shapes would need one `.vmfb`
  per size, and ahead of time that is an error, not a recompile.
- **A signature hash**: each generated call carries its declaration's FNV-1a,
  which the shim compares with the table, so a stale `.gen.rb` with a newer
  table or `.vmfb` fails loudly at the first call.
- **Shape constraints** derived from the body (for `matvec`,
  `cols(W) == len(x)` and `rows(W) == len(dest)`) are in the table, and the shim
  checks them before pushing a single argument. For window ops the table also
  requires the input and output to be different buffers: an output pixel reads
  its input's neighbourhood, so `blur(img, img)` would depend on how the backend
  tiled it.

## Fused statements: `dest.assign!(expr)`

`tensor_def` is one marked method, one kernel. **A fused statement is one host
statement, one kernel**, like Julia's `y .= a .* x .+ y`:

```ruby
Tensor.device("metal", vmfb) do
  y.assign!(x * 2.5 + y)                    # one statement, one dispatch
  y.assign!(((x * a + y) * b - z).relu)     # five ops, still one dispatch
end
```

The statement is rewritten before it is compiled:

```sh
tools/tensor/spinel-tensor kernels.rb --tensor --fuse prog.rb --emit-fused prog.fused.rb ...
spinel prog.fused.rb -o prog --link sp_tensor_shim.o ...     # compile the .fused.rb
```

Ruby evaluates `assign!`'s argument before calling it, so there is no other
way. The original file does not even compile, so there is no silently wrong
path. Only the replaced statements change, so a `diff` is the complete list of
what was compiled.

The rules for fused statements:

- They take **elementwise ops only** (`*` `+` `-` `/` `relu`), with
  `dest.assign!(expr)` as the root.
- A leaf is a Tensor local or a Ruby number; both are run-time arguments.
- Rank is 1 or 2, dtype is `:f32`, and there are at most four tensors
  including the destination.
- `sum`, `max`, `min` and `matvec` belong in `tensor_def` only.
- The same expression fuses into the same kernel, named by the hash of its
  MLIR.

**Fusing can change f32 bits.** `fastmath<contract>` allows an FMA where a
multiply feeds an add directly, so the fused expression becomes an FMA and the
two-dispatch chain does not. Both are correct f32 answers, and the fused one is
the more accurate. An expression with no multiply does not change at all.

## Limits

- The op set above, rank at most 2.
- **`/` is not bitwise equal on CPU and Metal** (Metal's f32 division is not
  correctly rounded). Among elementwise ops, bitwise equality can be required
  only of `*`, `+`, `-` and `relu`.
- `:fixed_tree` does not cover `matvec`, and there are no multi-stage
  reductions.
- The shim is not thread-safe (process-global state).
- `--extern-check` checks only the signature's shape. A module with types the
  shim cannot handle (i8, several outputs) fails in IREE after the table is
  written.
- No performance claim is made here.

## Checks

`tests/tensor/run.sh` builds and runs the examples on the CPU and on Metal. The
examples' comparisons with a second implementation (an f64 reference in Ruby,
or `ref.c`) are oracles; they run only with `SPINEL_ORACLE=1`.
