# examples/observability/scx_simple.rb
#
# E094: Ruby で書いた Linux CPU スケジューラ (scx_simple equivalent).
#
# struct_ops/sched_ext_ops の本物の attach で、kernel の sched_ext
# サブシステムに **Ruby で書いた scheduler を登録 + 有効化** する。
#
# 動作:
#   - enqueue: 新しく runnable になった task を global DSQ に投入
#   - dispatch: idle CPU の local DSQ に global DSQ から consume
#   - init: スケジューラ起動時の初期化 (今は 0 を返すだけ)
#
# Build:
#   bin/spinel-ebpf compile examples/observability/scx_simple.rb \
#                   -o build/scx --build
# Run (要 root):
#   sudo ./build/scx/scx_simple &
#   # libbpf が struct_ops.link を attach → kernel が自動的に
#   # spnl_sx スケジューラを有効化
#   cat /sys/kernel/sched_ext/state          # → "enabled"
#   cat /sys/kernel/sched_ext/root/ops       # → "spnl_sx"
#   # ワークロードを動かす:
#   stress-ng --cpu 8 --timeout 10
#   # Ctrl+C で終了 → libbpf が link を destroy → kernel が
#   # スケジューラを無効化、ビルトイン CFS/EEVDF に戻る

# Recent sched_ext kernels disallow dsq_move_to_local directly on
# SCX_DSQ_GLOBAL; tasks must transit through a user-created DSQ. Use
# integer 0 inline (top-level Ruby constants aren't yet supported by
# spinel-ebpf's partition).

class SimpleScx < BPF::SchedExt
  def init
    scx_create_dsq(0, -1)
    0
  end

  def enqueue(p, enq_flags)
    scx_dispatch(p, 0, SCX::SLICE_DFL, enq_flags)
  end

  def dispatch(cpu, prev)
    scx_consume(0)
  end
end

puts "[E094] scx_simple (spnl_sx) — a sched_ext scheduler written in Ruby"
puts "       cat /sys/kernel/sched_ext/state to verify it's enabled"
sleep 3600
