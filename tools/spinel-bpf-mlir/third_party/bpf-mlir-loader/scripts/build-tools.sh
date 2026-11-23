#!/bin/bash
# scripts/build-tools.sh — 試験の道具 (test/<層>/) と bml-precheck (cmd/bml-precheck/) を build する (E002)。
#
#   scripts/build-tools.sh [release|asan|mut]
#
# release: build/libs の libbml.a (scripts/build-libs.sh) に link — build/tools/。
# asan:    src の全ての .c を clang の ASan + UBSan で直接 compile して link — build/tools-asan/ (製品の .a とは別)。
# mut:     変異の対照の build (-DBML_MUTATION — src/util/mutation.h) — build/tools-mut/。製品の .a とは別。
# asan と mut は -DBML_TEST_CAPS (試験の caps の kind 1 / 2 — E006、src/abi/object.c) も。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-release}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
export TMPDIR="$HERE/build/tmp"
mkdir -p "$TMPDIR"
TOOLS="netkit_finish_unit own_ids_unit target_rows_case live_target_rows_unit parse_case json_check elf_case check_case json_case maps_case kbtf_case live_case load_case feat_case abi_case abi_more abi_globals abi_race abi_trace abi_tcx abi_dead abi_up dwarf_case abi_lpm usdt_case tp_cpus strarg_case checked_load uprobe_offset e56_attach kernel_values_unit rejected_case"
SRCS=$("$HERE/scripts/srcs.sh" src)
PRECHECK=$("$HERE/scripts/srcs.sh" cmd bml-precheck)

case "$MODE" in
release)
  OUT="$HERE/build/tools"
  L="$HERE/build/libs"
  CC=(gcc -O2 -g -std=gnu11 -Wall -Wextra -Werror -I"$HERE/src" -I"$HERE/cmd" -I"$L/include")
  LIB=("$L/lib/libbml.a")
  ;;
asan)
  OUT="$HERE/build/tools-asan"
  CC=("$LLVM_PREFIX/bin/clang" -O1 -g -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all -DBML_TEST_CAPS
      -fno-omit-frame-pointer -I"$HERE/src" -I"$HERE/cmd" -I"$HERE/include" -I"$HERE/third_party/libbpf/include/uapi" -I"$HERE/build/libs/include")
  # shellcheck disable=SC2206
  LIB=($SRCS)
  ;;
mut)
  OUT="$HERE/build/tools-mut"
  CC=(gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror -DBML_MUTATION -DBML_TEST_CAPS -I"$HERE/src" -I"$HERE/cmd" -I"$HERE/include" -I"$HERE/third_party/libbpf/include/uapi" -I"$HERE/build/libs/include")
  # shellcheck disable=SC2206
  LIB=($SRCS)
  ;;
*)
  echo "build-tools: mode must be release, asan or mut" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
# E011 H1: asan / mut は src を mode ごとに 1 回だけ (並列に) compile して archive に — 道具はそれに link する (前は道具ごとに src の全てを
# compile し直した)。同じ source と flag — 差は link の単位だけ (archive の object は道具が参照するものだけが入る — libbml.a と同じ)
if [ "$MODE" != release ]; then
  O="$OUT/obj"
  rm -rf "$O"; mkdir -p "$O"
  printf '%s\n' "${LIB[@]}" | xargs -P "$(nproc)" -I{} sh -c 'o="$1/$(printf "%s" "${2#"$3"/src/}" | tr / _)"; shift 3; exec "$@" -c "$0" -o "${o%.c}.o"' {} "$O" {} "$HERE" "${CC[@]}"
  rm -f "$OUT/libsrc.a"
  ar crD "$OUT/libsrc.a" $(ls "$O"/*.o | LC_ALL=C sort)
  LIB=("$OUT/libsrc.a")
fi
# load (E005) は libbpf・libelf・zlib (build-libs.sh の産物 — 版固定) に link する
LIB+=("$HERE/build/libs/lib/libbpf.a" "$HERE/build/libs/lib/libelf.a" "$HERE/build/libs/lib/libz.a")
for t in $TOOLS; do
  "${CC[@]}" -o "$OUT/$t" "$("$HERE/scripts/srcs.sh" test "$t")" "${LIB[@]}"
done
# E067: VM の runner は全ての mode に (H6〜H8 は release の libbml.a を測る、H9 は mut)。own_program_id は runner にだけ link する別の .o
for t in netkit_run sleepable_run; do
  "${CC[@]}" -o "$OUT/$t" "$("$HERE/scripts/srcs.sh" test $t)" "$("$HERE/scripts/srcs.sh" test own_program_id)" "${LIB[@]}"
done
# E017: 試験の口 (bml_testonly_ — -DBML_TEST_CAPS の build だけに在る) の試験は asan / mut だけ
if [ "$MODE" != release ]; then
  "${CC[@]}" -o "$OUT/abi_testonly" "$("$HERE/scripts/srcs.sh" test abi_testonly)" "${LIB[@]}"
  "${CC[@]}" -o "$OUT/kbtf_index" "$("$HERE/scripts/srcs.sh" test kbtf_index)" "${LIB[@]}" # E022: 索引の新旧の byte の比べ
  "${CC[@]}" -o "$OUT/abi_tpbtf" "$("$HERE/scripts/srcs.sh" test abi_tpbtf)" "${LIB[@]}" # E024: tp_btf (試験の口の差し替えと照合しない load)
  "${CC[@]}" -o "$OUT/abi_print" "$("$HERE/scripts/srcs.sh" test abi_print)" "${LIB[@]}"  # E025: libbpf の print の行き先
  "${CC[@]}" -o "$OUT/run_wave1" "$("$HERE/scripts/srcs.sh" test run_wave1)" "${LIB[@]}"  # E034: 波 1 の test run (変異 run.* は mut)
  "${CC[@]}" -o "$OUT/attach_wave1" "$("$HERE/scripts/srcs.sh" test attach_wave1)" "${LIB[@]}"  # E035: 波 1 の attach (変異 attach.* は mut)
  "${CC[@]}" -o "$OUT/attach_caller" "$("$HERE/scripts/srcs.sh" test attach_caller)" "${LIB[@]}"  # E038: 呼び手の先への attach
  "${CC[@]}" -o "$OUT/tp_allcpu" "$("$HERE/scripts/srcs.sh" test tp_allcpu)" "${LIB[@]}"  # E040: tracepoint の全ての CPU の attach
  "${CC[@]}" -o "$OUT/usdt_run" "$("$HERE/scripts/srcs.sh" test usdt_run)" "${LIB[@]}"  # E044: USDT の attach (変異 usdt.* は mut)
  "${CC[@]}" -o "$OUT/ksys_run" "$("$HERE/scripts/srcs.sh" test ksys_run)" "${LIB[@]}"  # E049: ksyscall の attach (変異 ksys.* は mut)
  "${CC[@]}" -o "$OUT/nf_run" "$("$HERE/scripts/srcs.sh" test nf_run)" "${LIB[@]}"  # E051: netfilter の link (変異 nf.* は mut)
  "${CC[@]}" -o "$OUT/print_hold" "$("$HERE/scripts/srcs.sh" test print_hold)" "${LIB[@]}" -lpthread # E026: print の借りの数え
  "${CC[@]}" -o "$OUT/tpbtf_diff" "$("$HERE/scripts/srcs.sh" test tpbtf_diff)" "${LIB[@]}"  # E024: cilium の AttachTracing との差動の C の側
fi
# shellcheck disable=SC2086
"${CC[@]}" -o "$OUT/bml-precheck" $PRECHECK "${LIB[@]}"
# E005 の負の対照: libbpf の feature の判断を偽る wrap 付きの load_case (試験の道具だけ — 製品の library に hook は無い)
"${CC[@]}" -Wl,--wrap=feat_supported -o "$OUT/load_case_wrap" "$("$HERE/scripts/srcs.sh" test load_case)" "$("$HERE/scripts/srcs.sh" test feat_wrap)" "${LIB[@]}"
# 差動の相手の Go の ebpf-precheck も毎回 submodule から (版を上げた後に古い binary を黙って使わない — 在れば使う形を作らない)
(cd "$HERE/third_party/bpf-mlir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly "${GO:-/usr/local/go/bin/go}" build -o "$OUT/ebpf-precheck" ./kernel/cmd/ebpf-precheck)
echo "$OUT"
