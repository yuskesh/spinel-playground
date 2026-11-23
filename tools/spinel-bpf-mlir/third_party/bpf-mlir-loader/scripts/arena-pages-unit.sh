#!/bin/bash
# E065: frozen ELF inputs, real guard/native encoder, lower syscall/target substitutes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?arena-pages-unit.sh FRESH_OUT}"
mkdir "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$HERE"
INPUT=docs/experiments/results/E065/prepare/inputs
sha256sum -c "$INPUT/inputs.sha256" > "$OUT/input-check.log"
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
  cc+=(-Isrc -Iinclude -Ibuild/libs/include -Ithird_party/libbpf/include/uapi)
  libs=("$lib" build/libs/lib/libbpf.a build/libs/lib/libelf.a build/libs/lib/libz.a -lpthread -ldl)
  for name in arena_shape arena_recipe arena_extern arena_pages; do
    extra=()
    case "$name" in
      arena_recipe) extra=(-Wl,--wrap=syscall -Wl,--wrap=close);;
      arena_pages) extra=(-Wl,--wrap=bml_check -Wl,--wrap=feat_supported -Wl,--wrap=bpf_object__load
        -Wl,--wrap=bpf_map__initial_value -Wl,--wrap=bpf_obj_get_info_by_fd -Wl,--wrap=bpf_object__close);;
    esac
    "${cc[@]}" "$(scripts/srcs.sh test "$name")" "${extra[@]}" "${libs[@]}" -o "$OUT/$mode/$name"
    args=()
    if [ "$name" = arena_extern ] || [ "$name" = arena_pages ]; then
      args=("$INPUT/pages-1024.bpf.o" "$INPUT/pages-segv.bpf.o")
    fi
    if [ "$mode/$name" = asan/arena_pages ]; then
      args=("$INPUT/pages-high-1024.bpf.o" "$INPUT/pages-high-segv.bpf.o")
    fi
    "$OUT/$mode/$name" "${args[@]}" > "$OUT/$mode/$name.log" 2>&1
    test -s "$OUT/$mode/$name.log"
  done
  [ "$(grep -c '^arena-recipe-' "$OUT/$mode/arena_recipe.log")" = 26 ]
  [ "$(grep -c '^arena-extern-' "$OUT/$mode/arena_extern.log")" = 54 ]
  [ "$(grep -c '^arena-pages-' "$OUT/$mode/arena_pages.log")" = 22 ]
done
rc=0
"$OUT/mut/arena_shape" --flags-mutant > "$OUT/flags-mutant.log" 2>&1 || rc=$?
[ "$rc" = 1 ]
grep -q '^arena-shape-extra-flags: FAIL$' "$OUT/flags-mutant.log"
rc=0
"$OUT/mut/arena_pages" "$INPUT/pages-1024.bpf.o" "$INPUT/pages-segv.bpf.o" --info-mutant > "$OUT/info-mutant.log" 2>&1 || rc=$?
[ "$rc" = 1 ]
grep -q '^arena-pages-132096-transaction2: FAIL$' "$OUT/info-mutant.log"
echo 'arena-pages-unit: release/ASan/UBSan/mut finite flags/recipe/extern/owner; 2 sensitivities PASS; kernel0'
