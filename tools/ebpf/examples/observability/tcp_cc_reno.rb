# examples/observability/tcp_cc_reno.rb
#
# E069 + E070: Reno-like TCP congestion control written in Ruby.
#
# Uses E070's dot-accessor sugar so the math reads like ordinary Ruby
# instead of `tcp_sock_snd_cwnd(sk)` / `tcp_sock_snd_cwnd_add(sk, n)`.
# Under the hood it lowers to the same field reads / writes against
# `struct tcp_sock` that the kernel TCP stack uses.
#
#   slow start          : while cwnd < ssthresh, cwnd += acked
#   congestion avoidance: +1 every cwnd ACKs (cwnd_cnt accumulator)
#   on loss             : ssthresh = cwnd / 2  (floor at 2)
#
# Build:
#   spinel-ebpf compile examples/observability/tcp_cc_reno.rb \
#       -o build/tcp_cc_reno --build
# Run:
#   ./build/tcp_cc_reno/tcp_cc_reno &
#   echo spnl_cc > /proc/sys/net/ipv4/tcp_congestion_control
#   # generate some TCP traffic; watch cwnd grow via `ss -tin`

# struct_ops は class 継承で書く (E330: flat `def tcp_cc__<member>` は SEC("syscall")
# に落ち登録されない — class 形のみ tcp_congestion_ops として register する)。
class RenoCC < BPF::TcpCC
  def init(sk)
    0
  end

  def ssthresh(sk)
    half = sk.snd_cwnd / 2
    if half < 2
      2
    else
      half
    end
  end

  def undo_cwnd(sk)
    sk.prior_cwnd
  end

  def cong_avoid(sk, ack, acked)
    if sk.snd_cwnd < sk.snd_ssthresh
      sk.snd_cwnd += acked
    else
      cnt = sk.snd_cwnd_cnt + acked
      if cnt >= sk.snd_cwnd
        sk.snd_cwnd += 1
        sk.snd_cwnd_cnt = 0
      else
        sk.snd_cwnd_cnt = cnt
      end
    end
  end

  def set_state(sk, new_state)
    0
  end
end

puts "[E069+E070] Reno-like Ruby CC loaded (spnl_cc). echo spnl_cc > /proc/sys/net/ipv4/tcp_congestion_control"
sleep 3600
