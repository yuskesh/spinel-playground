#!/bin/bash
# scripts/setup.sh — 依存を揃える: bpf-mlir (third_party/bpf-mlir — submodule、版は固定) を LLVM 23.1.1 で build し、
# Spinel (third_party/spinel — submodule、upstream matz/spinel の固定の commit) を build する。
#
#   scripts/setup.sh
#   LLVM_PREFIX=/path/to/llvm scripts/setup.sh
#
# 出力: build/bpf-mlir/bin/{ebpf-opt,ebpf-compile}、third_party/spinel/bin/spinel、build/bml/lib (C の loader の archive 5 つ)・build/bml-test/lib/libbml.a (試験の caps)。network が要る (submodule・lit・libprism の gem)。
# submodule の pointer を上げるときは pointer (と go.mod / go.sum) を stage してから走らせる — submodule update は index の pointer に合わせる。
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
export LLVM_PREFIX

git -C "$HERE" submodule update --init third_party/bpf-mlir third_party/spinel
# bpf-mlir-loader (P010 E041 — file:// の submodule: この machine の外では clone できない、利用者の決定 2026-09-27)。入れ子は build に要る 3 つだけ (bml の bpf-mlir は取らない — 版の照合は gitlink)
. "$HERE/scripts/lib/bml-submodule.sh"; bml_submodule_update "$HERE" --init # E167: file:// の URL の時だけ protocol.file.allow
git -C "$HERE/third_party/bpf-mlir-loader" submodule update --init third_party/libbpf third_party/elfutils third_party/zlib
echo "== bpf-mlir: $(git -C "$HERE/third_party/bpf-mlir" describe --tags --always) ($(git -C "$HERE/third_party/bpf-mlir" rev-parse HEAD))"
echo "== spinel:   $(git -C "$HERE/third_party/spinel" log -1 --format='%h %s' | cut -c1-100)"
"$LLVM_PREFIX/bin/clang" --version | head -1

BUILD_DIR="$HERE/build/bpf-mlir" "$HERE/third_party/bpf-mlir/build.sh"

# Spinel の build の産物 (bin/・build/・vendor/prism) は Spinel の .gitignore の中 — submodule を汚さない
make -C "$HERE/third_party/spinel" deps
# E131: 版の文字列 (spinel_rev.h — git rev-parse --short) を最小 8 桁に — 桁が repo の object の数で変わると spinel の binary (verified の鍵) が checkout ごとに違う
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.abbrev GIT_CONFIG_VALUE_0=8 make -C "$HERE/third_party/spinel" -j"$(nproc)"
"$HERE/third_party/spinel/bin/spinel" --version
if [ -n "$(git -C "$HERE/third_party/spinel" status --porcelain)" ]; then
  echo "setup: third_party/spinel is dirty (build products outside .gitignore)" >&2; exit 1
fi
# C の loader (bml) の archive 5 つと試験の caps の libbml (P010 E041)
# E131: cwd を bml の zlib の dir に — gcc の cwd (DWARF の comp_dir) が build-libs.sh の -ffile-prefix-map (bml・zlib) で写り、archive に checkout の path が残らない (verified の鍵が path に依らない)
(cd "$HERE/third_party/bpf-mlir-loader/third_party/zlib" && "$HERE/third_party/bpf-mlir-loader/scripts/build-libs.sh" "$HERE/build/bml")
"$HERE/scripts/build-bml-test.sh"
if [ -n "$(git -C "$HERE/third_party/bpf-mlir-loader" status --porcelain)" ]; then
  echo "setup: third_party/bpf-mlir-loader is dirty" >&2; exit 1
fi
echo "== ok: $HERE/build/bpf-mlir/bin/ebpf-compile, $HERE/third_party/spinel/bin/spinel, $HERE/build/bml/lib"
