# E063 / E407 / E412: PROG_ARRAY + bpf_tail_call, in the shape E063 shipped.
#
# History, because this file changed sides. E063 gave `xdp_tail__<name>` (the
# jump TARGET), `tail_call_to(slot)` (the jump) and the per-unit PROG_ARRAY (the
# table). All three were lost in the ADR-011 Stage 2 port, and three separate
# audits withdrew one piece each: E406 the builtin, E407 the attach kind, E409
# the map type. This fixture was the NEGATIVE one for the attach kind, pinned in
# codegen_reject.tsv -- before E407 the same source compiled with exit 0 into a
# plain SEC("syscall") wrapper: not an XDP program, not a tail-call target.
#
# E412 re-ported all three, so the fixture is positive now. It is deliberately
# E063's own demo (same method names, same declaration order, same discriminator
# byte) so the golden can be diffed against
# docs/experiments/results/E063/generated_tail_call.bpf.c -- the retired Ruby
# codegen's own output -- and the port shown not to have changed the shape.
#
# What the golden has to show, beyond "it compiled":
#   - ONE spnl_prog_array, emitted because either half of the pair is present
#   - both targets carrying SEC("xdp") (the loader tells them apart by NAME, and
#     the wrapper comment says [xdp_tail -> xdp], not [xdp -> xdp])
#   - the tail call as a STATEMENT with the branch value 0 after it, because
#     bpf_tail_call does not return on success and falls through on failure
XDP_PASS = 2

@tcp_pkts = 0
@other_pkts = 0

# Slot 0: the loader (E065) assigns slots in declaration order.
def xdp_tail__tcp_handler
  @tcp_pkts = @tcp_pkts + 1
  XDP_PASS
end

# Slot 1.
def xdp_tail__other_handler
  @other_pkts = @other_pkts + 1
  XDP_PASS
end

# Byte 23 of an Ethernet frame is the protocol field of a vanilla 20-byte IPv4
# header. 6 = TCP.
def xdp__dispatcher
  proto = pkt_dynptr_byte_at(23)
  if proto == 6
    tail_call_to(0)
  else
    tail_call_to(1)
  end
  # Reached only when the tail call did NOT happen (empty slot) -- the jump
  # itself never returns here.
  XDP_PASS
end
