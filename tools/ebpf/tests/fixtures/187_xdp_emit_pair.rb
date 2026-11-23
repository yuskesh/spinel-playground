# E155: XDP から pair record を emit する垂直スライス。
#
# MLIR backend (spbpf dialect) が表現できる範囲 — xdp program + ringbuf への
# 定数 pair emit — に絞った、イベント列差動 (現行 .bpf.o vs MLIR .bpf.o) の
# 対象 unit。packet ごとに (7, 9) を 1 record 送り、XDP_PASS を返す。
#
# 定義は 24_xdp_counter と同じく CRuby としても有効な形に保つ。

XDP_ABORTED  = 0
XDP_DROP     = 1
XDP_PASS     = 2
XDP_TX       = 3
XDP_REDIRECT = 4

def xdp__main
  spnl_emit_pair(7, 9)
  XDP_PASS
end

# consumer: 受けた pair を数えて読み上げる (E242 の on_emit_pair 面)。
@pairs = 0
@last_a = 0
@last_b = 0
on_emit_pair do |a, b|
  @pairs = @pairs + 1
  @last_a = a
  @last_b = b
end

sleep 2
consume_events(200)
puts @pairs
puts @last_a
puts @last_b
