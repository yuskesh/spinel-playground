require "bpf"

# P026 E126: socket_filter の context に tracing の API
Out = BPF::ArrayMap.new("Out", :u64, 1)

def p(skb)
  Out.update(0, skb.arg(1))
  BPF::SF_KEEP
end
BPF.socket_filter :p
# 予測は SB002 (E126 H3) — packet を持たない context の読みは tracing の kind と同じ SB028 (E126 追補 1)
# want: SB028 7:17
