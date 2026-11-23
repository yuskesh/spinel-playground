require "bpf"

# P029 E153: tracepoint の固定 byte の配列の field を record の map の借用へ — `r.load.daddr = ctx.copy(:daddr)` (bpf-mlir E552 の
# ebpf.tp.field.copy の写し先は借用)。TCP の CLOSE → SYN_SENT で Filter の tgid のとき Last[0] に最後の {family, dport, daddr, daddr_v6} を書き
# Out[0] に 1 を足す (本体の最後が member の書きだと Spinel の型の probe が SB010 — 写しに依らない既存の振る舞い、E153 の記録)
Ev = Struct.new(:family, :dport, :daddr, :daddr_v6)
BPF.record(Ev, family: :u16, dport: :u16, daddr: [:u8, 4], daddr_v6: [:u8, 16])

Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)
Last = BPF::RecordMap.new("Last", Ev.new(0, 0, Array.new(4, 0), Array.new(16, 0)), 1)

def on_state(ctx)
  tgid = BPF.pid_tgid >> 32
  f = Filter.lookup(0)
  if f
    if f.load == tgid
      if ctx.field(:protocol) == 6 && ctx.field(:oldstate) == 7 && ctx.field(:newstate) == 2
        r = Last.lookup(0)
        if r
          r.load.family = ctx.field(:family)
          r.load.dport = ctx.field(:dport)
          r.load.daddr = ctx.copy(:daddr)
          r.load.daddr_v6 = ctx.copy(:daddr_v6)
          Out.atomic_add(0, 1)
        end
      end
    end
  end
end
BPF.tracepoint :on_state, "sock/inet_sock_set_state", fields: {oldstate: [16, :i32], newstate: [20, :i32], dport: [26, :u16], family: [28, :u16], protocol: [30, :u16], daddr: [36, [:u8, 4]], daddr_v6: [56, [:u8, 16]]}
