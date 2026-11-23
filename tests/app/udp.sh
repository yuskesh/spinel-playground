#!/bin/sh
# tests/app/udp.sh -- the udp: channel transport (decision 0014 §5, decisions
# 0024 and 0025): its declaration, the network file, the transport on the
# host, and the inbound OCRAM ring's get on the host.
#
#   sh tests/app/udp.sh
#
# What is checked, and against what:
#
#   1. Declarations. An :out and an :in channel with `udp: true` are read
#      (decision 0025); an endpoint written in the source, a message above
#      one datagram (1472 bytes) either way, a channel with both transports
#      and an `mqtt:` one are each refused, naming why.
#   2. The network file (tools/app/lib/core_app/net.rb). A complete file
#      becomes spc_net.h beside transport_udp.c; a file missing a key, with a
#      key twice, without a line for a udp: channel, with a line for a UART
#      channel, or with an address or a port that is not one is refused,
#      naming the line. With an :in channel (fixtures/udp/app-in.rb), its
#      `inbound NAME PORT from ADDRESS` line is read; a file without it, an
#      inbound line for an :out channel or a channel line for an :in one, a
#      line without `from`, given twice, or with a bad port or address is
#      refused, naming the line.
#   3. The transport on the host (fixtures/udp/udp_harness.c), every unit
#      compiled with -Wall -Wextra -Werror: one datagram per message, payload
#      verbatim and in order, through the loopback; a channel at port 0
#      discarded and counted; planted send failures -- no buffer three times
#      (the message is kept and leaves first), then a permanent one (counted,
#      dropped) -- and conservation, put == received + errors. The kept
#      failing input: a copy of the generated transport that drops a message
#      it had no buffer for fails the same harness.
#   3b. The inbound ring's get (fixtures/udp/ring_in_harness.c), generated as
#      the build generates it for a board whose udp_consumer is ocram-ring-v1
#      and run against the harness's own region: the boot check, empty,
#      order, the counts' wrap, depth, and the faults of a bad length. The
#      geometry headers say the inbound slots follow the outbound ones after
#      the 512-byte header (ring ABI version 5). The kept failing input: a copy of the get that
#      does not advance its tail fails the harness.
#   4. The build's refusals before any compile: a udp: channel without --net,
#      and on a board whose table names no network configuration; on a board
#      whose udp_consumer is ocram-ring-v1 (decision 0024's amendment), two
#      udp: :out channels, two udp: :in ones, a depth that is not a power of
#      two, slots beyond the region's 128 KB, and an udp_consumer value this
#      tool does not know (--mutate-udp-consumer); and a udp: :in channel on a
#      board whose network is its own (decision 0025). These need
#      the tools spinel-core-app build checks for first (KERNEL,
#      SPINEL_TYPEDUMP, LLVM_PREFIX or CLANG, ZEPHYR_BASE); without them they
#      are skipped, or fail under REQUIRE_ALL=1.
#
# CLANG (or LLVM_PREFIX) and RUBY select the tools. The harness binds a UDP
# port on 127.0.0.1, chosen from the process id.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures/udp"
BOARD="$ROOT/tests/app/fixtures/synthetic-board"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
RUBY="${RUBY:-ruby}"
die() { echo "udp: $*" >&2; exit 1; }
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
"$RUBY" -e 'require "prism"; exit(RUBY_VERSION >= "3.1" ? 0 : 1)' >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' ($("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null)) is below 3.1 or cannot load prism, which the application tool needs."

W=$(mktemp -d "${TMPDIR:-/tmp}/app-udp.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skips=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then echo "  FAIL $1 (REQUIRE_ALL=1; $2 checks)"; fail=$((fail + $2)); else echo "  skip $1 ($2 checks)"; skips=$((skips + $2)); fi; }
# package APP [NET] -> exit status, output in $W/pkg.out
package() {
  rm -rf "$W/pkg"
  if [ -n "${2:-}" ]; then set -- "$1" --net "$2"; fi
  "$RUBY" "$TOOL" package --app "$@" --board "$BOARD/board.rb" --out "$W/pkg" > "$W/pkg.out" 2>&1 && echo 0 || echo $?
}
# an application of one channel declaration
app() { printf 'require "spinel/core"\nstate :m, :u8, 2000\n%s\nevery_ms 5, :tick\ndef tick(m)\n  0\nend\n' "$1" > "$W/$2.rb"; }

echo "udp: 1. declarations"
ok "the fixture's udp: :out channels are read and packaged" "$(package "$FIX/app.rb")" 0
app "channel :c, :in, size: 8, depth: 2, udp: true" decl-in
ok "a udp: :in channel is read and packaged (decision 0025)" "$(package "$W/decl-in.rb")" 0
for c in "in-size|channel :c, :in, size: 1473, depth: 2, udp: true|is at most 1472 bytes, one datagram" \
         "endpoint|channel :c, :out, size: 8, depth: 2, udp: \"192.0.2.1:9000\"|the endpoint comes from the network file" \
         "size|channel :c, :out, size: 1473, depth: 2, udp: true|is at most 1472 bytes, one datagram" \
         "both|channel :c, :out, size: 8, depth: 2, uart: true, udp: true|one of \`uart: true\` and \`udp: true\`" \
         "mqtt|channel :c, :out, size: 8, depth: 2, mqtt: true|\`mqtt:\` is not implemented"; do
  name=${c%%|*}; rest=${c#*|}; decl=${rest%%|*}; want=${rest#*|}
  app "$decl" "decl-$name"
  rc=$(package "$W/decl-$name.rb")
  ok "refused: $name ($want)" "$rc:$(grep -c "declaration: channel: .*$want" "$W/pkg.out")" "1:1"
done
app "channel :c, :out, size: 1472, depth: 2, udp: true" decl-max
ok "a udp: message of exactly 1472 bytes is read" "$(package "$W/decl-max.rb")" 0

echo "udp: 2. the network file"
PORT=$((20000 + $$ % 20000))
good() { printf 'interface lo\naddress 127.0.0.1   # the board\nnetmask 255.0.0.0\n\nchannel frames 127.0.0.1 %s\nchannel spare 127.0.0.1 0\n' "$1"; }
good "$PORT" > "$W/net"
ok "a complete file is read" "$(package "$FIX/app.rb" "$W/net")" 0
CH="$W/pkg/channels"
ok "it becomes spc_net.h beside transport_udp.c: the interface, the address, each channel's endpoint" \
   "$(grep -c -e '^#define SPC_NET_IFACE "lo"$' -e '^#define SPC_NET_ADDRESS "127.0.0.1"$' -e "^#define SPC_NET_FRAMES_PORT ${PORT}u\$" \
      -e '^#define SPC_NET_SPARE_PORT 0u$' "$CH/spc_net.h"):$(ls "$CH" | grep -c '^transport_udp\.c$')" "4:1"
cp -R "$W/pkg" "$W/pkg-good"
for c in "no-netmask|/^netmask/d|no netmask line" \
         "twice|\$a\\
interface lo|interface is given twice" \
         "no-channel|/^channel spare/d|no channel line for spare" \
         "uart-channel|\$a\\
channel console 127.0.0.1 9|channel console is not a udp: :out channel" \
         "address|s/^address 127.0.0.1/address 127.0.0.256/|is not an IPv4 dotted quad" \
         "port|s/^channel spare 127.0.0.1 0/channel spare 127.0.0.1 65536/|is not an integer from 0 (off) to 65535" \
         "unknown|\$a\\
gateway 127.0.0.1|unknown line \"gateway\"" \
         "half-dhcp|s/^address 127.0.0.1.*/address dhcp/|address and netmask are both dhcp, or both IPv4 dotted quads"; do
  name=${c%%|*}; rest=${c#*|}; edit=${rest%%|*}; want=${rest#*|}
  sed "$edit" "$W/net" > "$W/net-$name"
  cmp -s "$W/net" "$W/net-$name" && die "the planted edit $name did not apply"
  rc=$(package "$FIX/app.rb" "$W/net-$name")
  ok "refused: $name ($want)" "$rc:$(grep -cF "$want" "$W/pkg.out")" "1:1"
done

sed -e 's/^address 127.0.0.1.*/address dhcp/' -e 's/^netmask 255.0.0.0/netmask dhcp/' "$W/net" > "$W/net-dhcp"
ok "address dhcp and netmask dhcp are read, and spc_net.h says DHCP and no address" \
   "$(package "$FIX/app.rb" "$W/net-dhcp"):$(grep -c -e '^#define SPC_NET_DHCP 1$' "$W/pkg/channels/spc_net.h"):$(grep -c SPC_NET_ADDRESS "$W/pkg/channels/spc_net.h" || true)" "0:1:0"

# an :in channel's inbound line (decision 0025)
INF="$FIX/app-in.rb"
printf 'interface lo\naddress 127.0.0.1\nnetmask 255.0.0.0\nchannel frames 127.0.0.1 %s\ninbound keys 5030 from 192.0.2.1\n' "$PORT" > "$W/net-in"
ok "an inbound line for the :in channel is read" "$(package "$INF" "$W/net-in")" 0
for c in "no-inbound|/^inbound keys/d|no inbound line for keys" \
         "inbound-out|s/^inbound keys/inbound frames/|inbound frames is not a udp: :in channel" \
         "channel-in|\$a\\
channel keys 127.0.0.1 9|channel keys is not a udp: :out channel" \
         "no-from|s/ from / at /|inbound takes a name, a port, \`from\` and an IPv4 address" \
         "inbound-twice|\$a\\
inbound keys 5031 from 192.0.2.1|inbound keys is given twice" \
         "inbound-port|s/^inbound keys 5030/inbound keys 70000/|is not an integer from 0 (off) to 65535" \
         "inbound-addr|s/from 192.0.2.1/from 192.0.2.300/|\"192.0.2.300\" is not an IPv4 dotted quad"; do
  name=${c%%|*}; rest=${c#*|}; edit=${rest%%|*}; want=${rest#*|}
  sed "$edit" "$W/net-in" > "$W/net-$name"
  cmp -s "$W/net-in" "$W/net-$name" && die "the planted edit $name did not apply"
  rc=$(package "$INF" "$W/net-$name")
  ok "refused: $name ($want)" "$rc:$(grep -cF "$want" "$W/pkg.out")" "1:1"
done

echo "udp: 3. the transport on the host"
CH="$W/pkg-good/channels"
n=0; bad=
for f in "$CH"/*.c; do
  b=$(basename "$f" .c)
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O2 -DSPC_HOST -D_DEFAULT_SOURCE -c "$f" -o "$W/$b.o" 2>"$W/$b.err" || bad="$bad $b"
  n=$((n + 1))
done
ok "every unit compiles with -Wall -Wextra -Werror ($n units)" "${bad:-clean}" clean
OBJS=$(ls "$W"/channel_*.o)
"$CC_BIN" -O2 -Wall -I"$CH" "$FIX/udp_harness.c" "$W/transport_uart.o" "$W/transport_udp.o" $OBJS -o "$W/udp" > "$W/udp.build" 2>&1 \
  || die "the harness did not link: $(cat "$W/udp.build")"
"$W/udp" "$PORT" > "$W/udp.out" 2>&1 && rc=0 || rc=$?
[ "$rc" = 3 ] && die "the harness could not bind 127.0.0.1:$PORT: $(cat "$W/udp.out")"
grep -E '^  (ok|FAIL)' "$W/udp.out"
ok "the harness ran to its summary" "$rc:$(tail -1 "$W/udp.out")" "0:harness: 0 failed"
ok "the harness made 14 checks" "$(grep -c '^  ok ' "$W/udp.out")" 14
# The kept failing input, made from a copy of the generated transport, not
# from the product: a send without buffers drops its message instead of
# keeping it.
sed 's|return 0; /\* SPC_KEEP: kept for the next pass \*/|return 1;|' "$CH/transport_udp.c" > "$W/transport_mut.c"
cmp -s "$CH/transport_udp.c" "$W/transport_mut.c" && die "the mutation did not apply; the keep line moved"
"$CC_BIN" -std=c11 -O2 -DSPC_HOST -D_DEFAULT_SOURCE -I"$CH" -c "$W/transport_mut.c" -o "$W/transport_mut.o" 2>"$W/mut.err" || die "the mutated transport did not compile: $(cat "$W/mut.err")"
"$CC_BIN" -O2 -Wall -I"$CH" "$FIX/udp_harness.c" "$W/transport_uart.o" "$W/transport_mut.o" $OBJS -o "$W/udp_mut" > /dev/null 2>&1 || die "the mutated harness did not link"
"$W/udp_mut" "$PORT" > "$W/udp_mut.out" 2>&1 && mrc=0 || mrc=$?
ok "control: a transport that drops a message it had no buffer for fails the harness, on the kept message and on conservation" \
   "$mrc:$(grep -c -e '^  FAIL once a buffer is there the kept message leaves first' -e '^  FAIL every message put was received or counted' "$W/udp_mut.out")" "1:2"

echo "udp: 3b. the inbound ring's get on the host"
# generated as the build generates a board's udp: channels whose other
# end is the M33 (pipeline step 1 and Channels.c_files)
mkdir -p "$W/xin"
"$RUBY" -I"$ROOT/tools/app/lib" -e '
  require "core_app/declarations"; require "core_app/channels"; require "core_app/net"
  app = CoreApp::Declarations.read(ARGV[0])
  out_c = app.channels.find { |c| c.direction == "out" }; in_c = app.channels.find { |c| c.direction == "in" }
  layout, used = CoreApp::Channels.ring_layout(out_c, in_c)
  layout.each { |c, g| c.xcore = true; c.ring = g }
  CoreApp::Channels.c_files(app).each { |n, t| File.write(File.join(ARGV[1], n), t) }
  File.write(File.join(ARGV[1], "spc_ring_geometry.h"), CoreApp::Channels.ring_geometry_h(out_c, in_c))
  File.write(File.join(ARGV[1], "spc_net.h"), CoreApp::Net.launcher_header(CoreApp::Net.read(ARGV[2], app), out_c, in_c))
  puts "#{in_c.ring.join(" ")} #{used}"' "$INF" "$W/xin" "$W/net-in" > "$W/xin.geom" || die "the inbound ring did not generate"
read -r STRIDE OFFSET USED < "$W/xin.geom"
# frames: 64 bytes, depth 4 -> 4 slots of 96 after the 512-byte header; keys after them
ok "the inbound slots follow the outbound ones after the 512-byte header" "$STRIDE $OFFSET $USED" "32 896 1408"
ok "the M33's geometry header names both rings" \
   "$(grep -c -e '^#define SPC_RING_OFFSET 512u$' -e '^#define SPC_RING_IN_DEPTH 16u$' -e '^#define SPC_RING_IN_OFFSET 896u$' -e '^#define SPC_RING_IN_MAX_LEN 17u$' "$W/xin/spc_ring_geometry.h")" 4
ok "the M33's network header names the inbound port and host" \
   "$(grep -c -e '^#define SPC_NET_IN_PORT 5030$' -e '^#define SPC_NET_IN_HOST "192.0.2.1"$' "$W/xin/spc_net.h")" 2
ok "the M7 has the :in channel's get and no put" "$(ls "$W/xin" | grep -c '^channel_keys_get\.c$'):$(ls "$W/xin" | grep -c '^channel_keys_put\.c$')" "1:0"
xin() { # get.c harness-out -> exit status
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O2 -include "$FIX/ring_host.h" -I"$ROOT/tools/app" -I"$W/xin" \
    -DSPC_T_STRIDE="${STRIDE}u" -DSPC_T_OFFSET="${OFFSET}u" "$FIX/ring_in_harness.c" "$1" -o "$2.bin" > "$2.build" 2>&1 \
    || { echo build; return; }
  "$2.bin" > "$2" 2>&1 && echo 0 || echo $?
}
rc=$(xin "$W/xin/channel_keys_get.c" "$W/xin.out")
grep -E '^  (ok|FAIL)' "$W/xin.out" || cat "$W/xin.out.build"
ok "the harness ran to its summary" "$rc:$(tail -1 "$W/xin.out")" "0:harness: 0 failed"
ok "the harness made 13 checks" "$(grep -c '^  ok ' "$W/xin.out")" 13
sed 's|^\tspc_tail++;$|\t/* the tail is not advanced */|' "$W/xin/channel_keys_get.c" > "$W/xin_mut.c"
cmp -s "$W/xin/channel_keys_get.c" "$W/xin_mut.c" && die "the get mutation did not apply; the tail line moved"
rc=$(xin "$W/xin_mut.c" "$W/xin_mut.out")
ok "control: a get that does not advance its tail fails the harness, on order and on the published tail" \
   "$rc:$(grep -c -e '^  FAIL three messages come out whole and in order' -e '^  FAIL then the ring is empty, and in_tail is published as 3' "$W/xin_mut.out")" "1:2"

echo "udp: 4. the build's refusals"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
if [ -x "$KERNEL" ] && [ -x "$READER" ] && [ -n "${ZEPHYR_BASE:-}" ]; then
  source_stamp kernel "$KERNEL"
  source_stamp reader "$READER"
  export LLVM_PREFIX="${LLVM_PREFIX:-$(dirname "$(dirname "$CC_BIN")")}"
  KERNEL=$KERNEL SPINEL_TYPEDUMP=$READER "$RUBY" "$TOOL" build --app "$FIX/app.rb" --board mps2_an521 --out "$W/b1" > "$W/b1.out" 2>&1 && rc=0 || rc=$?
  ok "a udp: channel without --net is refused at step 1, naming the channels and the file" \
     "$rc:$(grep -c 'step 1: the udp: channels frames, spare need the network file: --net FILE' "$W/b1.out")" "1:1"
  KERNEL=$KERNEL SPINEL_TYPEDUMP=$READER "$RUBY" "$TOOL" build --app "$FIX/app.rb" --board mps2_an521 --out "$W/b2" --net "$W/net" > "$W/b2.out" 2>&1 && rc=0 || rc=$?
  ok "on a board whose table names no network configuration it is refused at step 2" \
     "$rc:$(grep -c 'step 2: the udp: channels need the board.s network configuration, and mps2_an521 names none' "$W/b2.out")" "1:1"
  # a board whose udp_consumer is ocram-ring-v1 (frdm_imxrt1186_cm7, decision
  # 0024's amendment): the channel's consumer is the M33, through the ring
  printf 'interface swp0\naddress dhcp\nnetmask dhcp\nchannel a 192.0.2.1 5029\nchannel b 192.0.2.1 5030\n' > "$W/net-ab"
  printf 'interface swp0\naddress dhcp\nnetmask dhcp\nchannel a 192.0.2.1 5029\n' > "$W/net-a"
  xbuild() { # name app net [args] -> exit status, output in $W/x-name.out
    n=$1; a=$2; nf=$3; shift 3
    KERNEL=$KERNEL SPINEL_TYPEDUMP=$READER "$RUBY" "$TOOL" build --app "$a" --board frdm_imxrt1186_cm7 --out "$W/x-$n" --net "$nf" "$@" > "$W/x-$n.out" 2>&1 && echo 0 || echo $?
  }
  ok "ocram-ring-v1: two udp: channels are refused at step 1, the ring carrying one" \
     "$(xbuild two "$FIX/xcore/two.rb" "$W/net-ab"):$(grep -c 'step 1: 2 udp: :out channels (a, b): the OCRAM ring carries one :out channel' "$W/x-two.out")" "1:1"
  printf 'interface swp0\naddress dhcp\nnetmask dhcp\ninbound a 5030 from 192.0.2.1\ninbound b 5031 from 192.0.2.1\n' > "$W/net-in-ab"
  ok "ocram-ring-v1: two udp: :in channels are refused at step 1, the ring carrying one" \
     "$(xbuild two-in "$FIX/xcore/two-in.rb" "$W/net-in-ab"):$(grep -c 'step 1: 2 udp: :in channels (a, b): the OCRAM ring carries one :in channel' "$W/x-two-in.out")" "1:1"
  ok "ocram-ring-v1: a depth that is not a power of two is refused at step 1" \
     "$(xbuild depth "$FIX/xcore/depth.rb" "$W/net-a"):$(grep -c 'step 1: channel a: depth 6 is not a power of two' "$W/x-depth.out")" "1:1"
  ok "ocram-ring-v1: slots beyond the region's 128 KB are refused at step 1, with the bytes" \
     "$(xbuild big "$FIX/xcore/big.rb" "$W/net-a"):$(grep -c 'step 1: the OCRAM rings. slots (a: 128 of 1312 bytes) end at 168448 bytes, above the region.s 131072' "$W/x-big.out")" "1:1"
  ok "a udp_consumer this tool does not know is refused at step 1, naming it" \
     "$(xbuild unknown "$FIX/xcore/depth.rb" "$W/net-a" --mutate-udp-consumer ocram-ring-v9):$(grep -c 'step 1: the board.s udp_consumer is "ocram-ring-v9"; ocram-ring-v1 is the only one this tool generates' "$W/x-unknown.out")" "1:1"
  KERNEL=$KERNEL SPINEL_TYPEDUMP=$READER "$RUBY" "$TOOL" build --app "$INF" --board mps2_an521 --out "$W/b3" --net "$W/net-in" > "$W/b3.out" 2>&1 && rc=0 || rc=$?
  ok "a udp: :in channel on a board whose network is its own is refused at step 1 (decision 0025)" \
     "$rc:$(grep -c 'step 1: channel keys: udp: on an :in channel is received by the other core' "$W/b3.out")" "1:1"
else
  skipped "the build's refusals (no kernel, reader or ZEPHYR_BASE)" 8
fi

echo "udp: $((pass + fail + skips)) checked, $pass pass, $fail fail, $skips skip"
[ "$fail" -eq 0 ]
