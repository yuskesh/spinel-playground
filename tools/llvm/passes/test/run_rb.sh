#!/usr/bin/env bash
# E016 -- end-to-end runner for the Ruby-level SpinelGCRoots regression tests.
#
# For each *.rb here: compile it with `bin/spinel -c`, link the result TWICE
# through the same ThinLTO line (E015 results/E015/cc.sh) -- once stock, once
# with the pass plugin -- and compare the two outputs BOTH with and without
# SPINEL_GC_STRESS=1.  The stock build is the oracle; a `<name>.expected` file,
# if present, is checked too.
#
# The stress leg is the point: the R3 hole is INVISIBLE without it (measured on
# a pre-fix build of the pass: 7 with no stress, 990000 with stress).
#
# A `# XFAIL: <reason>` line marks a test that documents a KNOWN, UNFIXED bug.
# It is expected to fail; an unexpected pass (XPASS) is reported as a failure so
# the marker is removed when the bug is fixed.
#
#   tools/llvm/passes/test/run_rb.sh
#   PLUGIN=/path/to/other.so tools/llvm/passes/test/run_rb.sh   # bite-check
#
# Overrides: LLVM_PREFIX, PLUGIN, NOGC, VENDOR, RTLIB, KEEP=1 (keep the tmpdir).
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
LLVM=${LLVM_PREFIX:-/opt/homebrew/opt/llvm}
PLUGIN=${PLUGIN:-$HERE/../build/libSpinelGCRoots.so}
NOGC=${NOGC:-$REPO/docs/experiments/results/E015/nogc_rt.list}
VENDOR=${VENDOR:-$REPO/vendor/spinel}
RTLIB=${RTLIB:-$REPO/tools/llvm/build/libspinel_rt_lto.a}
SPINEL=$VENDOR/bin/spinel

for f in "$PLUGIN" "$NOGC" "$RTLIB" "$SPINEL"; do
  [ -e "$f" ] || { echo "run_rb.sh: missing $f" >&2; exit 2; }
done

TMP=$(mktemp -d /tmp/e016-rb.XXXXXX)
[ "${KEEP:-0}" = 1 ] || trap 'rm -rf "$TMP"' EXIT

# the frozen `spinel-llvm --mode thinlto` link line (results/E015/cc.sh)
link() { # link <src.c> <out> [extra...]
  local c=$1 out=$2; shift 2
  "$LLVM/bin/clang" -O2 -Wno-everything -ffunction-sections -fdata-sections \
    -I"$VENDOR/lib" -I"$VENDOR/lib/regexp" -flto=thin -DSP_INT_OVERFLOW_MODE_RAISE \
    "$@" "$c" "$RTLIB" -lm -Wl,-dead_strip -o "$out"
}

files=("$@")
if [ ${#files[@]} -eq 0 ]; then files=("$HERE"/*.rb); fi

pass=0; fail=0; xfail=0
for rb in "${files[@]}"; do
  case "$rb" in /*) ;; *) rb="$HERE/$rb" ;; esac
  name=$(basename "$rb" .rb)
  xreason=$(sed -n 's/^# *XFAIL: *//p' "$rb" | head -1)
  ok=1; msg=()

  if ! "$SPINEL" "$rb" -c --no-line-map -o "$TMP/$name.c" >"$TMP/$name.gen.log" 2>&1; then
    echo "FAIL $name (spinel -c failed)"; sed 's/^/  | /' "$TMP/$name.gen.log"; fail=$((fail+1)); continue
  fi
  if ! link "$TMP/$name.c" "$TMP/$name.stock" 2>"$TMP/$name.stock.log"; then
    echo "FAIL $name (stock link failed)"; fail=$((fail+1)); continue
  fi
  if ! link "$TMP/$name.c" "$TMP/$name.pass" \
        -fpass-plugin="$PLUGIN" -mllvm -spinel-nogc-list="$NOGC" \
        -mllvm -spinel-gc-report 2>"$TMP/$name.report"; then
    echo "FAIL $name (pass link failed)"; sed 's/^/  | /' "$TMP/$name.report"; fail=$((fail+1)); continue
  fi

  for mode in plain stress; do
    if [ "$mode" = stress ]; then env_pfx=(env SPINEL_GC_STRESS=1); else env_pfx=(env); fi
    s_out=$("${env_pfx[@]}" "$TMP/$name.stock" 2>&1); s_rc=$?
    p_out=$("${env_pfx[@]}" "$TMP/$name.pass"  2>&1); p_rc=$?
    if [ "$s_out" != "$p_out" ] || [ "$s_rc" != "$p_rc" ]; then
      ok=0
      msg+=("  $mode: stock rc=$s_rc [$s_out]  !=  pass rc=$p_rc [$p_out]")
    fi
    if [ -f "$rb.expected" ]; then
      exp=$(cat "$rb.expected")
      if [ "$p_out" != "$exp" ]; then
        ok=0; msg+=("  $mode: pass output [$p_out] != expected [$exp]")
      fi
    fi
  done

  if [ -n "$xreason" ]; then
    if [ "$ok" = 1 ]; then
      echo "XPASS $name -- marked XFAIL but passed; remove the marker ($xreason)"
      fail=$((fail+1))
    else
      echo "XFAIL $name -- $xreason"
      printf '%s\n' "${msg[@]}"
      xfail=$((xfail+1))
    fi
  elif [ "$ok" = 1 ]; then
    echo "PASS $name  ($(grep -o 'seen .*' "$TMP/$name.report" | tail -1))"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    printf '%s\n' "${msg[@]}"
    fail=$((fail+1))
  fi
done

echo "---- $pass passed, $fail failed, $xfail expected-fail"
[ "$fail" -eq 0 ]
