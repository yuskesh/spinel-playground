#!/bin/bash
# scripts/run-xdpcount-host.sh — P001 E004: examples/xdpcount の 1 つの実行 file (spinelbpf build -o) を host の kernel で veth に attach し、
# 既知の数 (M) の UDP の packet を送って counts を確かめる (mojo-bpf-mlir・go-bpf-mlir の scripts/run-xdpcount-host.sh の形)。
#
#   sudo BIN=<xdpcount の path> [M=20] scripts/run-xdpcount-host.sh
#
# 期待 (P001 のレビューの P2): counts[0] == M、0 < counts[1] ≤ counts[0]
#   (counts[1] は slot 0 の読みの写しで atomic でない — 多 CPU の並行では等号が保証されない)。
# 数を合わせるため、peer の側 (XDP を attach する側) に来る packet を送った UDP だけにする: 両端の IPv6 を止め (router solicitation・MLD)、
# 両端に相手の MAC の静的な neighbor を置く (ARP が要らない)。同じ名前の netns / interface が既に在れば何も触らずに止まる。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin"

BIN="${BIN:?pass the path of xdpcount}"
M="${M:-20}"
# veth と netns は scripts/lib/hostnet.sh (P008 E031 — pid の名前と subnet・host の route / address との重なりの検査・失敗の時の log)
. "$(dirname "$0")/lib/hostnet.sh"
hostnet_setup xc

echo "== uname: $(uname -r)"
echo "== binary: $(sha256sum "$BIN" | cut -d' ' -f1) ($(stat -c %s "$BIN") bytes)"
ip netns exec "$NS" "$BIN" --iface "$PEER_IF" --duration-ms 3000 > "$WORK/out.txt" 2>&1 &
RUN=$!
for _ in $(seq 50); do grep -q '^attached ' "$WORK/out.txt" 2>/dev/null && break; sleep 0.1; done
grep -q '^attached ' "$WORK/out.txt" || { echo "!! not attached"; wait $RUN || true; cat "$WORK/out.txt"; exit 1; }

# attach した program の id (終了の後に「この program が残っていない」を名前でなく id で見る — 名前は同じ program を load する並行の試験と衝突する)
PROG_ID=$(ip -n "$NS" -d link show "$PEER_IF" | grep -o "prog/xdp id [0-9]*" | awk "{print \$3}")
[ -n "$PROG_ID" ] || { echo "!! no XDP program id on $PEER_IF"; wait $RUN || true; exit 1; }
echo "== attached program id $PROG_ID"
echo "== bpftool (attached programs and maps — the kernel truncates names to 15 bytes)"
bpftool prog show 2>/dev/null | grep -E "xdp +name" | grep -E 'count_pkts' || echo "(program not listed)"
bpftool map show 2>/dev/null | grep -E 'name Counts' || echo "(map not listed)"

echo "== send $M UDP packets to $PEER_IP:9"
for _ in $(seq "$M"); do echo -n x > /dev/udp/$PEER_IP/9; done

rc=0; wait $RUN || rc=$?
echo "== xdpcount output (rc=$rc)"
cat "$WORK/out.txt"
[ "$rc" = 0 ] || { echo "!! xdpcount exited with $rc"; exit 1; }

last=$(grep -E '^counts\[0\]=' "$WORK/out.txt" | tail -1)
c0=$(echo "$last" | sed -E 's/.*counts\[0\]=([0-9]+).*/\1/')
c1=$(echo "$last" | sed -E 's/.*counts\[1\]=([0-9]+).*/\1/')
echo "== check: want counts[0]=$M and 0 < counts[1] <= counts[0], got counts[0]=$c0 counts[1]=$c1"
[ "$c0" = "$((M + ${WANT_SHIFT:-0}))" ] && [ "$c1" -gt 0 ] && [ "$c1" -le "$c0" ] || { echo "!! mismatch"; exit 1; }

echo "== no program left after exit"
if bpftool prog show id "$PROG_ID" >/dev/null 2>&1; then echo "!! program $PROG_ID left"; exit 1; fi
echo "RESULT ok"
