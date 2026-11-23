require "bpf"

# P026 E128: netfilter の context に len (整数の field は無い — sk_buff の len は ctx.skb(T) から)
Out = BPF::ArrayMap.new("Out", :u32, 1)

def p(ctx)
  Out.update(0, ctx.len)
  BPF::NF_ACCEPT
end
BPF.netfilter :p
# want: SB028 7:17
