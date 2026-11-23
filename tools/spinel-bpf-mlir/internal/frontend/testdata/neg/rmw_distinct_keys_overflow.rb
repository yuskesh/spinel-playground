require "bpf"

# P015 E062 H4: 同じ map の違う literal の key (受ける形 — RMW でない) の値の + 1 の溢れは SB014 のまま
Out = BPF::ArrayMap.new("Out", :u64, 2)

def prog(ctx)
  p = Out.lookup(0)
  if p
    Out.update(1, p.load + 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB014 9:19
