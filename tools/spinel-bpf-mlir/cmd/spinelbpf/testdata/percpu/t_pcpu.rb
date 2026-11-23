require "bpf"

# E039 の表の program — per-CPU の record の member の += / -=・整数の lookup → update・per-CPU の hash の status と add_or_init。
# kernel の harness は 1 つの CPU に固定 (taskset -c 0) — 双子は CPU を 1 つとして比べる (CPU ごとの和と 0 でない slot の数)
S = Struct.new(:a, :b, :c)
BPF.record(S, a: :u64, b: :u32, c: :i32)

PR = BPF::PerCpuRecordMap.new("PR", S.new(0, 0, 0), 2)
PI = BPF::PerCpuArrayMap.new("PI", :i64, 2)
PH = BPF::PerCpuHashMap.new("PH", :u32, :i64, 4)
In = BPF::ArrayMap.new("In", :i64, 4)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def t_add(ctx)
  k = 0
  x = 0
  a = In.lookup(0)
  if a
    k = a.load & 1
  end
  b = In.lookup(1)
  if b
    x = b.load & 0xFFFF
  end
  p = PR.lookup(k)
  if p
    p.load.a += x
    p.load.b += x
    p.load.c -= x
  end
  q = PI.lookup(k)
  if q
    PI.update(k, (q.load & 0xFFFFFF) + x)
  end
  BPF::XDP_PASS
end
BPF.xdp :t_add

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
    s0 = PH.update(k, v)
    Out.update(0, s0)
  elsif op == 1
    s1 = PH.insert(k, v)
    Out.update(0, s1)
  elsif op == 2
    s2 = PH.replace(k, v)
    Out.update(0, s2)
  elsif op == 3
    s3 = PH.delete(k)
    Out.update(0, s3)
  elsif op == 4
    s4 = PH.add_or_init(k, v)
    Out.update(0, s4)
  end
  BPF::XDP_PASS
end
BPF.xdp :t_h
