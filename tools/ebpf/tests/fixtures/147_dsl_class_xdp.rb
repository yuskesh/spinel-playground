# E073 / E408: class-based attach -- `class N < BPF::XDP` binds every method of
# N to the XDP attach kind, and E073 states the emitted .bpf.c is byte-identical
# to the flat `def xdp__<member>`.
#
# E408 measured six of the nine class parents (XDP, SockOps, TcIngress,
# TcEgress, SkReuseport, SkMsg) as SILENTLY dead: exit 0, SEC("syscall"), a
# program that loads and never fires. Only the struct_ops trio (TcpCC/SchedExt/
# Qdisc) survived the ADR-011 Stage 2 port, because those three are bound during
# IR construction and the other six were never added there.
#
# E407 audited all 33 attach kinds and did not see this: it probed every kind
# through its FLAT spelling, which works. The failure lives in the surface.
XDP_PASS = 2

class ProtoCounter < BPF::XDP
  def count
    n = pkt_l4_proto
    if n == IPPROTO_TCP
      @tcp = @tcp + 1
    end
    XDP_PASS
  end
end
