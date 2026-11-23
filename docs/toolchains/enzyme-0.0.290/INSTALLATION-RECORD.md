# Enzyme 0.0.290 — installation record

Enzyme is the LLVM pass that builds the adjoint of a function. The gradient
tools load it as a pass plugin: `spinel-gradgen` through `opt`, and
`spinel-fs-grad` in-process (`tools/grad`, `tests/grad`, and the freestanding
lanes E079, E083 and E084). It is a third-party dependency, built user-local and
pinned. Nothing shared is changed, and nothing in this repository names its
location: the callers pass it as `ENZYME`.

## The pin

| | |
|---|---|
| version | `v0.0.290`, commit `db618fa4e8fa8170ff3db4d8517eeb0bc6e937f1` (2026-08-08) |
| built against | the official LLVM 23.1.1 (`docs/building.md`) |
| source | <https://github.com/EnzymeAD/Enzyme>, the release tag |

This is the version spinel-llvm used, against LLVM 22.1.8. It builds against
LLVM 23.1.1 without a change to its source. Enzyme names its plugins after the
LLVM major version, so the plugin here is `LLVMEnzyme-23.so`, not
`LLVMEnzyme-22`. The newest release when this was written was v0.0.294
(2026-09-22); it was not tried.

## Debian 13 (x86_64)

```sh
cd ~/toolchains
git clone --depth 1 --branch v0.0.290 https://github.com/EnzymeAD/Enzyme.git enzyme-0.0.290
cd enzyme-0.0.290 && mkdir build && cd build
cmake -G Ninja ../enzyme \
    -DLLVM_DIR=/opt/llvm-23.1.1/lib/cmake/llvm \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/opt/llvm-23.1.1/bin/clang \
    -DCMAKE_CXX_COMPILER=/opt/llvm-23.1.1/bin/clang++ \
    -DLLVM_EXTERNAL_LIT=/bin/false \
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON
ninja
export ENZYME=$HOME/toolchains/enzyme-0.0.290/build/Enzyme/LLVMEnzyme-23.so
```

- The build took 55 s wall on 16 jobs and reported 0 errors. It produced
  `LLVMEnzyme-23.so`, `ClangEnzyme-23.so` and `LLDEnzyme-23.so`; only the first
  is used here. `sha256(LLVMEnzyme-23.so)` =
  `544b918615fb4f6ba26b46fb73e374402692fa170e6e5dfd40f8a9cd87edb77f`.
- `LLVM_EXTERNAL_LIT`: the LLVM release ships no `lit`, and Enzyme's own test
  suite is not built or run here.
- `CMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON` is required. Enzyme's CMake calls
  `export(PACKAGE Enzyme)`, which writes an entry into the user package registry
  `~/.cmake/packages/Enzyme/`. That directory is shared with every other CMake
  project the user builds. The first configure here ran without the flag and
  wrote an entry. The entry was removed, and the tree was reconfigured with the
  flag. The rebuild had no work to do, and the plugin's sha256 is unchanged.
- The plugin was checked with `opt -load-pass-plugin=$ENZYME -passes=enzyme` on a
  module where a cube function (x³) is passed to `__enzyme_autodiff`. `opt` exited
  0 and emitted a `diffe` function.

## macOS (arm64)

Not recorded yet. The same commands apply, with the macOS LLVM path, and the
plugin is `LLVMEnzyme-23.dylib`.
