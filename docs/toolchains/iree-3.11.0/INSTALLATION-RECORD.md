# IREE 3.11.0 — installation record

IREE compiles the tensor lane's MLIR to `.vmfb` modules and runs them on the CPU
the Apple GPU and NVIDIA GPUs through CUDA (`tools/tensor`, `examples/tensor`, `examples/image`,
`tests/tensor`). It is a third-party dependency, installed user-local and
pinned. Nothing shared was changed: no system package, no Xcode component, and
nothing in `~/.cmake/packages`, which was checked before and after.

## The pin

| Part | Version | Where it comes from |
|---|---|---|
| compiler | `iree-compile` 3.11.0 (`3.11.0rc20260316`) at commit `e4a3b0405d7d23554da26403658d0e8c3c5ecf25` | the `iree-base-compiler==3.11.0` wheel from PyPI |
| runtime | `libiree_runtime_unified.a` at the **same** commit | built from source, runtime only |

**The two must come from one commit.** A `.vmfb` is a versioned format, and a
compiler and runtime from different commits fail in ways that show only at run
time. This is the pin spinel-llvm used (its `docs/tools/iree.md`).

## No Python

This repository admits Python only inside the Zephyr installation. spinel-llvm
installed the compiler with `pip`. Here, no Python interpreter runs at any step:

- **The compiler.** A wheel is a zip archive, and this one carries native
  binaries. Downloaded with `curl` and checked against PyPI's published sha256;
  only the native tools and their library are unpacked:

  ```sh
  I=$HOME/toolchains/iree-3.11.0
  mkdir -p $I/dl $I/compiler && cd $I/dl
  curl -sSLo whl.zip 'https://files.pythonhosted.org/packages/4c/1f/ae45ccb7edef9eead14eacb0e8b472ce3d72ee3863a0f9eb6c916e09e6e3/iree_base_compiler-3.11.0-cp312-abi3-macosx_13_0_universal2.whl'
  shasum -a 256 whl.zip   # 2e9fc888b9044662a14eeba01b6302d75a6118f68874699dcf8f9c7e991a4ee2 (PyPI's digest)
  unzip -q whl.zip 'iree/compiler/_mlir_libs/iree-*' 'iree/compiler/_mlir_libs/libIREECompiler.dylib' -d x
  mv x/iree/compiler/_mlir_libs/* $I/compiler/ && rm -rf x
  $I/compiler/iree-compile --version   # IREE compiler version 3.11.0rc20260316 @ e4a3b040...
  ```

  `iree-compile` is a native arm64 executable that loads `libIREECompiler.dylib`
  from its own directory.

- **The runtime.** IREE's CMake looks for a Python interpreter even for a
  runtime-only build, and found one on this Mac through its own search. Turning
  the lookup off (`-DCMAKE_DISABLE_FIND_PACKAGE_Python3=ON`) removes it, and the
  build does not need it: none of the 307 build commands names Python, and the
  CMake cache holds no interpreter.

## The runtime build

With the official LLVM 23.1.1 (the repository's compiler, never Apple Clang) and
the macOS SDK named explicitly, because the Metal driver is Objective-C:

```sh
I=$HOME/toolchains/iree-3.11.0; L=/path/to/llvm-23.1.1/bin
cd $I && git init -q src && cd src
git remote add origin https://github.com/iree-org/iree.git
git fetch --depth 1 origin e4a3b0405d7d23554da26403658d0e8c3c5ecf25 && git checkout FETCH_HEAD
git submodule update --init --depth 1 third_party/flatcc third_party/benchmark \
  third_party/googletest third_party/vulkan_headers third_party/tracy \
  third_party/webgpu-headers third_party/printf third_party/spirv_cross
cd $I && cmake -S src -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$L/clang -DCMAKE_CXX_COMPILER=$L/clang++ -DCMAKE_OBJC_COMPILER=$L/clang \
  -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)" -DCMAKE_DISABLE_FIND_PACKAGE_Python3=ON \
  -DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_TESTS=OFF -DIREE_BUILD_SAMPLES=OFF \
  -DIREE_BUILD_PYTHON_BINDINGS=OFF -DIREE_BUILD_BINDINGS_TFLITE=OFF \
  -DIREE_HAL_DRIVER_METAL=ON -DIREE_HAL_DRIVER_LOCAL_SYNC=ON -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
  -DIREE_HAL_DRIVER_VULKAN=OFF -DIREE_HAL_DRIVER_HIP=OFF -DIREE_HAL_DRIVER_CUDA=OFF \
  -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF -DIREE_ENABLE_ASSERTIONS=OFF -DBUILD_SHARED_LIBS=OFF
ninja -C build runtime/src/iree/runtime/libiree_runtime_unified.a
```

Fetching took 31 s, configuring 8 s, and building 3 s (308 steps).
`libiree_runtime_unified.a` is not link-closed; the tensor lane also links
`build_tools/third_party/flatcc/libflatcc_parsing.a` and
`build_tools/third_party/printf/libprintf_printf.a`.

## Metal

Xcode on this Mac has `metal` but no `metallib`, which Xcode 26 ships
separately. Installing Apple's Metal toolchain would change a shared Xcode
component, so it was not installed. The Metal kernels are compiled with
`--iree-metal-compile-to-metallib=false`: the shader source is embedded and
compiled on the device at load time. spinel-llvm verified both paths (its
E027).

## What was installed, on the Mac that verified the port (2026-09-23)

`~/toolchains/iree-3.11.0/`, with the macOS SDK at 27.0:

| Path | Size | sha256 |
|---|---|---|
| `compiler/iree-compile` | 33 KB | `69144949ca97db5c822af57c655230967f8bb822cadbfc49bc21a1016b987223` |
| `compiler/libIREECompiler.dylib` | 291 MB | `9093c2db7523ccac12116b115f8f487c0bfeeeadd7bbc15efbeceb86d5f3a4ba` |
| `build/runtime/src/iree/runtime/libiree_runtime_unified.a` | 1,292,560 B | `c6006e24edc06a695a8f8ba6f10b524f0cbda3d453425516e7e560518d5ba333` |
| `build/build_tools/third_party/flatcc/libflatcc_parsing.a` | | `23ff104e281dbf8f5a8adcfa916353232c927f849e2768819d934d9646725596` |
| `build/build_tools/third_party/printf/libprintf_printf.a` | | `79c24620e7eb51c22d8973f5a547287fd89ec515498bf49a39ae32d5b6d9ca78` |
| `src/` (the IREE source at the pin, runtime submodules only) | 197 MB | |

The lane reads them through three variables, which it requires and never
guesses:

```sh
export IREE_SRC=$HOME/toolchains/iree-3.11.0/src
export IREE_BUILD=$HOME/toolchains/iree-3.11.0/build
export IREE_COMPILE=$HOME/toolchains/iree-3.11.0/compiler/iree-compile
```

The runtime archive's digest is this build's; another machine or compiler gives
another digest, and the pin is the commit, not the archive's bytes.

## Debian 13 (x86_64), 2026-09-23

The same pin and the same two rules -- one commit, no Python -- on Debian 13.6
(glibc 2.41), with the official LLVM 23.1.1 at `/opt/llvm-23.1.1`.

- **The compiler** is the manylinux wheel of the same release, unpacked the
  same way: `iree_base_compiler-3.11.0-cp312-abi3-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl`,
  sha256 `99fc3369375405485f11da541a75ef2b153d529fa3712c1d9771c98a35e2669e`
  (PyPI's digest, matched), unzipping `iree/compiler/_mlir_libs/iree-*` and
  `libIREECompiler*` into `compiler/`. `iree-compile --version` prints
  `3.11.0rc20260316 @ e4a3b0405d7d23554da26403658d0e8c3c5ecf25`.
- **The runtime** is built from the same commit with the Mac's CMake line
  minus the macOS parts: no `CMAKE_OBJC_COMPILER`, no `CMAKE_OSX_SYSROOT`, and
  `-DIREE_HAL_DRIVER_METAL=OFF` (Metal exists only on macOS). Fetching took 30
  s, configuring 5 s, building 1 s. The 280 commands of the three archives'
  targets name no Python (`ninja -t commands ... | grep -ci python` is 0); the
  `python3` rules in `build.ninja` belong to test targets that are not built.

| Path | sha256 |
|---|---|
| `compiler/iree-compile` | `577e9a85d77ebfc19c2e41fb713e443aba497a60e9edfa1c7790d8be26f4f891` |
| `compiler/libIREECompiler.so` (352,899,616 B) | `43ba79ec5b5fbeb53d1741cd199557271faf59900b57c89ffbde0464c92ffd6d` |
| `build/runtime/src/iree/runtime/libiree_runtime_unified.a` | `f5ad9652d62320e8a550cea42c5b75dd4232a06272018f59ff50df4870807bdb` |
| `build/build_tools/third_party/flatcc/libflatcc_parsing.a` | `01358f70d56ffb00158d525e7e73cbf7b9becbc1c83ed006d35266f6f6ccd61f` |
| `build/build_tools/third_party/printf/libprintf_printf.a` | `0c6544de7042bece192eac156dd7ba8615dbbe6aaa9e761f996520798938b677` |

The tensor lane runs every example on the CPU (`local-sync`) here, and names
each Metal check as not applicable.

## CUDA

`iree-compile` has the `cuda` backend in the Linux wheel used here
(`iree-compile --iree-hal-list-target-backends`). The runtime needs its own
build, because the CUDA driver is off above. It goes in a second directory, so
the first build stays as it was:

```sh
I=$HOME/toolchains/iree-3.11.0; L=/path/to/llvm-23.1.1/bin
cd $I && cmake -S src -B build-cuda -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$L/clang -DCMAKE_CXX_COMPILER=$L/clang++ \
  -DCMAKE_DISABLE_FIND_PACKAGE_Python3=ON -DCUDAToolkit_ROOT=/opt/cuda-13.1 \
  -DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_TESTS=OFF -DIREE_BUILD_SAMPLES=OFF \
  -DIREE_BUILD_PYTHON_BINDINGS=OFF -DIREE_BUILD_BINDINGS_TFLITE=OFF \
  -DIREE_HAL_DRIVER_DEFAULTS=OFF -DIREE_HAL_DRIVER_CUDA=ON \
  -DIREE_HAL_DRIVER_LOCAL_SYNC=ON -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
  -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF -DIREE_ENABLE_ASSERTIONS=OFF -DBUILD_SHARED_LIBS=OFF
ninja -C build-cuda runtime/src/iree/runtime/libiree_runtime_unified.a \
  build_tools/third_party/flatcc/libflatcc_parsing.a \
  build_tools/third_party/printf/libprintf_printf.a
```

The driver loads `libcuda.so` at run time, so the program links no CUDA library.
Set `IREE_BUILD` to `build-cuda` and pass device `cuda`; `tests/tensor/run.sh`
then runs its GPU checks on CUDA. Checked on Debian x86_64 with CUDA Toolkit 13.1
on an NVIDIA GeForce RTX 4090.
