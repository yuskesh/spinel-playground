#!/bin/sh
# tests/ebpf-go/run.sh -- the Go path to eBPF, without privilege.
#
# Ported from spinel-llvm 463d49dd tools/ebpf/go/run_gate.sh (E152), minus its
# otlp-agent step (that program is an oracle, kept as files). In order:
#   1. the spbpf builder and bindgen's own Go tests;
#   2. the builder's committed .mlir passes the SpBPF verifier (spbpf-opt);
#   3. spbpf-bindgen builds;
#   4. examples/ebpf-go/xdp-counter is generated end to end
#      (builder -> .mlir -> spbpf-compile -> ELF -> typed bindings);
#   5. the example's Go tests (ELF parse without privilege, dependency scan);
#   6. the generated .mlir and objects_gen.go are the committed ones, byte for
#      byte (the generator reproduces its own output).
# The live check (attach, count, ring buffer) is tests/ebpf-go/live.sh.
#
#   GO=/path/to/go sh tests/ebpf-go/run.sh      # docs/toolchains/go-1.25.14
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
: "${GO:?set GO to the go binary (docs/toolchains/go-1.25.14)}"
export GOTOOLCHAIN=local
BIN=${SPINEL_CORE_BUILD:-$REPO/tools/mlir/native/build}/bin
for t in spbpf-compile spbpf-opt; do
  [ -x "$BIN/$t" ] || { echo "ebpf-go: no $t in $BIN (tools/mlir/native/build.sh)" >&2; exit 2; }
done
W=${EBPF_GO_WORK:-${TMPDIR:-/tmp}/spinel-ebpf-go}
mkdir -p "$W"
X=$REPO/examples/ebpf-go/xdp-counter
t0=$(date +%s)
echo "== 1. builder and bindgen tests"; (cd "$REPO/tools/ebpf/go" && "$GO" test ./...)
echo "== 2. the builder's .mlir verifies"
"$BIN/spbpf-opt" --spbpf-verify-ownership "$REPO/tools/ebpf/go/spbpf/testdata/xdp_counter.mlir" -o /dev/null
echo "== 3. spbpf-bindgen"; (cd "$REPO/tools/ebpf/go" && "$GO" build -o "$W/spbpf-bindgen" ./cmd/spbpf-bindgen)
echo "== 4. generate xdp-counter"
(cd "$X" && SPBPF_COMPILE="$BIN/spbpf-compile" SPBPF_BINDGEN="$W/spbpf-bindgen" "$GO" generate ./...)
echo "== 5. the example's tests"; (cd "$X" && "$GO" test ./...)
echo "== 6. the generated files are the committed ones"
# Tracked first: git diff says nothing about an untracked file.
(cd "$REPO" && git ls-files --error-unmatch examples/ebpf-go/xdp-counter/objects_gen.go \
    examples/ebpf-go/xdp-counter/xdp_counter.mlir > /dev/null \
  && git diff --exit-code -- examples/ebpf-go/xdp-counter/objects_gen.go \
    examples/ebpf-go/xdp-counter/xdp_counter.mlir)
echo "ebpf-go: every step passed [$(( $(date +%s) - t0 )) s]"
