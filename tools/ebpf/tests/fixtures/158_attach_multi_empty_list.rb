# E401: 空のシンボルリスト。何にも attach されない handler は
# 「load はするが一生発火しないプログラム」なので落とす (ADR-003)。
module FileOps
  include BPF::EventLoop

  on :kprobe, %w[] do
    @n = @n + 1
  end
end
