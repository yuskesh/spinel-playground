require "bpf"

# E039 H2 の対照: 共有の RecordMap の += (SB019 — hook percpu-exempt-all の build だけが免除を漏らして通す)。同じ runner の P を読む
S = Struct.new(:n, :m)
BPF.record(S, n: :u64, m: :u64)
P = BPF::RecordMap.new("P", S.new(0, 0), 1)

def prog(ctx)
  p = P.lookup(0)
  if p
    p.load.n += 1
    p.load.m += 2
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
