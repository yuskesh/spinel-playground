#!/bin/bash
# E061: pure/link-wrapped units only. No target BPF operation or privilege.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?arena-unit.sh FRESH_OUT}"
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$HERE"
sha256sum third_party/bpf-mlir/kernel/arena/mlir/window.mlir \
  third_party/bpf-mlir/kernel/arena/mlir/schema.json test/load/arena_schema.json test/arena_fixture.h \
  build/bpf-mlir/bin/ebpf-compile > "$OUT/fixture-before.sha256"
cp third_party/bpf-mlir/kernel/arena/mlir/window.mlir "$OUT/window.mlir"
cp test/load/arena_schema.json "$OUT/schema.json"
sha256sum "$OUT/window.mlir" "$OUT/schema.json" > "$OUT/derived-before.sha256"
build/bpf-mlir/bin/ebpf-compile "$OUT/window.mlir" \
  --schema "$OUT/schema.json" -o "$OUT/window.bpf.o" > "$OUT/compile.log" 2>&1
sha256sum "$OUT/window.bpf.o" > "$OUT/fixture-after.sha256"
for mode in release asan mut; do
  mkdir "$OUT/$mode"
  cc=(gcc -O1 -g -std=gnu11 -Wall -Wextra -Werror)
  lib=build/libs/lib/libbml.a
  if [ "$mode" = asan ]; then
    cc=("${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang" -O1 -g -std=gnu11 -Wall -Wextra -Werror \
      -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    lib=build/tools-asan/libsrc.a
  elif [ "$mode" = mut ]; then
    cc+=(-DBML_MUTATION -DBML_TEST_CAPS)
    lib=build/tools-mut/libsrc.a
  fi
  cc+=(-Isrc -Iinclude -Ithird_party/libbpf/include/uapi -Ibuild/libs/include)
  libs=("$lib" build/libs/lib/libbpf.a build/libs/lib/libelf.a build/libs/lib/libz.a -lpthread -ldl)
  for test in arena_decl arena_shape arena_reserve arena_transaction arena_object arena_checked; do
    extra=()
    case "$test" in
      arena_transaction) extra=(-Wl,--wrap=bpf_map__initial_value -Wl,--wrap=bpf_obj_get_info_by_fd -Wl,--wrap=bpf_object__close) ;;
      arena_object) extra=(-Wl,--wrap=memmove -Wl,--wrap=__asan_memmove -Wl,--wrap=bml_obj_arena_span -Wl,--wrap=bpf_object__find_map_by_name) ;;
      arena_checked) extra=(-Wl,--wrap=bml_check -Wl,--wrap=bml_load_guarded_values) ;;
    esac
    src="$(scripts/srcs.sh test "$test")"
    "${cc[@]}" "$src" "${extra[@]}" "${libs[@]}" -o "$OUT/$mode/$test"
    args=("$OUT/window.bpf.o")
    [ "$test" != arena_checked ] || args+=("third_party/bpf-mlir/docs/experiments/results/E639/window.bpf.o")
    "$OUT/$mode/$test" "${args[@]}" > "$OUT/$mode/$test.log" 2>&1
  done
  "${cc[@]}" test/abi/arena_copy.c src/abi/arena.c -o "$OUT/$mode/arena_copy"
  "$OUT/$mode/arena_copy" > "$OUT/$mode/arena_copy.log" 2>&1
done
rc=0
"$OUT/mut/arena_copy" --mutate-boundary > "$OUT/boundary-mutant.log" 2>&1 || rc=$?
[ "$rc" = 1 ]
[ "$(grep -c 'FAIL' "$OUT/boundary-mutant.log")" = 1 ]
grep -q '^arena-copy-end-cross: FAIL$' "$OUT/boundary-mutant.log"
echo 'arena-unit: declarations/shape/reservation/lifetime/copy pass; boundary mutation caught; kernel0'
bash "$HERE/scripts/load-shape-unit.sh" "$OUT/guard" "$OUT/window.bpf.o"
bash "$HERE/scripts/arena-pages-unit.sh" "$OUT/pages"
