#!/bin/sh
# tests/ebpf/live.sh -- the HTTP server and its eBPF programs, live on this kernel.
#
# Each check builds a program with tools/ebpf/bin/spinel-ebpf, grants it the file
# capabilities it needs, runs it, and checks the program's documented job:
#
#   m002        the server answers; the L7 per-path counter (a BPF HASH map fed
#               through transparent dispatch) holds exactly the requests made
#   m003        4 SO_REUSEPORT workers answer; the sk_reuseport program is loaded
#               and its SOCKARRAY holds the 4 worker sockets
#   tcp_slice   with nothing listening on :8080, GET /health is answered by the
#               XDP program alone (M004's kernel-side static response)
#   ruby_slice  the same TCP slice written as a plain Ruby xdp__ method (/hello)
#   enforcer    XDP early reject: ICMP is dropped at XDP while TCP passes, and
#               the drop class counts exactly the pings sent
#
# PRIVILEGE, the least that works. The programs get file capabilities
# (cap_bpf,cap_net_admin,cap_perfmon) through `$SUDO setcap`; they are then
# run as the invoking user. Reading a map needs the same capabilities, so the
# checks read them with `$SUDO bpftool` (read-only). Every privileged command
# is logged and printed at the end. Nothing else runs as root.
#
# File capabilities are ignored on a nosuid mount, which /tmp usually is, so the
# capability binaries go to EBPF_CAP_DIR, a directory the caller owns on a
# filesystem mounted without nosuid.
#
#   EBPF_CAP_DIR=/path/on/a/suid/fs NANOPB_DIR=... sh tests/ebpf/live.sh
#
# Port 8080 must be free, and the XDP programs attach to lo for a few seconds.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E=$(cd "$HERE/../../tools/ebpf" && pwd)
: "${EBPF_CAP_DIR:?set EBPF_CAP_DIR to a directory you own on a filesystem without nosuid}"
: "${NANOPB_DIR:?set NANOPB_DIR to nanopb-0.4.9.1 (docs/toolchains/spinel-ebpf-deps)}"
export NANOPB_DIR LANG=C.UTF-8
SUDO=${SUDO:-sudo}
BPFTOOL=${BPFTOOL:-bpftool}
W=${EBPF_WORK:-${TMPDIR:-/tmp}/spinel-ebpf}/live
C=$EBPF_CAP_DIR
mkdir -p "$W" "$C"
: > "$W/privileged.log"
case "$(findmnt -n -o OPTIONS -T "$C" 2>/dev/null)" in
  *nosuid*) echo "live: $C is on a nosuid mount; file capabilities would be ignored" >&2; exit 2 ;;
esac
if ss -ltn | grep -q ':8080 '; then echo "live: port 8080 is in use" >&2; exit 2; fi

pass=0; fail=0; t_all=$(date +%s)
row() { # name ok detail
  if [ "$2" = 0 ]; then pass=$((pass + 1)); v=PASS; else fail=$((fail + 1)); v=FAIL; fi
  printf '%s\t%s\t%s\n' "$1" "$v" "$3"
}
# Every privileged command is logged to $W/privileged.log and printed at the end.
priv() { echo "priv: $*" >> "$W/privileged.log"; "$@"; }
build() { # name source [flags]
  n=$1; src=$2; shift 2
  rm -rf "$W/$n"
  (cd "$E" && ruby -Isrc bin/spinel-ebpf compile "$src" -o "$W/$n" --build "$@") > "$W/$n.build.log" 2>&1 || return 1
  b=$(ls "$W/$n"/* 2>/dev/null | while read -r f; do [ -x "$f" ] && [ ! -d "$f" ] && echo "$f"; done | head -1)
  [ -n "$b" ] || return 1
  cp "$b" "$C/$n" && priv $SUDO setcap cap_bpf,cap_net_admin,cap_perfmon+ep "$C/$n"
}
code() { curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080$1"; }
wait_port() { i=0; while [ $i -lt 50 ] && ! ss -ltn | grep -q ':8080 '; do sleep 0.1; i=$((i + 1)); done; }
# Servers start under setsid, so a server and the workers it forks are one
# process group, and stopping the group stops them all.
start() { setsid "$@" & p=$!; }
stop() { kill -- "-$1" 2>/dev/null; wait "$1" 2>/dev/null; i=0; while [ $i -lt 30 ] && kill -0 -- "-$1" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done; }
lo_xdp() { priv $SUDO "$BPFTOOL" net show dev lo 2>/dev/null | sed -n '/^xdp:/,/^tc:/p' | grep -c 'id '; }
# The plain dump, which bpftool formats from the map's BTF as JSON (-j gives raw bytes).
mapj() { priv $SUDO "$BPFTOOL" map dump name "$1" 2>/dev/null; }

# ---- m002: the server, and the L7 counter --------------------------------------
if build m002 examples/http_server/M002/server.rb --ebpf-dispatch; then
  start "$C/m002" > "$W/m002.out" 2>&1; wait_port
  got="$(code /)$(code /)$(code /health)$(code /x)"
  counts=$(mapj bpf_path_counts | ruby -rjson -e 'puts JSON.parse($stdin.read).map { |e| [e["key"], e["value"]] }.sort.map { |k, v| "#{k}=#{v}" }.join(",")')
  stop $p
  [ "$got" = 200200200404 ]; row m002_answers $? "codes $got"
  [ "$counts" = "1=2,2=1,3=1" ]; row m002_l7_counter $? "bpf_path_counts $counts (/ twice, /health once, other once)"
else row m002_build 1 "$W/m002.build.log"; fi

# ---- m003: SO_REUSEPORT workers and the sk_reuseport program --------------------
if build m003 examples/http_server/M003/server.rb --ebpf-dispatch; then
  SPINEL_HTTP_WORKERS=4 start "$C/m003" > "$W/m003.out" 2>&1; wait_port; sleep 0.5
  ok=0; i=0; while [ $i -lt 40 ]; do [ "$(code /)" = 200 ] && ok=$((ok + 1)); i=$((i + 1)); done
  listeners=$(ss -ltn | grep -c ':8080 ')
  prog=$(priv $SUDO "$BPFTOOL" -j prog show 2>/dev/null | ruby -rjson -e 'puts JSON.parse($stdin.read).count { |p| p["type"] == "sk_reuseport" && p["name"] == "sk_reuseport__select" }')
  # The SOCKARRAY of THIS run: several maps may share the name, so the id is the
  # one whose owning pids include the server; empty slots print as <no entry>.
  mid=$(priv $SUDO "$BPFTOOL" -j map show 2>/dev/null | ruby -rjson -e 'pid = ARGV[0].to_i; m = JSON.parse($stdin.read).find { |x| x["name"] == "bpf_worker_sock" && (x["pids"] || []).any? { |q| q["pid"] == pid } }; puts m ? m["id"] : ""' "$p")
  socks=0
  [ -n "$mid" ] && socks=$(priv $SUDO "$BPFTOOL" map dump id "$mid" 2>/dev/null | grep -c '"value": [0-9]')
  stop $p
  [ "$ok" = 40 ] && [ "$listeners" = 4 ]; row m003_workers_answer $? "$ok of 40 answered, $listeners listeners"
  [ "$prog" = 1 ]; row m003_reuseport_prog_loaded $? "sk_reuseport__select loaded: $prog"
  [ "$socks" = 4 ]; row m003_sockarray $? "bpf_worker_socks holds $socks sockets"
else row m003_build 1 "$W/m003.build.log"; fi
sleep 0.5

# ---- M004's kernel-side response: the two TCP slices ---------------------------
slice() { # name source path want-body
  if build "$1" "$2"; then
    SPNL_XDP_IFACE=lo start "$C/$1" > "$W/$1.out" 2>&1; sleep 1.5
    listeners=$(ss -ltn | grep -c ':8080 ')
    body=$(curl -s -m 3 "http://127.0.0.1:8080$3")
    stop $p; sleep 0.3
    after=$(lo_xdp)
    [ "$listeners" = 0 ] && [ "$body" = "$4" ]; row "$1_xdp_response" $? "no listener; GET $3 -> '$body'"
    [ "$after" = 0 ]; row "$1_detached" $? "XDP programs on lo after exit: $after"
  else row "$1_build" 1 "$W/$1.build.log"; fi
}
slice tcp_slice examples/http_server/M004/tcp_slice.rb /health OK
slice ruby_slice examples/http_server/M004/ruby_slice.rb /hello hello

# ---- XDP early reject ------------------------------------------------------------
if build enforcer examples/observability/otlp/access_enforcer.rb && [ -x "$C/m002" ]; then
  start "$C/m002" > "$W/m002e.out" 2>&1; ps=$p; wait_port
  SPNL_XDP_IFACE=lo OTLP_ENDPOINT=http://127.0.0.1:4318 PROBE_SECONDS=6 start "$C/enforcer" > "$W/enforcer.out" 2>&1; pe=$p; sleep 1.5
  loss=$(ping -c 3 -W 1 -i 0.3 127.0.0.1 2>/dev/null | sed -n 's/.* \([0-9]*\)% packet loss.*/\1/p')
  tcp=$(code /)
  icmp=$(mapj bpf_hist_keyed | ruby -rjson -e 'e = JSON.parse($stdin.read).find { |x| x["key"] == 1 }; puts e ? e["value"]["buckets"].sum : 0')
  stop $pe; stop $ps; sleep 0.3
  after_loss=$(ping -c 1 -W 1 127.0.0.1 2>/dev/null | sed -n 's/.* \([0-9]*\)% packet loss.*/\1/p')
  [ "$loss" = 100 ] && [ "$tcp" = 200 ]; row enforcer_drops_icmp_passes_tcp $? "ping loss $loss%, TCP $tcp"
  [ "$icmp" = 3 ]; row enforcer_drop_count $? "ICMP class counted $icmp of 3"
  [ "$after_loss" = 0 ] && [ "$(lo_xdp)" = 0 ]; row enforcer_detached $? "ping after exit: loss $after_loss%"
else row enforcer_build 1 "$W/enforcer.build.log"; fi

echo "privileged commands run:"; sort "$W/privileged.log" | uniq -c
echo "live: $pass pass, $fail fail [$(( $(date +%s) - t_all )) s]"
[ "$fail" = 0 ]
