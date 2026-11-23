# examples/observability/full_observability_demo.rb
#
# E076-E079: reactor DSL の "全部入り" demo。1 つの module で 6 種の event
# 源を同時 handle、共通 ivar に counter / state を集約、bpf_timer で periodic
# dump も走らせる。Sinatra app のような感覚で書ける kernel-side observability
# suite の最終形。
#
# 構成:
#   - on :xdp                          ─ NIC 入力 packet (+ user_ringbuf drain)
#   - on :sock_ops                     ─ cgroup-scoped TCP state 遷移
#   - on :kprobe, "do_sys_openat2"     ─ file open syscall
#   - on :tracepoint, "sched", "..."   ─ context switch
#   - on :user_cmd do |cmd|            ─ userspace から libbpf push
#   - on :timer, every: 1.seconds      ─ kernel-side periodic
#
# Build:
#   spinel-ebpf compile examples/observability/full_observability_demo.rb \
#       -o build/full_observability --build
#
# Run:
#   mount -t tracefs nodev /sys/kernel/tracing            # 必要なら 1 度だけ
#   SPNL_XDP_IFACE=lo SPNL_CGROUP_PATH=/sys/fs/cgroup \
#     ./build/full_observability/full_observability_demo &
#
#   # 各 event 源を発火:
#   ping -c 5 -q 127.0.0.1                # → xdp + sock_ops + kprobe + sched
#   ls /etc /tmp /usr >/dev/null          # → kprobe (open)
#   /tmp/push_one $(bpftool map list | awk '/bpf_user_cmds/{sub(":","",$1);print $1}') 42
#                                          # → user_cmd
#   sleep 3                                # → timer (~3 ticks)
#
#   # 全 counter を確認 — ただし名前では引けない:
#   # カーネルが保持する map 名は 15 文字までなので、この probe の ivar 7 本は
#   # どれも `full_observabil` に潰れて名前で区別できない。id で 1 本ずつ引く:
#   bpftool map show | grep full_observabil     # 7 つの id が出る
#   bpftool map dump id <上で出た id>            # どれがどれかは値で判断する

@rx_total      = 0
@tcp_connects  = 0
@open_count    = 0
@ctx_switches  = 0
@cmds_received = 0
@last_cmd      = 0
@ticks         = 0

module FullObservability
  include BPF::EventLoop

  # NOTE: `on :user_cmd` を `on :xdp` より上に書くこと。XDP handler が
  # user_ringbuf_drain を呼ぶ時点で callback 名が必要なため、partition の
  # enumerate 順 (= ソース順) で callback が先に定義されてる必要がある。
  # 将来の codegen 改善で pre-scan できるようになれば順序自由になる。

  # ── 入力 1: userspace control channel (libbpf user_ringbuf push)
  on :user_cmd do |cmd|
    @cmds_received = @cmds_received + 1
    @last_cmd = cmd
  end

  # ── 入力 2: NIC packet (XDP hook)
  # 副作用: user_ringbuf を drain して on :user_cmd を pump
  on :xdp do
    @rx_total = @rx_total + 1
    user_ringbuf_drain
    XDP::PASS
  end

  # ── 入力 3: TCP state 遷移 (cgroup-scoped SOCK_OPS)
  on :sock_ops do
    if sock_ops_op == BPF::SockOps::TCP_CONNECT_CB
      @tcp_connects = @tcp_connects + 1
    end
  end

  # ── 入力 4: kprobe — file open syscall
  on :kprobe, "do_sys_openat2" do
    @open_count = @open_count + 1
  end

  # ── 入力 5: tracepoint — context switch
  on :tracepoint, "sched", "sched_switch" do
    @ctx_switches = @ctx_switches + 1
  end

  # ── 入力 6: 時間軸 (bpf_timer, kernel-side periodic)
  on :timer, every: 1.seconds do
    @ticks = @ticks + 1
  end
end

puts "[E076-E079] FullObservability loaded — 6 event sources active in 1 module"
puts "[E076-E079]  trigger each source, then read the counters by map id (see the header)"
sleep 3600
