# examples/observability/qdisc_fifo.rb
#
# E096: 本物の FIFO BPF qdisc — bpf_list で packet を実際に queue + dequeue。
#
# E095 (blackhole) は packet を全部 drop していたが、E096 は queue_push /
# queue_pop builtin の裏で:
#   - bpf_obj_new でラッパー struct を alloc
#   - bpf_kptr_xchg で skb のオーナーシップを安全に移譲
#   - bpf_spin_lock 経由で bpf_list_push_back / bpf_list_pop_front
#   - bpf_obj_drop でラッパーを返却
# を行い、kernel の network stack に正しく packet を pass する。
#
# Build:
#   bin/spinel-ebpf compile examples/observability/qdisc_fifo.rb \
#                   -o build/qf --build
# Run:
#   ./build/qf/qdisc_fifo &
#   tc qdisc add dev lo root handle 1: spnl_qdisc
#   ping -c 5 127.0.0.1                     # 5 packets all pass through!
#   tc -s qdisc show dev lo                  # Sent X bytes Y pkt (dropped 0)
#   # カーネルが保持する map 名は 15 文字までなので、@enqueued / @dequeued の
#   # 2 本はどちらも `qdisc_fifo_top_` に見えて名前では区別できない。id で引く:
#   bpftool map show | grep qdisc_fifo_top_
#   bpftool map dump id <上で出た id>

class FifoQdisc < BPF::Qdisc
  def init(sch, opt, extack)
    0
  end

  def enqueue(skb, sch, to_free)
    @enqueued = @enqueued + 1
    queue_push(skb, to_free)  # NET_XMIT_SUCCESS (0) or NET_XMIT_DROP (1)
  end

  def dequeue(sch)
    @dequeued = @dequeued + 1
    skb = queue_pop  # struct sk_buff * (cast to __s64; 0 = NULL = queue empty)
    if skb != 0
      # E097: update Qdisc bstats so `tc -s qdisc show` reports accurate
      # Sent bytes / packets counts (instead of always 0).
      qdisc_bstats_update(sch, skb)
    end
    skb
  end

  def reset(sch)
    0
  end

  def destroy(sch)
    0
  end
end

@enqueued = 0
@dequeued = 0

puts "[E096] qdisc_fifo (spnl_qdisc) loaded — actual FIFO queue, not blackhole"
puts "       tc qdisc add dev <iface> root handle 1: spnl_qdisc"
sleep 3600
