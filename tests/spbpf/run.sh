#!/bin/sh
# tests/spbpf/run.sh -- the SpBPF lane's lit tests, without lit.
#
# tools/mlir/native/test/{Dialect,Target}/SpBPF came with the lane from
# spinel-llvm 463d49dd, where lit ran them. lit is Python, which this
# repository does not admit, so this runs their RUN lines itself: each test's
# RUN lines (joined across trailing `\`) with %s, %S and %t substituted, in
# bash, in order, failing the test on the first line that exits non-zero, with
# pipefail as lit sets it. It supports exactly what those files use: two carry
# `REQUIRES: bpftool`, which the bpftool check below satisfies; none carries
# XFAIL or UNSUPPORTED.
#
# A test whose RUN lines call spinel-mlirgen is NOT-PORTED: that tool is
# spinel-llvm's MLIR front end, which this repository does not build.
#
#   FILECHECK_DIR=/dir/with/FileCheck-and-not LLVM_PREFIX=... sh tests/spbpf/run.sh
#
# FileCheck and `not` are LLVM test utilities the release does not ship; any
# recent LLVM's will do (they match text). bpftool must be on PATH.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
N=$(cd "$HERE/../../tools/mlir/native" && pwd)
: "${LLVM_PREFIX:?set LLVM_PREFIX to the official LLVM 23.1.1}"
: "${FILECHECK_DIR:?set FILECHECK_DIR to a directory holding FileCheck and not}"
for t in FileCheck not; do
  [ -x "$FILECHECK_DIR/$t" ] || { echo "spbpf: no $t in $FILECHECK_DIR" >&2; exit 2; }
done
BIN=${SPINEL_CORE_BUILD:-$N/build}/bin
for t in spbpf-opt spbpf-compile spinel-mlir-capi-smoke spinel-spbpf-schema-test; do
  [ -x "$BIN/$t" ] || { echo "spbpf: no $t in $BIN (tools/mlir/native/build.sh)" >&2; exit 2; }
done
command -v bpftool >/dev/null 2>&1 || { echo "spbpf: no bpftool on PATH" >&2; exit 2; }
PATH=$BIN:$LLVM_PREFIX/bin:$FILECHECK_DIR:$PATH
export PATH
W=${SPBPF_WORK:-${TMPDIR:-/tmp}/spinel-spbpf}
rm -rf "$W"; mkdir -p "$W"

pass=0; fail=0; np=0; t0=$(date +%s)
for f in "$N"/test/Dialect/SpBPF/*.mlir "$N"/test/Target/SpBPF/*.test; do
  rel=${f#"$N"/test/}
  # The RUN lines, continuation lines joined.
  runs=$(sed -n 's/^.*RUN: \{0,1\}//p' "$f" | awk '{ if (sub(/\\$/, "")) { buf = buf $0 } else { print buf $0; buf = "" } }')
  if printf '%s\n' "$runs" | grep -q 'spinel-mlirgen'; then
    echo "NOT-PORTED $rel (needs spinel-mlirgen)"; np=$((np + 1)); continue
  fi
  tmp=$W/$(printf '%s' "$rel" | tr '/' '_')
  dir=$(dirname "$f")
  ok=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cmd=$(printf '%s' "$line" | sed -e "s#%s#$f#g" -e "s#%S#$dir#g" -e "s#%t#$tmp#g")
    if ! bash -c "set -o pipefail; $cmd" > "$tmp.out" 2>&1; then
      ok=0; echo "FAIL $rel"; echo "  RUN: $line"; sed 's/^/    /' "$tmp.out" | head -12
      break
    fi
  done <<EOF
$runs
EOF
  if [ "$ok" = 1 ]; then pass=$((pass + 1)); echo "PASS $rel"; else fail=$((fail + 1)); fi
done
echo "spbpf: $pass pass, $fail fail, $np not ported [$(( $(date +%s) - t0 )) s]"
[ "$fail" = 0 ]
