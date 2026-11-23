#!/bin/bash
# scripts/build-bml-test.sh — 試験の build だけの libbml (-DBML_TEST_CAPS — caps の種類 1 / 2 — Go の試験の archive の denyCaps / unknownHelperCaps と同じ) を
# build/bml-test/lib/libbml.a に (P010 E041)。bml の build-libs.sh の libbml と同じ flag と source (bml の scripts/srcs.sh src) — 製品の build/bml/lib/libbml.a には入らない
# (gate が nm で確かめる)。先に build/bml (製品の archive と header) が要る。
#   scripts/build-bml-test.sh
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BML=$HERE/third_party/bpf-mlir-loader
OUT=$HERE/build/bml
T=$HERE/build/bml-test
# Spinel Extended: bml's libbpf and zlib are user-local checkouts here, named as for
# bml's scripts/build-libs.sh (tools/spinel-bpf-mlir/README.md).
LIBBPF_DIR="${BML_LIBBPF_DIR:-$BML/third_party/libbpf}"
ZLIB_DIR="${BML_ZLIB_DIR:-$BML/third_party/zlib}"
[ -f "$OUT/lib/libbml.a" ] || { echo "build-bml-test: $OUT/lib/libbml.a is missing — run scripts/setup.sh first" >&2; exit 1; }
rm -rf "$T"
mkdir -p "$T/obj" "$T/lib"
CF="-O2 -g -std=gnu11 -Wall -Wextra -Werror -DBML_TEST_CAPS -ffile-prefix-map=$BML=bml -ffile-prefix-map=$OUT=out -ffunction-sections -fdata-sections -I$BML/src -I$BML/include -I$LIBBPF_DIR/include/uapi -I$OUT/include"
# E131: cwd を bml の dir の下に — DWARF の comp_dir が -ffile-prefix-map=$BML=bml で写る (setup.sh の build-libs.sh と同じ形)
cd "$ZLIB_DIR"
for c in $("$BML/scripts/srcs.sh" src); do
  obj=$(printf '%s' "${c#"$BML"/src/}" | tr / _)
  gcc $CF -c "$c" -o "$T/obj/${obj%.c}.o"
done
ar crD "$T/lib/libbml.a" $(ls "$T"/obj/*.o | LC_ALL=C sort)
echo "build-bml-test: $T/lib/libbml.a"
