require "bpf"

# E094 (P023 段 2): 同じ計算を inline に書いた program (key 0) と借用の helper を呼ぶ program (key 1) — 双子 = kernel と inline = helper の差動。
Stat = Struct.new(:hits, :last, :tag)
BPF.record(Stat, hits: :u64, last: :u32, tag: :u32)
Vals = BPF::ArrayMap.new("Vals", :u64, 2)
Stats = BPF::RecordMap.new("Stats", Stat.new(0, 0, 0), 2)
Out = BPF::ArrayMap.new("Out", :u64, 4)

def peek(q)
  q.load & 0xFFFF
end

def bump(q, d)
  q.atomic_add(d & 0xFF)
  0
end

def note(r, tag)
  r.atomic_add(:hits, 1)
  r.load.last = tag & 0xFFFF
  r.load.tag = (tag + 1) & 0xFFFF
  x = r.load.hits & 0xFFFF
  x
end

def p_inline(ctx)
  p = Vals.lookup(0)
  if p
    Out.update(0, p.load & 0xFFFF)
    p.atomic_add(3)
  end
  s = Stats.lookup(0)
  if s
    s.atomic_add(:hits, 1)
    s.load.last = 42
    s.load.tag = 43
    x = s.load.hits & 0xFFFF
    Out.update(2, x)
  end
  BPF::XDP_PASS
end
BPF.xdp :p_inline

def p_helper(ctx)
  p = Vals.lookup(1)
  if p
    Out.update(1, peek(p) & 0xFFFF)
    bump(p, 3)
  end
  s = Stats.lookup(1)
  if s
    Out.update(3, note(s, 42) & 0xFFFF)
  end
  BPF::XDP_PASS
end
BPF.xdp :p_helper
