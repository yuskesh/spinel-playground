# E242 #3: 名前付き emit — emit 元を名前で区別する。
#
# `emit :NAME, value`(producer)は spnl_emit_pair(<name tag>, value) に lower
# され、`on_emit :NAME do |v|`(consumer)は pair ringbuf を tag で振り分けて
# 該当ハンドラに dispatch する。同じ kind(pair)の複数 emit 元を名前で区別
# できる(数値 per-site タグの代替・OBI 的な「どのプローブの値か」を解決)。
#
# 制約(MVP): `emit :NAME, <単一値>` は文(独立行)で書く。1 イベント 1 値。
# 名前付きと生 on_emit_pair は混在不可(どちらも pair ringbuf を使う)。
#
# build: bin/spinel-ebpf compile examples/observability/named_demo.rb --build --ebpf-dispatch -o build
# run:   ./build/named_demo     # -> 6 (http) then 300 (tcp)
# 内省:  bin/spinel-ebpf describe examples/observability/named_demo.rb
@http = 0
@tcp  = 0

def produce(n)
  n.times do |i|
    emit :http_open, (i + 1)     # 1,2,3 -> :http_open
  end
  n.times do |i|
    emit :tcp_send, 100          # 100 x n -> :tcp_send
  end
end

on_emit :http_open do |v|
  @http = @http + v
end

on_emit :tcp_send do |v|
  @tcp = @tcp + v
end

produce(3)
consume_events(200)
puts @http     # 1+2+3 = 6
puts @tcp      # 100*3 = 300
