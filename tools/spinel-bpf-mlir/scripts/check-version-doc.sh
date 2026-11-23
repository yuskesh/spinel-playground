#!/bin/bash
# scripts/check-version-doc.sh — docs/tutorial.md の段 0 の `--version` の依存の行の期待 (「続く行が」の後の backtick の項目) と、spinelbpf --version の
# 出力の依存の行 (2 行目から) を両向きに照らす (E098 — 版の上げで tutorial の古い行を黙って残さない、E091 の取り残し)。`…` を含む項目は `…` の前が前方一致・後が後方一致。
#   scripts/check-version-doc.sh <tutorial.md> <version の出力の file>
set -euo pipefail
doc=$1 out=$2
# 「続く行が」から「であること」までの文の、「続く行が」より後の backtick の項目
text=$(awk '/続く行が/{f=1} f{print} /であること/{if(f) exit}' "$doc" | tr '\n' ' ' | sed 's/.*続く行が//')
mapfile -t items < <(grep -o '`[^`]*`' <<<"$text" | tr -d '`')
[ "${#items[@]}" -gt 0 ] || { echo "check-version-doc: no expected dependency lines found in $doc (the sentence after 続く行が)" >&2; exit 1; }
mapfile -t lines < <(tail -n +2 "$out")
rc=0
match() { # $1 項目 $2 行
  local it=$1 ln=$2
  if [[ $it == *…* ]]; then [[ $ln == "${it%%…*}"* && $ln == *"${it#*…}" ]]; else [[ $ln == "$it" ]]; fi
}
for it in "${items[@]}"; do
  ok=0
  for ln in "${lines[@]}"; do match "$it" "$ln" && ok=1; done
  [ $ok = 1 ] || { echo "check-version-doc: $doc expects \`$it\` but --version has no such line" >&2; rc=1; }
done
for ln in "${lines[@]}"; do
  [ -n "$ln" ] || continue
  ok=0
  for it in "${items[@]}"; do match "$it" "$ln" && ok=1; done
  [ $ok = 1 ] || { echo "check-version-doc: --version prints \`$ln\` but $doc does not list it" >&2; rc=1; }
done
exit $rc
