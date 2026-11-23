#!/bin/bash
# scripts/e56-attach-target.sh — E056 の H3: .dynsym だけの本体への製品の uprobe / uretprobe の attach (自分の子 process だけ)。
#
#   scripts/e56-attach-target.sh prep <dir> [<前の commit>]   # 非 root: fixture・ELF・runner (今の build/tools の e56_attach と、前の commit の
#                                                           #   libbml.a で link した e56_attach-old — 使い捨ての worktree)
#   sudo scripts/e56-attach-target.sh run <dir>              # root: 今の runner と前の runner を 1 回ずつ (bpf-mlir の root の lock の中で呼ぶ)
#
# 合否 (run): 今は load=0 up=0 ur=0 hits=4,4 calls=4、前は load=0 で attach が "the target has 0 FUNC symbols named e56_fn" で落ちる
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:?prep か run}"; D="${2:?dir}"
case "$D" in /*) ;; *) D="$PWD/$D" ;; esac
if [ "$MODE" = prep ]; then
  OLD="${3:-afd5441}"
  rm -rf "$D"; mkdir -p "$D"
  "$HERE/scripts/e56-fixtures.sh" "$D/fx" > "$D/fx.sha256" || exit 1
  sha=$(sha256sum "$D/fx/dynsym" | cut -d' ' -f1)
  jq --arg s "$sha" '.core.programs[].binary_sha256 = $s' "$HERE/test/abi/fixture/e56.schema.json" > "$D/schema.jsn"
  "$HERE/build/bpf-mlir/bin/ebpf-compile" "$HERE/test/abi/fixture/e56.mlir" --schema "$D/schema.jsn" -o "$D/e56.bpf.o" || exit 1
  sha256sum "$D/schema.jsn" | cut -d' ' -f1 > "$D/schema.sha"
  printf '{"maps":[{"name":"hits","kind":"array","key":"u32","value":"u64","max_entries":2}]}\n' > "$D/maps.jsn"
  cp "$HERE/build/tools/e56_attach" "$D/e56_attach"
  if [ "$OLD" = none ]; then # gate: 今の runner だけ
    (cd "$D" && sha256sum e56.bpf.o schema.jsn maps.jsn e56_attach fx/dynsym fx/full.debug) > "$D/prepared.sha256"
    exit 0
  fi
  # 前の commit の library (E055 の main — attach は .symtab だけ)
  WT="$D/old-wt"
  git -C "$HERE" worktree add -q --detach "$WT" "$OLD" || exit 1
  for s in libbpf elfutils zlib bpf-mlir; do rmdir "$WT/third_party/$s" 2>/dev/null; ln -sfn "$HERE/third_party/$s" "$WT/third_party/$s"; done
  (cd "$WT" && scripts/build-libs.sh "$D/old-libs" > "$D/old-libs.log" 2>&1) || { tail -5 "$D/old-libs.log"; exit 1; }
  L="$D/old-libs/lib"
  gcc -O2 -std=gnu11 -I"$D/old-libs/include" -o "$D/e56_attach-old" "$HERE/test/abi/e56_attach.c" "$L/libbml.a" "$L/libbpf.a" "$L/libelf.a" "$L/libz.a" || exit 1
  git -C "$HERE" worktree remove --force "$WT"
  (cd "$D" && sha256sum e56.bpf.o schema.jsn maps.jsn e56_attach e56_attach-old fx/dynsym fx/full.debug) > "$D/prepared.sha256"
  echo "prepared: $D ($(sha256sum "$D/prepared.sha256" | cut -c1-16))"
elif [ "$MODE" = run ]; then
  [ "$(id -u)" = 0 ] || { echo "e56-attach-target: run は root で" >&2; exit 2; }
  (cd "$D" && sha256sum -c --quiet prepared.sha256) || { echo "e56-attach-target: prepared の hash が違う" >&2; exit 1; }
  for t in e56_attach e56_attach-old; do
    [ -x "$D/$t" ] || continue # gate の prep (none) は今の runner だけ
    echo "== $t"
    "$D/$t" "$D/e56.bpf.o" "$(cat "$D/schema.sha")" "$D/maps.jsn" "$D/fx/dynsym" "$D/fx/full.debug"
  done 2>&1 | tee "$D/run.txt"
  chown -R "${SUDO_UID:-1000}" "$D"
  grep -qx 'load=0 up=0 ur=0 hits=4,4 calls=4' "$D/run.txt" && { [ ! -x "$D/e56_attach-old" ] || grep -q 'attach up: kind=.* the target has 0 FUNC symbols named e56_fn' "$D/run.txt"; } && echo same || { echo DIFF; exit 1; }
else
  echo "e56-attach-target: mode は prep か run" >&2; exit 2
fi
