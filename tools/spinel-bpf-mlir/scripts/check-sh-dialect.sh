#!/bin/bash
# scripts/check-sh-dialect.sh — E171: `#!/bin/sh` の script (scripts/・scripts/lib/) と、それが `. "$HERE/…"` で source する repo の中の file を
# dash -n で構文検査する (この host の /bin/sh は dash — bash 専用の lib を sh の script が source すると README の手順が落ちる、E167 の誤り)。
#   scripts/check-sh-dialect.sh [root]   # 既定は repo の root。落ちた file を名指して rc 1
# sh の script の中の source で path を解けない形 (`source`・`$HERE/` 以外の `. `) も止める (fail closed — 検査の外に黙って出さない)。
set -euo pipefail
ROOT=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
command -v dash >/dev/null || { echo "check-sh-dialect: dash is missing" >&2; exit 1; }
fail=0 n=0
for f in "$ROOT"/scripts/* "$ROOT"/scripts/lib/*; do
  [ -f "$f" ] || continue
  IFS= read -r first < "$f" || true
  case "$first" in '#!/bin/sh'|'#!/bin/sh '*|'#! /bin/sh'*|'#!/usr/bin/env sh'*) ;; *) continue ;; esac
  n=$((n + 1))
  rel=${f#"$ROOT"/}
  if ! out=$(dash -n "$f" 2>&1); then echo "check-sh-dialect: $rel: $out" >&2; fail=1; fi
# source lines: resolve every `. "$HERE/<path>"` on a line (several sources on one line — the bpf-mlir reviewer's i3204). If the number of source-like words and of resolved ones differ
# (source mixed with another variable or an unquoted path), stop on that line
  while IFS= read -r line; do
    total=$(printf '%s\n' "$line" | grep -oE '(^|[;&|[:space:]])(\.|source)[[:space:]]+[^=[:space:]]' | wc -l)
    mapfile -t ps < <(printf '%s\n' "$line" | grep -oE '(^|[;&|[:space:]])\.[[:space:]]+"\$HERE/[^"]+"' | sed -E 's/.*"\$HERE\/([^"]+)"$/\1/')
    if [ "${#ps[@]}" -eq 0 ] || [ "${#ps[@]}" -ne "$total" ]; then echo "check-sh-dialect: $rel: cannot resolve the sourced file: $line" >&2; fail=1; continue; fi
    for p in "${ps[@]}"; do
      if [ ! -f "$ROOT/$p" ]; then echo "check-sh-dialect: $rel sources $p, which is missing" >&2; fail=1; continue; fi
      if ! out=$(dash -n "$ROOT/$p" 2>&1); then echo "check-sh-dialect: $p (sourced by $rel under /bin/sh): $out" >&2; fail=1; fi
    done
  done < <(grep -E '(^|[;&|[:space:]])(\.|source)[[:space:]]+[^=[:space:]]' "$f" | grep -vE '^[[:space:]]*#' || true)
done
[ "$fail" = 0 ] || exit 1
echo "check-sh-dialect: $n #!/bin/sh scripts and the files they source parse under dash"
