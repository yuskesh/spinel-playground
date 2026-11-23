require "bpf"

In = BPF::ArrayMap.new("In", :u64, 2)
Out = BPF::ArrayMap.new("Out", :i64, 5)
OW = BPF::ArrayMap.new("OW", :u64, 1)

def prog(ctx)
  p = In.lookup(0)
  if p
    Out.update(0, p.load & 0xFFFF)
    Out.update(1, p.load >> 1)
    Out.update(2, p.load >> 32)
    Out.update(3, (p.load & 0x7FFF_FFFF_FFFF_FFFF) / 3)
    Out.update(4, (p.load >> 33) * 3)
    OW.update(0, p.load)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
