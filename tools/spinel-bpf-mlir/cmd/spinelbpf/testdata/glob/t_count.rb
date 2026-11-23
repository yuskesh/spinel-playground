require "bpf"

# E059 (P014): global の counter の並行の保存則 — packet ごとに Hits に 1、Bytes に byte 1 を atomic に (Thread の harness の並行の test run)。
Hits = BPF::Counter.new("Hits", :u64)
Bytes = BPF::Counter.new("Bytes", :u32)

def prog(ctx)
  w = ctx.check(0, 14)
  if w
    Hits.add(1)
    Bytes.add(w.u8(1))
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
