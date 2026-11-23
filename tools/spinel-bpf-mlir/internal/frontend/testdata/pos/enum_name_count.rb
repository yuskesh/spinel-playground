require "bpf"
# E056: Enumerable の method の名前 (count) で Spinel が builtins を継ぎ込む program — 行のずれを補正して受ける (E055 では SB000)

Counts = BPF::ArrayMap.new("Counts", :u64, 2)

def prog(ctx)
  Counts.atomic_add(0, 1)
  BPF::XDP_PASS
end
BPF.xdp :prog

def count(x)
  x + 1
end
puts count(1)
