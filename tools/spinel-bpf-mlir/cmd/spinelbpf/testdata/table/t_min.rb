require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 11)

def prog(ctx)
  m = -9223372036854775807 - 1
  Out.update(0, m / 8)
  Out.update(1, m % 8)
  Out.update(2, m >> 1)
  Out.update(3, m & 255)
  Out.update(4, m ^ -1)
  Out.update(5, m / -8)
  Out.update(6, m % -8)
  Out.update(7, m < 0 ? 1 : 0)
  Out.update(8, m + 1)
  Out.update(9, m | 1)
  Out.update(10, m)
  BPF::XDP_PASS
end
BPF.xdp :prog
