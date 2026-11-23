require "bpf"

# The path to an embedded member of a kernel struct — reads skc_daddr (destination IPv4 — network order), skc_dport (destination port —
# network order) and skc_num (own port — host order) of __sk_common (struct sock_common, embedded by value) in the sock of fentry/tcp_sendmsg with t.load.a.m
# (bpf-mlir's kfield.load with the path "__sk_common.skc_daddr"). When the tgid matches Filter, sends to Events, and adds 1 to Out[0] when that succeeds
SockCommon = Struct.new(:skc_daddr, :skc_rcv_saddr, :skc_dport, :skc_num)
BPF.kernel_type(SockCommon, "sock_common", skc_daddr: :u32, skc_rcv_saddr: :u32, skc_dport: :u16, skc_num: :u16)
Sock = Struct.new(:__sk_common)
BPF.kernel_type(Sock, "sock", __sk_common: [:struct, SockCommon])
SockT = BPF::KernelType.new(Sock.new(SockCommon.new(0, 0, 0, 0)))

Ev = Struct.new(:daddr, :dport, :sport)
BPF.record(Ev, daddr: :u32, dport: :u16, sport: :u16)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0), 4096)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def on_send(ctx)
  sk = ctx.kptr_or_null(0, SockT)
  if sk
    tgid = BPF.pid_tgid >> 32
    f = Filter.lookup(0)
    if f
      if sk.load.__sk_common.skc_daddr == 1
        if Events.output(Ev.new(sk.load.__sk_common.skc_daddr, sk.load.__sk_common.skc_dport, sk.load.__sk_common.skc_num))
          Out.atomic_add(0, 1)
        end
      end
    end
  end
end
BPF.fentry :on_send, "tcp_sendmsg", args: {0 => [:or_null, SockT]}
