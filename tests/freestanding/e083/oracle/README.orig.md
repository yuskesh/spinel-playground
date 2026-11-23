# E083's products — the optimiser loop inside the kernel (E081 + E082/E079 joined)

Experiment record: [../../E083_kernel_optimizer_loop.md](../../E083_kernel_optimizer_loop.md)

## Rerun

```bash
bash build_all.sh     # 4 targets x 2 generators (kern.o + grad.o) + link + west build
bash run_gates.sh     # 4-way differential + E079 bit-identity + loop equivalence + trap + surface
bash run_reject.sh    # 19 compile-time refusals (profile lies q1-q8 / kernel misuse r1-r7 / controls c1-c4)
bash run_nonreg.sh    # named changed paths + host-mode byte identity + the summary of E081/E079/E082 reruns
```

Prerequisites: Zephyr (`ZEPHYR_BASE`), QEMU, node, llvm@22, Enzyme (third_party).
`NO_DEVICE=1` skips the QEMU legs (native + wasm32 only).
run_nonreg.sh's E081/E079/E082 rows summarise those experiments' rerun scripts,
which must run **first** (the session record is in the experiment record).

## Layout

| file | contents |
|---|---|
| `e083_kern.rb` | the kernel. E079's sections A to D **verbatim** + `calibrate` (the SGD loop, calling the adjoint through an extern) + `grad_probe` (the length check's control and breakage) |
| `*-e083.yaml` | 4 profiles: a shipped profile + the adjoint's extern declaration (buffer arguments). The 3 shipped profiles are unmodified |
| `drv/e083_drv.c` | the C driver (shared by native/M33/RV32). **It has no step loop**: the difference from E079 is the result itself |
| `run_node.mjs` | the JS driver (written independently), likewise without a loop |
| `zephyr/` | the Zephyr app. It links **two objects**, kern.o + grad.o |
| `reject/` | the rejection corpus (q* = profile lies / r* = kernel misuse / c* = controls) |

## Tables (one TSV row = one gate)

| table | rows | contents |
|---|---|---|
| `gates.tsv` | 4 | the sha256 of the 324-row stream x 4 legs (IDENTICAL on every leg) |
| `e079.tsv` | 246+1 | row-by-row bit comparison with E079's **stored** products (loss 41 + weights 200 + shipped 5) |
| `loop.tsv` | 12 | one call with steps=40 == 40 calls with steps=1 (per leg, in bits) |
| `trap.tsv` | 25 | 5 learning-rate refusals x 4 legs (including zero writes) + 4 length-check traps (native x2 / wasm x2 / M33 panic) |
| `surface.tsv` | 7 | kern.o imports only the adjoint + the trap hook / grad.o exports one adjoint / kern.wasm imports only spinel_trap |
| `reject.tsv` | 19 | compile-time refusals and controls |
| `determinism.tsv` | 9 | generator determinism + **G5 on both the loop side (kern.ll) and the adjoint side** |
| `abi.tsv` (+ details) | 4 (9x4) | abi-check: an extern is checked against kern.ll's **declare** (the caller's ABI) (extended by E083) |
| `extern_check.tsv` | 1 | the declaration vs **the gradfs shim** (the "wrapper TU" that defines the adjoint) |
| `undef.kern.*.tsv` / `undef.grad.*.tsv` | 4+4 | the unresolved-symbol verdicts of each of the two objects |
| `nonreg.tsv` | 19 | named changed paths / host-mode byte identity / the summary of E081, E079 and E082 reruns (E082's replay record is `e082_replay_nonreg.txt`) |
