#!/bin/bash
# scripts/fuzz.sh — libFuzzer の harness (test/<層>/fuzz_<名前>.c) を ASan + UBSan で build して回す (E002)。
#
#   scripts/fuzz.sh <名前> <秒>       # 例: scripts/fuzz.sh req_parse 600 (探索 — 版の取り込みの時に手で)
#   scripts/fuzz.sh <名前> 0          # 種の再生だけ (gate — E011)
#
# 種は corpus (parse・cases の requirements と ELF の section)、work の corpus と crash は build/fuzz/<名前>/。
# rc 0 は crash 0、それ以外は crash (libFuzzer の rc)。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1"
SECS="$2"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
export TMPDIR="$HERE/build/tmp"
W="$HERE/build/fuzz/$NAME"
mkdir -p "$W/corpus" "$W/seeds" "$W/crash"
CF=(-O1 -g -std=gnu11 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -I"$HERE/src" -I"$HERE/include"
    -I"$HERE/third_party/libbpf/include/uapi" -I"$HERE/build/libs/include")
# E011 H1: src は fuzzer の計装で 1 回だけ compile して harness の間で共有 (src・include のどれかが archive より新しければ作り直す)
A="$HERE/build/fuzz/libsrc.a"
if [ ! -f "$A" ] || [ -n "$(find "$HERE/src" "$HERE/include" "$HERE/scripts/fuzz.sh" -newer "$A" -type f -print -quit)" ]; then
  O="$HERE/build/fuzz/obj"
  rm -rf "$O"; mkdir -p "$O"
  "$HERE/scripts/srcs.sh" src | xargs -P "$(nproc)" -I{} sh -c 'o="$1/$(printf "%s" "${2#"$3"/src/}" | tr / _)"; shift 3; exec "$@" -fsanitize=fuzzer-no-link -c "$0" -o "${o%.c}.o"' {} "$O" {} "$HERE" "$LLVM_PREFIX/bin/clang" "${CF[@]/-fsanitize=fuzzer,address,undefined/-fsanitize=address,undefined}"
  rm -f "$A"; ar crD "$A" $(ls "$O"/*.o | LC_ALL=C sort)
fi
"$LLVM_PREFIX/bin/clang" "${CF[@]}" -o "$W/fuzz" "$("$HERE/scripts/srcs.sh" test "fuzz_$NAME")" "$A" \
  "$HERE/build/libs/lib/libbpf.a" "$HERE/build/libs/lib/libelf.a" "$HERE/build/libs/lib/libz.a"
C="$HERE/third_party/bpf-mlir/conformance/requirements"
case "$NAME" in
req_parse)
  i=0
  for f in "$C"/parse/*/requirements.txt "$C"/cases/*/requirements.txt; do cp "$f" "$W/seeds/s$i"; i=$((i + 1)); done
  for o in "$C"/cases/*/object.bpf.o; do
    "$LLVM_PREFIX/bin/llvm-objcopy" -O binary --only-section=.ebpf_requirements "$o" "$W/seeds/s$i" 2>/dev/null && i=$((i + 1))
  done ;;
json)
  i=0
  for f in $(find "$C" -name '*.json' | LC_ALL=C sort); do cp "$f" "$W/seeds/s$i"; i=$((i + 1)); done ;;
req_elf)
  i=0
  for f in "$C"/cases/*/object.bpf.o; do cp "$f" "$W/seeds/s$i"; i=$((i + 1)); done ;;
maps_decls)
  # records の照合が BTF を読む経路を通す ELF (corpus の records の case)
  export BML_FUZZ_ELF="$C/maps/rec_match/object.bpf.o"
  i=0
  for f in "$C"/maps/*/maps.json; do cp "$f" "$W/seeds/s$i"; i=$((i + 1)); done ;;
btf_layout)
  i=0
  for f in "$C"/maps/*/object.bpf.o "$C"/cases/*/object.bpf.o; do [ -f "$f" ] && cp "$f" "$W/seeds/s$i" && i=$((i + 1)); done ;;
kbtf)
  i=0
  "$LLVM_PREFIX/bin/clang" -g -O2 --target=bpf -c "$HERE/test/btf/fixtures/kbtf_fixture.c" -o "$W/fx.o"
  "$LLVM_PREFIX/bin/llvm-objcopy" --dump-section .BTF="$W/seeds/fx" "$W/fx.o" "$W/x.o"
  for o in "$C"/cases/*/object.bpf.o "$C"/maps/*/object.bpf.o; do
    "$LLVM_PREFIX/bin/llvm-objcopy" --dump-section .BTF="$W/seeds/s$i" "$o" "$W/x.o" 2>/dev/null && i=$((i + 1))
  done ;;
recorded)
  i=0
  for f in "$C"/cases/*/caps.json; do cp "$f" "$W/seeds/s$i"; i=$((i + 1)); done ;;
dwarf)
  # E008 H6: uprobe の C / C++ / DWARF 無しの fixture (Go の binary は max_len を超える)
  i=0
  for f in "$C"/bin/fixture "$C"/bin/fixture_cpp "$C"/bin/fixture_cpp_rust_lang "$C"/bin/fixture_nodwarf "$HERE"/docs/experiments/results/E008/fuzz-*.elf; do
    cp "$f" "$W/seeds/s$i"; i=$((i + 1))
  done ;;
*)
  echo "fuzz: 知らない harness $NAME" >&2; exit 2 ;;
esac
cd "$W"
rc=0
if [ "$SECS" = 0 ]; then
  # E011 H2 (a): 種の再生だけ (-runs=0 — 種の各々を ASan + UBSan で 1 回、探索しない — gate の形。探索は秒を与えて手で)
  ./fuzz -runs=0 -max_len=131072 -artifact_prefix="$W/crash/" seeds 2> "$W/log.txt" || rc=$?
  echo "fuzz $NAME: replay $(ls seeds | wc -l) seeds rc=$rc"
  exit $rc
fi
./fuzz -max_total_time="$SECS" -max_len=131072 -artifact_prefix="$W/crash/" -print_final_stats=1 corpus seeds 2> "$W/log.txt" || rc=$?
grep -E '^stat::(number_of_executed_units|peak_rss_mb)|^#[0-9]+.*DONE' "$W/log.txt" || true
echo "fuzz $NAME: ${SECS}s rc=$rc crash=$(ls "$W/crash" | wc -l)"
exit $rc
