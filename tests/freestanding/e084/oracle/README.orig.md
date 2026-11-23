# E084's products — Newton/HVP inside the kernel (closing what E083 left)

Experiment record: [../../E084_kernel_newton.md](../../E084_kernel_newton.md)

## Rerun

```bash
bash build_all.sh     # 4 targets x 2 generators (kern.o + grad.o; grad.o has two exports, gradient + HVP) + link + west build
bash run_gates.sh     # 4-way differential + the analytic Hessian oracle + symmetry/GDOT + loop equivalence + trap
bash run_host.sh      # the host differential (gradgen mirror, by layer + FMA attribution) + Ruby Newton-CG
bash run_reject.sh    # the rejection table, 11 cases (subset 5 + gradfs hvp gate 4 + controls 2)
bash run_nonreg.sh    # every gate of E079 / E083 / E082 rerun + byte checks + named changed paths
```

Prerequisites: Zephyr (`ZEPHYR_BASE`), QEMU, node, llvm@22, Enzyme (third_party).
`NO_DEVICE=1` skips the QEMU legs (native + wasm32 only).
run_gates comes after build_all, run_host after run_gates (it reads the native stream).

## Layout

| file | contents |
|---|---|
| `e084_kern.rb` | the kernel. E079's sections A/C **verbatim** + `freestanding_grad_def ... hvp: true` + `newton_calibrate` (Newton-CG: outer iterations + inner CG + damped steps, all in the subset's Ruby) + `grad_norm2` + `hvp_probe` |
| `*-e084.yaml` | 4 profiles: E083's declarations + **the hvp extern** (four buffers governed by one `len`, in the settled spelling) |
| `drv/e084_drv.c` | the C driver (shared by native/M33/RV32). **It has no Newton loop**: only an HVP block on its own (5 columns of H + 2 symmetric directions) and the calibration stream's instruments |
| `run_node.mjs` | the JS driver (written independently), likewise |
| `zephyr/` | the Zephyr app. It links kern.o + grad.o (2 exports). Stack 16K (for the hvp shim's VLA) |
| `analytic_check.c` | the analytic oracle: the squared hinge's closed-form gradient and H written from paper, judging the generated object's exports (without touching Enzyme). 82 rows over two active sets |
| `host/` | the host differential: `host_kernel.rb` (grad_def hvp:, body verbatim) / `host_mirror.c` (mirrors the kernel's Newton and prints the bits) / `unfuse_fmuladd.py` (the FMA-attribution tool) / `host_newton.rb` (a Ruby Newton-CG of E082's shape) |
| `reject/` | the rejection corpus (n* = subset refusals = the constraints that set the kernel's shape / h* = gradfs hvp gate / hc1 = the hvp: false control) |

## Tables (one TSV row = one gate)

| table | rows | contents |
|---|---|---|
| `gates.tsv` | 4 | the sha256 of the 186-row stream x 4 legs (IDENTICAL on every leg, `ef113fcd5c575c9a`) |
| `analytic.tsv` | 82+1 | analytic Hessian / gradient / GDOT / symmetry (worst 9.1e-16, 0 fails). gxr = the hvp's g against the reverse g (bit identity also recorded in row counts) |
| `hvpsym.tsv` | 24+1 | from **the bits each leg printed**, checks u·Hv = v·Hu and return value = ∇f·e_j (the legs only print; the checker does the dot products) |
| `loop.tsv` | 12 | sum of steps = the one-shot rc / F rows == the 12 S rows / the control (from W0) replays the one-shot |
| `trap.tsv` | 25 | 4 refusals of iters/gtol2 x 4 legs (including zero writes) + control + **4 length-check traps on the hvp extern** (native x2 / wasm x2 / M33 panic) |
| `surface.tsv` | 7 | kern.o imports **two adjoints** + trap / grad.o exports exactly 2 / kern.wasm imports only spinel_trap |
| `determinism.tsv` | 14 | generator determinism (mlirgen + **gradfs's object reproducibility**) + G5 (loop side + adjoint side, with forward) + fwddiffe present |
| `abi.tsv` (+ details) | 4 (8x4) | abi-check: **both externs' declares** checked on 4 targets |
| `extern_check.tsv` | 2 | the declarations vs the gradfs shim (both grad and hvp MATCH) |
| `host.tsv` | 149+5 | **the host differential by layer** (the native kernel vs the gradgen mirror): primal / gradient / hvp / trajectory. The plain comparison splits at the primal layer |
| `host_fma.tsv` | 6 | **attribution**: 17 fmuladd sites (host only); with unfuse + the mirror at `-ffp-contract=off`, **155/155 shared rows bit-identical** = the whole split is FMA |
| `host_newton.tsv` | 3 | Ruby Newton-CG: converges (gnorm 2.8e-15) / settles in one shot (the hinge is piecewise quadratic) / **7 steps = the kernel's B row** |
| `host_gradgen_gates.tsv` and others | 37 | gradgen's own gates on the host surface (with G3H/GDOT/GSYM/G4H/G5, 0 fails) |
| `reject.tsv` | 11 | refusals and controls (subset 4 + 1 accepted pair / gradfs 3 + 2 controls + 1 real-kernel control) |
| `undef.kern.*.tsv` / `undef.grad.*.tsv` | 4+4 | the unresolved-symbol verdicts of the two objects (3 externs ALLOWed: grad + hvp + trap) |
| `nonreg.tsv` | 28 | named changed paths / parallel lanes untouched / the summary and byte checks of E079, E083 and E082 reruns |
