require "bpf"

# P014 E057: global 変数 — .rodata の Config (必須) と OptionalConfig (無ければ 0)、.bss の Counter (u64 と i32 — 負の add)
Port = BPF::Config.new("Port", :u16)
Verbose = BPF::OptionalConfig.new("Verbose", :u8)
Hits = BPF::Counter.new("Hits", :u64)
Neg = BPF::Counter.new("Neg", :i32)

def prog(ctx)
  w = ctx.check(0, 14)
  if w
    if w.be16(12) == Port.value
      Hits.add(1)
      if Verbose.value > 0
        Neg.add(-3)
      end
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
