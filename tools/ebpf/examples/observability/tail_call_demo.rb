# examples/observability/tail_call_demo.rb
#
# E063: PROG_ARRAY + bpf_tail_call demo. A dispatcher XDP picks a slot
# based on the IP protocol byte and tail-calls into one of two
# sub-programs. Each sub-prog has its own verifier instruction budget
# (1M each) and independent state — a foundation for splitting larger
# XDP programs (e.g., the tcp_slice from E054) into per-state sub-progs
# (TLS handshake parser, HTTP/2 frame parser, etc.).
#
# Build:
#   spinel-ebpf compile examples/observability/tail_call_demo.rb \
#       -o build/tail_call_demo --build
# Run (manual PROG_ARRAY population for the demo):
#   SPNL_XDP_IFACE=lo ./build/tail_call_demo/tail_call_demo &
#   # Populate spnl_prog_array slot 0 and 1 with the two xdp_tail__ progs
#   # via bpftool (see Edoc).
#   ping -c 5 127.0.0.1
#   # カーネルが保持する map 名は 15 文字までなので、この 2 本は
#   # どれも `tail_call_demo_` に見えて名前では区別できない。id で 1 本ずつ引く:
#   bpftool map show | grep tail_call_demo_
#   bpftool map dump id <上で出た id>

@tcp_pkts = 0
@other_pkts = 0

# Slot 0: counts TCP-ish packets
def xdp_tail__tcp_handler
  @tcp_pkts = @tcp_pkts + 1
  XDP::PASS
end

# Slot 1: counts everything else
def xdp_tail__other_handler
  @other_pkts = @other_pkts + 1
  XDP::PASS
end

# Dispatcher: peek byte 23 (= IPv4 protocol field for std 20-byte IP header)
# and tail_call to slot 0 (TCP) or slot 1 (others).
def xdp__dispatcher
  proto = pkt.byte_at(23)
  if proto == IP::Proto::TCP
    tail_call_to(0)
  else
    tail_call_to(1)
  end
  # falls through here only if bpf_tail_call failed
  XDP::PASS
end

puts "[E063] tail_call demo loaded. Populate PROG_ARRAY then send traffic."
sleep 3600
