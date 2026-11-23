#!/bin/bash
# E153: 単一 Go バイナリを **実 kernel** に載せ、packet を流して counter と
# ring buffer の record を確かめる (P013 Task 6)。
#
# veth + netns を使うので、外の network に触らない。
# 権限: XDP の attach は CAP_BPF + CAP_NET_ADMIN で足りる (kernel_env.md の実測)
# が、netns の出入りに CAP_SYS_ADMIN が要るのでここでは root で回す。
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin"

BIN="${BIN:?xdp-counter のパスを渡すこと}"
NS=e153xdp
HOST_IF=e153h
PEER_IF=e153p
SECS="${SECS:-3}"

cleanup() {
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$HOST_IF" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

ip netns add "$NS"
ip link add "$HOST_IF" type veth peer name "$PEER_IF"
ip link set "$PEER_IF" netns "$NS"
ip addr add 10.153.1.1/24 dev "$HOST_IF"
ip link set "$HOST_IF" up
ip -n "$NS" addr add 10.153.1.2/24 dev "$PEER_IF"
ip -n "$NS" link set "$PEER_IF" up

echo "== 単一バイナリを netns 内で起動 (外部 .bpf.o を持たない) =="
ip netns exec "$NS" "$BIN" -iface "$PEER_IF" -duration "${SECS}s" > /tmp/e153_out.txt 2>&1 &
RUN=$!
sleep 1

echo "== 外から packet を流す =="
ping -c 10 -i 0.1 -W 1 10.153.1.2 >/dev/null 2>&1 || true
wait $RUN || true

echo "== 出力 =="
cat /tmp/e153_out.txt

echo "== 検査 =="
counter=$(grep -o 'counter=[0-9]*' /tmp/e153_out.txt | tail -1 | cut -d= -f2)
ticks=$(grep -c '^tick count=' /tmp/e153_out.txt || true)
[ "${counter:-0}" -gt 0 ] || { echo "!! counter が増えていない"; exit 1; }
[ "$ticks" -gt 0 ] || { echo "!! ring buffer から record が来ていない"; exit 1; }
echo "counter=$counter ticks=$ticks -> OK"

echo "== 終了後に resource が残っていないこと =="
left_prog=$(bpftool prog show 2>/dev/null | grep -c 'name count_packets' || true)
[ "$left_prog" = "0" ] || { echo "!! program が残っている"; bpftool prog show | grep count_packets; exit 1; }
echo "残存 program 0 -> OK"
