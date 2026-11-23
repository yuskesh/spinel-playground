#!/bin/bash
# scripts/setup.sh — 依存を揃える: bpf-mlir (third_party/bpf-mlir — submodule、版は固定) を LLVM 23.1.1 で build し、
# libelf (third_party/elfutils — elfutils-0.196) と libbpf (third_party/libbpf — v1.7.0) と libbml を静的に build する
# (build/libs/ — scripts/build-libs.sh、source の tree は汚さない)。
#
#   scripts/setup.sh
#   LLVM_PREFIX=/path/to/llvm scripts/setup.sh
#
# 出力: build/bpf-mlir/bin/{ebpf-opt,ebpf-compile}、build/libs/{lib,include,LICENSES,NOTICE}。network が要る (submodule・lit)。
# submodule の pointer を上げるときは pointer を stage してから走らせる — submodule update は index の pointer に合わせる。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
export LLVM_PREFIX

git -C "$HERE" submodule update --init third_party/bpf-mlir third_party/libbpf third_party/elfutils
echo "== bpf-mlir: $(git -C "$HERE/third_party/bpf-mlir" describe --tags --always) ($(git -C "$HERE/third_party/bpf-mlir" rev-parse HEAD))"
echo "== libbpf:   $(git -C "$HERE/third_party/libbpf" describe --tags --always) ($(git -C "$HERE/third_party/libbpf" rev-parse HEAD))"
echo "== elfutils: $(git -C "$HERE/third_party/elfutils" describe --tags --always) ($(git -C "$HERE/third_party/elfutils" rev-parse HEAD))"
"$LLVM_PREFIX/bin/clang" --version | sed -n 1p

BUILD_DIR="$HERE/build/bpf-mlir" "$HERE/third_party/bpf-mlir/build.sh"

# 製品の静的な library (libelf → libbpf → libbml): build/libs/ (scripts/build-libs.sh — submodule を汚さない)
"$HERE/scripts/build-libs.sh" "$HERE/build/libs"
echo "== ok: $HERE/build/bpf-mlir/bin/ebpf-compile, $HERE/build/libs/lib/{libelf,libbpf,libbml}.a"
