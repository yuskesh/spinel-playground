require "bpf"

# P014 E057: 使われない global (宣言だけ) — SB013 の Conditional で ELF・schema・maps.json・表に出ない
Counts = BPF::ArrayMap.new("Counts", :u64, 2)
Unused = BPF::Counter.new("Unused", :u64)

def prog(ctx)
  Counts.atomic_add(0, 1)
  BPF::XDP_PASS
end
BPF.xdp :prog
