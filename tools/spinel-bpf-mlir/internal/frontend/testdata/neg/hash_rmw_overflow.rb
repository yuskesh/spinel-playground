require "bpf"

# P015 E062 H3: u64 の hash の同じ entry の read-modify-write の値に溢れる + 1 — 直しの前は SB014 が RMW を隠した
H = BPF::HashMap.new("H", :u32, :u64, 16)

def prog(ctx)
  p = H.lookup(1)
  if p
    _ = H.update(1, p.load + 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 9:9
