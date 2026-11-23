# tools/llvm/passes -- SpinelGCRoots

Ported from spinel-llvm `463d49dd` (E015, E016, E017); see
[provenance](../../../docs/provenance.md). An out-of-tree LLVM pass plugin that
removes the GC shadow-stack root pushes (`SP_GC_ROOT`) of the Spinel runtime
over regions it proves cannot collect, and batches the rest. It runs at
PipelineStartEP, before mem2reg and SROA, because the root convention is no
longer recognisable in optimised IR.

Here it is used by one caller: `tools/grad/spinel-gradgen`, which loads it into
clang (`-fpass-plugin`) with `-spinel-gc-callee-roots=false` only for methods
that `spinel-rtcheck` has proved allocation-free, and passes the rules
primitives as `-spinel-nogc-list`. spinel-llvm's status for general use was
proof of concept, opt-in only; nothing here turns it on for ordinary builds.

## Build

```sh
cmake -G Ninja -S tools/llvm/passes -B tools/llvm/passes/build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=$LLVM_PREFIX/bin/clang -DCMAKE_CXX_COMPILER=$LLVM_PREFIX/bin/clang++
ninja -C tools/llvm/passes/build        # -> build/libSpinelGCRoots.so
```

CMake finds LLVM through `$LLVM_PREFIX/bin/llvm-config`, or `-DLLVM_DIR`, and
refuses any LLVM other than 23.1.1; it never falls back to a system LLVM.

## Checks

```sh
FILECHECK=/path/to/FileCheck bash tools/llvm/passes/test/run.sh   # the IR tests: 5 files
```

The LLVM release ships no FileCheck, so `FILECHECK` names one; it matches text
and any recent LLVM's will do. `test/run_rb.sh` compares programs built with and
without the pass (the stock build is the reference), which makes it an oracle:
it is kept and runs only on the user's instruction. spinel-llvm's
`nogc_list.py` was not imported (no Python here); gradgen writes its list
itself.
