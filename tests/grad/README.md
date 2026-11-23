# Host gradient cases

`spinel-gradgen` on the host, ported from spinel-llvm `463d49dd`, where the
cases were experiments E076 and E082 ([tools/grad](../../tools/grad/README.md),
[provenance](../../docs/provenance.md)).

| Case | What it checks |
|---|---|
| `e076/twoexits` | one emission gives the method and its adjoint: G1-G4 pass, the object exports three symbols, and the compiled method and the object's primal agree bit for bit at 25 points |
| `e076/rejects` | the obstacle corpus runs as Ruby, and each of its declarations is refused with the obstacle its section names, except O6's `odecay`, accepted since the pin `baddd25a9` with its gradient gate G3 OK; `--bite` gives the empty adjoint E076 describes |
| `e076/demoB` | calibrating a scorer with the gradient raises held-out accuracy and F1 |
| `e076/demoA` | the taps of a 3x3 filter are recovered (error below 1e-9), and the learned window, applied through the tensor lane, gives the same bytes as the exact one on every device |
| `e082/rules` | custom derivative rules: the kernels pass every gate; the four refusals name `norule`, `norulefwd`, `fwd1`, `O5` |
| `e082/hvp` | `hvp:`/`jvp:` pass their gates; Newton-CG over H.v products converges quadratically and beats gradient descent at the same budget |
| `e082/searchgate` | the search gate passes a correct searcher, refuses two defective ones, and refuses E080's aggregate curves |
| `gates/g5` | G5 counts each fast-math flag in a hand-written adjoint, except `nnan`/`ninf` on an operation whose operands are all integer-to-float conversions in the same function (written here, not ported) |

```sh
export LLVM_PREFIX=/path/to/llvm-23.1.1
export ENZYME=/path/to/LLVMEnzyme-23.so          # docs/toolchains/enzyme-0.0.290
export IREE_SRC=... IREE_BUILD=... IREE_COMPILE=...   # demoA's second phase
sh tests/grad/run.sh
```

Before the run: `make -C vendor/spinel`, `tools/contract/build.sh`,
`tools/mlir/native/build.sh`, `tools/llvm/build_rt_bc.sh` and the pass plugin
(`tools/llvm/passes/README.md`). Output goes under `$GRAD_WORK` (default
`$TMPDIR/spinel-grad`); `e082/searchgate` reads the build `e082/rules` left
there.

Local changes: the cases write under `$GRAD_WORK` instead of beside their
sources, and each prints its checks as `result.tsv`. Where spinel-llvm printed
a table for a person to read, the claim that table was for is now a check. The
rejects expectations (`expect.tsv`) are the obstacles each corpus names in its
own comments. demoA uses the tracked `img.pgm`; spinel-llvm regenerated it with
a Python script that was not imported.

## Oracles: kept as files, not run

- `e076/oracle/tables`, `e082/oracle/tables`: spinel-llvm's recorded outputs.
- `e082/oracle/rules_check.c` and `analytic_check.c`: derivatives written by
  hand from the mathematics.
- `e082/oracle/nonreg`: re-runs byte-compared with recorded outputs.
- demoA's comparison of the device output with an f64 Ruby implementation of the
  same filter. It is in `apply.rb` and runs only with `SPINEL_ORACLE=1`.
