#!/bin/bash
# scripts/check-gate-privilege.sh — gate と scripts の直接の昇格の呼び出しの読みを固定する (E068 H3)。root は要らない。
# 許すのは gate-vm.sh の rsudo の sudo (--vm-root の分岐を通らない) と gate.sh の e004-live の sudo -n true (--vm-root では選ばれない段) だけ。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PAT='(^|[^[:alnum:]_/-])(/[[:alnum:]_/.-]*/)?(sudo|doas|pkexec)([[:space:]]|$)|(^|[^[:alnum:]_/-])su[[:space:]]+-'
scan() { # コメントの行と行末のコメントを除いて照らす (文字列の中の語は呼び出しでないものも拾う — 増えたら読んで表を直す)
  grep -nE "$PAT" "$@" /dev/null | awk -F: '{ l=$0; sub(/^[^:]*:[^:]*:/, "", l); if (l ~ /^[[:space:]]*(#|step[[:space:]])/) next; sub(/[[:space:]]#.*$/, "", l); if (l ~ /(^|[^[:alnum:]_\/-])(\/[[:alnum:]_\/.-]*\/)?(sudo|doas|pkexec)([[:space:]]|$)|(^|[^[:alnum:]_\/-])su[[:space:]]+-/) print $1 ":" l }' || true
}
got=$(scan "$HERE"/scripts/*.sh | sed "s|^$HERE/scripts/||" | grep -vE '^(check-gate-privilege|gate-vm-unit)\.sh:' | LC_ALL=C sort || true)
want=$(cat <<'EOF'
gate-vm.sh:    sudo -n "$@" ) 9< "$RL"; }
gate.sh:sudo -n true 2> /dev/null || die "E004 の live の差動に sudo -n が要る (root の probe — 飛ばさない)"
EOF
)
got_want=$(printf '%s\n' "$want" | LC_ALL=C sort)
if [ "$got" != "$got_want" ]; then
  echo 'gate-privilege: 昇格の呼び出しの集合が表と違う' >&2
  diff <(printf '%s\n' "$got_want") <(printf '%s\n' "$got") >&2 || true
  exit 1
fi
echo 'gate-privilege: GREEN 昇格の呼び出しは表の 2 箇所だけ'
