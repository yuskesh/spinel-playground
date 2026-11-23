#!/bin/bash
# scripts/diff-split-dwarf.sh — E055 H4 / H5: 分けた DWARF の照合 (bpf-mlir E557 — 判定の版 16) の bml-precheck と ebpf-precheck の差動。
# fixture は scripts/split-fixtures.sh (repo の中で作る)。requirements は corpus の split_debug_* の形 (ELF 無し — --requirements)。出力の JSON の全体
# (Unmet の文まで — versions.bpf_mlir を除く) を比べる。
#
#   scripts/diff-split-dwarf.sh n [TOOLS_DIR] [OUT]   # 非 root: 記録の caps (uprobe_debug の file / unknown / error の答え・問いの無い記録・
#                                                    #   caps.json の dir 基準の相対 path)
#   scripts/diff-split-dwarf.sh r [TOOLS_DIR] [OUT]   # root: --live --binary と --debug / --debug-root (既定の root・空・override の優先と
#                                                    #   fallback の無さ・相対 path の絶対化)、--record の記録と再生 (H5)
set -uo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-split-dwarf.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:?n か r}"
TOOLS="$(cd "${2:-$HERE/build/tools}" && pwd)" # 絶対 path (組ごとに cwd を変える — E055 の 1 回目は相対のまま両方が実行できず偽の same)
W="${3:-$HERE/build/tmp/diff-split-dwarf-$MODE}"
# 絶対 path (caps.json の fixture の path も — E055 の変異の 1 回目は相対で両方が binary を開けず偽の same)。DIFF_SPLIT_KEEP_RELATIVE=1 は
# 検めの感度の負の対照 (相対のまま走らせ、全ての組が結果の検めで差になることを示す — gate は使わない)
[ "${DIFF_SPLIT_KEEP_RELATIVE:-0}" = 1 ] || case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
GOPRE="$TOOLS/ebpf-precheck"; [ -x "$GOPRE" ] || GOPRE="$HERE/build/tools/ebpf-precheck" # 変異の build (tools-mut) は Go の道具を持たない
S="$W/fx"
rm -rf "$W"; mkdir -p "$W/c"
"$HERE/scripts/split-fixtures.sh" "$S" > /dev/null || exit 1
ID=$(cat "$S/build-id.txt")
BASECAPS="$HERE/third_party/bpf-mlir/conformance/requirements/cases/split_debug_multi/caps.json"
# req <名前> <attach の型> <target (multi は , の列)> <body> <引数 "n:型 …">
req() {
  local p=$1 at=$2 t=$3 b=$4 args=$5 v=4 sha
  sha=$(sha256sum "$S/$b" | cut -d' ' -f1)
  [ "$at" = uretprobe ] && v=9
  [ "$at" = uprobe_multi ] && v=12
  printf 'ebpf-requirements %d\nschema\tsha256\t%064d\nprogram\t%s\tkprobe\t2\n' "$v" 0 "$p"
  if [ "$at" = uprobe_multi ]; then printf 'attach\t%s\tuprobe_multi\t%d\n' "$p" "$(tr ',' '\n' <<< "$t" | wc -l)"; else printf 'attach\t%s\t%s\t%s\n' "$p" "$at" "$t"; fi
  printf 'arch\t%s\tx86_64\n' "$p"
  if [ "$at" = uretprobe ]; then printf 'ctxfield\t%s\tpt_regs\tax\t80\t8\n' "$p"; else printf 'ctxfield\t%s\tpt_regs\tdi\t112\t8\nctxfield\t%s\tpt_regs\tsi\t104\t8\n' "$p" "$p"; fi
  printf 'binary\t%s\tsha256\t%s\n' "$p" "$sha"
  if [ "$at" = uprobe_multi ]; then i=0; for x in ${t//,/ }; do printf 'mtarget\t%s\t%d\t%s\n' "$p" "$i" "$x"; i=$((i + 1)); done; fi
  for a in $args; do printf 'uprobearg\t%s\t%s\t%s\n' "$p" "${a%%:*}" "${a#*:}"; done
  [ "$at" = uprobe_multi ] && printf 'btf\tint\n'
  return 0
}
# caps <program> <body> <答え: file:<fx の名前> | relfile:<caps.json からの相対> | unknown:<文> | error:<文> | noq | nokey>
caps() {
  local p=$1 b=$2 ans=$3 a
  case "$ans" in
    file:*) a=$(jq -n --arg f "$S/${ans#file:}" '{file: $f}') ;;
    relfile:*) a=$(jq -n --arg f "${ans#relfile:}" '{file: $f}') ;;
    unknown:*) a=$(jq -n --arg f "${ans#unknown:}" '{unknown: $f}') ;;
    error:*) a=$(jq -n --arg f "${ans#error:}" '{error: $f}') ;;
    *) a=null ;;
  esac
  jq --arg p "$p" --arg b "$S/$b" --arg k "$p/$ID" --arg ans "$ans" --argjson a "$a" '
    .queries.struct_field["pt_regs.ax/80/8"] = {diffs: []} | .queries.uprobe_binary = {($p): {file: $b}} |
    if $ans == "noq" then del(.queries.uprobe_debug) elif $ans == "nokey" then .queries.uprobe_debug = {"other/00": {file: "x"}}
    else .queries.uprobe_debug = {($k): $a} end' "$BASECAPS"
}
n=0 bad=0
one() { # 名前 cwd 引数… — 両方の出力を比べる
  local name=$1 cwd=$2; shift 2
  n=$((n + 1))
  gr=0; (cd "$cwd" && "$GOPRE" "$@") > "$W/c/$name.go.json" 2> "$W/c/$name.go.err" || gr=$?
  cr=0; (cd "$cwd" && "$TOOLS/bml-precheck" "$@") > "$W/c/$name.c.json" 2> "$W/c/$name.c.err" || cr=$?
  g=$(jq -cS 'del(.versions.bpf_mlir)' "$W/c/$name.go.json" 2>/dev/null); c=$(jq -cS 'del(.versions.bpf_mlir)' "$W/c/$name.c.json" 2>/dev/null)
  local res; res=$(jq -r '.result // empty' <<< "$g" 2>/dev/null)
  # JSON の結果が無い出力は差、mode n の組は照合まで進むはず (ok か target_rejected — usage_error・precheck_failed は道具の入力の誤り)
  if [ "$gr" != "$cr" ] || [ "$g" != "$c" ] || [ -z "$res" ] || { [ "$MODE" = n ] && [ "$res" != ok ] && [ "$res" != target_rejected ]; }; then
    bad=$((bad + 1)); echo "DIFF $name: go=$gr c=$cr"
    diff <(jq -S 'del(.versions.bpf_mlir)' "$W/c/$name.go.json") <(jq -S 'del(.versions.bpf_mlir)' "$W/c/$name.c.json") | head -8
  else
    printf '%s\t%s\t%s\n' "$name" "$(jq -r .result <<< "$c")" "$(jq -r '[.unmet[]? | "\(.kind): \(.detail)"] | join(" | ")' <<< "$c")" >> "$W/summary.tsv"
  fi
}
LA=--load-as=0:000001ffffffffff
if [ "$MODE" = n ]; then
  while IFS='|' read -r name body at t args ans; do
    [ -z "$name" ] && continue
    d="$W/c/$name.d"; mkdir -p "$d"
    req p "$at" "$t" "$body" "$args" > "$d/requirements.txt"
    caps p "$body" "$ans" > "$d/caps.json"
    one "$name" / --loader=cilium-v0.22 --caps="$d/caps.json" "$LA" --requirements="$d/requirements.txt"
  done <<'T'
alias_ok|stripped|uprobe|e55_alias|1:u64 2:u64|file:whole.debug
target_ok|stripped|uprobe|e55_target|1:u64 2:u64|file:whole.debug
twocu_u64|stripped|uprobe|e55_twocu|1:u64|file:whole.debug
twocu_u32|stripped|uprobe|e55_twocu|1:u32|file:whole.debug
embed_twocu_u64|whole|uprobe|e55_twocu|1:u64|noq
embed_twocu_u32|whole|uprobe|e55_twocu|1:u32|noq
embed_alias|whole|uprobe|e55_alias|1:u64 2:u64|noq
ret_alias|stripped|uretprobe|e55_alias||file:whole.debug
multi|stripped|uprobe_multi|e55_target,e55_alias|2:u64|file:whole.debug
multi_badid|stripped|uprobe_multi|e55_target,e55_alias|2:u64|file:badid.debug
nolink_ok|nolink|uprobe|e55_alias|1:u64 2:u64|file:whole.debug
badid|stripped|uprobe|e55_alias|1:u64 2:u64|file:badid.debug
badcrc|stripped|uprobe|e55_alias|1:u64 2:u64|file:badcrc.debug
badcrc_nolink|nolink|uprobe|e55_alias|1:u64 2:u64|file:badcrc.debug
machine|stripped|uprobe|e55_alias|1:u64 2:u64|file:machine.debug
text|stripped|uprobe|e55_alias|1:u64 2:u64|file:text.debug
big|stripped|uprobe|e55_alias|1:u64 2:u64|file:big.debug
missing|stripped|uprobe|e55_alias|1:u64 2:u64|file:nonexistent.debug
dir|stripped|uprobe|e55_alias|1:u64 2:u64|file:root
dupnote|nolink|uprobe|e55_alias|1:u64 2:u64|file:dupnote.debug
altlink_debug|nolink|uprobe|e55_alias|1:u64 2:u64|file:altlink.debug
rel|nolink|uprobe|e55_alias|1:u64 2:u64|file:rel.debug
types|nolink|uprobe|e55_alias|1:u64 2:u64|file:types.debug
nobits|nolink|uprobe|e55_alias|1:u64 2:u64|file:nobits.debug
zdebug|nolink|uprobe|e55_alias|1:u64 2:u64|file:zdebug.debug
zstd|nolink|uprobe|e55_alias|1:u64 2:u64|file:zstd.debug
zlib|nolink|uprobe|e55_alias|1:u64 2:u64|file:zlib.debug
noinfo|nolink|uprobe|e55_alias|1:u64 2:u64|file:noinfo.debug
noid|noid|uprobe|e55_alias|1:u64 2:u64|noq
badlink|badlink|uprobe|e55_alias|1:u64 2:u64|file:whole.debug
altlink_body|altlink|uprobe|e55_alias|1:u64 2:u64|file:whole.debug
noq|stripped|uprobe|e55_alias|1:u64 2:u64|noq
nokey|stripped|uprobe|e55_alias|1:u64 2:u64|nokey
unknown_disabled|stripped|uprobe|e55_alias|1:u64 2:u64|unknown:separate DWARF lookup is disabled
unknown_other|stripped|uprobe|e55_alias|1:u64 2:u64|unknown:a caller-supplied reason
error_answer|stripped|uprobe|e55_alias|1:u64 2:u64|error:boom
relpath|stripped|uprobe|e55_alias|1:u64 2:u64|relfile:../../fx/whole.debug
T
elif [ "$MODE" = r ]; then
  [ "$(id -u)" = 0 ] || { echo "diff-split-dwarf: r は root で" >&2; exit 1; }
  d="$W/c/live.d"; mkdir -p "$d"
  req p uprobe e55_alias stripped "1:u64 2:u64" > "$d/alias.txt"
  req p uprobe e55_twocu stripped "1:u32" > "$d/twocu32.txt"
  req p uretprobe e55_alias stripped "" > "$d/ret.txt"
  B="--binary=p=$S/stripped"
  L=(--loader=cilium-v0.22 --live)
  one live_override / "${L[@]}" "$B" --debug=p="$S/whole.debug" --requirements="$d/alias.txt"
  one live_override_twocu32 / "${L[@]}" "$B" --debug=p="$S/whole.debug" --requirements="$d/twocu32.txt"
  one live_override_ret / "${L[@]}" "$B" --debug=p="$S/whole.debug" --requirements="$d/ret.txt"
  one live_root / "${L[@]}" "$B" --debug-root="$S/root" --requirements="$d/alias.txt"
  one live_root_slash / "${L[@]}" "$B" --debug-root="$S/root/" --requirements="$d/alias.txt"
  one live_root_default / "${L[@]}" "$B" --requirements="$d/alias.txt"
  one live_root_empty / "${L[@]}" "$B" --debug-root= --requirements="$d/alias.txt"
  one live_override_missing / "${L[@]}" "$B" --debug-root="$S/root" --debug=p="$S/missing.debug" --requirements="$d/alias.txt"
  one live_override_empty_root / "${L[@]}" "$B" --debug-root= --debug=p="$S/whole.debug" --requirements="$d/alias.txt"
  one live_override_rel "$S" "${L[@]}" "$B" --debug=p=whole.debug --requirements="$d/alias.txt"
  one live_override_badid / "${L[@]}" "$B" --debug=p="$S/badid.debug" --requirements="$d/alias.txt"
  one live_override_big / "${L[@]}" "$B" --debug=p="$S/big.debug" --requirements="$d/alias.txt"
  one usage_dup / "${L[@]}" "$B" --debug=p="$S/whole.debug" --debug=p="$S/badid.debug" --requirements="$d/alias.txt"
  one usage_form / "${L[@]}" "$B" --debug=p --requirements="$d/alias.txt"
  one usage_caps / --loader=cilium-v0.22 --caps="$BASECAPS" --live --debug-root=/x --requirements="$d/alias.txt"
  one usage_nolive / --loader=cilium-v0.22 --caps="$BASECAPS" --debug=p=/x --requirements="$d/alias.txt"
  # H5: --record の記録 (live の暗黙の path と CLI の明示の path は絶対) と、両方の道具での再生
  for t in go c; do
    tool=$GOPRE; [ $t = c ] && tool=$TOOLS/bml-precheck
    (cd "$S" && "$tool" "${L[@]}" "$B" --debug=p=whole.debug --record="$W/rec-$t.json" --requirements="$d/alias.txt") > /dev/null 2>&1
    (cd / && "$tool" "${L[@]}" "$B" --debug-root="$S/root" --record="$W/rec-root-$t.json" --requirements="$d/alias.txt") > /dev/null 2>&1
  done
  for r in rec rec-root; do
    n=$((n + 1))
    if cmp -s <(jq -S . "$W/$r-go.json") <(jq -S . "$W/$r-c.json"); then
      echo "record $r: $(jq -c '.queries.uprobe_debug' "$W/$r-c.json")" >> "$W/summary.tsv"
    else
      bad=$((bad + 1)); echo "DIFF record $r"; diff <(jq -S . "$W/$r-go.json") <(jq -S . "$W/$r-c.json") | head -8
    fi
    for t in go c; do one "replay_${r}_$t" / --loader=cilium-v0.22 --caps="$W/$r-$t.json" "$LA" --requirements="$d/alias.txt"; done
  done
  chown -R "${SUDO_UID:-1000}" "$W"
else
  echo "diff-split-dwarf: mode は n か r" >&2; exit 2
fi
echo "diff-split-dwarf: $MODE 組 $n、差 $bad — $([ "$bad" = 0 ] && echo ok || echo FAIL)"
[ "$bad" = 0 ]
