# E060 / E406 / E408 / E410: the dynptr-backed byte read, in BOTH of its
# spellings.
#
# History, because this file changed sides. E060 shipped
# `pkt_dynptr_byte_at(off)` (bpf_dynptr_from_xdp + bpf_dynptr_slice) and E071
# gave it the chain spelling `pkt.byte_at(off)` -- the ONE member of the pkt.*
# chain that is not a pkt_* reader, and the one that takes an argument. Both
# were lost in the ADR-011 Stage 2 port; E406 withdrew the builtin and E408 the
# sugar, and this fixture was a NEGATIVE one, pinned in codegen_reject.tsv.
#
# E410 re-ported it, so the fixture is positive now. It uses both spellings in
# one unit on purpose: the golden then shows each lowering to a call of the same
# helper, and that only ONE definition of that helper is emitted (both spellings
# book the same per-unit flag). Whether the two are byte-identical is a
# different claim and lives where equivalence claims live --
# tools/affordance_gate.rb --section sugar.
XDP_PASS = 2

def xdp__probe
  # chain spelling: byte 14 is version|ihl of a vanilla IPv4 header (0x45).
  if pkt.byte_at(14) == 69
    @ipv4 = @ipv4 + 1
  end
  # flat spelling, and a RUNTIME offset -- the thing a fixed-offset pkt_* reader
  # cannot express (the reason this builtin is not redundant with them).
  off = 14 + 9
  if pkt_dynptr_byte_at(off) == 1
    @icmp = @icmp + 1
  end
  XDP_PASS
end
