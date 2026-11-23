# examples/http_server/M004/ruby_slice.rb
#
# E157: the pure-XDP TCP slice written as a PLAIN Ruby xdp__ method, using the
# DSL builtins from E151-E156 (instead of the C template emit_tcp_slice_bundle).
#
#   #1 pkt.tcp.seq / pkt.tcp.ack   (E151)
#   #2 flow_get / flow_set         (E152)
#   #3 tcp_syncookie_gen / check   (E153)
#   #4 tcp_reply_header            (E154)
#   #5a payload_starts             (E155)
#   #5b tcp_reply_data             (E156)
#
# The control flow (if/elsif state machine) lowers via the structured CIf/CBlock
# codegen (E146); packet/ref ownership is the linear-use pass's domain (E150).
#
# Build / run (in a Linux container on the spinel kernel):
#   bin/spinel-ebpf compile examples/http_server/M004/ruby_slice.rb -o build/rbslice --build
#   SPNL_XDP_IFACE=lo ./build/rbslice/ruby_slice &
#   curl http://127.0.0.1:8080/hello
#
# Status (E161): ★ FULL curl-200 ACHIEVED on the spinel kernel.
#   $ curl http://127.0.0.1:8080/hello   ->   HTTP 200, body "hello"
# This Ruby slice (synack_cookie + flow map + payload match + reply_data, all DSL
# builtins) now completes the SYN-cookie 3-way handshake and serves the response
# entirely in XDP — no kernel listener on :8080, no worker process. Two fixes over
# E157-E160 got here, both found via the C-inspection + BPF-counter methodology
# (no big flat-subprog rewrite needed):
#  1. E161 compiler barrier (`asm volatile("" ::: "memory")`) after the synack
#     bpf_xdp_adjust_tail grow, so clang re-reads ctx->data_end with a clean LDX
#     instead of `ctx+4` (the verifier's "modified ctx ptr"). The cheap C reshapes
#     of E160 didn't help; this one-line barrier — the standard post-adjust_tail
#     idiom — makes the full slice load with the existing __noinline structure.
#  2. Verdicts: every handled :8080 packet is CONSUMED (XDP::DROP), never PASS.
#     There is no kernel listener, so PASSing the bare handshake-ACK made the stack
#     emit a RST that killed the connection. The bundle DROPs these (codegen line
#     ~2282); matching that is what turns load+attach into a real 200.

# NOTE: the spinel-ebpf eBPF codegen is EXPRESSION-style (E011) — no early `return`,
# no `unless`. Each branch evaluates to the XDP verdict; the method value is the
# trailing if/elsif/else expression. (Found via E157: UnlessNode / early-return are
# not lowerable.)
def xdp__rbslice
  if pkt.l4.proto != IP::Proto::TCP
    XDP::PASS
  elsif pkt.l4.dport != 8080
    XDP::PASS
  else
    flags = pkt.tcp.flags
    if (flags & TCP::Flag::SYN) != 0 && (flags & TCP::Flag::ACK) == 0
      # SYN -> SYN-ACK with a stateless SYN cookie + MSS option, the E052 bundle
      # sequence in one builtin (grow-to-60, gen, build, shrink) — #4b'.
      if tcp_synack_cookie < 0
        XDP::ABORTED
      else
        XDP::TX
      end
    elsif (flags & TCP::Flag::ACK) == 0
      # Non-ACK packet to :8080. There is NO kernel listener (pure-XDP), so we
      # must CONSUME it (XDP::DROP) — passing it up makes the stack send a RST
      # that tears down the client's connection.
      XDP::DROP
    elsif pkt.l4.payload_len == 0
      # Pure ACK completing the handshake: validate the cookie, open the flow,
      # and DROP (consume) — the client treats the connection as established the
      # moment it sends this ACK; the kernel must never see it (no listener).
      if tcp_syncookie_check < 0
        XDP::DROP
      else
        flow_set(:conn, :state, 1)   # ESTABLISHED
        XDP::DROP
      end
    elsif payload_starts("GET /hello ")
      # Data: GET /hello -> 200 response (data + FIN), mark CLOSED.
      if tcp_reply_data(pkt.tcp.ack, pkt.tcp.seq + pkt.l4.payload_len,
                        "HTTP/1.0 200 OK\r\nContent-Length: 6\r\n\r\nhello\n") < 0
        XDP::ABORTED
      else
        flow_set(:conn, :state, 3)   # CLOSED
        XDP::TX
      end
    else
      # Any other :8080 packet (non-GET data, etc.) — consume it.
      XDP::DROP
    end
  end
end

puts "[E157] Ruby tcp slice (xdp__rbslice) attached on :8080"
puts "[E157] curl http://127.0.0.1:8080/hello"
sleep 3600
