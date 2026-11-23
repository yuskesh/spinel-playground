#!/bin/bash
# scripts/run-xdpcount-vm.sh — P001 E005: 同じ xdpcount の実行 file の --selftest を virtme-ng の VM の kernel で走らせる (mojo-bpf-mlir の同名の script の形)。
#
#   sudo scripts/run-xdpcount-vm.sh <bzImage> <xdpcount の実行 file> [N=50]
#
# VM は host の rootfs を read-write でそのまま使い (--rw)、VM の中は root。network は使わない (--selftest は BPF_PROG_TEST_RUN)。
# 実行 file は libc・libm・libcrypt だけに依存する (E004) — host の rootfs を共有するので VM の中でも同じ file。
# stdin は /dev/null に固定する (vng は stdin が端末でも /dev/null でもないと `not a valid pts` で止まる — bpf-mlir E013)。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
KERNEL=${1:?bzImage}
BIN=$(readlink -f "${2:?xdpcount executable}")
N=${3:-50}
exec vng --run "$KERNEL" --rw --user root --cpus 2 --memory 2G \
  --exec "echo uname=\$(uname -r); echo binary=\$(sha256sum $BIN | cut -d' ' -f1); $BIN --selftest $N; echo rc=\$?" < /dev/null
