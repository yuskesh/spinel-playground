require "bpf"

# P026 E128: netfilter の宣言に余分な引数 (hook は user の側の attach の引数)
def p(ctx)
  BPF::NF_ACCEPT
end
BPF.netfilter :p, :x
# want: SB008 7:1
