#!/bin/bash
# scripts/attach-wave1-target.sh — E035: 波 1 の attach (raw_tp・kretprobe・uretprobe・iter・fmod_ret) を bml (test/abi/attach_wave1 — ASan) と
# cilium (bpf-mlir の kernel/cmd/traceattach -only-ebpf) で同じ mlir・同じ起こし方・同じ観測の文で比べ (権限 root と bpf+perfmon、unshare -n)、
# C ABI の対照 (check の行) と変異 (attach.* — root) を予測と照らす。試験の program は後に残らない (0 — 前後で同じ)。
#
#   sudo scripts/attach-wave1-target.sh <出力の親> <TOOLS (asan)> <TOOLS_MUT> <traceattach> <ebpf-compile>
# 出力: <親>/<kernel>/summary.txt と入力ごとの .bml・.ta。予測と違えば rc 1。
set -uo pipefail
PARENT="${1:?}"; TOOLS="${2:?}"; TMUT="${3:?}"; TA="${4:?}"; EC="${5:?}"
[ "$(id -u)" = 0 ] || { echo "attach-wave1-target: root で走らせる" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$HERE/third_party/bpf-mlir"
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O/elf" "$O/shim/build/bin" "$O/tmp"
# E038: traceattach の toolsnap は /tmp (他の session と共有の tmpfs) に compiler を写し、os.Exit で終わるので消さない (bpf-mlir の側の漏れ —
# 1 回 72 MB × 12) — 自分の dir の下に置き、終わりに消す
chmod 1777 "$O/tmp"
export TMPDIR="$O/tmp"
U=${SUDO_UID:-1000}
# traceattach は <repo>/build/bin/ebpf-compile を写して使う — submodule に書かず、shim の repo (submodule の kernel と同じ compiler) を渡す
ln -s "$REPO/kernel" "$O/shim/kernel"
ln -s "$REPO/docs" "$O/shim/docs"
cp "$EC" "$O/shim/build/bin/ebpf-compile"
BIN="kernel/uprobe/fixture/bin/fixture"
# id mode mlir schema 追加 (N か binary か want-ret)
INPUTS="rawtp rawtp kernel/rawtp/mlir/rawtp.mlir kernel/rawtp/mlir/schema.json 1000
kret kretprobe kernel/retprobe/mlir/kret.mlir kernel/retprobe/mlir/kret.schema.json 1000
uret uretprobe kernel/retprobe/mlir/uret.mlir kernel/retprobe/mlir/uret.schema.json $BIN
elem iter kernel/iter/mlir/elem.mlir kernel/iter/mlir/schema.json -
modret fmodret kernel/fmodret/mlir/modret.mlir kernel/fmodret/mlir/modret.schema.json 65607
done fmodret kernel/fmodret/mlir/modret_done.mlir kernel/fmodret/mlir/modret_done.schema.json 131105"
mapsof() { jq -c '{globals: [], maps: [.core.maps[] | {name: .symbol, kind, key: ((if .key.signed then "i" else "u" end) + (.key.bits|tostring)), value: ((if .value.signed then "i" else "u" end) + (.value.bits|tostring)), max_entries}]}' "$REPO/$1"; }
# 残りの数は試験の program の名前だけ (同じ host の他の session の bpf の object を数えない)
counts() { echo "progs=$(bpftool prog list 2> /dev/null | grep -cE 'name (rawtp|kret|uret|elem|modret|trig)( |$)')"; }
# 予測 (E035 の H1 / H3 — 走らせる前に書いた): check の行
declare -A WANT=(
  [rawtp]="check kprobe_on_rawtp 6|check iter_open_rawtp_link 6"
  [kret]="check kprobe_on_kretprobe 6|check fentry_on_kretprobe 6|check uretprobe_on_kretprobe 6"
  [uret]="check uprobe_link_file_of_uretprobe 0|check uprobe_on_uretprobe 6|check kretprobe_on_uretprobe 6"
  [elem]="check iter_no_map 5|check iter_read_short 9|check iter_read_exact 0|check iter_open_same 0|check fentry_on_iter 6"
  [modret]="check fentry_on_fmodret 6|check raw_tp_on_fmodret 6"
  [done]="check fentry_on_fmodret 6|check raw_tp_on_fmodret 6"
)
# 変異 (root): 入力 → 変異 (1 行目が attach 5 か、iter_read_truncate は check iter_read_short が 0 になる)
declare -A MUT=([rawtp]=attach.rawtp_name_other [kret]=attach.kretprobe_info_other [uret]=attach.uretprobe_offset_other [elem]=attach.iter_target_other [modret]=attach.fmodret_btf_other)
before=$(counts)
bad=0
S="$O/summary.txt"
: > "$S"
while read -r id mode mlir schema extra; do
  elf="$O/elf/$id.bpf.o"
  "$EC" "$REPO/$mlir" --schema "$REPO/$schema" -o "$elf" || { echo "FAIL $id: ebpf-compile" >> "$S"; bad=1; continue; }
  sha=$(sha256sum "$REPO/$schema" | cut -d' ' -f1)
  maps=$(mapsof "$schema")
  arg="$extra"; taextra=()
  case "$mode" in
    rawtp | kretprobe) taextra=(-n "$extra") ;;
    uretprobe) arg="$REPO/$extra"; taextra=(-binary "$extra") ;;
    iter) arg="" ;;
    fmodret) arg=""; taextra=(-want-ret "$extra") ;;
  esac
  for s in root bpf,perfmon; do
    if [ "$s" = root ]; then run=(); tan=(); else
      c=$(echo "$s" | sed 's/,/,+/g')
      run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+"$c" --ambient-caps=-all,+"$c" --bounding-set=-all,+"$c")
      tan=(-allow-nonroot)
    fi
    b="$O/$s-$id"
    chmod -R a+rX "$O"
    # shellcheck disable=SC2086
    unshare -n "${run[@]}" "$TOOLS/attach_wave1" "$mode" "$elf" "$sha" "$maps" $arg > "$b.bml" 2> "$b.bml.err"
    mkdir -p "$b.ta.d"; chown "$U" "$b.ta.d"
    unshare -n "${run[@]}" "$TA" -repo "$O/shim" -mode "$mode" -mlir "$mlir" -schema "$schema" -only-ebpf "${taextra[@]}" "${tan[@]}" -out "$b.ta.d" > "$b.ta" 2> "$b.ta.err"
    bobs=$(head -1 "$b.bml"); [[ "$bobs" == attach* || "$bobs" == load* ]] && bobs="fail"
    tobs=$(awk -F'\t' '$2 == "ebpf" {print $3; exit}' "$b.ta"); [[ -n "$tobs" && "$tobs" != error:* ]] || tobs="fail" # traceattach の attach の誤りは "error: …"
    if [ "$bobs" = "$tobs" ]; then echo "same $s $id $bobs" >> "$S"; else echo "DIFF $s $id bml=$bobs cilium=$tobs" >> "$S"; bad=1; fi
    # 同じ compiler・同じ mlir の ELF か (traceattach が作った ELF と byte で)
    cmp -s "$elf" "$b.ta.d/elf/ebpf.bpf.o" || echo "note $s $id: the ELF differs from traceattach's" >> "$S"
    if [ "$s" = root ]; then
      got=$(grep '^check ' "$b.bml" | tr '\n' '|'); want="${WANT[$id]}|"
      [ "$got" = "$want" ] && echo "checks $id ok" >> "$S" || { echo "CHECKS $id got=$got want=$want" >> "$S"; bad=1; }
    fi
  done
  m="${MUT[$id]:-}"
  if [ -n "$m" ]; then
    # shellcheck disable=SC2086
    BML_MUTANT=$m unshare -n "$TMUT/attach_wave1" "$mode" "$elf" "$sha" "$maps" $arg > "$O/mut-$id.bml" 2> "$O/mut-$id.err"
    [ "$(head -1 "$O/mut-$id.bml")" = "attach 5" ] && echo "mutant $m ok (attach 5)" >> "$S" || { echo "MUTANT $m: $(head -1 "$O/mut-$id.bml")" >> "$S"; bad=1; }
  fi
  if [ "$id" = elem ]; then
    BML_MUTANT=attach.iter_read_truncate unshare -n "$TMUT/attach_wave1" iter "$elf" "$sha" "$maps" > "$O/mut-trunc.bml" 2> "$O/mut-trunc.err"
    grep -qx 'check iter_read_short 0' "$O/mut-trunc.bml" && echo "mutant attach.iter_read_truncate ok (iter_read_short 0)" >> "$S" ||
      { echo "MUTANT attach.iter_read_truncate: $(grep iter_read_short "$O/mut-trunc.bml")" >> "$S"; bad=1; }
  fi
done <<< "$INPUTS"
after=$(counts)
[ "$before" = "$after" ] && echo "counts same ($before)" >> "$S" || { echo "COUNTS before=$before after=$after" >> "$S"; bad=1; }
rm -rf "$O/tmp" # traceattach の toolsnap の残り (E038)
chown -R "$U:$(id -g "$U")" "$PARENT"
cat "$S"
exit "$bad"
