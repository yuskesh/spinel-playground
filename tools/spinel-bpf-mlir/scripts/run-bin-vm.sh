#!/bin/bash
# scripts/run-bin-vm.sh — 実行 file を引数付きで virtme-ng の VM の kernel で走らせる (run-xdpcount-vm.sh の一般形 — P004 E017)。
#
#   sudo scripts/run-bin-vm.sh <bzImage> <実行 file> [引数…]
#
# VM は host の rootfs を read-write で使い、VM の中は root。stdin は /dev/null に固定する (vng — bpf-mlir E013)。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
KERNEL=${1:?bzImage}
BIN=$(readlink -f "${2:?executable}")
shift 2
exec vng --run "$KERNEL" --rw --user root --cpus 2 --memory 2G \
  --exec "echo uname=\$(uname -r); echo binary=\$(sha256sum $BIN | cut -d' ' -f1); $BIN $*; echo rc=\$?" < /dev/null
