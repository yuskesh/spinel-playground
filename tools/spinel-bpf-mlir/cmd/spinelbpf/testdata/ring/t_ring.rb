require "bpf"

# E028 の表の program — ring buffer の output の 3 つの形 (if・unless・_ =)。event の値は In から (a・b は同じ u32 — 変異 ring-swap が入れ替える)
Ev = Struct.new(:a, :b, :c, :_pad0, :d)
BPF.record(Ev, a: :u32, b: :u32, c: :i32, _pad0: :u32, d: :u64)

Events = BPF::RingBuf.new("Events", Ev.new(0, 0, 0, 0, 0), 4096)
In = BPF::ArrayMap.new("In", :i64, 2)
Cnt = BPF::ArrayMap.new("Cnt", :u64, 3)

def t_if(ctx)
  x = 0
  y = 0
  p = In.lookup(0)
  if p
    x = p.load
  end
  q = In.lookup(1)
  if q
    y = q.load
  end
  if Events.output(Ev.new(x & 0xFFFFFFFF, (x >> 32) & 0xFFFFFFFF, (y & 0xFFFFFFFF) - 2147483648, 0, y & 0x7FFF_FFFF_FFFF_FFFF))
    Cnt.atomic_add(0, 1)
  else
    Cnt.atomic_add(1, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :t_if

def t_unless(ctx)
  unless Events.output(Ev.new(1, 2, -3, 0, 4))
    Cnt.atomic_add(2, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :t_unless

def t_any(ctx)
  _ = Events.output(Ev.new(5, 6, 7, 0, 8))
  BPF::XDP_PASS
end
BPF.xdp :t_any
