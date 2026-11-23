# E079's products — gradients on every target (the edge calibration loop)

Experiment record: [../../E079_edge_calibration.md](../../E079_edge_calibration.md).
**`vendor/spinel` is READ-ONLY (at `8e30ae3c`)**; the only change under
`tools/` is **two new files in `tools/grad/`** (`nonreg.tsv` is the evidence).

## How to run

```bash
bash build_all.sh    # 4 targets x (kernel, kernel+adjoint) -> wasm / native / 2 Zephyr images
bash run_gates.sh    # 4-way differential + an independent model + the fast-math control + the closed loop
bash run_reject.sh   # the rejection table
bash run_nonreg.sh   # E076's and E077's products have not moved
```

`NO_DEVICE=1` skips QEMU (only the two legs native + wasm32 remain).

## Inputs (written by hand)

| file | what |
|---|---|
| `e079_kern.rb` | **the only shared file**: six `freestanding_def` and one `freestanding_grad_def` |
| `drv/e079_drv.c` | the C driver (native, M33 and RV32 use **the same one**) |
| `drv/native_main.c` | the host's `main` and trap hook (this is the whole platform surface) |
| `run_node.mjs` | the driver for wasm32 = **the edge**, written independently without looking at the C |
| `model.py` | an independent implementation **in a fourth language** (primal, analytic gradient, central differences, SGD) |
| `zephyr/` | the device's Zephyr project (CMakeLists / prj.conf / src/main.c) |
| `arm64-host.yaml` | the host leg's profile (**not a shipped profile**; the reason is at the top of the file) |
| `reject/*.rb` | 15 broken declarations + 1 control |

## Outputs (measurements)

| file | what |
|---|---|
| **`gates.tsv`** | the sha256 of the **whole stream** of the four legs. 465 rows, `fae55f159c4d3f0e` on all four |
| **`grad4.tsv`** | 15 gradient components x 4 legs, per component rather than summarised |
| `sgd.tsv` | 40 steps of loss and weights + the number of legs that agreed |
| **`g3.tsv`** / `g3.summary.txt` | model.py's verdicts (primal bit-identical / G3 / G4 / SGD reproduced / learning rate allowed) |
| **`fastmath.tsv`** | the control: with `-enzyme-fast-math` the four-way agreement breaks |
| **`loop.tsv`** | the closed loop device -> edge -> device, five stages |
| `trap.tsv` | 5 run-time refusals of the learning rate x 4 legs = 20 rows |
| `reject.tsv` | 15 compile-time refusals + 2 controls + 1 control (18 rows) |
| `nonreg.tsv` | tools and vendor unchanged, E076's and E077's products byte-identical |
| `determinism.tsv` | the generator's determinism + **`freestanding_grad_def` is inert on the freestanding output** |
| `undef.<target>.tsv` | the unresolved symbols of **the object with the adjoint** (on wasm32 only `spinel_trap`) |
| `size.tsv` | `.text` of the kernel alone / kernel+adjoint, the wasm size, the number of allocas |
| `targets.tsv` / `build.*.tsv` | the declaration table, and adjoint names, alloca counts, fast-math sites, exports |
| `qemu_*.log` | the three raw QEMU consoles (m33 / rv32 / m33 shipped) |
| `shim.c` / `spinel_grad.h` / `grad_m33.ll` / `kern.wasm` / `weights_shipped.h` | the generated products themselves |

`weights_shipped.h` is **the real thing that crossed the boundary**: the five
doubles the edge (wasm32) produced after 40 steps, burnt into the device image
as hexadecimal bit patterns.
