#!/bin/sh
# Build the core and freestanding checkers and emitters.
#
# Prerequisites, in order, from a clean checkout:
#   git submodule update --init --recursive
#   make -C vendor/spinel deps        # the compiler objects need Prism and RBS
#   tools/contract/build.sh           # the in-process contract reader
# then this script. See docs/building.md.
#
#   ./build.sh                        # uses /opt/llvm-23.1.1
#   LLVM_PREFIX=/path/to/llvm ./build.sh
#   BUILD_DIR=/path/to/build ./build.sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
BUILD="${BUILD_DIR:-$here/build}"

[ -f "$LLVM_PREFIX/lib/cmake/mlir/MLIRConfig.cmake" ] || {
  echo "build.sh: no MLIRConfig.cmake under $LLVM_PREFIX" >&2
  echo "          set LLVM_PREFIX to an LLVM installation that includes MLIR" >&2
  exit 1
}

# The official Darwin LLVM archive ships newer libc++ headers than the system
# dylib. Use the SDK headers with the SDK runtime, while retaining LLVM/MLIR 23.
set --
if [ "$(uname -s)" = Darwin ]; then
  sdk=$(xcrun --show-sdk-path)
  set -- "-DCMAKE_CXX_FLAGS=-nostdinc++ -isystem $sdk/usr/include/c++/v1"
fi
cmake "$@" -G Ninja -S "$here" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${CC:-$LLVM_PREFIX/bin/clang}" \
  -DCMAKE_CXX_COMPILER="${CXX:-$LLVM_PREFIX/bin/clang++}" \
  -DMLIR_DIR="$LLVM_PREFIX/lib/cmake/mlir" \
  -DLLVM_DIR="$LLVM_PREFIX/lib/cmake/llvm"

# WHAT A BUILD PRODUCES IS STATED HERE AND CHECKED AGAINST THE DIRECTORY. The
# list is explicit on purpose -- it is the answer to "what does this script give
# me" -- but an explicit list beside a directory drifts, and this one has twice:
# spinel-core-emit was missing once and a clean build produced a tree the core
# driver could not run, and spinel-core-stack was missing the same way, so
# tests/core-stack could not run at all while its own refusal said to build
# tools/mlir/native first. A comment recording the first occurrence did not
# prevent the second, so the list is compared with tools/CMakeLists.txt and the
# build refuses when they disagree.
TARGETS="spbpf-compile spbpf-opt spinel-mlir-capi-smoke spinel-fs-emit spinel-fs-codegen spinel-fs-check spinel-fs-grad spinel-tensor-import spinel-rtcheck spinel-core-check spinel-core-emit
spinel-core-boundary spinel-core-kernel spinel-core-adapter spinel-core-package
spinel-core-stack"

cfg=$(sed -n 's/^add_subdirectory(\([A-Za-z0-9_-]*\))[[:space:]]*$/\1/p' \
        "$here/tools/CMakeLists.txt" | sort)
lst=$(printf '%s\n' $TARGETS | sort)
if [ "$cfg" != "$lst" ]; then
  echo "build.sh: the target list and tools/CMakeLists.txt disagree" >&2
  printf '%s\n' "$cfg" > "$BUILD/.targets.cfg"
  printf '%s\n' "$lst" > "$BUILD/.targets.lst"
  echo "  configured but not built: $(comm -23 "$BUILD/.targets.cfg" "$BUILD/.targets.lst" | tr '\n' ' ')" >&2
  echo "  built but not configured: $(comm -13 "$BUILD/.targets.cfg" "$BUILD/.targets.lst" | tr '\n' ' ')" >&2
  rm -f "$BUILD/.targets.cfg" "$BUILD/.targets.lst"
  exit 2
fi

# Test executables live under unittests/ and are checked the same way, against
# the add_llvm_executable names there.
TEST_TARGETS="spinel-spbpf-schema-test"
tcfg=$(cat "$here"/unittests/*/*/CMakeLists.txt 2>/dev/null | \
        sed -n 's/^add_llvm_executable(\([A-Za-z0-9_-]*\) .*/\1/p' | sort)
tlst=$(printf '%s\n' $TEST_TARGETS | sort)
if [ "$tcfg" != "$tlst" ]; then
  echo "build.sh: the test target list and unittests/ disagree" >&2
  echo "  unittests/: $(echo $tcfg)  list: $(echo $tlst)" >&2
  exit 2
fi

ninja -C "$BUILD" $TARGETS $TEST_TARGETS
# The source stamp: what this build compiled, which a lane compares with its
# tree before it uses the kernel (tools/test/source-stamp.rb).
"${RUBY:-ruby}" "$here/../../test/source-stamp.rb" write kernel "$BUILD/bin"
echo "$BUILD/bin"
