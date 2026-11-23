# tools/grad -- differentiable Ruby

Ported from spinel-llvm `463d49dd` (P007: E076, E079, E082, E083, E084; the
native freestanding generator from E167); see
[provenance](../../docs/provenance.md). A declaration asks for the gradient of a
Ruby method. The tools build it with Enzyme
([installation record](../../docs/toolchains/enzyme-0.0.290/INSTALLATION-RECORD.md))
and gate it before anything is written.

| | |
|---|---|
| `spinel/grad.rb` | `grad_def` (host). The declaration is inert at run time: the body is ordinary Ruby |
| `spinel/grad_freestanding.rb` | `freestanding_grad_def`, beside a `freestanding_def` |
| `spinel/grad_rules.rb` | `SPGR`, the differentiable runtime primitives (`spg_clamp01`, `spg_lut1`, ...) |
| `rules/` | `rules.tsv` (which primitives have reverse and forward rules) and their C implementations and Enzyme registrations |
| `spinel-gradgen` | host generator and gates |
| `spinel-searchgate` | gate for an optimiser's search trace |
| `../mlir/native/tools/spinel-fs-grad` | freestanding generator, Enzyme loaded in-process |

## Host: `spinel-gradgen`

```ruby
require_relative "spinel/grad"
grad_def :dense_loss, wrt: [:w, :b], tol: 1.0e-6,
         probe: [[[0.1, 0.2], [0.05], [1.0, 2.0], [0.5]]]
def dense_loss(w, b, x, t) ... end
```

```sh
export LLVM_PREFIX=/opt/llvm-23.1.1 ENZYME=/path/to/LLVMEnzyme-23.so
tools/grad/spinel-gradgen app.rb -o build/grad     # -> <stem>_grad.o, <stem>_grad.gen.rb, tables
vendor/spinel/bin/spinel prog.rb -o prog --link build/grad/app_grad.o
```

Keywords: `wrt:` (required; `float` or `float_array` parameters), `mode:`
(`:reverse` only; `:forward` is refused, not silently reversed), `tol:` (G3's
relative threshold), `probe:` (required; the points G3/G4 evaluate), `export:`,
and the additive `hvp: true` / `jvp: true` products. The object exports
`spg_val_<f>`, `spg_grad_<f>` and `spg_sig_<f>` (plus `spg_hvp_`/`spg_jvp_`);
the `.gen.rb` wraps them as `gdval_<f>`, `grad_<f>` and `grad_check_signatures!`.

One `spinel -S` emission feeds both the method and its adjoint. The gates, in
order; any failure writes no object:

- **G1, types**: the method must be float in, float out, with no boxed or
  bignum local, no toplevel constant, no string, hash, block or rescue. Enzyme
  would build an empty adjoint for an integer primal and say nothing.
- **G2, no allocation**: `spinel-rtcheck` must prove the method
  allocation-free. Only then are its GC roots dropped (by
  `tools/llvm/passes`), because only then can no collection happen.
- **G3, differential**: the adjoint must agree with central differences at
  every probe, within `tol:`.
- **G4, non-trivial**: the gradient must not be identically zero over the
  probes.
- **G5, determinism**: no adjoint may carry a fast-math flag. With `hvp:` or
  `jvp:`, the forward gates (G3F, GXF, G3H, GDOT, GSYM, G4H) apply as well.

The refusals name their obstacle (O2, O4, O5, O6, O7, `subset`, `decl`,
`mode`, `probe`, `norule`, `norulefwd`, `fwd1`); `--allow-rejects` tabulates
them. `--bite NAME` forces a refused integer primal through, to show what G1
prevents. It is for demonstration only.

Dependencies: `vendor/spinel`, `tools/contract/build/spinel-typedump`,
`tools/realtime/spinel-rtcheck` (with the runtime bitcode from
`tools/llvm/build_rt_bc.sh`), `tools/llvm/passes/build/libSpinelGCRoots.so`, the
LLVM from `LLVM_PREFIX` and the plugin from `ENZYME`. Each can be overridden by
a flag (`--help`).

## Freestanding: `spinel-fs-grad`

```ruby
freestanding_grad_def :loss, wrt: :w, tol: 1.0e-6        # hvp: true adds spinel_hvp_loss
freestanding_def :loss, params: [[:f64_buf, :in], :len, [:f64_buf, :in], :len], returns: :f64
```

```sh
tools/mlir/native/build/bin/spinel-fs-grad kern.rb --profile P.yaml -o build \
    --emit-header build/spinel_grad.h --enzyme "$ENZYME" [--grads-only]
```

It generates the kernel IR in-process (as `spinel-fs-emit` would), builds the
`__enzyme_autodiff` shim in IR against the same triple and data layout, runs
Enzyme with fast-math off, and writes one object. With `--grads-only`, the
object holds only the gradient (and hvp) symbols, for a kernel that imports
them as platform externs. Its gates: the boundary of the declaration (g01-g12),
no allocator or other undeclared symbol in the adjoint object, and no fast-math
flag in the module (G5), which is what lets one IR give the same bits on every
target.

## Checks

- `tests/grad/run.sh`: the host cases (E076, E082).
- `tests/freestanding/run.sh`: the lanes e079, e083 and e084, on the host,
  QEMU Cortex-M33, QEMU RV32 and wasm32.

`ab/` (`run_e171.sh`, `test_e171.rb`) compared these tools byte for byte with
spinel-llvm's frozen Python and its recorded goldens. It is an oracle, kept as
files; its fixtures under spinel-llvm's `docs/experiments/results/E171/` were
not imported.

## Local changes

- The LLVM and the plugin come from `LLVM_PREFIX` and `ENZYME`, and the plugin
  name follows the LLVM major version (`LLVMEnzyme-23`).
- Off macOS, the gate driver links `-lcrypt`, as the pinned compiler links every
  program.
- The pinned runtime's float element is `sp_float` (spinel-llvm: `mrb_float`).
- The rules prototypes spell `int64` as `int64_t`, which is how the pinned
  compiler declares the same FFI function. `long long` conflicts with it where
  `int64_t` is `long` (Linux x86_64).
