require "bpf"

Counts = BPF::ArrayMap.new("Counts", :u64, 2)
Small = BPF::ArrayMap.new("Small", :u32, 1073741823) # P010 E041: bpf-mlir v0.17.0 の上限 (1073741823 を超える map は kernel が BTF を拒否 — C の loader は btf_dropped で止める)

def prog(ctx)
  Small.atomic_add(1073741822, 4294967295) # key は map の範囲の上の境界 (E008 の意図)
  Counts.atomic_add(1, 9223372036854775807)
  Small.update(0, 4294967295)
  p = Small.lookup(3)
  if p
    Small.update(1, p.load)
  else
    Counts.atomic_add(1, 0)
  end
  return BPF::XDP_DROP
end
BPF.xdp :prog
