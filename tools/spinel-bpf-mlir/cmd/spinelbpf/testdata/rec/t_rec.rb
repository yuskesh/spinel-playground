require "bpf"

# E022 の表の program — record の型 3 つ (全ての幅と符号・padding の隣・同じ幅の 2 member)。行末の印は変異の対照が書き換える op の行
W = Struct.new(:u64, :i64, :u32, :i32, :u16, :i16, :u8, :i8, :_pad0)
BPF.record(W, u64: :u64, i64: :i64, u32: :u32, i32: :i32, u16: :u16, i16: :i16, u8: :u8, i8: :i8, _pad0: :u16)
P = Struct.new(:a, :_pad0, :b)
BPF.record(P, a: :u8, _pad0: :u8, b: :i16)
Q = Struct.new(:x, :y)
BPF.record(Q, x: :u16, y: :u16)

Ws = BPF::RecordMap.new("Ws", W.new(0, 0, 0, 0, 0, 0, 0, 0, 0), 3)
Ps = BPF::RecordMap.new("Ps", P.new(0, 0, 0), 2)
Qs = BPF::RecordMap.new("Qs", Q.new(0, 0), 1)
In = BPF::ArrayMap.new("In", :i64, 2)
Out = BPF::ArrayMap.new("Out", :i64, 6)

def t(ctx)
  x = 0
  y = 0
  a = In.lookup(0)
  if a
    x = a.load
  end
  b = In.lookup(1)
  if b
    y = b.load
  end
  p = Ws.lookup(0)
  if p
    p.load.u8 = x & 0xFF
    p.load.i8 = (x & 0xFF) - 128
    p.load.u16 = x & 0xFFFF # MS
    p.load.i16 = (x & 0xFFFF) - 32768
    p.load.u32 = x & 0xFFFFFFFF
    p.load.i32 = (x & 0xFFFFFFFF) - 2147483648
    p.load.u64 = x & 0x7FFF_FFFF_FFFF_FFFF
    p.load.i64 = y
    Out.update(0, p.load.i8) # MX
    Out.update(1, p.load.i16 + p.load.u16)
  end
  r = Ws.lookup(1)
  if r
    r.atomic_add(:u32, x & 0xFFFFFFFF)
    r.atomic_add(:i32, (x & 0xFFFFFFFF) - 2147483648)
    r.atomic_add(:u64, x & 0xFFFF)
    r.atomic_add(:i64, (x & 0xFFFF) - 32768)
  end
  s = Ws.lookup(2)
  if s
    s.atomic_add(:u32, 1) # MA
  end
  Ps.update(0, P.new(x & 0xFF, 0, (x & 0xFFFF) - 32768))
  Qs.update(0, Q.new(x & 0xFFFF, (x >> 16) & 0xFFFF)) # MM
  q = Ps.lookup(1)
  if q
    Out.update(2, q.load.a + q.load.b)
    Out.update(3, q.load.b)
  end
  BPF::XDP_PASS
end
BPF.xdp :t
