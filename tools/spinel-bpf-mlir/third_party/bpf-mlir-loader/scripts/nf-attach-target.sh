#!/bin/bash
# scripts/nf-attach-target.sh — E051: netfilter の link の root の段。各 run は自分の使い捨ての netns (unshare -n と loopback の up) の中 —
# host の netns に付けない。bml (nf_run — ASan) と cilium の link.AttachNetfilter (nf-attach-oracle) の行を比べ、変異 2 つを見る。予測と違えば rc 1。
#
#   sudo scripts/nf-attach-target.sh <作業の dir — nf.bpf.o と nf.sha> <tools-asan> <tools-mut> <nf-attach-oracle>
set -uo pipefail
D="${1:?}"; TA="${2:?}"; TM="${3:?}"; ORA="${4:?}"
[ "$(id -u)" = 0 ] || { echo "nf-attach-target: root で走らせる" >&2; exit 2; }
U=${SUDO_UID:-1000}
bad=0
NS='ip link set lo up && exec "$@"'
inns() { timeout 60 unshare -n sh -c "$NS" _ "$@"; }
S=$(cat "$D/nf.sha")
inns "$ORA" "$D/nf.bpf.o" > "$D/go.txt" 2> "$D/go.err" || { echo "FAIL go"; bad=1; }
inns "$TA/nf_run" "$D/nf.bpf.o" "$S" > "$D/c.txt" 2> "$D/c.err" || { echo "FAIL c"; bad=1; }
obs='control:100:ok,100:ok,100:ok,1200:ok,1200:ok received:100x3,1200x2 linked:100:ok,100:ok,100:ok,1200:EPERM,1200:EPERM received:100x3,1200x0 out:hook=3,pf=2,len=1228,runs=5'
# C の "range" の行は bml の VALUE_RANGE (kind 9) だけの検め — Go の側に無い
diff <(grep -v '^range ' "$D/c.txt") "$D/go.txt" > /dev/null && [ "$(head -1 "$D/c.txt")" = "$obs" ] &&
  grep -x 'info pf=2 hooknum=3 priority=-128 flags=0' "$D/c.txt" > /dev/null && grep -x 'range priority=2147483648 kind=9' "$D/c.txt" > /dev/null &&
  grep -x 'left 0' "$D/c.txt" > /dev/null && echo "same c go" || { echo "DIFF c go"; bad=1; }
BML_MUTANT=nf.priority_other inns "$TM/nf_run" "$D/nf.bpf.o" "$S" > /dev/null 2> "$D/m1.err"
grep 'priority -127 flags 0) is not the requested pf 2 hooknum 3 priority -128' "$D/m1.err" > /dev/null && echo "mutant nf.priority_other ok" ||
  { echo "BAD priority_other"; bad=1; }
BML_MUTANT=nf.priority_other_unconfirmed inns "$TM/nf_run" "$D/nf.bpf.o" "$S" > "$D/m2.txt" 2> /dev/null
[ "$(head -1 "$D/m2.txt")" = "$obs" ] && grep -x 'info pf=2 hooknum=3 priority=-127 flags=0' "$D/m2.txt" > /dev/null &&
  echo "mutant nf.priority_other_unconfirmed ok" || { echo "BAD priority_other_unconfirmed"; bad=1; }
chown -R "$U:$(id -g "$U")" "$D"
exit $bad
