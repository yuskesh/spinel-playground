require "bpf"

# P015 E062 H4: 別の u64 の map の値の + 1 を Out に — RMW でない溢れは SB014 のまま
Out = BPF::ArrayMap.new("Out", :u64, 2)
In = BPF::ArrayMap.new("In", :u64, 2)

def prog(ctx)
  q = In.lookup(0)
  if q
    Out.update(0, q.load + 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB014 10:19
