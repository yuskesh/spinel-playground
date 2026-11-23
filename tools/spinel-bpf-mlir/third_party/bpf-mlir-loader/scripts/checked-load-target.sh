#!/bin/bash
# scripts/checked-load-target.sh — E053 の H7 (root で): tpfield / sysarg の strptr・strarray を持つ ELF を製品の照合する load (bml_load_checked —
# build/tools/checked_load) で load だけ (attach も test run もしない)、root と CAP_BPF + CAP_PERFMON (uid 1000) で。同じ権限の Go の
# ebpf-precheck --live --loader=cilium-v0.22-usdt-ksyscall の result と、BlocksLoad の Unmet の kind の列と比べる (bml_load_checked の結果は
# 止める Unmet だけを持つ — 止めない Unknown (例: 非 root の tracefs の attach_target_unknown) は Go の側からも外して比べる)。
#
#   sudo scripts/checked-load-target.sh <ELF の dir (<名前>.bpf.o と <名前>.sha)> <maps.json> <TOOLS_DIR> <ebpf-precheck> [<名前> …]
#
# 名前を省くと E053 の 5 つ (E054 は tparray・kfieldpath の 13 を名前で渡す — maps.json は未宣言を許す test/abi/fixture/e54-undeclared.maps.json)。
#
# 出力の行: "<権限> <ELF> kind=N unmet=…" (C — checked_load の行) と "<権限> <ELF> go <result> unmet=…"、最後に "same" か "DIFF"。
set -uo pipefail
D="${1:?}"; M="${2:?}"; T="${3:?}"; PRE="${4:?}"; shift 4
NAMES=("$@"); [ "${#NAMES[@]}" -gt 0 ] || NAMES=(tp_user_str tp_argv argv argv20 ksys_user_str)
[ "$(id -u)" = 0 ] || { echo "checked-load-target: root で" >&2; exit 2; }
U="${SUDO_UID:-1000}"
kind() { case "$1" in ok) echo 0;; precheck_failed) echo 2;; target_rejected) echo 3;; verifier_rejected) echo 4;; *) echo "?$1";; esac; }
bad=0
for p in root bpf,perfmon; do
  run=()
  [ "$p" = root ] || run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+bpf,+perfmon --ambient-caps=-all,+bpf,+perfmon --bounding-set=-all,+bpf,+perfmon)
  for e in "${NAMES[@]}"; do
    c=$("${run[@]}" "$T/checked_load" "$D/$e.bpf.o" "$(cat "$D/$e.sha")" "$M")
    g=$("${run[@]}" "$PRE" --loader=cilium-v0.22-usdt-ksyscall --live --schema-sha256="$(cat "$D/$e.sha")" --maps="$M" "$D/$e.bpf.o" |
      jq -r '"\(.result) unmet=\([.unmet[] | select(.blocks_load) | .kind] | join(","))"') # 製品の結果は止める Unmet だけを持つ (止めない Unknown は載らない)
    echo "$p $c"
    echo "$p $e.bpf.o go $g"
    [ "${c#* }" = "kind=$(kind "${g%% *}") ${g#* }" ] || { echo "DIFF $p $e"; bad=1; }
  done
done
[ "$bad" = 0 ] && echo same || echo DIFF
exit $bad
