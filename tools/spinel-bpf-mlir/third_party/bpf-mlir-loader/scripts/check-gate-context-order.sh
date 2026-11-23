#!/bin/bash
# Saved-raw controls and six real non-root context-mutation arms (E060).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/gate-mode.sh"
. "$HERE/scripts/gate-case-order.sh"
fail() { echo "context-order: $*" >&2; exit 1; }
read_expected() {
  local definitions
  definitions=$(sed -n '/^V9E388=/,/^V9CTX=/p' "$HERE/scripts/gate.sh") || return 2
  [ -n "$definitions" ] || return 2
  source /dev/stdin <<< "$definitions"
  [ -n "$V9CTX" ] || return 2
}
case "${1:-}" in
--raw)
  [ "$#" = 3 ] || fail 'usage: --raw STOP_DIR FRESH_OUT'
  raw=$2; out=$3
  [ ! -e "$out" ] || fail 'output already exists'
  mkdir -p "$out"
  expected=$(cat "$raw/expected-order.txt")
  actual=$(gate_read_diff_ids "$raw/ctx-access-mutant.log")
  [ "$expected" != "$actual" ] || fail 'old order control was not RED'
  echo 'old-order: RED exact sequence mismatch'
  gate_case_ids_match check.ctx_access_ignored 1 "$actual" "$expected"
  control() {
    local name=$1 pattern=$2 rc=0 message
    shift 2
    message=$(gate_case_ids_match "$name" "$@" 2>&1) || rc=$?
    [ "$rc" = 1 ] && [[ "$message" == *"$pattern"* ]] || fail "named control $name: $message / $rc"
    echo "named RED: $name / $pattern"
  }
  control missing 'missing b' 1 a 'a b'
  control extra 'extra c' 1 'a b c' 'a b'
  control duplicate 'duplicate a' 1 'a a b' 'a b'
  control return-code 'rc mismatch' 0 'a b' 'a b'
  printf 'DIFF missing-colon\n' > "$out/malformed.log"
  rc=0; message=$(gate_read_diff_ids "$out/malformed.log" 2>&1) || rc=$?
  [ "$rc" = 2 ] && [[ "$message" == *'malformed DIFF record'* ]] || fail 'parser failure swallowed'
  echo 'named RED: malformed DIFF record'
  rc=0; message=$(sort() { return 7; }; gate_case_ids_match sort-failure 1 a a 2>&1) || rc=$?
  [ "$rc" = 2 ] && [[ "$message" == *'sort/parser failed'* ]] || fail 'sort failure swallowed'
  echo 'named RED: sort/parser failed'
  echo 'context-order saved raw: GREEN'
  ;;
--arm)
  [ "$#" = 4 ] || fail 'usage: --arm MODE LOCALE FRESH_OUT'
  mode=$2; wanted_locale=$3; out=$4
  [ ! -e "$out" ] || fail 'output already exists'
  mkdir -p "$out"
  # Locale is selected by the parent command, not by the gate or mode parser.
  [ "${LC_ALL:-}" = "$wanted_locale" ] || fail 'locale argument/environment mismatch'
  LC_ALL="$wanted_locale" locale charmap > "$out/charmap.txt" 2> "$out/locale-errors.txt"
  [ ! -s "$out/locale-errors.txt" ] || fail 'requested locale unavailable'
  locale > "$out/locale-before.txt"
  case "$mode" in
    default) gate_mode_init ;;
    full) gate_mode_init --full ;;
    static) gate_mode_init --static ;;
    *) fail 'unknown mode' ;;
  esac
  locale > "$out/locale-after.txt"
  cmp "$out/locale-before.txt" "$out/locale-after.txt" || fail 'mode changed effective locale'
  printf '%s\n' "$GATE_MODE" > "$out/mode.txt"
  read_expected
  gate_context_mutation check.ctx_access_ignored "$V9CTX" "$HERE/build/tools-mut" "$out/mutation.log"
  [ "$(wc -l < "$out/mutation.log.canonical-ids")" = 23 ] || fail 'expected 23 IDs'
  echo "context-order arm: GREEN mode=$mode locale=$wanted_locale"
  ;;
*) fail 'use --raw or --arm (never runs the root gate)' ;;
esac
