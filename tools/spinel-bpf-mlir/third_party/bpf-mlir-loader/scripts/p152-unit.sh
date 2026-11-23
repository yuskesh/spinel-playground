#!/bin/bash
# E062: finite non-root controls; real live binary is built but never run here.
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/p152-unit.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?p152-unit.sh FRESH_OUT}"
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
gcc -O1 -g -Wall -Wextra -Werror -ffunction-sections -fdata-sections \
  -I"$HERE/build/libs/include" "$HERE/test/abi/arena_observe_test.c" \
  -Wl,--gc-sections -o "$OUT/arena-observe-test"
"$OUT/arena-observe-test" > "$OUT/arena-observe.log" 2>&1
bash "$HERE/scripts/unknown-probes.sh" "$OUT/unknown" > "$OUT/unknown.log" 2>&1
cd "$HERE/test/oracle"
GO="${GO:-/usr/local/go/bin/go}"
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOWORK=off
"$GO" test -count=1 -v ./internal/p152 ./cmd/p152-plan ./cmd/p152-live-check ./internal/waveproof ./cmd/load-oracle ./cmd/wave-proof > "$OUT/unit.log" 2>&1
E062_ASAN=1 "$GO" test -count=1 -v ./internal/p152 -run '^TestArenaRunnerStops$' > "$OUT/asan-stub.log" 2>&1
for cmd in p152-plan p152-live-check; do
  "$GO" build -buildvcs=false -o "$HERE/build/tools/$cmd" "./cmd/$cmd"
done
cd "$HERE"
gcc -O2 -g -std=gnu11 -Wall -Wextra -Werror -Iinclude -Isrc \
  -Ithird_party/libbpf/include/uapi -Ibuild/libs/include \
  test/abi/arena_live.c test/abi/arena_live_wrap.c \
  -Wl,--wrap=bpf_object__load -Wl,--wrap=bpf_object__close \
  -Wl,--wrap=mmap -Wl,--wrap=mmap64 -Wl,--wrap=munmap \
  build/libs/lib/libbml.a build/libs/lib/libbpf.a build/libs/lib/libelf.a \
  build/libs/lib/libz.a -lpthread -ldl -o build/tools/arena_live > "$OUT/live-build.log" 2>&1
# E063: the preroot first-bpf variant links (into OUT, not build/tools — the gate only builds it).
gcc -O2 -g -std=gnu11 -Wall -Wextra -Werror -Iinclude -Isrc \
  -Ithird_party/libbpf/include/uapi -Ibuild/libs/include \
  test/abi/arena_live.c test/abi/arena_live_wrap.c test/abi/arena_live_firstbpf.c \
  -Wl,--wrap=bpf_object__load -Wl,--wrap=bpf_object__close \
  -Wl,--wrap=mmap -Wl,--wrap=mmap64 -Wl,--wrap=munmap -Wl,--wrap=syscall \
  build/libs/lib/libbml.a build/libs/lib/libbpf.a build/libs/lib/libelf.a \
  build/libs/lib/libz.a -lpthread -ldl -o "$OUT/arena_live_firstbpf" > "$OUT/firstbpf-build.log" 2>&1
sha256sum build/tools/{p152-plan,p152-live-check,arena_live} > "$OUT/tools.sha256"
echo 'p152-unit: checker/driver/runner controls PASS; ASan+UBSan stub PASS; root0/BPF0/boot0'
