# E069/E070 (E330 で C codegen に移植): Ruby で書いた Reno 風 TCP 輻輳制御。
# 検証目的: tcp_congestion_ops struct_ops の load + tcp_sock_* field accessor
# (reader / writer / adder) と sk.<field> dot accessor の codegen 出力を golden で固定。

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
