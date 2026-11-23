# scripts/lib/hostnet.sh — host の runner (scripts/run-*-host.sh) の veth と netns の準備 (P008 E031 — go-bpf-mlir E095 の scripts/lib/hostnet.sh の写し)。source して使う:
#
#   . "$(dirname "$0")/lib/hostnet.sh"
#   hostnet_setup <tag>      # tag は 1〜4 文字の英小文字と数字 (runner ごと — 例 "xc")
#   … "$NS" "$HOST_IF" "$PEER_IF" "$HOST_IP" "$PEER_IP" "$PEER_MAC" "$WORK" を使う …
#
# 同じ host で複数の agent・repo が veth の試験を同時に走らせても重ならないように:
#   - netns と interface の名前に pid を入れる (NS=sbpf-<tag>-<pid>、HOST_IF=s<tag><pid>h / PEER_IF=s<tag><pid>p — 15 文字以内)
#   - subnet は pid から決めた 10.<X>.<Y>.0/24 (X = 64 + (pid / 256) % 64、Y = pid % 256 — go / mojo と同じ式、同時に走る pid は別なので別の subnet)。使う前に host の IPv4 の address と route
#     (default を除く、全ての table・全ての種類 — blackhole / unreachable も) の全てと重ならないことを確かめ、重なれば相手の行を名指しして止める (黙って別の subnet に逃げない)
#   - 同じ名前の netns / interface が在れば止める (触らない)
# 失敗 (非 0 の終わり) の時は link の状態・address・neighbor・route を log に残してから片付ける。
# 両端の IPv6 は止め、両端に相手の MAC の静的な neighbor (ARP の要求は出ない — peer に来る packet を送ったものだけにする)。
# 送り手は bash の /dev/udp と ping (固定の送り手の port を使わない — go の E095 の「送り手を host の address に bind」は該当しない)。

hostnet_ip2int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# hostnet_overlaps <cidr> — 自分の /24 と重なれば 0。
hostnet_overlaps() {
  local net=${1%/*} len=${1#*/}
  [ "$net" = "$1" ] && len=32
  local n m mine
  n=$(hostnet_ip2int "$net")
  mine=$(hostnet_ip2int "$HOSTNET_NET")
  # 2 つの prefix は、短い方の mask で両方の network が一致すれば重なる。
  local short=$(( len < 24 ? len : 24 ))
  if [ "$short" = 0 ]; then m=0; else m=$(( (0xffffffff << (32 - short)) & 0xffffffff )); fi
  [ $(( n & m )) = $(( mine & m )) ]
}

hostnet_check_free() {
  local line cidr
  while read -r line; do
    cidr=${line%% *}
    case "$cidr" in default | "") continue ;; esac
    if hostnet_overlaps "$cidr"; then
      echo "!! subnet $HOSTNET_NET/24 (from pid $$) overlaps an existing route: $line — not using it" >&2
      return 1
    fi
  done < <(ip -4 route show table all 2>/dev/null | sed -E "s/^(unicast|local|broadcast|blackhole|unreachable|prohibit|throw|anycast|multicast|nat) //")
  while read -r line; do
    cidr=$(echo "$line" | awk '{for (i = 1; i <= NF; i++) if ($i == "inet") print $(i + 1)}')
    [ -n "$cidr" ] || continue
    if hostnet_overlaps "$cidr"; then
      echo "!! subnet $HOSTNET_NET/24 (from pid $$) overlaps an existing address: $line — not using it" >&2
      return 1
    fi
  done < <(ip -o -4 addr show 2>/dev/null)
}

hostnet_diag() {
  echo "== hostnet diagnostics (failure — E031)"
  echo "-- host: ip -d link show $HOST_IF"; ip -d link show "$HOST_IF" 2>&1 || true
  echo "-- peer: ip -n $NS -d link show $PEER_IF"; ip -n "$NS" -d link show "$PEER_IF" 2>&1 || true
  echo "-- host addresses"; ip -4 addr show dev "$HOST_IF" 2>&1 || true
  echo "-- peer addresses"; ip -n "$NS" -4 addr show 2>&1 || true
  echo "-- host neighbors"; ip neigh show dev "$HOST_IF" 2>&1 || true
  echo "-- host route to the peer"; ip -4 route get "$PEER_IP" 2>&1 || true
  if [ -s "$WORK/cap.txt" ]; then echo "-- capture summary"; grep -E '^(ingress|egress) total=' "$WORK/cap.txt" || tail -5 "$WORK/cap.txt"; fi
}

hostnet_cleanup() {
  local rc=$?
  if [ "$rc" != 0 ] && [ -n "${HOSTNET_CREATED_NS:-}" ]; then hostnet_diag; fi
  [ -n "${HOSTNET_CREATED_NS:-}" ] && ip netns del "$HOSTNET_CREATED_NS" 2>/dev/null || true
  [ -n "${HOSTNET_CREATED_IF:-}" ] && ip link del "$HOSTNET_CREATED_IF" 2>/dev/null || true
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return "$rc"
}

hostnet_setup() {
  local tag=$1
  [[ "$tag" =~ ^[a-z0-9]{1,4}$ ]] || { echo "!! hostnet: tag must be 1-4 of [a-z0-9]" >&2; exit 2; }
  export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin"
  NS="sbpf-$tag-$$"
  HOST_IF="s$tag$$h"
  PEER_IF="s$tag$$p"
  HOSTNET_NET="10.$(( 64 + ($$ / 256) % 64 )).$(( $$ % 256 )).0"
  HOST_IP="${HOSTNET_NET%.0}.1"
  PEER_IP="${HOSTNET_NET%.0}.2"
  if ip netns list | awk '{print $1}' | grep -qx "$NS"; then echo "!! netns $NS already exists — not touching it" >&2; exit 2; fi
  for i in "$HOST_IF" "$PEER_IF"; do
    if ip link show "$i" >/dev/null 2>&1; then echo "!! interface $i already exists — not touching it" >&2; exit 2; fi
  done
  hostnet_check_free || exit 2
  HOSTNET_CREATED_NS=""; HOSTNET_CREATED_IF=""
  WORK=$(mktemp -d)
  trap hostnet_cleanup EXIT
  ip netns add "$NS"; HOSTNET_CREATED_NS="$NS"
  ip link add "$HOST_IF" type veth peer name "$PEER_IF"; HOSTNET_CREATED_IF="$HOST_IF"
  ip link set "$PEER_IF" netns "$NS"
  sysctl -qw "net.ipv6.conf.$HOST_IF.disable_ipv6=1"
  ip netns exec "$NS" sysctl -qw "net.ipv6.conf.$PEER_IF.disable_ipv6=1"
  ip addr add "$HOST_IP/24" dev "$HOST_IF"
  ip -n "$NS" addr add "$PEER_IP/24" dev "$PEER_IF"
  PEER_MAC=$(ip -n "$NS" -o link show "$PEER_IF" | grep -o 'link/ether [0-9a-f:]*' | cut -d' ' -f2)
  ip link set "$HOST_IF" up
  ip -n "$NS" link set "$PEER_IF" up
  HOST_MAC=$(ip -o link show "$HOST_IF" | grep -o 'link/ether [0-9a-f:]*' | cut -d' ' -f2)
  ip neigh replace "$PEER_IP" lladdr "$PEER_MAC" dev "$HOST_IF" nud permanent
  ip -n "$NS" neigh replace "$HOST_IP" lladdr "$HOST_MAC" dev "$PEER_IF" nud permanent
  echo "== hostnet: netns $NS  host $HOST_IF $HOST_IP  peer $PEER_IF $PEER_IP ($PEER_MAC)"
  sleep 1 # link が上がるまで (この間の packet は attach の前なので数えない)
}
