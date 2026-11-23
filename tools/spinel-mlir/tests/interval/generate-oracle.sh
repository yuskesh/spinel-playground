#!/bin/sh
set -eu
src=${1:?pinned repository}; scratch=${2:?private scratch}
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
pin=0ae550f4d92ebeb606f00576119ef9633c961019
mkdir -p "$scratch"
for f in interval.go narrow.go; do git -C "$src" show "$pin:internal/frontend/$f" > "$scratch/$f"; done
cp "$root/tests/interval/Oracle_test.go" "$scratch/Oracle_test.go"
cd "$scratch"
sha256sum interval.go narrow.go > "$root/docs/experiments/results/E004/oracle-source.sha256"
E004_CASES="$root/tests/interval/cases.tsv" GOTOOLCHAIN=local /usr/local/go/bin/go test interval.go narrow.go Oracle_test.go -run TestGenerate -count=1
