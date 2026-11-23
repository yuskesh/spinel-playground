# E413 (P011 A4): SO_REUSEPORT worker selection from BPF.
#
# Same shape E043 shipped and the public example still carries: read the
# kernel's 5-tuple hash of the incoming SYN, fold it into a worker index, and
# hand that index to bpf_sk_select_reuseport via a REUSEPORT_SOCKARRAY the
# workers register their own listen sockets into (sp_bpf_reuseport_register).
#
# SK_PASS confirms the selection. If the chosen slot is empty the kernel falls
# back to its own 5-tuple distribution -- which is why "several workers got
# connections" cannot on its own prove the program chose them (E413 D3).
#
# The two builtins here (reuseport_hash / worker_select) and the SOCKARRAY were
# withdrawn in E406/E409 and re-ported in E413.

@syns = 0

def sk_reuseport__select
  @syns = @syns + 1
  idx = reuseport_hash % 4
  worker_select(idx)
  SK_PASS
end

puts "[168] sk_reuseport worker selection"
