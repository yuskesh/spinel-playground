#!/bin/bash
# scripts/srcs.sh — library と道具の source の一覧 (sort 済み — build の順を決定的に)。構造の整理 (E003 の前) の後の 1 か所。
#   scripts/srcs.sh src                 # 製品の library の .c (src/ の全ての層)
#   scripts/srcs.sh cmd <名前>          # cmd/<名前>/ の .c
#   scripts/srcs.sh test <道具の名前>    # test/*/<名前>.c (1 つだけ — 無い・2 つは誤り)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
src) find "$HERE/src" -name '*.c' | LC_ALL=C sort ;;
cmd) find "$HERE/cmd/$2" -name '*.c' | LC_ALL=C sort ;;
test)
  m=$(find "$HERE/test" -path "$HERE"/test/oracle -prune -o -name "$2.c" -print)
  [ "$(printf '%s\n' "$m" | grep -c .)" = 1 ] || { echo "srcs: test/*/$2.c is not exactly one file: $m" >&2; exit 1; }
  echo "$m" ;;
*) echo "srcs: src | cmd <name> | test <name>" >&2; exit 2 ;;
esac
