require "bpf"

# E035 H5 の対照: lookup の値を同じ hash の update に入れる非 atomic の形 (SB019 — hook no-rmw の build だけが通す)。Stat[0] は実行の数
Counts = BPF::HashMap.new("Counts", :u32, :u64, 1024)
Stat = BPF::ArrayMap.new("Stat", :u64, 5)

def prog(ctx)
  Stat.atomic_add(0, 1)
  k = BPF.ktime_ns & 7
  p = Counts.lookup(k)
  if p
    _ = Counts.update(k, (p.load & 0xFFFFFFFF) + 1)
  else
    _ = Counts.insert(k, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
