#!/bin/bash
# Exercise the gate's real mode/selection functions without running a gate stage.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$HERE/scripts/gate-mode.sh"
[ -f "$HELPER" ] || { echo 'gate-mode: missing real selection helper' >&2; exit 1; }
. "$HELPER"
want=(e004-live e005-load e033-wave1-load e043-wave24-load e034-wave1-run
  e035-wave1-attach e038-caller-attach e040-tpallcpu e044-usdt e049-ksyscall
  e051-netfilter e053-strarg e054-tparray e055-splitdwarf e056-uprobe-offset
  e006-abi e012-mojo e019-capload e024-tpbtf e025-print e026-holder)
fail() { echo "gate-mode: $*" >&2; exit 1; }
select_stages() {
  for stage in "${want[@]}"; do
    if gate_root "$stage"; then echo "selected $stage"; fi
  done
}
normal=$(unset GATE_FULL VERIFIED_RECORD; gate_mode_init; select_stages)
full=$(unset GATE_FULL VERIFIED_RECORD; gate_mode_init --full; select_stages)
[ "$normal" = "$full" ] || fail 'default/full selection mismatch'
[ "$(printf '%s\n' "$normal" | wc -l)" = 21 ] || fail 'default stage count'
static=$(unset GATE_FULL VERIFIED_RECORD; gate_mode_init --static; select_stages; gate_mode_finish 0)
! grep -q '^selected ' <<< "$static" || fail 'unexpected-root'
expected=$(printf 'deferred: %s\n' "${want[@]}")
got=$(grep '^deferred:' <<< "$static")
[ "$got" = "$expected" ] || fail 'deferred-set mismatch'
for arm in abi_print load.print_passthrough load.print_no_restore; do
  grep -qx "deferred-arm: e025-print/$arm" <<< "$static" || fail "E025 arm missing: $arm"
done
grep -q '^== gate: STATIC PASS ' <<< "$static" || fail 'static receipt missing'
! grep -q '^== gate: PASS ' <<< "$static" || fail 'static claimed full/default PASS'
for mode in --bad '--static --full' '--full --static' '--static --static'; do
  # Intentional splitting: each value above is a fixed argv test vector.
  rc=0; out=$(unset GATE_FULL VERIFIED_RECORD; gate_mode_init $mode 2>&1) || rc=$?
  [ "$rc" = 64 ] || fail "invalid mode accepted: $mode"
  grep -q '^gate: usage:' <<< "$out" || fail "invalid mode lacks named error: $mode"
done
rc=0; (GATE_FULL=1; gate_mode_init --static) >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail 'GATE_FULL/static accepted'
rc=0; (VERIFIED_RECORD=E060; gate_mode_init --static) >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail 'VERIFIED_RECORD/static accepted'
rc=0; (gate_mode_init --static; gate_root not-a-stage) >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail 'unknown stage accepted'
# A source-site inventory independently ties the helper unit to the actual callers.
sites=$(sed -nE 's/.*if gate_root ([a-z0-9-]+)(;| ).*/\1/p' \
  "$HERE/scripts/gate.sh" "$HERE/scripts/gate-wave1.sh" | LC_ALL=C sort)
want_sites=$(printf '%s\n' "${want[@]}" | LC_ALL=C sort)
[ "$sites" = "$want_sites" ] || fail 'call-site inventory mismatch'
# The same validator detects the two named mutations; neither executes root code.
rc=0; mutant=$(gate_mode_init --static; gate_root() { return 0; }; select_stages |
  { ! grep -q '^selected ' || { echo 'unexpected-root' >&2; exit 1; }; } 2>&1) || rc=$?
[ "$rc" = 1 ] && [ "$mutant" = unexpected-root ] || fail 'root-pass mutant not detected by name'
bad=$(grep '^deferred:' <<< "$static" | grep -v '^deferred: e025-print$')
rc=0; mutant=$([ "$bad" = "$expected" ] || { echo 'deferred-set mismatch'; exit 1; }) || rc=$?
[ "$rc" = 1 ] && [ "$mutant" = 'deferred-set mismatch' ] || fail 'missing-deferred mutant not detected by name'
echo 'gate-mode: GREEN default/full/static, invalid modes, 21 sites, E025 3 arms'
echo 'gate-mode: named RED controls unexpected-root / deferred-set mismatch'
