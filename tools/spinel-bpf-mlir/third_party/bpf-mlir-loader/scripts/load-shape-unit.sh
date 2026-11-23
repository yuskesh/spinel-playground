#!/bin/bash
# E062 STOP C: real guard path with lower probe/target-load stubs, never root.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?load-shape-unit.sh FRESH_OUT FIXTURE}"
FIXTURE="${2:?HighMem arena ELF}"
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$HERE"
features=(third_party/bpf-mlir/docs/experiments/results/E628/{h2/probe,h4-stop/dead,h4-stop/reach,h4/hoist}.bpf.o)
arenas=(third_party/bpf-mlir/docs/experiments/results/E639/window{,-alt,-hi,-lo}.bpf.o)
sha256sum "$FIXTURE" "${features[@]}" "${arenas[@]}" src/load/pre.c test/load/{feature_mapping,arena_guard_shape}.c test/abi/arena_checked_shape.c > "$OUT/inputs.sha256"
for mode in release asan mut; do
  mkdir "$OUT/$mode"
  cc=(gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror)
  lib=build/libs/lib/libbml.a
  if [ "$mode" = asan ]; then
    cc=("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang" -O1 -g -std=gnu11 -Wall -Wextra -Werror
      -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    lib=build/tools-asan/libsrc.a
  elif [ "$mode" = mut ]; then
    cc+=(-DBML_MUTATION -DBML_TEST_CAPS)
    lib=build/tools-mut/libsrc.a
  fi
  cc+=(-Isrc -Iinclude -Ithird_party/libbpf/include/uapi -Ibuild/libs/include)
  libs=("$lib" build/libs/lib/libbpf.a build/libs/lib/libelf.a build/libs/lib/libz.a -lpthread -ldl)
  for name in feature_mapping arena_guard_shape arena_checked_shape; do
    extra=(-Wl,--wrap=feat_supported)
    [ "$name" = feature_mapping ] || extra+=(-Wl,--wrap=bpf_object__load)
    [ "$name" != arena_checked_shape ] || extra+=(-Wl,--wrap=bml_check)
    "${cc[@]}" "$(scripts/srcs.sh test "$name")" "${extra[@]}" "${libs[@]}" -o "$OUT/$mode/$name"
    args=("$FIXTURE")
    [ "$name" != feature_mapping ] || args=("${features[@]}")
    [ "$name" != arena_guard_shape ] || args=("$FIXTURE" "${arenas[@]}")
    if [ "$mode/$name" = release/arena_checked_shape ]; then
      strace -qq -f -e trace=bpf -o "$OUT/target-bpf.strace" "$OUT/$mode/$name" "${args[@]}" > "$OUT/$mode/$name.log" 2>&1
      ! grep -q 'bpf(' "$OUT/target-bpf.strace"
    else
      "$OUT/$mode/$name" "${args[@]}" > "$OUT/$mode/$name.log" 2>&1
    fi
  done
done
# Compile the real guard with only the dedicated check replaced by unconditional acceptance.
gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror -Isrc -Iinclude -Ibuild/libs/include \
  -Dbml_arena_elf=e062_accept_extra -c src/load/pre.c -o "$OUT/any-extra.o"
gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror -Isrc -Iinclude -Ibuild/libs/include \
  -DE062_ANY_MAP_EXTRA test/load/arena_guard_shape.c "$OUT/any-extra.o" \
  -Wl,--wrap=feat_supported -Wl,--wrap=bpf_object__load \
  build/libs/lib/libbml.a build/libs/lib/libbpf.a build/libs/lib/libelf.a build/libs/lib/libz.a -lpthread -ldl -o "$OUT/any-extra"
rc=0
"$OUT/any-extra" "$FIXTURE" > "$OUT/any-extra.log" 2>&1 || rc=$?
[ "$rc" = 1 ]
grep -q '^arena-guard-1-nonarena: FAIL' "$OUT/any-extra.log"
sha256sum -c "$OUT/inputs.sha256" > "$OUT/input-check.log"
echo 'load-shape-unit: real checked/shape/reservation, feature cross-check, refusal sensitivity PASS; kernel0'
