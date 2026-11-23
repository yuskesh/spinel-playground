#!/usr/bin/env bash
# E016 -- minimal lit-style runner for the SpinelGCRoots IR tests.
#
# Homebrew LLVM ships FileCheck but not lit (`llvm-lit` is absent and the `lit`
# python package is not installed), so this executes the `; RUN:` lines itself.
# Substitutions: %s (the test file), %opt (opt with the plugin loaded), and a
# bare `FileCheck` (resolved to the pinned toolchain).  A test passes when every
# RUN line exits 0.
#
# A `; XFAIL: <reason>` line marks a test that documents a KNOWN, UNFIXED bug:
# it is expected to fail, and an unexpected PASS (XPASS) is reported as a
# failure so the marker gets removed when the bug is fixed.
#
#   tools/llvm/passes/test/run.sh              # all *.ll here
#   tools/llvm/passes/test/run.sh foo.ll bar.ll
#
# LLVM_PREFIX / PLUGIN override the toolchain and the .so.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LLVM=${LLVM_PREFIX:-/opt/homebrew/opt/llvm}
PLUGIN=${PLUGIN:-$HERE/../build/libSpinelGCRoots.so}
OPT="$LLVM/bin/opt -load-pass-plugin=$PLUGIN"
# Spinel Extended: the official LLVM release ships no FileCheck; FILECHECK names
# one (any recent LLVM's: it matches text, it does not read IR).
FC="${FILECHECK:-$LLVM/bin/FileCheck}"

if [ ! -f "$PLUGIN" ]; then
  echo "run.sh: no plugin at $PLUGIN -- build it first (see ../README.md)" >&2
  exit 2
fi

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=("$HERE"/*.ll)
fi

pass=0; fail=0; xfail=0
for f in "${files[@]}"; do
  case "$f" in /*) ;; *) f="$HERE/$f" ;; esac
  name=$(basename "$f")
  xreason=$(sed -n 's/^; *XFAIL: *//p' "$f" | head -1)
  ok=1
  n=0
  while IFS= read -r line; do
    cmd=${line#*RUN:}
    n=$((n + 1))
    cmd=${cmd//%opt/$OPT}
    # bare `FileCheck` resolves to the pinned toolchain.  Do NOT also expand
    # `%FileCheck` here: $FC itself ends in "FileCheck", so a second pass would
    # rewrite the path it just inserted.
    cmd=${cmd//FileCheck/$FC}
    cmd=${cmd//%s/$f}
    if ! out=$(bash -c "$cmd" 2>&1); then
      ok=0
      [ -n "$xreason" ] && continue
      echo "FAIL $name (RUN line $n)"
      echo "  \$ $cmd"
      printf '%s\n' "$out" | sed 's/^/  | /'
    fi
  done < <(grep '^; *RUN:' "$f")
  if [ "$n" -eq 0 ]; then
    ok=0
    echo "FAIL $name (no RUN lines)"
  fi
  if [ -n "$xreason" ]; then
    if [ "$ok" -eq 1 ]; then
      echo "XPASS $name -- marked XFAIL but passed; remove the marker ($xreason)"
      fail=$((fail + 1))
    else
      echo "XFAIL $name -- $xreason"
      xfail=$((xfail + 1))
    fi
  elif [ "$ok" -eq 1 ]; then
    echo "PASS $name ($n RUN lines)"
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "---- $pass passed, $fail failed, $xfail expected-fail"
[ "$fail" -eq 0 ]
