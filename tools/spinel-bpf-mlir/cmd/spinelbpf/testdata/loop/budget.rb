require "bpf"

# P015 E060: 64 回の本体に map の atomic_add 12 個 — frontend は通り、ebpf-compile の (U) の展開の見積もり (4096 op) が止める → build が SB030 に包む
C = BPF::ArrayMap.new("C", :u64, 12)

def prog(ctx)
  64.times do |i|
    C.atomic_add(0, i)
    C.atomic_add(1, i)
    C.atomic_add(2, i)
    C.atomic_add(3, i)
    C.atomic_add(4, i)
    C.atomic_add(5, i)
    C.atomic_add(6, i)
    C.atomic_add(7, i)
    C.atomic_add(8, i)
    C.atomic_add(9, i)
    C.atomic_add(10, i)
    C.atomic_add(11, i)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
