#!/bin/bash
# E153: ring buffer だけを見る (P013 Task 6)。
# packet を n 発流し、**型付き record が n 件、count が単調増加で届く**ことを確かめる。
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin"

BIN="${BIN:?xdp-counter のパスを渡すこと}"
NS=e153rb
HOST_IF=e153rh
PEER_IF=e153rp
N="${N:-8}"

cleanup() {
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$HOST_IF" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

ip netns add "$NS"
ip link add "$HOST_IF" type veth peer name "$PEER_IF"
ip link set "$PEER_IF" netns "$NS"
ip addr add 10.153.2.1/24 dev "$HOST_IF"
ip link set "$HOST_IF" up
ip -n "$NS" addr add 10.153.2.2/24 dev "$PEER_IF"
ip -n "$NS" link set "$PEER_IF" up

out=/tmp/e153_rb.txt
ip netns exec "$NS" "$BIN" -iface "$PEER_IF" -duration 3s > "$out" 2>&1 &
RUN=$!
sleep 1
ping -c "$N" -i 0.1 -W 1 10.153.2.2 >/dev/null 2>&1 || true
wait $RUN || true

echo "== ring buffer から来た record =="
grep '^tick count=' "$out" || true

counts=$(grep -o '^tick count=[0-9]*' "$out" | cut -d= -f2)
n=$(printf '%s\n' "$counts" | grep -c . || true)
[ "$n" -ge "$N" ] || { echo "!! record が $n 件しか来ていない (>= $N 要る)"; exit 1; }

# **単調増加であること** — counter の値がそのまま record に載っている証明。
prev=0
for c in $counts; do
  [ "$c" -gt "$prev" ] || { echo "!! count が単調増加でない: $prev -> $c"; exit 1; }
  prev=$c
done
echo "record $n 件、count は 1..$prev で単調増加 -> OK"
