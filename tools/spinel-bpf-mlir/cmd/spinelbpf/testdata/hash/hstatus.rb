require "bpf"

# E032 H3: hash / lru_hash の status の表 — 4 つの program を順に 1 回ずつ test run し、status と値を Out に書き、user 空間が map_get で読む (新しく load した空の map で)。
# program を分けるのは BPF の stack の 512 byte のため (map の操作ごとに key と値の stack の領域を取る — 1 つに 21 の操作は超えた)
K = Struct.new(:a, :_pad0, :b, :c)
BPF.record(K, a: :u8, _pad0: :u8, b: :u16, c: :u32)
Stat = Struct.new(:frames, :bytes)
BPF.record(Stat, frames: :u64, bytes: :u64)

H = BPF::HashMap.new("H", :u32, :i64, 4)
L = BPF::LruHashMap.new("L", :u32, :u64, 4)
R = BPF::HashMap.new("R", K.new(0, 0, 0, 0), :u32, 8)
V = BPF::RecordHashMap.new("V", :u64, Stat.new(0, 0), 8)
Out = BPF::ArrayMap.new("Out", :i64, 24)

def t1(ctx)
  s0 = H.insert(1, 10)
  Out.update(0, s0)
  s1 = H.insert(1, 11)
  Out.update(1, s1)
  s2 = H.replace(2, 5)
  Out.update(2, s2)
  s3 = H.replace(1, 12)
  Out.update(3, s3)
  s4 = H.update(3, 7)
  Out.update(4, s4)
  s5 = H.delete(3)
  Out.update(5, s5)
  s6 = H.delete(3)
  Out.update(6, s6)
  s7 = H.add_or_init(9, 5)
  Out.update(7, s7)
  s8 = H.add_or_init(9, 6)
  Out.update(8, s8)
  h9 = H.lookup(9)
  if h9
    Out.update(9, h9.load)
  end
  h1 = H.lookup(1)
  if h1
    Out.update(10, h1.load)
  end
  BPF::XDP_PASS
end
BPF.xdp :t1

def t2(ctx)
  s11 = H.insert(20, 1)
  Out.update(11, s11)
  s12 = H.insert(21, 1)
  Out.update(12, s12)
  s13 = H.insert(22, 1)
  Out.update(13, s13)
  _ = L.insert(1, 1)
  _ = L.insert(2, 1)
  _ = L.insert(3, 1)
  _ = L.insert(4, 1)
  s14 = L.insert(5, 1)
  Out.update(14, s14)
  BPF::XDP_PASS
end
BPF.xdp :t2

def t3(ctx)
  s15 = R.insert(K.new(1, 0, 2, 3), 5)
  Out.update(15, s15)
  r = R.lookup(K.new(1, 0, 2, 3))
  if r
    r.atomic_add(2)
    Out.update(16, r.load)
  end
  s17 = R.insert(K.new(1, 0, 2, 3), 6)
  Out.update(17, s17)
  if R.delete(K.new(9, 0, 9, 9)) == BPF::ENOENT
    Out.update(20, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :t3

def t4(ctx)
  s18 = V.update(4, Stat.new(1, 2))
  Out.update(18, s18)
  v = V.lookup(4)
  if v
    v.atomic_add(:frames, 3)
    Out.update(19, v.load.frames & 0xFFFF)
  end
  BPF::XDP_PASS
end
BPF.xdp :t4

require "spinelbpf"

obj = SpinelBPF.load_embedded
obj.test_run_xdp("t1", 1)
obj.test_run_xdp("t2", 1)
obj.test_run_xdp("t3", 1)
obj.test_run_xdp("t4", 1)
i = 0
while i < 21
  puts "Out[#{i}]=#{obj.map_get(Out, i)}"
  i += 1
end
puts "errno ENOENT=#{BPF::ENOENT} E2BIG=#{BPF::E2BIG} ENOMEM=#{BPF::ENOMEM} EEXIST=#{BPF::EEXIST}"
obj.close
