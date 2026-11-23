#!/bin/bash
# scripts/run-table-vm.sh — P002 E011: 表の kernel の harness を virtme-ng の VM の kernel で走らせる (E005 の run-xdpcount-vm.sh の形)。
#
#   sudo scripts/run-table-vm.sh <bzImage> <dir>
#
# <dir> の `<name>.kernel` (kernel の harness の実行 file) を `<name>.script` (命令の列) を stdin にして走らせ、`<name>.<uname>.out` に書く。
# `<name>.pin` が在れば VM の中で `taskset -c 0` で走らせる (per-CPU の表 — 0 でない slot を 1 つに、P009 E040)。
# VM は host の rootfs を read-write で使う (出力は host の file)。vng の stdin は /dev/null に固定する (bpf-mlir E013) — 命令は file で渡す。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
KERNEL=${1:?bzImage}
DIR=$(readlink -f "${2:?dir}")
exec vng --run "$KERNEL" --rw --user root --cpus 2 --memory 2G \
  --exec "u=\$(uname -r); echo uname=\$u; for s in $DIR/*.script; do n=\${s%.script}; if [ -e \$n.pin ]; then taskset -c 0 \$n.kernel < \$s > \$n.\$u.out 2>&1; else \$n.kernel < \$s > \$n.\$u.out 2>&1; fi; echo \$(basename \$n) rc=\$? \$(sha256sum \$n.kernel | cut -c1-16); done" < /dev/null
