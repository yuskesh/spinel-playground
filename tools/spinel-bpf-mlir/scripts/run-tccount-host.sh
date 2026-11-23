#!/bin/bash
# scripts/run-tccount-host.sh — P019 E079: examples/tccount の 1 つの実行 file (spinelbpf build -o) を host の kernel で veth の peer に attach し
# (XDP・tcx の ingress・tcx の egress)、host から peer へ UDP (閉じた port — peer は ICMP port unreachable を返す) を N 個と ping を M 個送り、両向きの数を確かめる
# (run-protostat-host.sh の形)。
#
#   sudo BIN=<tccount の path> [N=20] [M=5] scripts/run-tccount-host.sh
#
# 期待 (peer の側): XDP と tcx の ingress は UDP N・echo request M・他 0、tcx の egress は unreachable N・echo reply M・他 0。
# 両端の IPv6 を止め、静的な neighbor で ARP は無い (hostnet)。peer の netns の net.ipv4.icmp_ratelimit を 0 に (netns の sysctl — unreachable を絞らず N 個)。
set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/guest-only.sh"; vm_guest_require # E165: root の段は VM の guest だけ
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin:/usr/local/sbin"

BIN="${BIN:?pass the path of tccount}"
N="${N:-20}"
M="${M:-5}"
. "$(dirname "$0")/lib/hostnet.sh"
hostnet_setup tc

echo "== uname: $(uname -r)"
echo "== binary: $(sha256sum "$BIN" | cut -d' ' -f1) ($(stat -c %s "$BIN") bytes)"
ip netns exec "$NS" sysctl -q -w net.ipv4.icmp_ratelimit=0
ip netns exec "$NS" "$BIN" --iface "$PEER_IF" --duration-ms 4000 > "$WORK/out.txt" 2>&1 &
RUN=$!
for _ in $(seq 50); do grep -q '^attached ' "$WORK/out.txt" 2>/dev/null && break; sleep 0.1; done
grep -q '^attached ' "$WORK/out.txt" || { echo "!! not attached"; wait $RUN || true; cat "$WORK/out.txt"; exit 1; }

# attach した 3 つの program の id (終了の後に残っていないことを名前でなく id で見る — 同じ名前の program を load する並行の試験と衝突しない)
IDS=$(ip netns exec "$NS" bpftool net show dev "$PEER_IF" 2>/dev/null | grep -oE '(prog_id|driver id|generic id) [0-9]+' | awk '{print $NF}' | sort -u | tr '\n' ' ')
echo "== attached program ids: $IDS"
[ "$(echo $IDS | wc -w)" = 3 ] || { echo "!! want 3 program ids on $PEER_IF"; ip netns exec "$NS" bpftool net show dev "$PEER_IF" || true; wait $RUN || true; exit 1; }

echo "== send $N UDP packets to $PEER_IP:9999 (closed) and $M pings"
for _ in $(seq "$N"); do echo -n x > /dev/udp/$PEER_IP/9999; done
ping -c "$M" -i 0.2 -W 1 $PEER_IP > "$WORK/ping.txt" 2>&1 || { echo "!! ping failed"; cat "$WORK/ping.txt"; }

rc=0; wait $RUN || rc=$?
echo "== tccount output (rc=$rc)"
cat "$WORK/out.txt"
[ "$rc" = 0 ] || { echo "!! tccount exited with $rc"; exit 1; }

grep -q "^attached tcc_xdp tcc_in=ingress tcc_out=egress to $PEER_IF\$" "$WORK/out.txt" || { echo "!! the tcx directions differ from the declarations"; exit 1; }
got=$(grep -E '^count ' "$WORK/out.txt")
want="count xdp udp=$N echo_request=$M echo_reply=0 unreachable=0 other=0
count tc_ingress udp=$N echo_request=$M echo_reply=0 unreachable=0 other=0
count tc_egress udp=0 echo_request=0 echo_reply=$M unreachable=$N other=0"
echo "== check: want"; echo "$want"
echo "==        got"; echo "$got"
[ "$got" = "$want" ] || { echo "!! mismatch"; exit 1; }

echo "== no program left after exit"
for id in $IDS; do
  if bpftool prog show id "$id" >/dev/null 2>&1; then echo "!! program $id left"; exit 1; fi
done
echo "RESULT ok"
