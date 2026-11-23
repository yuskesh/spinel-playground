#!/bin/bash
# scripts/diff-uprobe-offset.sh — E056 H1 / H2: uprobe の attach の file offset の C (build/tools/uprobe_offset — bml_uprobe_file_offset) と cilium の写し
# (test/oracle/cmd/uprobe-offset) の比べ。入力は system の libc (.dynsym だけ) と scripts/e56-fixtures.sh の 4 つ。root 不要。
#
#   scripts/diff-uprobe-offset.sh [TOOLS_DIR] [OUT]
#
# 合否: C が offset を出した名前は全て cilium と同じ offset。C が拒否した名前は cilium の答えの種類を数えて出す (照合と同じ拒否 — cilium は後勝ち)。
# 負の対照: twoaddr / twosym の e56_fn は C が "has 2 FUNC symbols" で拒否、dynsym の e56_fn は offset を出す。
set -uo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-uprobe-offset.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$(cd "${1:-$HERE/build/tools}" && pwd)"
W="${2:-$HERE/build/tmp/diff-uprobe-offset}"
case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
rm -rf "$W"; mkdir -p "$W"
"$HERE/scripts/gen-uprobe-offset-copy.sh" --check || exit 1
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod /usr/local/go/bin/go build -o "$W/uprobe-offset" ./cmd/uprobe-offset) || exit 1
"$HERE/scripts/e56-fixtures.sh" "$W/fx" > "$W/fx.sha256" || exit 1
LIBC=/usr/lib/x86_64-linux-gnu/libc.so.6
BINS=("$LIBC" "$W/fx/full" "$W/fx/dynsym" "$W/fx/twoaddr" "$W/fx/twosym")
"$TOOLS/uprobe_offset" "${BINS[@]}" > "$W/c.txt"
"$W/uprobe-offset" "${BINS[@]}" > "$W/go.txt"
bad=$(paste <(awk -F'\t' '/^== /{f=$0; next} {print f"\t"$0}' "$W/c.txt") <(awk -F'\t' '/^== /{f=$0; next} {print f"\t"$0}' "$W/go.txt") |
  awk -F'\t' '$3 != "error" && ($2 != $5 || $3 != $6) {print}' | tee "$W/mismatch.txt" | wc -l)
same=$(awk -F'\t' '/^== /{next} $2 != "error"' "$W/c.txt" | wc -l)
rej=$(paste <(awk -F'\t' '/^== /{f=$0; next} {print f"\t"$0}' "$W/c.txt") <(awk -F'\t' '/^== /{f=$0; next} {print f"\t"$0}' "$W/go.txt") |
  awk -F'\t' '$3 == "error" {print $1"\t"$2"\t"($7 == "error" ? "cilium-error" : "cilium-offset")}' | tee "$W/rejected.txt" | cut -f3 | sort | uniq -c | tr '\n' ' ') # C の誤りの行は列が 1 つ多い — cilium の答えは 7 列目
neg=0
for f in twoaddr twosym; do grep -qP '^e56_fn\terror\tthe binary has 2 FUNC symbols named e56_fn \(want exactly one\)$' <(awk -v f="== $W/fx/$f" '$0 == f {on = 1; next} /^== / {on = 0} on' "$W/c.txt") || { echo "負の対照 $f: C が e56_fn を 2 つの address で拒否しない"; neg=1; }; done
grep -qP '^e56_fn\t0x' <(awk -v f="== $W/fx/dynsym" '$0 == f {on = 1; next} /^== / {on = 0} on' "$W/c.txt") || { echo "正の対照 dynsym: C が e56_fn の offset を出さない"; neg=1; }
ga=$(grep -P '^getaddrinfo\t' "$W/c.txt" | head -1); gg=$(grep -P '^getaddrinfo\t' "$W/go.txt" | head -1)
echo "diff-uprobe-offset: C の offset $same 名 — cilium との不一致 $bad、C が拒否した名前 $rej、libc の getaddrinfo: C ${ga#*$'\t'} cilium ${gg#*$'\t'}"
[ "$bad" = 0 ] && [ "$neg" = 0 ] && [ -n "$ga" ] && [ "${ga#*$'\t'}" = "${gg#*$'\t'}" ]
