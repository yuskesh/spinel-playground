#!/bin/bash
# E066: 形式 30〜32 の corpus の外の分岐 — Go と C の差動 (parse・記録の caps・FromELF の sleepable・Check / Unmet の文)、段 A の loud な停止 (H4)、
# 答えの規則の単体 (H7)。kernel・root に触れない。使い方: scripts/target-rows-unit.sh FRESH_OUT
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/target-rows-unit.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?target-rows-unit.sh FRESH_OUT}"
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
GO="${GO:-/usr/local/go/bin/go}"
OC="${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-objcopy"
F="$HERE/test/req/fixture/target_rows"
B="$HERE/third_party/bpf-mlir"
EC="$HERE/build/bpf-mlir/bin/ebpf-compile"
for name in parse-oracle target-rows-oracle recorded-check; do
  (cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$GO" build -o "$OUT/$name" "./cmd/$name")
done

# sleepable の ELF: 正の入力と、照合の各文を踏む変形 (section の名・symbol・requirements の section だけを変える)
E="$OUT/elf"; mkdir "$E"
"$EC" "$B/kernel/sleepable/mlir/copy.mlir" --schema "$B/kernel/sleepable/mlir/schema.json" -o "$E/base.bpf.o" > "$OUT/compile-copy.log" 2>&1
SEC=fentry.s/__x64_sys_getpgid
"$OC" -O binary --only-section=.ebpf_requirements "$E/base.bpf.o" "$OUT/req.txt"
"$OC" --rename-section "$SEC=fentry/__x64_sys_getpgid" "$E/base.bpf.o" "$E/plain_section.bpf.o"
"$OC" --rename-section "$SEC=fentry.s/other" "$E/base.bpf.o" "$E/other_target.bpf.o"
grep -vP '^sleepable\t' "$OUT/req.txt" > "$OUT/req-norow.txt"
"$OC" --update-section ".ebpf_requirements=$OUT/req-norow.txt" "$E/base.bpf.o" "$E/no_row.bpf.o"
"$OC" --redefine-sym prog=renamed "$E/base.bpf.o" "$E/renamed_func.bpf.o"
: > "$OUT/empty"
"$OC" --add-section "fentry.s/empty=$OUT/empty" "$E/base.bpf.o" "$E/extra_section.bpf.o"
"$OC" --add-section "$SEC=$OUT/empty" "$E/base.bpf.o" "$E/dup_section.bpf.o" # 同じ名前の空の section (Go の holds は名前が鍵 — 通る)
{ grep -vP '^(attach|sleepable)\t' "$OUT/req.txt"
  printf 'program\tghost\ttracing\t26\n'
  grep -P '^(attach|sleepable)\t' "$OUT/req.txt"
  printf 'attach\tghost\ttrace_fentry\t__x64_sys_getpgid\nsleepable\tghost\n'; } > "$OUT/req-ghost.txt"
"$OC" --update-section ".ebpf_requirements=$OUT/req-ghost.txt" "$E/base.bpf.o" "$E/row_no_func.bpf.o"

"$OUT/parse-oracle" "$F"/parse/*.txt > "$OUT/parse.go"
"$OUT/target-rows-oracle" caps "$F"/caps/*.json > "$OUT/caps.go"
"$OUT/target-rows-oracle" elf "$E"/*.bpf.o > "$OUT/elf.go"
for mode in tools tools-asan; do
  T="$HERE/build/$mode"
  "$T/parse_case" -m "$F"/parse/*.txt > "$OUT/parse.$mode"
  "$T/target_rows_case" caps "$F"/caps/*.json > "$OUT/caps.$mode"
  "$T/target_rows_case" elf "$E"/*.bpf.o > "$OUT/elf.$mode"
  for k in parse caps elf; do diff "$OUT/$k.go" "$OUT/$k.$mode" || { echo "target-rows: $k の Go と C ($mode) が違う" >&2; exit 1; }; done
  "$OUT/recorded-check" "$F/cases" "$T/check_case" "$OUT/$mode-recorded"
  "$T/live_target_rows_unit" > "$OUT/live.$mode"
done
# Close の失敗の seam: syscall を link の --wrap で置き換える (kernel0)。mut の binary は target-rows-mutants.sh が使う
wrap=(-Wl,--wrap=lv_prog_load -Wl,--wrap=lv_bpf -Wl,--wrap=lv_close_checked -Wl,--wrap=bml_live_func_args)
for mode in release asan mut; do
  cc=(gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror); lib="$HERE/build/libs/lib/libbml.a"
  if [ "$mode" = asan ]; then
    cc=("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang" -O1 -g -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    lib="$HERE/build/tools-asan/libsrc.a"
  elif [ "$mode" = mut ]; then
    cc+=(-DBML_MUTATION -DBML_TEST_CAPS); lib="$HERE/build/tools-mut/libsrc.a"
  fi
  "${cc[@]}" -I"$HERE/src" -I"$HERE/include" -I"$HERE/third_party/libbpf/include/uapi" -I"$HERE/build/libs/include" \
    "$HERE/test/caps/live_target_rows_close.c" "${wrap[@]}" "$lib" "$HERE/build/libs/lib/libbpf.a" "$HERE/build/libs/lib/libelf.a" "$HERE/build/libs/lib/libz.a" -lpthread -ldl -o "$OUT/live_close.$mode"
  "$OUT/live_close.$mode" > "$OUT/live_close.$mode.log" 2>&1 || { cat "$OUT/live_close.$mode.log"; exit 1; }
done
[ "$(grep -c ': PASS$' "$OUT/live_close.release.log")" = 15 ] || { cat "$OUT/live_close.release.log"; exit 1; }
[ "$(wc -l < "$OUT/parse.go")" = "$(find "$F/parse" -name '*.txt' | wc -l)" ]
[ "$(wc -l < "$OUT/caps.go")" = "$(find "$F/caps" -name '*.json' | wc -l)" ]
# 感度: 負の入力がそれぞれ名指しの文で落ちている (全て ok で「差 0」にならない)
[ "$(grep -c $'\tok$' "$OUT/elf.go")" = 2 ] && grep -q $'^base.bpf.o\tok$' "$OUT/elf.go" && grep -q $'^dup_section.bpf.o\tok$' "$OUT/elf.go"
[ "$(grep -c $'\terr\tsleepable: ' "$OUT/elf.go")" = 6 ] || { cat "$OUT/elf.go"; exit 1; }
[ "$(grep -c $'\terr\t' "$OUT/caps.go")" -ge 20 ] || { cat "$OUT/caps.go"; exit 1; }
echo "target-rows: parse $(wc -l < "$OUT/parse.go")・caps $(wc -l < "$OUT/caps.go")・elf $(wc -l < "$OUT/elf.go") が Go と一致 (release・ASan)、kernel0"

# E067 H1 (E066 の H4 を反転): netkit/・fentry.s/ の ELF は読めて load の入口の形の検査を通る。表に足していない綴りは名指しで止まる
S="$OUT/stop"; mkdir "$S"
for m in peer-drop peer-pass primary-drop primary-pass; do
  "$EC" "$B/kernel/netkit/mlir/$m.mlir" --schema "$B/kernel/netkit/mlir/$m.schema.json" -o "$S/$m.bpf.o" > "$OUT/compile-$m.log" 2>&1
done
cp "$E/base.bpf.o" "$S/copy.bpf.o"
"$HERE/build/tools/target_rows_case" elf "$S"/*.bpf.o > "$OUT/stop-read"
[ "$(grep -c $'\tok$' "$OUT/stop-read")" = 5 ] || { cat "$OUT/stop-read"; exit 1; }
"$HERE/build/tools/target_rows_case" shape "$S"/*.bpf.o > "$OUT/stop-shape"
[ "$(grep -c $'\trc=0\t' "$OUT/stop-shape")" = 5 ] || { cat "$OUT/stop-shape"; exit 1; }
O2="$OUT/other-spellings"; mkdir "$O2"
for sp in fsession/x kprobe.multi/x lsm_cgroup/x fexit.s/x; do
  "$OC" --rename-section "$SEC=$sp" "$E/base.bpf.o" "$O2/$(printf '%s' "$sp" | tr '/.' '__').bpf.o"
done
"$HERE/build/tools/target_rows_case" shape "$O2"/*.bpf.o > "$OUT/other-shape"
[ "$(grep -cP '\trc=-?[1-9][0-9]*\tstage=[^\t]*\t.*(fsession/x|kprobe\.multi/x|lsm_cgroup/x|fexit\.s/x)' "$OUT/other-shape")" = 4 ] || { cat "$OUT/other-shape"; exit 1; }
"$HERE/build/tools/target_rows_case" guard "$S/copy.bpf.o" "$E/plain_section.bpf.o" > "$OUT/guard" 2> "$OUT/guard.err"
[ "$(cat "$OUT/guard")" = "$(printf 'copy.bpf.o\trc=0\tsleepable=1\nplain_section.bpf.o\trc=0\tsleepable=0')" ] || { cat "$OUT/guard"; exit 1; }
echo 'target-rows: netkit 4・sleepable 1 は load の入口を通り、表の外の 4 綴りは名指しで止まる、fentry.s/ だけに sleepable の印、kernel0'
