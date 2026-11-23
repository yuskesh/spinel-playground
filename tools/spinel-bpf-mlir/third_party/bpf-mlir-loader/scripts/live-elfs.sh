#!/bin/bash
# scripts/live-elfs.sh — E004 の live の差動の ELF の一覧 (bpf-mlir の tree の .ebpf_requirements を持つ ELF — 内容で重複を除く、
# sweep-precheck.sh と同じ選び方)。root は要らない。
#
#   scripts/live-elfs.sh <出力の file>
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?出力の file}"
find "$HERE/third_party/bpf-mlir" -name '*.o' -type f -not -path '*/build/*' | LC_ALL=C sort > "$OUT.all"
: > "$OUT"
declare -A seen
while read -r f; do
  secs=$("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-readelf" -S "$f" 2>/dev/null || true)
  if grep -q "\.ebpf_requirements" <<< "$secs"; then
    h=$(sha256sum "$f" | cut -c1-64)
    [ -n "${seen[$h]:-}" ] && continue
    seen[$h]=1
    echo "$f" >> "$OUT"
  fi
done < "$OUT.all"
rm -f "$OUT.all"
echo "live-elfs: $(wc -l < "$OUT") ELF"
