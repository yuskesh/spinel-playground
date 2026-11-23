#!/bin/bash
# scripts/prep-bmlcheck.sh — P021 E085 (mojo-bpf-mlir P026 E111 の写し): bml の照合 (C) と Go の reference の照合を比べる道具を spinel の build/ に作る (bml と bpf-mlir の tree は変えない)。
#   bml-precheck・check_case (bml の corpus の case の実行) — setup の build/bml の libbml.a・libbpf・libelf・libz に link
#   ebpf-precheck — bpf-mlir の submodule の kernel/cmd/ebpf-precheck (go build -o — 在る時だけ、E167)
#
#   scripts/prep-bmlcheck.sh [出力の dir (既定 build/bml/tools)]
set -euo pipefail
cd "$(dirname "$0")/.."
HERE=$(pwd)
OUT=$(mkdir -p "${1:-build/bml/tools}" && cd "${1:-build/bml/tools}" && pwd)
BML="$HERE/third_party/bpf-mlir-loader"
L="$HERE/build/bml"
[ -f "$L/lib/libbml.a" ] || { echo "!! $L/lib/libbml.a is missing — run scripts/setup.sh first" >&2; exit 1; }
CC=(gcc -O2 -g -std=gnu11 -Wall -Wextra -Werror -I"$BML/src" -I"$BML/cmd" -I"$L/include")
LIB=("$L/lib/libbml.a" "$L/lib/libbpf.a" "$L/lib/libelf.a" "$L/lib/libz.a")
# shellcheck disable=SC2046
"${CC[@]}" -o "$OUT/bml-precheck" $("$BML/scripts/srcs.sh" cmd bml-precheck) "${LIB[@]}"
"${CC[@]}" -o "$OUT/check_case" "$("$BML/scripts/srcs.sh" test check_case)" "${LIB[@]}"
# E167: 公開 bpf-mlir に kernel/ は無い (Go の reference の ebpf-precheck が無い) — 在る時だけ作り、無ければ言って bml の 2 つだけ (run-bmlcheck は無ければ止まる)
if [ -d "$HERE/third_party/bpf-mlir/kernel/cmd/ebpf-precheck" ]; then
  (cd "$HERE/third_party/bpf-mlir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly /usr/local/go/bin/go build -o "$OUT/ebpf-precheck" ./kernel/cmd/ebpf-precheck)
else
  rm -f "$OUT/ebpf-precheck"
  echo "prep-bmlcheck: third_party/bpf-mlir has no kernel/cmd/ebpf-precheck (the public bpf-mlir source release) — built bml-precheck and check_case only; scripts/run-bmlcheck.sh needs the Go reference and stops without it" >&2
fi
echo "$OUT"
