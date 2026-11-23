#!/bin/bash
# scripts/clone-check.sh — 新しい clone (bpf-mlir・spinel の submodule 無し — bml の submodule は local から取る) で、ebpf-compile 無しに spinelbpf build -o が commit 済みの生成物から通ることを確かめる (P001 E004 の H5)。
# **commit の後に**走らせる (clone は commit した状態を見る — working tree の変更は入らない)。Spinel と Go は要る (SPINEL は元の repo の build を使う)。
#   scripts/clone-check.sh            # build だけ
#   SUDO=1 scripts/clone-check.sh     # 出来た実行 file の selftest も (root)
#   SETUP=1 scripts/clone-check.sh    # E171: clone の中で README の手順の ./scripts/setup.sh を shebang で走らせ (network・bpf-mlir の build — 長い)、
#                                     #   clone の toolchain (ebpf-compile・spinel・bml) で build する — release の前に 1 回 (毎回の gate には入れない)
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$HERE/build/tmp"
WORK=$(mktemp -d "$HERE/build/tmp/clone-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
git clone -q "$HERE" "$WORK/repo"
cd "$WORK/repo"
echo "== clone of $(git log -1 --format='%h %s' | cut -c1-80)"
echo "== submodules checked out: $(ls third_party/bpf-mlir 2>/dev/null | wc -l) files in third_party/bpf-mlir (0 = not checked out)"
if [ "${SETUP:-0}" = 1 ]; then
  # E171: README の手順のとおり shebang で (bash で明示して呼ばない — E167 の誤りを捕まえなかった形)
  ./scripts/setup.sh
  TOOLS="$WORK/repo"
  [ -x build/bpf-mlir/bin/ebpf-compile ] || { echo "!! setup did not build ebpf-compile in the clone"; exit 1; }
else
  # C の loader (P010 E042): bml の submodule だけを local (file://) から取る (入れ子は取らない — 版の照合は bml の tree の gitlink と header)、archive は元の repo の build
  . "$HERE/scripts/lib/bml-submodule.sh"; bml_submodule_update . -q --init # E167: file:// の URL の時だけ protocol.file.allow
  TOOLS="$HERE"
fi
export SPINELBPF_LOADER_LIBS="$TOOLS/build/bml/lib"
export GOFLAGS=-mod=mod TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
GO=${GO:-/usr/local/go/bin/go}
"$GO" build -o "$WORK/spinelbpf" ./cmd/spinelbpf
# ebpf-compile は既定の path (clone の build/bpf-mlir) — 既定の形では無い (commit 済みの生成物から)、SETUP=1 では setup が作った物で生成物を作り直し、commit 済みと照らす
SPINEL="$TOOLS/third_party/spinel/bin/spinel" "$WORK/spinelbpf" build -o "$WORK/xdpcount" examples/xdpcount/xdpcount.rb
# P019 E079: sched_cls (tcx) の例も commit 済みの生成物から
SPINEL="$TOOLS/third_party/spinel/bin/spinel" "$WORK/spinelbpf" build -o "$WORK/tccount" examples/tccount/tccount.rb
# P020 E083: uprobe の例 (target の greeter は clone の中の commit 済みの binary — build は SHA-256 を読むだけ)
SPINEL="$TOOLS/third_party/spinel/bin/spinel" "$WORK/spinelbpf" build -o "$WORK/greetwatch" examples/greetwatch/greetwatch.rb
# P021 E087: tp_btf と CO-RE の例
SPINEL="$TOOLS/third_party/spinel/bin/spinel" "$WORK/spinelbpf" build -o "$WORK/forkcount" examples/forkcount/forkcount.rb
git status --porcelain examples
[ -z "$(git status --porcelain examples)" ] || { echo "!! the build changed committed artefacts"; exit 1; }
ls -l "$WORK/xdpcount" "$WORK/tccount" "$WORK/greetwatch" "$WORK/forkcount"
if [ "${SUDO:-0}" = 1 ]; then # E106: 1 つずつ bpf-mlir の root の lock の中で
  . "$HERE/scripts/lib/rootlock.sh"
  rsudo "$WORK/xdpcount" --selftest 10; rsudo "$WORK/tccount" --selftest; rsudo "$WORK/greetwatch" --selftest --target "$WORK/repo/examples/greetwatch/target/greeter"; rsudo "$WORK/forkcount" --selftest
fi
echo "RESULT ok"
