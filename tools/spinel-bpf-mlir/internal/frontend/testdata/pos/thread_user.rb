require "bpf"
# E049: user の側の Thread (SB012 を外した — 前は neg/thread.rb で SB012)

Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def prog(ctx)
  BPF::XDP_PASS
end
BPF.xdp :prog

t = Thread.new { 1 }
puts t.value
