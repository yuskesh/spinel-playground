#!/bin/sh
set -eu
export LC_ALL=C
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD=${1:?usage: build-consumer-sanitizers.sh FRESH_BUILD}
LLVM_PREFIX=${LLVM_PREFIX:-/opt/llvm-23.1.1}
LIT=${LLVM_EXTERNAL_LIT:?set LLVM_EXTERNAL_LIT to existing 23.1.1 runner}
test "$(id -u)" -ne 0
test ! -e "$BUILD"
test "$(git -C "$ROOT/third_party/bpf-mlir" rev-parse HEAD)" = 41b188568cb36a15d4c185d5f72027267b3fa544
test -x "$LLVM_PREFIX/bin/clang++"
test -x "$LIT"
FLAGS='-fsanitize=address,undefined -fno-sanitize=vptr -fno-sanitize-recover=all -fno-omit-frame-pointer'
configure() {
  cmake -G Ninja -S "$1" -B "$2" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
    -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
    -DCMAKE_C_FLAGS="$FLAGS" \
    -DCMAKE_CXX_FLAGS="-fno-rtti -fno-exceptions $FLAGS" \
    '-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O1 -g -DNDEBUG' \
    '-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O1 -g -DNDEBUG' \
    -DCMAKE_EXE_LINKER_FLAGS='-fsanitize=address,undefined' \
    -DCMAKE_SHARED_LINKER_FLAGS='-fsanitize=address,undefined' \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DMLIR_DIR="$LLVM_PREFIX/lib/cmake/mlir" \
    -DLLVM_DIR="$LLVM_PREFIX/lib/cmake/llvm" \
    -DLLVM_EXTERNAL_LIT="$LIT"
}
configure "$ROOT/third_party/bpf-mlir" "$BUILD/bpf-mlir"
cmake --build "$BUILD/bpf-mlir" --parallel "${BUILD_JOBS:-2}" --target \
  MLIREBPFDialect BpfMLIRKernelABI BpfMLIREBPFSchema
configure "$ROOT" "$BUILD"
cmake --build "$BUILD" --parallel "${BUILD_JOBS:-2}" --target spinel-mlir
