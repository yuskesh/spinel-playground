# scripts/lib/rootlock.sh — root calls one at a time inside bpf-mlir's host-wide lock (E106 — at the bpf-mlir coordinator's request, 2026-10-04; the same form as the rsudo of bml's gate).
# source して `rsudo <command> …` (= `sudo -n <command> …`)。fd は呼び出しごとの subshell で開いて閉じる (呼び手の shell は fd を持たない —
# 途中の失敗・signal で lock が残らない)。読みの fd でも flock は取れる。file が無ければ止める (作るのは bpf-mlir の側 — 黙って作らない)、
# 30 分待って取れなければ rc 125。SPINELBPF_ROOT_LOCK で lock の path を替えられる (試験のため)。
# E165: VM の guest の印が無ければ sudo を実行せず rc 126 で止める (host の kernel に対して root を走らせない)。sudo と cmdline の path は rsudo_at の引数で —
# 対照 (TestRsudoGuestGuard) は偽物だけを渡す (env で替える経路を作らない)。
RL=${SPINELBPF_ROOT_LOCK:-/run/lock/bpf-mlir-root.lock}
. "$(dirname -- "${BASH_SOURCE[0]}")/guest-only.sh"
rsudo_at() { local s=$1 c=$2; shift 2
  vm_guest_check "$c" || { echo "rsudo: refusing to run on the host — root runs only in the VM guest (scripts/gate-vm.sh, E165)" >&2; return 126; }
  [ -e "$RL" ] || { echo "rsudo: the bpf-mlir root lock $RL is missing (bpf-mlir's root stage creates it)" >&2; return 125; }
  ( flock -n 9 || { echo "rsudo: another holds the bpf-mlir root lock — waiting" >&2; flock -w 1800 9; } || { echo "rsudo: could not take the root lock in 30 minutes" >&2; exit 125; }
    "$s" -n "$@" ) 9<"$RL" # rootlock:ok
}
rsudo() { rsudo_at /usr/bin/sudo /proc/cmdline "$@"; }
