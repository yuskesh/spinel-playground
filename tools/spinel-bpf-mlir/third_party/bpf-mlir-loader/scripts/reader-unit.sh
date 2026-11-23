#!/bin/bash
# E060: pure public Go oracles and synthetic BTF; no target/kernel operations.
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/reader-unit.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?reader-unit.sh FRESH_OUT}"
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
GO="${GO:-/usr/local/go/bin/go}"
for name in recorded-check rejected-check btfblob-check; do
  (cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$GO" build -o "$OUT/$name" "./cmd/$name")
done
"$OUT/btfblob-check" "$HERE/src/caps/live_misc.c"
for mode in tools tools-asan; do
  "$HERE/build/$mode/kernel_values_unit"
  "$OUT/recorded-check" "$HERE/third_party/bpf-mlir/conformance/requirements/cases" "$HERE/build/$mode/check_case" "$OUT/$mode-recorded"
  "$OUT/rejected-check" "$HERE/build/$mode/rejected_case" "$HERE/third_party/bpf-mlir/go/bindrt/testdata/verifierlog" "$OUT/$mode-rejected"
done
# Preserve the old algorithm as a test-only control; it must fail the nine named cases.
gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror -DBML_REJECTED_LEGACY \
  -I"$HERE/src" -I"$HERE/test/abi" -o "$OUT/rejected-old" \
  "$HERE/test/abi/rejected_case.c" "$HERE/build/tools-mut/libsrc.a" \
  "$HERE/build/libs/lib/libbpf.a" "$HERE/build/libs/lib/libelf.a" "$HERE/build/libs/lib/libz.a"
rc=0
"$OUT/rejected-check" "$OUT/rejected-old" "$HERE/third_party/bpf-mlir/go/bindrt/testdata/verifierlog" "$OUT/legacy-rejected" > "$OUT/legacy.log" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$OUT/legacy.log"; exit 1; }
grep -q '18/27 same, 9 different' "$OUT/legacy.log"
expected='saved-idxdef-6.12.111.txt saved-voff-6.12.111.txt saved-voff-7.1.8.txt blank-tail positive-path invalid-nearest-2 invalid-nearest-3 source-only-after cap-11 '
[ "$(awk '/^DIFF / {printf "%s ", $2}' "$OUT/legacy.log")" = "$expected" ]
echo 'reader-unit: public Go records/Unmet/blob/rejected controls pass; kernel0'
