# E076's products

Experiment record: [E076](../../E076_grad_def.md). The tool:
[tools/grad](../../../../tools/grad/README.md).

```
E076/
├── twoexits/   measurement of reason (iii) for entering the lane    ./run.sh
├── rejects/    the rejection corpus of 11 cases + the O2 bite-proof  ./run.sh
├── demoA/      filter learning (learn on the CPU, apply on the GPU)  ./build.sh && ./run.sh
├── demoB/      scorer calibration (CPU only)                         ./build.sh && ./calib 2000 3000
└── tables/     the tables the four runs wrote (the only record with no hand work in it)
```

**No build product is kept.** `.o`, `.ll`, binaries and `.vmfb` are all
rebuilt by the scripts above. What is kept is the Ruby, shell and Python
sources, one test image, and `tables/`.

| prerequisite | what it needs |
|---|---|
| twoexits / rejects / demoB | llvm@22 + `third_party/enzyme` + the built products of `tools/{contract,realtime,llvm}` |
| demoA phase 1 (learning) | the same |
| demoA phase 2 (applying on the GPU) | the above + the IREE runtime / `iree-compile` (the prerequisites in `examples/image/README.md`; it reads `examples/tensor/iree.env`) |

## Reading tables/

| file | what |
|---|---|
| `*_targets.tsv` | the accepted declarations (target, wrt, mode, tol, argument types, **signature hash**, exports, number of probes) |
| `*_gates.tsv` | every observation of G1 to G4. `G3` rows give enzyme / fd / relative error per probe point and per component |
| `*_build.tsv` | hashes of the `spinel -S` output, adjoint names, the object's undefined symbols, worst_rel |
| `rejects.tsv` | **the 11 rejections**. The `obstacle` column is the obstacle id of the design review |
| `bite_oint_adjoint.ll` | **the adjoint Enzyme made for an integer primal** (`ret void`) |
| `bite_opt_silence.txt` | that `opt` then gave **exit 0 and 0 bytes on stderr** |
| `twoexits.tsv` | that one emission gives two exits + 25/25 bit-identical |
| `demoA_learn.tsv` / `demoA_learned.txt` | the descent's result and the six recovered taps |
| `demoA_apply_{learned,truth}_*.tsv` | the application on 3 devices x (learned coefficients / true values) |
| `demoA_out_metal.pgm` | metal's output image (byte-identical on the 3 devices) |
| `demoB_calibration.tsv` | weights, threshold, confusion matrix and metrics before and after calibration |
