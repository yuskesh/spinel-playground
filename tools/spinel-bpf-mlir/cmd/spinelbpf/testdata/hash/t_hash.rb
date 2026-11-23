require "bpf"

# E034 の表の program — In[0] の op (0 update・1 insert・2 replace・3 delete・4 add_or_init・5 `delete == BPF::ENOENT`) を 1 回の run に 1 つ、status を Out[0] に。
# H は u32 → i64 (max_entries 4)、R は record の key (a・b は同じ u16 — 変異 hash-key-swap が入れ替える) → i64、L は lru_hash (数だけを比べる)。
K = Struct.new(:a, :b, :c)
BPF.record(K, a: :u16, b: :u16, c: :u32)

H = BPF::HashMap.new("H", :u32, :i64, 4)
R = BPF::HashMap.new("R", K.new(0, 0, 0), :i64, 4)
L = BPF::LruHashMap.new("L", :u32, :u64, 4)
In = BPF::ArrayMap.new("In", :i64, 4)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def t_h(ctx)
  op = 0
  k = 0
  v = 0
  a = In.lookup(0)
  if a
    op = a.load
  end
  b = In.lookup(1)
  if b
    k = b.load & 0xFFFFFFFF
  end
  c = In.lookup(3)
  if c
    v = (c.load & 0xFFFF) - 32768
  end
  if op == 0
    s0 = H.update(k, v)
    Out.update(0, s0)
  elsif op == 1
    s1 = H.insert(k, v)
    Out.update(0, s1)
  elsif op == 2
    s2 = H.replace(k, v)
    Out.update(0, s2)
  elsif op == 3
    s3 = H.delete(k)
    Out.update(0, s3)
  elsif op == 4
    s4 = H.add_or_init(k, v)
    Out.update(0, s4)
  elsif op == 5
    if H.delete(k) == BPF::ENOENT
      Out.update(1, 1)
    else
      Out.update(1, 2)
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :t_h

def t_r(ctx)
  op = 0
  k1 = 0
  k2 = 0
  v = 0
  a = In.lookup(0)
  if a
    op = a.load
  end
  b = In.lookup(1)
  if b
    k1 = b.load & 0xFFFFFFFF
  end
  c = In.lookup(2)
  if c
    k2 = c.load & 0xFFFFFFFF
  end
  d = In.lookup(3)
  if d
    v = (d.load & 0xFFFF) - 32768
  end
  if op == 0
    s0 = R.update(K.new(k1 & 0xFFFF, k1 >> 16, k2), v)
    Out.update(0, s0)
  elsif op == 1
    s1 = R.insert(K.new(k1 & 0xFFFF, k1 >> 16, k2), v)
    Out.update(0, s1)
  elsif op == 2
    s2 = R.replace(K.new(k1 & 0xFFFF, k1 >> 16, k2), v)
    Out.update(0, s2)
  elsif op == 3
    s3 = R.delete(K.new(k1 & 0xFFFF, k1 >> 16, k2))
    Out.update(0, s3)
  elsif op == 4
    s4 = R.add_or_init(K.new(k1 & 0xFFFF, k1 >> 16, k2), v)
    Out.update(0, s4)
  end
  BPF::XDP_PASS
end
BPF.xdp :t_r

def t_l(ctx)
  k = 0
  v = 0
  b = In.lookup(1)
  if b
    k = b.load & 0xFFFFFFFF
  end
  d = In.lookup(3)
  if d
    v = d.load & 0xFFFF
  end
  s = L.update(k, v)
  Out.update(0, s)
  BPF::XDP_PASS
end
BPF.xdp :t_l
