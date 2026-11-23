require "bpf"

# E092 (P023): 同じ計算を inline に書いた program (Out[0..3]) と helper を呼ぶ program (Out[4..7]) — 双子 = kernel と inline = helper の差動。
In = BPF::ArrayMap.new("In", :u64, 2)
Out = BPF::ArrayMap.new("Out", :u64, 8)

def mix(a, b)
  (a * 3 + b) & 0xFFFF
end

def sum_to(n)
  s = 0
  (0...n).each do |i|
    s += i
  end
  s
end

def read_in(k)
  x = 0
  p = In.lookup(k)
  if p
    x = p.load & 0xFFFF
  end
  x
end

def bump(slot, d)
  Out.atomic_add(slot & 7, d & 0xFF)
  0
end

def p_inline(ctx)
  a = 0
  p = In.lookup(0)
  if p
    a = p.load & 0xFFFF
  end
  b = 0
  q = In.lookup(1)
  if q
    b = q.load & 0xFFFF
  end
  Out.update(0, (a * 3 + (b & 0xFF)) & 0xFFFF)
  s = 0
  (0...(b & 7)).each do |i|
    s += i
  end
  Out.update(1, s & 0xFF)
  Out.update(2, (((a & 0xFF) * 3 + (a & 0xFF)) & 0xFFFF) ^ ((b * 3 + 1) & 0xFFFF))
  Out.atomic_add(3, (b + 1) & 0xFF)
  BPF::XDP_PASS
end
BPF.xdp :p_inline

def p_helper(ctx)
  a = read_in(0) & 0xFFFF
  b = read_in(1) & 0xFFFF
  Out.update(4, mix(a, b & 0xFF) & 0xFFFF)
  Out.update(5, sum_to(b & 7) & 0xFF)
  Out.update(6, (mix(a & 0xFF, a & 0xFF) & 0xFFFF) ^ (mix(b, 1) & 0xFFFF))
  bump(7, b + 1)
  BPF::XDP_PASS
end
BPF.xdp :p_helper
