#!/bin/bash
# scripts/tutorial-run.sh — docs/tutorial.md の `sh` の block の command を新しい clone で順に走らせる (P022 E090)。command の行は tutorial と
# 同じ綴り (TestTutorialCommands が tutorial の各行がこの file に在ることを見る — 頁と runner の食い違いで落ちる)。**commit の後に**走らせる。
#   scripts/tutorial-run.sh                       # 今の HEAD の clone、段 0 の setup は元の repo の build (toolchain・bml の archive) を使う
#   scripts/tutorial-run.sh --full                # 段 0 の scripts/setup.sh も clone の中で (network — bpf-mlir の submodule と libprism)
#   SPINELBPF_TAG=v0.8.0 scripts/tutorial-run.sh  # tag の clone (git clone --branch)
# 段 1〜4 の `sudo` は bpf-mlir の root の lock の中の `sudo -n` (E106 — root の許しが要る — 無ければ止まる)。
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FULL=0
[ "${1:-}" = "--full" ] && FULL=1
SRC="$HERE"
TAG="${SPINELBPF_TAG:-}"
mkdir -p "$HERE/build/tmp"
WORK=$(mktemp -d "$HERE/build/tmp/tutorial-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
cd "$WORK"
. "$HERE/scripts/lib/rootlock.sh"
vm_guest_require # E165: root の段は VM の guest だけ — host では clone の前に止める
sudo() { rsudo "$@"; } # E106: tutorial の綴りの `sudo` は bpf-mlir の root の lock の中の `sudo -n`
step() { echo "== $*"; }

# 段 0
if [ -n "$TAG" ]; then
  step "git clone --branch $TAG"
  git clone --branch "$TAG" "$SRC" spinel-bpf-mlir
else
  step "git clone (HEAD — SPINELBPF_TAG unset)"
  git clone "$SRC" spinel-bpf-mlir
fi
cd spinel-bpf-mlir
echo "== clone of $(git log -1 --format='%h %s' | cut -c1-80)"
if [ "$FULL" = 1 ]; then
  step "scripts/setup.sh"
  scripts/setup.sh
else
  # setup の代わり: 元の repo の build の toolchain と bml の archive (bml の submodule は link の header のため取る — clone-check と同じ)
  step "setup skipped (no --full) — the source repo's toolchain"
  . "$HERE/scripts/lib/bml-submodule.sh"; bml_submodule_update . -q --init # E167: file:// の URL の時だけ protocol.file.allow
  export SPINEL="$HERE/third_party/spinel/bin/spinel" EBPF_COMPILE="$HERE/build/bpf-mlir/bin/ebpf-compile" SPINELBPF_LOADER_LIBS="$HERE/build/bml/lib"
fi
export GOFLAGS=-mod=mod
/usr/local/go/bin/go build -o build/bin/spinelbpf ./cmd/spinelbpf
build/bin/spinelbpf --version
head -1 <(build/bin/spinelbpf --version) | grep -q "^spinel-bpf-mlir v[0-9.]* (commit $(git rev-parse HEAD | cut -c1-12))$" || { echo "!! --version: not this clone's commit or +dirty"; exit 1; }
if build/bin/spinelbpf --version | grep -q "^ebpf-compile: not found$"; then echo "!! ebpf-compile not found"; exit 1; fi
# E098: tutorial の段 0 の依存の行の期待と --version の依存の行を両向きに (版の上げで tutorial の古い行を黙って残さない)
build/bin/spinelbpf --version > "$WORK/version.txt"
"$HERE/scripts/check-version-doc.sh" docs/tutorial.md "$WORK/version.txt" || { echo "!! docs/tutorial.md and --version disagree on the dependency lines"; exit 1; }

# 段 1〜4
build/bin/spinelbpf build -o build/bin/xdpcount examples/xdpcount/xdpcount.rb
sudo build/bin/xdpcount --selftest 10
build/bin/spinelbpf build -o build/bin/tccount examples/tccount/tccount.rb
sudo build/bin/tccount --selftest
build/bin/spinelbpf build -o build/bin/greetwatch examples/greetwatch/greetwatch.rb
sudo build/bin/greetwatch --selftest --target examples/greetwatch/target/greeter
build/bin/spinelbpf build -o build/bin/forkcount examples/forkcount/forkcount.rb
sudo build/bin/forkcount --selftest

[ -z "$(git status --porcelain)" ] || { git status --porcelain; echo "!! the tutorial changed tracked files"; exit 1; }
echo "RESULT ok"
