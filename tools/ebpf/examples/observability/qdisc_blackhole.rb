# examples/observability/qdisc_blackhole.rb
#
# E095: Ruby で書いた BPF qdisc — blackhole (全パケット drop).
#
# 動作: enqueue で全パケットを bpf_qdisc_skb_drop に流して即 drop、
# dequeue は NULL を返す。tc 経由で interface に attach すると、その
# interface 経由のパケットが全部消える (= ping 100% loss)。
#
# Build:
#   bin/spinel-ebpf compile examples/observability/qdisc_blackhole.rb \
#                   -o build/qd --build
# Run:
#   ./build/qd/qdisc_blackhole &
#   bpftool struct_ops list           # spnl_qdisc が見える
#   ip link add dummy0 type dummy && ip link set dummy0 up
#   tc qdisc add dev dummy0 root handle 1: spnl_qdisc
#   ping -I dummy0 -c 5 192.0.2.1     # 100% loss (qdisc が全 drop)
#   bpftool map dump name qdisc_blackh_to  # @dropped が増える

class BlackHole < BPF::Qdisc
  # enqueue MUST release the skb reference (via bpf_qdisc_skb_drop)
  # — without it the verifier refuses the program with "Unreleased
  # reference … leads to reference leak". init/reset/destroy stay
  # body-empty (init_prologue / reset_destroy_epilogue are kfuncs that
  # the verifier flags as "not allowed" from this struct_ops member —
  # they're recommended for tracking stats but optional for liveness).
  def init(sch, opt, extack)
    0
  end

  def enqueue(skb, sch, to_free)
    @dropped = @dropped + 1
    qdisc_skb_drop(skb, to_free)
    1  # NET_XMIT_DROP
  end

  def dequeue(sch)
    0  # NULL — queue is always empty
  end

  def reset(sch)
    0
  end

  def destroy(sch)
    0
  end
end

@dropped = 0

puts "[E095] qdisc_blackhole (spnl_qdisc) loaded"
puts "       tc qdisc add dev <iface> root handle 1: spnl_qdisc"
sleep 3600
