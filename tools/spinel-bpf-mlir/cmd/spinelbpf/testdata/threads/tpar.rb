require "bpf"

# E050 (P012): Thread の入力の双子の差動 — packet の byte 0 の下位 3 bit を key に数と byte 1 の和を atomic に (順に依らない)。
# Slots は user 空間の並行の map_put (ppoke) の的 (eBPF の側も触れて ELF に入れる)。
Counts = BPF::ArrayMap.new("Counts", :u64, 8)
Sums = BPF::ArrayMap.new("Sums", :u64, 8)
Slots = BPF::ArrayMap.new("Slots", :u64, 64)

def prog(ctx)
  w = ctx.check(0, 14)
  if w
    k = w.u8(0) & 7
    Counts.atomic_add(k, 1)
    Sums.atomic_add(k, w.u8(1))
  end
  Slots.atomic_add(63, 0)
  BPF::XDP_PASS
end
BPF.xdp :prog
