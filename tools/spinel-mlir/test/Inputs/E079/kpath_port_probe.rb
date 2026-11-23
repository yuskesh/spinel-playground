require "bpf"

# tcpretrans — prints each TCP retransmission (bcc's tcpretrans, ported from spinel-ebpf 23fa4b0 tools/tcpretrans.rb).
# eBPF side: reads skc_family, skc_daddr, skc_dport and skc_num of __sk_common (struct sock_common, embedded by value) in sk of fentry tcp_retransmit_skb(struct sock *sk, …)
# through the path t.load.__sk_common.m and only copies them into the event (bpf-mlir's CO-RE path to an embedded member). No filtering (bcc also prints every retransmission);
# a path value is only copied straight into a record field — a local, arithmetic or a comparison is SB010 under Spinel's inference. Byte order (skc_dport is network order) and port filtering are the user side's. The attach differs: bcc uses tracepoint tcp/tcp_retransmit_skb (an alternative — that form can be
# written with an array field), spinel-ebpf a kprobe (spinel's kprobe has no CO-RE reads). Prints only v4 addresses (v6 is skc_v6_daddr, out of scope here).
SockCommon = Struct.new(:skc_daddr, :skc_dport, :skc_num, :skc_family)
BPF.kernel_type(SockCommon, "sock_common", skc_daddr: :u32, skc_dport: :u16, skc_num: :u16, skc_family: :u16)
Sock = Struct.new(:__sk_common)
BPF.kernel_type(Sock, "sock", __sk_common: [:struct, SockCommon])
SockT = BPF::KernelType.new(Sock.new(SockCommon.new(0, 0, 0, 0)))

Drops = BPF::ArrayMap.new("Drops", :u64, 1)
Ev = Struct.new(:family, :sport, :dport, :pad, :daddr)
BPF.record(Ev, family: :u16, sport: :u16, dport: :u16, pad: :u16, daddr: :u32)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, 0), 65536)

def on_retrans(ctx)
  sk = ctx.kptr_or_null(0, SockT)
  if sk
    port = sk.load.__sk_common.skc_dport
    host_port = ((port & 255) << 8) | ((port >> 8) & 255)
    if host_port == 80
      unless Events.output(Ev.new(sk.load.__sk_common.skc_family, sk.load.__sk_common.skc_num, sk.load.__sk_common.skc_dport, 0, sk.load.__sk_common.skc_daddr))
        Drops.atomic_add(0, 1)
      end
    end
  end
end
BPF.fentry :on_retrans, "tcp_retransmit_skb", args: {0 => [:or_null, SockT]}

