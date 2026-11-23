#!/bin/sh
set -eu
B=${1:?build directory}
R=${2:?source repository}
T="$B/batch-contract-test"
rm -rf "$T"
mkdir -p "$T/tools"
ln -s "$B/bpf-mlir/bin/ebpf-compile" "$T/tools/compiler-saved"
ln -s "$B/bin/spinel-ir-normalize" "$T/tools/spinel-ir-normalize"
ruby "$R/test/batch-contract.rb" "$R" "$T/tools" "$T/run"
