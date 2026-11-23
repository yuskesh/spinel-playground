#!/bin/sh
# tests/ebpf-go/live.sh -- xdp-counter, the single Go binary, on this kernel.
#
# Its documented job: attach the XDP program, count packets in an ARRAY map
# (counts[0]), and stream a tick per packet through a ring buffer, then close
# everything. This attaches it to lo for 3 s, sends 10 pings to 127.0.0.1 (XDP
# on lo sees each echo and each reply), and checks the counter it prints, the
# ticks it read from the ring buffer, and that no program or XDP attachment
# remains.
#
# PRIVILEGE, as tests/ebpf/live.sh: the binary gets cap_bpf,cap_net_admin by
# `$SUDO setcap` in EBPF_CAP_DIR (a directory on a filesystem without nosuid)
# and runs as the user; `$SUDO bpftool` only reads. spinel-llvm's own kernel
# script ran as root inside a network namespace; lo needs neither.
#
#   GO=... EBPF_CAP_DIR=... sh tests/ebpf-go/live.sh   (after tests/ebpf-go/run.sh)
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
: "${GO:?set GO to the go binary (docs/toolchains/go-1.25.14)}"
: "${EBPF_CAP_DIR:?set EBPF_CAP_DIR to a directory you own on a filesystem without nosuid}"
export GOTOOLCHAIN=local
SUDO=${SUDO:-sudo}; BPFTOOL=${BPFTOOL:-bpftool}
C=$EBPF_CAP_DIR; W=${EBPF_GO_WORK:-${TMPDIR:-/tmp}/spinel-ebpf-go}
mkdir -p "$C" "$W"; : > "$W/privileged.log"
case "$(findmnt -n -o OPTIONS -T "$C" 2>/dev/null)" in
  *nosuid*) echo "ebpf-go live: $C is on a nosuid mount; file capabilities would be ignored" >&2; exit 2 ;;
esac
priv() { echo "priv: $*" >> "$W/privileged.log"; "$@"; }
X=$REPO/examples/ebpf-go/xdp-counter
[ -f "$X/xdp_counter.bpf.o" ] || { echo "ebpf-go live: run tests/ebpf-go/run.sh first (it generates the ELF)" >&2; exit 2; }
pass=0; fail=0; t0=$(date +%s)
row() { if [ "$2" = 0 ]; then pass=$((pass + 1)); v=PASS; else fail=$((fail + 1)); v=FAIL; fi; printf '%s\t%s\t%s\n' "$1" "$v" "$3"; }

(cd "$X" && "$GO" build -o "$C/xdp-counter" .) || { echo "ebpf-go live: build failed" >&2; exit 1; }
priv $SUDO setcap cap_bpf,cap_net_admin+ep "$C/xdp-counter"
setsid "$C/xdp-counter" -iface lo -duration 3s > "$W/xdp-counter.out" 2>&1 & p=$!
sleep 1
ping -c 10 -i 0.1 -W 1 127.0.0.1 > /dev/null 2>&1
wait "$p"; rc=$?
counter=$(sed -n 's/^counter=\([0-9]*\)$/\1/p' "$W/xdp-counter.out" | tail -1)
ticks=$(grep -c '^tick count=' "$W/xdp-counter.out")
left=$(priv $SUDO "$BPFTOOL" prog show 2>/dev/null | grep -c 'name count_packets')
onlo=$(priv $SUDO "$BPFTOOL" net show dev lo 2>/dev/null | sed -n '/^xdp:/,/^tc:/p' | grep -c 'id ')
[ "$rc" = 0 ]; row exits_cleanly $? "rc $rc"
[ "${counter:-0}" -ge 20 ]; row counts_packets $? "counter=${counter:-none} for 10 pings (20 packets on lo)"
[ "$ticks" -gt 0 ]; row reads_ring_buffer $? "$ticks tick records"
[ "$left" = 0 ] && [ "$onlo" = 0 ]; row nothing_left $? "programs left $left, XDP on lo $onlo"
rm -f "$C/xdp-counter"
echo "privileged commands run:"; sort "$W/privileged.log" | uniq -c
echo "ebpf-go live: $pass pass, $fail fail [$(( $(date +%s) - t0 )) s]"
[ "$fail" = 0 ]
