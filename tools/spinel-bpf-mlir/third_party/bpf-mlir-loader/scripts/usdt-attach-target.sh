#!/bin/bash
# scripts/usdt-attach-target.sh — E044: USDT の attach の root の段 (unshare -n の中 — 呼び手は gate の rsudo か flock の中の sudo)。
# fixture の 3 つの build ごとに bml の製品の形 (usdt_run point — ASan) と Go の AttachUSDT (usdt-attach-oracle refctr) の行を比べ、
# 名前つきの観測 (multi・multi_perf・norefctr) と変異 6 つと製品の照合する load (checked) を見る。1 行ずつ結果を書き、予測と違えば rc 1。
#
#   sudo scripts/usdt-attach-target.sh <作業の dir — ELF・sha・fixture> <tools-asan> <tools-mut> <usdt-attach-oracle>
# 作業の dir は gate が非 root で作る: usdt-<b>.bpf.o・usdt-<b>.sha・fixture-<b> (b は O0・O2・gcc-O2)
set -uo pipefail
D="${1:?}"; TA="${2:?}"; TM="${3:?}"; ORA="${4:?}"
[ "$(id -u)" = 0 ] || { echo "usdt-attach-target: root で走らせる" >&2; exit 2; }
U=${SUDO_UID:-1000}
bad=0
run() { timeout 60 unshare -n "$@"; }
for b in O0 O2 gcc-O2; do
  e="$D/usdt-$b.bpf.o" s=$(cat "$D/usdt-$b.sha") f="$D/fixture-$b"
  run "$ORA" run "$e" "$f" refctr > "$D/go-$b.txt" 2> "$D/go-$b.err" || { echo "FAIL go $b"; bad=1; }
  run "$TA/usdt_run" run "$e" "$s" "$f" point > "$D/point-$b.txt" 2> "$D/point-$b.err" || { echo "FAIL point $b"; bad=1; }
  run "$TA/usdt_run" run "$e" "$s" "$f" multi > "$D/multi-$b.txt" 2> "$D/multi-$b.err" || { echo "FAIL multi $b"; bad=1; }
  for m in point multi; do
    cmp -s "$D/go-$b.txt" "$D/$m-$b.txt" && echo "same $m $b" || { echo "DIFF $m $b"; bad=1; }
  done
  # 製品の形は expected_attach_type 0、multi は libbpf の BPF_TRACE_UPROBE_MULTI (48)
  [ "$(grep -c 'expected_attach_type 0 ' "$D/point-$b.err")" = 2 ] && [ "$(grep -c 'expected_attach_type 48 ' "$D/multi-$b.err")" = 2 ] ||
    { echo "BAD expected_attach_type $b"; bad=1; }
  [ "$(grep -c '^event prog=0' "$D/go-$b.txt")" = 12 ] && [ "$(grep -c '^event prog=1' "$D/go-$b.txt")" = 4 ] && grep -qx 'left 0' "$D/go-$b.txt" ||
    { echo "BAD events $b"; bad=1; }
done
b=gcc-O2 e="$D/usdt-gcc-O2.bpf.o" s=$(cat "$D/usdt-gcc-O2.sha") f="$D/fixture-gcc-O2"
# multi_prog_perf_attach: UPROBE_MULTI の program を点ごとの uprobe で — kernel の EINVAL (BML_OTHER 5)
run "$TA/usdt_run" run "$e" "$s" "$f" multi_perf > "$D/multi_perf.txt" 2> /dev/null
[ "$(grep -c '^attach u[a-z]* kind=5 .*: invalid argument$' "$D/multi_perf.txt")" = 2 ] && echo "named multi_prog_perf_attach EINVAL" ||
  { echo "BAD multi_perf: $(tr '\n' '|' < "$D/multi_perf.txt")"; bad=1; }
# norefctr: Go の RefCtrOffset 0 と bml の変異 usdt.no_ref_ctr が同じ — guarded の event 0 件
run "$ORA" run "$e" "$f" norefctr > "$D/go-norefctr.txt" 2> /dev/null
BML_MUTANT=usdt.no_ref_ctr run "$TM/usdt_run" run "$e" "$s" "$f" point > "$D/mut-no_ref_ctr.txt" 2> /dev/null
cmp -s "$D/go-norefctr.txt" "$D/mut-no_ref_ctr.txt" && [ "$(grep -c '^event prog=1' "$D/go-norefctr.txt")" = 0 ] && echo "named norefctr guarded 0" ||
  { echo "BAD norefctr"; bad=1; }
# 変異: 予測 (E044 の追補) — 落ちる理由で照らす
for m in keep_more keep_libbpf_multi cookie_zero spec_skip no_prelink; do
  BML_MUTANT=usdt.$m run "$TM/usdt_run" run "$e" "$s" "$f" point > "$D/mut-$m.txt" 2> "$D/mut-$m.err"
  ok=0
  case "$m" in
    keep_more) diff <(grep -v '^left' "$D/go-$b.txt") <(grep -v '^left' "$D/mut-$m.txt") > /dev/null && grep -qx 'left 2' "$D/mut-$m.txt" && ok=1 ;;
    keep_libbpf_multi) cmp -s "$D/go-$b.txt" "$D/mut-$m.txt" && [ "$(grep -c 'expected_attach_type 48 ' "$D/mut-$m.err")" = 2 ] && ok=1 ;;
    cookie_zero) [ "$(grep '^event prog=0' "$D/mut-$m.txt" | grep -vc ' cookie=0 ')" = 0 ] && ! cmp -s "$D/go-$b.txt" "$D/mut-$m.txt" && ok=1 ;;
    spec_skip) [ "$(grep '^event' "$D/mut-$m.txt" | grep -vc ' st1=-22 v2=0 st2=-22$')" = 0 ] && [ "$(grep -c '^event' "$D/mut-$m.txt")" = 16 ] && ok=1 ;;
    no_prelink) cmp -s "$D/go-$b.txt" "$D/mut-$m.txt" && ok=1 ;;
  esac
  [ "$ok" = 1 ] && echo "mutant usdt.$m ok" || { echo "BAD mutant usdt.$m"; bad=1; }
done
# E046: 製品の照合する load (C ABI の loader の宣言 cilium-v0.22-usdt — usdt_attach ref_ctr) は OK、照合する load + bml_attach_usdt (product) は
# 3 build で Go と同じ。変異 abi.decl_cilium022 (前の宣言なし = cilium-v0.22) は usdt_loader で止める (E044 の H6 の形)
run "$TA/usdt_run" run "$e" "$s" "$f" checked > "$D/checked.txt" 2> /dev/null
grep -qx 'checked kind=0 unmet=' "$D/checked.txt" && echo "checked ok" || { echo "BAD checked: $(cat "$D/checked.txt")"; bad=1; }
BML_MUTANT=abi.decl_cilium022 run "$TM/usdt_run" run "$e" "$s" "$f" checked > "$D/checked-mut.txt" 2> /dev/null
grep -qx 'checked kind=3 unmet=usdt_loader,usdt_loader' "$D/checked-mut.txt" && echo "mutant abi.decl_cilium022 ok" ||
  { echo "BAD mutant abi.decl_cilium022: $(cat "$D/checked-mut.txt")"; bad=1; }
# E052: 宣言 cilium-v0.22-usdt-ksyscall の片方を落とす変異 — usdt を落とせば usdt_loader で止まり、ksyscall を落としても USDT は OK
BML_MUTANT=abi.decl_no_usdt run "$TM/usdt_run" run "$e" "$s" "$f" checked > "$D/checked-nousdt.txt" 2> /dev/null
grep -qx 'checked kind=3 unmet=usdt_loader,usdt_loader' "$D/checked-nousdt.txt" && echo "mutant abi.decl_no_usdt ok" ||
  { echo "BAD mutant abi.decl_no_usdt: $(cat "$D/checked-nousdt.txt")"; bad=1; }
BML_MUTANT=abi.decl_no_ksyscall run "$TM/usdt_run" run "$e" "$s" "$f" checked > "$D/checked-noksys.txt" 2> /dev/null
grep -qx 'checked kind=0 unmet=' "$D/checked-noksys.txt" && echo "mutant abi.decl_no_ksyscall ok (usdt)" ||
  { echo "BAD mutant abi.decl_no_ksyscall (usdt): $(cat "$D/checked-noksys.txt")"; bad=1; }
for b in O0 O2 gcc-O2; do
  run "$TA/usdt_run" run "$D/usdt-$b.bpf.o" "$(cat "$D/usdt-$b.sha")" "$D/fixture-$b" product > "$D/product-$b.txt" 2> /dev/null
  cmp -s "$D/go-$b.txt" "$D/product-$b.txt" && echo "same product $b" || { echo "DIFF product $b"; bad=1; }
done
chown -R "$U:$(id -g "$U")" "$D"
exit $bad
