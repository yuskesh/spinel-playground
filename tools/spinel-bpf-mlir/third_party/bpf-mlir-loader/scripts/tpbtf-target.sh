#!/bin/bash
# scripts/tpbtf-target.sh — E024: 1 つの target (host か VM — scripts/run-in-vm.sh) で群 6 (tp_btf) の
#   (1) 契約の試験 abi_tpbtf (ASan) と変異の対照 (mut) — 6.6.* は nullable (tp_btf の照合が arg_nullable で止まる — E024 追補 2)、他は checked
#   (2) 権限の組 (root・bpf+net_admin・bpf+perfmon・none) × e24tc / e24tp の load の kind と hint を bml と mojo の Go の loader で (capload の driver)
#   (3) 同じ権限の組の e24tc の照合しない load・test run・attach・fork・detach を bml (tpbtf_diff) と cilium の AttachTracing (tpbtf-oracle) で
# (root、unshare -n の中、root 以外は setpriv — capload-target.sh と同じ形)。
#
#   sudo scripts/tpbtf-target.sh <出力の親> <ASAN_DIR> <MUT_DIR> <DRV_DIR> <tpbtf-oracle> <ELF_DIR>     (ELF_DIR に e24{tc,tp}.bpf.o と .sha)
set -uo pipefail
PARENT="${1:?}"; ASAN="${2:?}"; MUT="${3:?}"; DRV="${4:?}"; ORA="${5:?}"; ED="${6:?}"
[ "$(id -u)" = 0 ] || { echo "tpbtf-target: root で走らせる" >&2; exit 2; }
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O"
U=${SUDO_UID:-1000}
case "$K" in 6.6.*) MODE=ptrnull ;; *) MODE=checked ;; esac # E027: 判定の版 6 — 6.6 は struct の引数の e24tp だけが止まる
TC="$ED/e24tc.bpf.o"; TP="$ED/e24tp.bpf.o"; STC=$(cat "$ED/e24tc.sha"); STP=$(cat "$ED/e24tp.sha")
fail=0
# (1)
unshare -n "$ASAN/abi_tpbtf" "$TC" "$STC" "$TP" "$STP" "$MODE" > "$O/contract.txt" 2>&1 || fail=1
cat "$O/contract.txt"
# 契約の ok の数と、変異ごとの意図した FAIL の id の組 (checked は e24tp の P も、ptrnull は e24tc の T だけ — L1・T1〜T8・L2 の 10)
if [ "$MODE" = checked ]; then okn=14; want=("trace.tpbtf_no_name_check:T7 P4" "trace.tpbtf_kind_fentry:T1" "trace.tpbtf_no_run_hint:T3 P1")
else okn=10; want=("trace.tpbtf_no_name_check:T7" "trace.tpbtf_kind_fentry:T1" "trace.tpbtf_no_run_hint:T3"); fi
grep -q "^abi_tpbtf: ok $okn, FAIL 0$" "$O/contract.txt" || { echo "tpbtf-target $K: 契約の ok が $okn でない — FAIL"; fail=1; }
for mf in "${want[@]}"; do
  m=${mf%%:*}
  BML_MUTANT=$m unshare -n "$MUT/abi_tpbtf" "$TC" "$STC" "$TP" "$STP" "$MODE" > "$O/mut-$m.txt" 2>&1
  got=$(grep -E '^[A-Z][0-9]+: .* — FAIL$' "$O/mut-$m.txt" | cut -d: -f1 | tr '\n' ' ')
  if [ "$got" = "${mf#*:} " ]; then echo "mut $m: FAIL $got— 意図どおり ok"; else echo "mut $m: FAIL「$got」が「${mf#*:}」でない — FAIL"; fail=1; fi
done
# (2) と (3)
for s in root bpf,net_admin bpf,perfmon none; do
  case "$s" in
    root) run=() ;;
    none) run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all) ;;
    *) c=$(echo "$s" | sed 's/,/,+/g')
       run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+"$c" --ambient-caps=-all,+"$c" --bounding-set=-all,+"$c") ;;
  esac
  for f in tc tp; do
    for side in mojo bml; do
      unshare -n "${run[@]}" "$DRV/drv_capload_$side" "$s/$f" "$ED/e24$f.bpf.o" "$(cat "$ED/e24$f.sha")" >> "$O/load-$side.txt" 2>> "$O/load-$side.msg"
    done
  done
  unshare -n "${run[@]}" "$ASAN/tpbtf_diff" "$s" "$TC" "$STC" tc sched_process_fork >> "$O/attach-bml.txt" 2>> "$O/attach-bml.msg"
  unshare -n "${run[@]}" "$ORA" "$s" "$TC" tc >> "$O/attach-go.txt" 2>> "$O/attach-go.msg"
done
# 名指しの既知の差 none_guard (E024 — 事後に見つけた): 権限の無い組の照合しない load で、bml は guard が libbpf の BTF の feature の probe の答えを
# 得られず load の前に止め (fail closed — E005、kind 2)、cilium は map の作成で EPERM。どちらも load しない (製品の照合する load は (2) で mojo と同じ)。
# bml の文が guard の止まりである時だけ、none の行の load=other を load=eperm と読み替えて比べる
cp "$O/attach-bml.txt" "$O/attach-bml.cmp"
if grep -q "the loader refused to load (predict): BTF feature" "$O/attach-bml.msg"; then
  sed -i 's/^none load=other /none load=eperm /' "$O/attach-bml.cmp"
  grep -q '^none load=eperm ' "$O/attach-bml.cmp" && echo "tpbtf-target $K: 名指しの既知の差 none_guard (bml の guard の止まり — cilium は EPERM)"
fi
# 名指しの既知の差 mojo_policy5 (E027 — 予測): mojo の Go の oracle (c-archive 5a53a6d) は bpf-mlir v0.17.0 (判定の版 5) で、6.6 の e24tc
# (読まない引数だけの tp_btf) を arg_nullable で止める (kind 3)。bml は判定の版 6 で load する (kind 0)。6.6 の root と bpf+perfmon の e24tc の
# 2 行だけを mojo の形に読み替えて比べる (mojo が v1.1.0 に上がれば消す)
cp "$O/load-bml.txt" "$O/load-bml.cmp"
case "$K" in 6.6.*)
  sed -i -E 's#^(root|bpf,perfmon)/tc kind=0 hint=no perfmon=no net_admin=no$#\1/tc kind=3 hint=no perfmon=no net_admin=no#' "$O/load-bml.cmp"
  cmp -s "$O/load-bml.txt" "$O/load-bml.cmp" || echo "tpbtf-target $K: 名指しの既知の差 mojo_policy5 ($(diff "$O/load-bml.txt" "$O/load-bml.cmp" | grep -c '^<') 行 — mojo は判定の版 5)" ;;
esac
for t in load attach; do
  a=mojo b="$O/load-bml.cmp"; [ $t = attach ] && { a=go; b="$O/attach-bml.cmp"; }
  echo "== $t ($a | bml)"; paste -d'|' "$O/$t-$a.txt" "$O/$t-bml.txt"
  if cmp -s "$O/$t-$a.txt" "$b"; then echo "tpbtf-target $K: $t の $(wc -l < "$b") 行が一致 — ok"; else echo "tpbtf-target $K: $t が違う — FAIL"; fail=1; fi
done
exit $fail
