require "bpf"

# E069 の表の program (P016 §3): record の配列の member の可変の読み・書き・定数の読み・N 5 の配列・loop の IV を双子と kernel で比べる。
Hist = Struct.new(:hist, :n)
BPF.record(Hist, hist: [:u32, 8], n: :u64)
Five = Struct.new(:a, :v)
BPF.record(Five, a: :u32, v: [:u32, 5])
Hs = BPF::RecordMap.new("Hs", Hist.new(Array.new(8, 0), 0), 2)
Ps = BPF::RecordMap.new("Ps", Five.new(0, Array.new(5, 0)), 1)
In = BPF::ArrayMap.new("In", :u32, 1)
Out = BPF::ArrayMap.new("Out", :u64, 4)

def prog(ctx)
  q = In.lookup(0)
  if q
    k = q.load
    i = k & 7
    j = (k >> 3) & 7
    u = (k & 0xFF) % 5
    p = Hs.lookup(0)
    if p
      Out.update(0, p.load.hist[i])
      p.load.hist[j] = k & 0xFFFF
      Out.update(1, p.load.hist[2])
    end
    r = Ps.lookup(0)
    if r
      Out.update(2, r.load.v[u])
    end
  end
  s = 0
  8.times do |t|
    p2 = Hs.lookup(1)
    if p2
      s += p2.load.hist[t]
    end
  end
  Out.update(3, s)
  BPF::XDP_PASS
end
BPF.xdp :prog
