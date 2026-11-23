require "bpf"

# E064 の表の program (P015 §3): 有界の loop の意味を双子 (Spinel の native の実行) と kernel の test run で比べる。
# 入力: In[0] = k (i32 — 実行時の回数の元)、In[1] = bpos (break / next の位置)、packet (TLV の walk)。
# 変異の対照が書き換える loop は N を program の中で一意にした (12・14・20 — .mlir の op の行で選ぶ)。
In = BPF::ArrayMap.new("In", :i32, 2)
Out = BPF::ArrayMap.new("Out", :i64, 16)
Cnt = BPF::ArrayMap.new("Cnt", :u64, 4)
H = BPF::HashMap.new("H", :u32, :u64, 32)

def prog(ctx)
  k = 0
  bpos = 0
  p = In.lookup(0)
  if p
    k = p.load
  end
  q = In.lookup(1)
  if q
    bpos = q.load & 15
  end
  # break の位置 (M1 は break ↔ continue、M2 は N 12 → 11)
  s = 0
  12.times do |i|
    break if i == bpos
    s += i + 1
  end
  Out.update(0, s)
  # next の位置
  t = 0
  8.times do |i|
    next if (i & 1) == (bpos & 1)
    t += i * 3
  end
  Out.update(1, t)
  # 実行時の回数 kk ∈ [-1, 14] (M3 は bound を外す、M4 は負の clamp を外す) — loop の中の map の操作
  kk = (k & 15) - 1
  c = 0
  kk.times do |i|
    c += i + 2
    Cnt.atomic_add(i & 3, 1)
    _ = H.add_or_init(i, 1)
  end
  Out.update(2, c)
  # (0..mm).each — mm ∈ [-2, 5]、回数 mm + 1
  mm = (k & 7) - 2
  e = 0
  (0..mm).each { |i| e += 10 + i }
  Out.update(3, e)
  # literal の回数 0・1・64 と loop の結果 (M5 は結果を初期値に — N 20)
  z = 0
  0.times { z += 1 }
  one = 0
  1.times { |i| one += 5 + i }
  big = 0
  64.times { |i| big += i }
  u = bpos
  20.times { |i| u += i + (k & 3) }
  Out.update(4, z)
  Out.update(5, one)
  Out.update(6, big)
  Out.update(7, u)
  # 入れ子 (外の break・内の next) と loop を跨ぐ値 3 つ
  n = 0
  mx = 0
  cnt = 0
  8.times do |i|
    break if i > bpos
    8.times do |j|
      next if j == i
      n += i * j
      cnt += 1
      mx = i + j if i + j > mx
    end
  end
  Out.update(8, n)
  Out.update(9, mx)
  Out.update(10, cnt)
  # loop の本体の packet の窓 (TLV の walk — 6 回)
  off = 14
  tl = 0
  ts = 0
  6.times do |i|
    ty = 0
    l = 0
    w = ctx.check(off, 2)
    if w
      ty = w.u8(0)
      l = w.u8(1) & 0x1F
    end
    break if ty == 0
    tl += 1
    ts += ty
    off += 2 + l
  end
  Out.update(11, tl)
  Out.update(12, ts)
  BPF::XDP_PASS
end
BPF.xdp :prog
