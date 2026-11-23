require "bpf"

# P029 E153: tracepoint の固定 byte の配列の field — sock/inet_sock_set_state の daddr[4] (offset 36) と daddr_v6[16] (offset 56) を
# ctx.copy(:f) で ring の event の配列の member に写す (bpf-mlir E552 — ebpf.tp.field.copy の写し先は予約)。
# TCP (6) の CLOSE (7) → SYN_SENT (2) (能動の connect) で Filter の tgid のとき Events に {family, dport, daddr, daddr_v6}、出せたら Out[0] に 1 を足す
Ev = Struct.new(:family, :dport, :daddr, :daddr_v6)
BPF.record(Ev, family: :u16, dport: :u16, daddr: [:u8, 4], daddr_v6: [:u8, 16])

Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)
Events = BPF::RingBuf.new("Events", Ev.new(0, 0, Array.new(4, 0), Array.new(16, 0)), 4096)

def on_state(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid && ctx.field(:protocol) == 6 && ctx.field(:oldstate) == 7 && ctx.field(:newstate) == 2
      if Events.output(Ev.new(ctx.field(:family), ctx.field(:dport), ctx.copy(:daddr), ctx.copy(:daddr_v6)))
        Out.atomic_add(0, 1)
      end
    end
  end
end
BPF.tracepoint :on_state, "sock/inet_sock_set_state", fields: {oldstate: [16, :i32], newstate: [20, :i32], dport: [26, :u16], family: [28, :u16], protocol: [30, :u16], daddr: [36, [:u8, 4]], daddr_v6: [56, [:u8, 16]]}
