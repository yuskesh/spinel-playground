#!/bin/bash
# scripts/load-wave1-target.sh — E033: 権限の組 (root・bpf+net_admin・bpf+perfmon・none) × ELF の照合しない load を bml (load_case --unchecked —
# guard 付き) と cilium (load-oracle — NewCollection) で (root、unshare -n の中、root 以外は setpriv — capload-target.sh と同じ形)。
# 1 行は "<権限>\t<ELF>\t<ok|errno の文|guard:<段>|other>"。bml の libbpf の段の文の末尾の errno の文を cilium の errno と比べる。
#
#   sudo scripts/load-wave1-target.sh <出力の親> <TOOLS> <load-oracle> <ELF の一覧の file>
set -uo pipefail
PARENT="${1:?}"; TOOLS="${2:?}"; ORA="${3:?}"; LIST="${4:?}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROOF="$(dirname "$ORA")/wave-proof"
[ "$(id -u)" = 0 ] || { echo "load-wave1-target: root で走らせる" >&2; exit 2; }
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O"
U=${SUDO_UID:-1000}
for s in root bpf,net_admin bpf,perfmon none; do
  case "$s" in
    root) run=() ;;
    none) run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all) ;;
    *) c=$(echo "$s" | sed 's/,/,+/g')
       run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+"$c" --ambient-caps=-all,+"$c" --bounding-set=-all,+"$c") ;;
  esac
  # bml: 段が ok なら ok、libbpf なら文の末尾の errno の文 ("libbpf could not load the object: <errno>[ (…)]")、他の段は guard:<段>
  # shellcheck disable=SC2046
  unshare -n "${run[@]}" "$TOOLS/load_case" --unchecked $(cat "$LIST") 2>> "$O/bml.err" |
    awk -F'\t' -v s="$s" '{ c = $3; if ($3 == "libbpf") { m = $4; sub(/^libbpf could not load the object: /, "", m); sub(/ \(.*$/, "", m); c = m }
                            else if ($3 != "ok") c = "guard:" $3; print s "\t" $1 "\t" c }' >> "$O/bml.txt" || exit 2
  # shellcheck disable=SC2046
  unshare -n "${run[@]}" "$ORA" --evidence-permission "$s" $(cat "$LIST") > "$O/go-$s.jsonl" 2>> "$O/go.err" || exit 2
  "$PROOF" render "$O/go-$s.jsonl" "$s" "$LIST" >> "$O/go.txt" || exit 2
done
paste "$O/go.txt" "$O/bml.txt" | awk -F'\t' '$3 != $6 {print "DIFF\t" $1 "\t" $2 "\tgo=" $3 "\tbml=" $6}' > "$O/diff.txt"
# 名指しの既知の差 (E033 — 事後に見つけた、どちらも bml が先に止める fail closed):
#   none_guard — 権限の無い組: bml の guard は libbpf の feature の probe の答えを得られず predict で止め、cilium は EPERM (E024 と同じ形)
#   exp_attach_rewrite — bpf+perfmon の cgroup_skb / flow_dissector (libbpf の SEC_EXP_ATTACH_OPT): libbpf は FEAT_EXP_ATTACH_TYPE を確かめられず
#     expected_attach_type を黙って 0 にする形 — bml の guard が rewrite で止める (E019 の xdp と同じ機構)。cilium は probe せず load する
#     (E036: v1.5.0 の tree の E405 の cge-mut — section cgroup_skb/egress の変異の ELF — も同じ形。dir の名前に cgroup_skb が無いので名指しに足した)
#   iter_target_missing — SEC_ATTACH_BTF の attach 先が vmlinux に無い iter (E398 の nosuch): libbpf は load の前に ESRCH ("no such process")、
#     cilium は ErrNotSupported ("… iterator not supported" — errno でない other)。どちらも kernel に load を出さない
#     (E043 — 事後: lsm の hook が vmlinux に無い E412 の nohook も同じ機構 — libbpf は ESRCH、cilium は "… LSM hook not supported"。
#     照らしの規則 (go=other・bml=no such process) は形を問わないのでそのまま当たる — 名前は iter のまま)
# E037: exp_attach_rewrite は dir の名前でなく ELF の section (cgroup_skb/* か flow_dissector) で照らす (E036 の cge-mut に続き dir の名前の外れを繰り返さない)
# E041: kfunc_extern — kfunc を呼ぶ ELF (symtab に未定義の GLOBAL の symbol — bpf-mlir E463 の bpf_task_from_pid): bml の guard は extern の symbol を
#   shape で止める (kfunc の relocation を guard が扱わない — fail closed)、cilium は kernel の BTF の id に解いて load する。ELF の symbol で照らす
: > "$O/expattach.txt"
: > "$O/kfunc.txt"
while read -r f; do
  # E043: 波 2〜4 の SEC_EXP_ATTACH_OPT の形 (sockops・sk_skb/*・sk_msg・lirc_mode2・cgroup/dev) も
  "${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-readelf" -S -W "$f" 2> /dev/null |
    grep -E '\] (cgroup_skb/(ingress|egress)|flow_dissector|sockops|sk_skb/(stream_parser|stream_verdict)|sk_msg|lirc_mode2|cgroup/dev) ' > /dev/null && echo "$f" >> "$O/expattach.txt" # E050: grep -q は SIGPIPE で外れる
  "${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-readelf" -s -W "$f" 2> /dev/null | awk '$5 == "GLOBAL" && $7 == "UND" {f = 1} END {exit !f}' && echo "$f" >> "$O/kfunc.txt"
done < "$LIST"
awk -F'\t' 'FILENAME == ARGV[1] { ea[$0] = 1; next }
            FILENAME == ARGV[2] { kf[$0] = 1; next }
            !(($2 == "none" && $4 != "go=ok" && $5 == "bml=guard:predict") ||
              ($2 == "bpf,perfmon" && $5 == "bml=guard:rewrite" && ($3 in ea)) ||
              ($5 == "bml=guard:shape" && ($3 in kf)) ||
              ($4 == "go=other" && $5 == "bml=no such process"))' "$O/expattach.txt" "$O/kfunc.txt" "$O/diff.txt" > "$O/diff-before-u3.txt" || exit 2
"$PROOF" check "$HERE" "$LIST" "$O" > "$O/diff-unnamed.txt" || exit 2
echo "load-wave1-target $K: $(wc -l < "$O/bml.txt") 行、違い $(wc -l < "$O/diff.txt") (名指しの none_guard $(grep -c 'bml=guard:predict' "$O/diff.txt")・exp_attach_rewrite $(grep -c 'bml=guard:rewrite' "$O/diff.txt")・iter_target_missing $(grep -c 'bml=no such process' "$O/diff.txt")・kfunc_extern $(grep -c 'bml=guard:shape' "$O/diff.txt"))、名指しの外 $(wc -l < "$O/diff-unnamed.txt")"
awk -F'\t' '{print $1 " " $3}' "$O/bml.txt" | sort | uniq -c
cat "$O/diff-unnamed.txt"
chown -R "$U:$(id -g "$U")" "$PARENT" # 出力を呼び手 (SUDO_UID) の持ち物に (後で sudo 無しで読み写せるように)
[ ! -s "$O/diff-unnamed.txt" ]
