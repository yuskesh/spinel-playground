#!/bin/bash
# E063: the non-root preroot sweep of a P152 candidate manifest (docs/tools/preroot.md).
#   scripts/p152-preroot.sh FRESH_OUT --manifest M --manifest-sha S --recorded DIR [--mutants=false]
# Builds p152-plan and the first-bpf arena_live (arena_live_firstbpf.c, --wrap=syscall) into
# FRESH_OUT/tools from this tree, then runs `p152-plan preroot --out FRESH_OUT/preroot`.
# No root, no bpf(2), no VM: P7 runs the candidate's wrapper with the real vng / virtme --dry-run (no QEMU).
# rc: 0 every row as expected, 1 a row / expectation / mutant differs, 2 usage or setup error.
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/p152-preroot.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?p152-preroot.sh FRESH_OUT --manifest M --manifest-sha S --recorded DIR}"
shift
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
mkdir "$OUT/tools"
GO="${GO:-/usr/local/go/bin/go}"
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOWORK=off
export TMPDIR="$HERE/build/tmp"
mkdir -p "$TMPDIR"
( cd "$HERE/test/oracle" && "$GO" build -buildvcs=false -o "$OUT/tools/p152-plan" ./cmd/p152-plan ) > "$OUT/build.log" 2>&1 || { echo "p152-preroot: p152-plan build failed ($OUT/build.log)" >&2; exit 2; }
cd "$HERE"
gcc -O2 -g -std=gnu11 -Wall -Wextra -Werror -Iinclude -Isrc \
  -Ithird_party/libbpf/include/uapi -Ibuild/libs/include \
  test/abi/arena_live.c test/abi/arena_live_wrap.c test/abi/arena_live_firstbpf.c \
  -Wl,--wrap=bpf_object__load -Wl,--wrap=bpf_object__close \
  -Wl,--wrap=mmap -Wl,--wrap=mmap64 -Wl,--wrap=munmap -Wl,--wrap=syscall \
  build/libs/lib/libbml.a build/libs/lib/libbpf.a build/libs/lib/libelf.a \
  build/libs/lib/libz.a -lpthread -ldl -o "$OUT/tools/arena_live_firstbpf" >> "$OUT/build.log" 2>&1 \
  || { echo "p152-preroot: arena_live_firstbpf build failed ($OUT/build.log)" >&2; exit 2; }
sha256sum "$OUT/tools/p152-plan" "$OUT/tools/arena_live_firstbpf" > "$OUT/tools.sha256"
rc=0
"$OUT/tools/p152-plan" preroot --out "$OUT/preroot" --firstbpf "$OUT/tools/arena_live_firstbpf" "$@" < /dev/null || rc=$?
exit "$rc"
