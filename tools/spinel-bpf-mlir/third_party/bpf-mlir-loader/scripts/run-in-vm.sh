#!/bin/bash
# scripts/run-in-vm.sh — command を virtme-ng の VM の kernel で root として走らせる (E004 — live の差動を 6.12.111 / 6.6.157 で)。
#
#   sudo scripts/run-in-vm.sh <bzImage> <command> [args…]
#
# VM は host の rootfs を read-write でそのまま使い (--rw)、VM の中は root。network は使わない。stdin は /dev/null に固定する
# (bpf-mlir E013 — vng は stdin が端末でも /dev/null でもないと止まる)。形は bpf-mlir の kernel/smoke/vm.sh・go-bpf-mlir の run-in-vm.sh と同じ。
# VM の中では Go の module の cache が無いので、Go の oracle は host で build して環境変数で渡す (diff-kbtf.sh・diff-live-btf.sh)。
set -euo pipefail
KERNEL=${1:?bzImage}
shift
CMD=$(printf '%q ' "$@")
ENVS=""
for v in KBTF_ORACLE KBTF_LIVE MUTATE STRARG_LIVE SUDO_UID; do # E053: STRARG_LIVE (diff-strarg.sh の Go の oracle) — 一覧の漏れで VM の段が飛んだ
  [ -z "${!v:-}" ] || ENVS="$ENVS $v=$(printf '%q' "${!v}")"
done
exec vng --run "$KERNEL" --rw --user root --cpus 4 --memory 4G \
  --exec "echo uname=\$(uname -r); cd $(printf '%q' "$PWD") && env$ENVS $CMD; echo rc=\$?" < /dev/null
