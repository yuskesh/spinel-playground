#!/bin/bash
# scripts/run-flowcount-host.sh — P008 E036: examples/flowcount の 1 つの実行 file (spinelbpf build -o) を host の kernel で veth に attach し、
# 既知の数の UDP (dst port 9999 を N 個) と ping (M 個) を送って数を確かめる (run-xdpcount-host.sh の形)。
#
#   sudo BIN=<flowcount の path> [N=20] [M=5] scripts/run-flowcount-host.sh
#
# 期待: flow はちょうど 2 つ — proto 17 port 9999 (frames N・bytes 29 × N — 1 byte の UDP の IPv4) と proto 1 port 0 (frames M・bytes 84 × M — ping)、宛先は peer、errs 0。
# peer の側 (XDP を attach する側) に来る packet を送ったものだけにする: 両端の IPv6 を止め、両端に相手の MAC の静的な neighbor を置く (ARP が要らない)。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin"

BIN="${BIN:?pass the path of flowcount}"
N="${N:-20}"
M="${M:-5}"
# veth と netns は scripts/lib/hostnet.sh (P008 E031 — pid の名前と subnet・host の route / address との重なりの検査・失敗の時の log)
. "$(dirname "$0")/lib/hostnet.sh"
hostnet_setup fc

echo "== uname: $(uname -r)"
echo "== binary: $(sha256sum "$BIN" | cut -d' ' -f1) ($(stat -c %s "$BIN") bytes)"
ip netns exec "$NS" "$BIN" --iface "$PEER_IF" --duration-ms 4000 > "$WORK/out.txt" 2>&1 &
RUN=$!
for _ in $(seq 50); do grep -q '^attached ' "$WORK/out.txt" 2>/dev/null && break; sleep 0.1; done
grep -q '^attached ' "$WORK/out.txt" || { echo "!! not attached"; wait $RUN || true; cat "$WORK/out.txt"; exit 1; }

# attach した program の id (終了の後に「この program が残っていない」を名前でなく id で見る — 名前は同じ program を load する並行の試験と衝突する)
PROG_ID=$(ip -n "$NS" -d link show "$PEER_IF" | grep -o "prog/xdp id [0-9]*" | awk "{print \$3}")
[ -n "$PROG_ID" ] || { echo "!! no XDP program id on $PEER_IF"; wait $RUN || true; exit 1; }
echo "== attached program id $PROG_ID"
bpftool prog show 2>/dev/null | grep -E "xdp +name" | grep -E 'flowcount' || echo "(program not listed)"

echo "== send $N UDP packets to $PEER_IP:9999 and $M pings"
for _ in $(seq "$N"); do echo -n x > /dev/udp/$PEER_IP/9999; done
ping -c "$M" -i 0.2 -W 1 $PEER_IP > "$WORK/ping.txt" 2>&1 || { echo "!! ping failed"; cat "$WORK/ping.txt"; }

rc=0; wait $RUN || rc=$?
echo "== flowcount output (rc=$rc)"
cat "$WORK/out.txt"
[ "$rc" = 0 ] || { echo "!! flowcount exited with $rc"; exit 1; }

IFS=. read -r o1 o2 o3 o4 <<< "$PEER_IP"
ADDR=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
got=$(grep -E '^flows?[ =]' "$WORK/out.txt")
want="flow proto=1 port=0 addr=$ADDR frames=$M bytes=$((84 * M))
flow proto=17 port=9999 addr=$ADDR frames=$((N + ${WANT_SHIFT:-0})) bytes=$((29 * N))
flows=2 errs=0"
echo "== check: want"; echo "$want"
echo "==        got"; echo "$got"
[ "$got" = "$want" ] || { echo "!! mismatch"; exit 1; }

echo "== no program left after exit"
if bpftool prog show id "$PROG_ID" >/dev/null 2>&1; then echo "!! program $PROG_ID left"; exit 1; fi
echo "RESULT ok"
