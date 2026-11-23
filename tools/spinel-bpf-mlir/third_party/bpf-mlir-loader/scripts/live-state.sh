#!/bin/bash
# scripts/live-state.sh — E004 の H5: bml-precheck --live --record の process の状態の検査 (root で — sudo)。ELF ごとに strace で
# signal (rt_sigaction・rt_sigprocmask・sigaltstack)・thread (clone・clone3)・rlimit (prlimit64・setrlimit) の syscall が 0、bpf と open で
# 得た fd が exit までに全て閉じられることを見る。
#
#   sudo scripts/live-state.sh <ELF の一覧> <TOOLS_DIR> <作業の dir> [load]   # load: 照合と guard 付きの load (load_case — E005 の H4)
set -uo pipefail
ELFS="${1:?}"; T="${2:?}"; W="${3:?}"; MODE="${4:-precheck}"
[ "$(id -u)" = 0 ] || { echo "live-state: root で走らせる" >&2; exit 2; }
rm -rf "$W"; mkdir -p "$W"
n=0 bad=0 bpfcalls=0
while read -r f; do
  n=$((n + 1))
  strace -f -qq -o "$W/trace" -e trace=rt_sigaction,rt_sigprocmask,sigaltstack,clone,clone3,prlimit64,setrlimit,bpf,openat,close,fcntl,dup,dup2,dup3 \
    $( [ "$MODE" = load ] && echo "$T/load_case" || echo "$T/bml-precheck --loader=cilium-v0.22 --live --record=$W/rec.json" ) "$f" > /dev/null 2>&1
  # glibc の起動は signal を触らない (min.c の検査 — E001)。ここは process の全体
  # prlimit64 の読み (新しい値が NULL — glibc の起動の RLIMIT_STACK) は状態を変えないので除く
  forbidden=$(grep -E ' (rt_sigaction|rt_sigprocmask|sigaltstack|clone|clone3|prlimit64|setrlimit)\(' "$W/trace" |
    grep -cvE ' prlimit64\([0-9]+, RLIMIT_[A-Z_]+, NULL,')
  bpfcalls=$((bpfcalls + $(grep -c ' bpf(' "$W/trace")))
  # fd の出入り: 返り値の fd を開いたに、close を閉じたに (0〜2 は除く)
  leaked=$(awk '
    / (bpf|openat|fcntl|dup|dup2|dup3)\(/ && / = [0-9]+$/ { fd = $NF; if (fd > 2 && $0 !~ /F_GETF|F_SETF/) open[fd] = $0 }
    / close\(/ { s = $0; sub(/.*close\(/, "", s); sub(/\).*/, "", s); delete open[s] }
    END { for (k in open) print k; }' "$W/trace" | wc -l)
  if [ "$forbidden" -ne 0 ] || [ "$leaked" -ne 0 ]; then
    bad=$((bad + 1)); echo "$f forbidden=$forbidden leaked=$leaked" >> "$W/bad.txt"; cp "$W/trace" "$W/trace.$bad"
  fi
done < "$ELFS"
echo "live-state: $(uname -r) elfs=$n bad=$bad (bpf の syscall の総数 $bpfcalls)"
chown -R "${SUDO_UID:-1000}" "$W"
[ "$bad" -eq 0 ]
