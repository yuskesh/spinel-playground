require "bpf"

Counts = BPF::ArrayMap.new("Counts", :u64, 2)

# E092 (P023): 前の user_call.rb (利用者の def の呼び出し — SB002) は段 1 で受理になった。helper の最後の文が map の呼び出し (値でない) の形の SB034 に改めた
def helper
  Counts.atomic_add(0, 1)
end

def prog(ctx)
  helper
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB034 7:3
