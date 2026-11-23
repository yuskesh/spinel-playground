# E132/E428: the DNS capture written with the RAW field read, kept as a fixture
# because it is still legal and because it is the only spelling of this probe the
# retired Ruby codegen (src/spinel_ebpf/codegen_bpf.rb, ADR-011 Stage 1) can read
# -- it predates both sock_* (E395) and udp_* (E428).
#
# It is not the form to copy. Two things are wrong with it as a DNS filter and
# neither one fails loudly:
#   - 13568 is 0x3500, port 53 written big-endian. E395 added sock_dport(sk) so
#     the byte order lives in the accessor instead of in the literal.
#   - the socket's peer port is 0 for a sender that passes the destination on
#     every send, so this filter reports nothing at all for, e.g., dnsmasq
#     forwarding upstream (E428). 105_emit_dns is the form that asks about the
#     datagram: udp_dport(sk, msg) == 53.
def kprobe__udp_sendmsg(sk, msg, len)
  if kfield(sk, "sock", "__sk_common.skc_dport") == 13568
    emit_dns(msg)
  end
  0
end
