require "bpf"
S = Struct.new(:n64, :n32, :n8, :_pad0, :_pad1, :_pad2)
BPF.record(S, n64: :u64, n32: :u32, n8: :u8, _pad0: :u8, _pad1: :u8, _pad2: :u8)
M = BPF::PerCpuRecordMap.new("M", S.new(0, 0, 0, 0, 0, 0), 2)
def prog(ctx)
  p = M.lookup(0)
  if p
    p.load.n64 += 1
    p.load.n32 -= 1
    p.load.n8 += 255
    p.load.n8 -= 1
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
