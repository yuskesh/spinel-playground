require "bpf"

# P029 E154: kernel の struct の埋め込みの member の経路 — fentry/tcp_sendmsg の sock の __sk_common (struct sock_common — 値の埋め込み) の
# skc_daddr (宛先の IPv4 — network order)・skc_dport (宛先の port — network order)・skc_num (自分の port — host order) を t.load.a.m で
# (bpf-mlir E553 — kfield.load の経路 "__sk_common.skc_daddr")。Filter の tgid のとき Events に、出せたら Out[0] に 1 を足す
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
      if f.load == tgid
        if Events.output(Ev.new(sk.load.__sk_common.skc_daddr, sk.load.__sk_common.skc_dport, sk.load.__sk_common.skc_num))
          Out.atomic_add(0, 1)
        end
      end
    end
  end
end
BPF.fentry :on_send, "tcp_sendmsg", args: {0 => [:or_null, SockT]}
