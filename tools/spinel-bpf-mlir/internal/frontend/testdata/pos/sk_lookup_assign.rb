require "bpf"

# P026 E129: sk_lookup の sk.assign — local_port の下位 1 bit を key に sockmap Socks の socket を選ぶ (st は sk_assign の status、entry が
# 無ければ −2)。st を Out[0] に、run の数を Out[1] に。判定は常に SK_PASS (選ばなければ通常の lookup)。Socks の socket は user の側が
# map_put で fd を入れる。
Socks = BPF::SockMap.new("Socks", :u64, 2)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def pick(ctx)
  k = ctx.local_port & 1
  st = Socks.assign(ctx, k)
  Out.update(0, st)
  Out.atomic_add(1, 1)
  BPF::SK_PASS
end
BPF.sk_lookup :pick
