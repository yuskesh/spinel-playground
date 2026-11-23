# E242 PoC: ユーザ空間 consumer — eBPF イベントを Ruby で処理する。
#
# 設計の核(spinel-Ruby userspace が emit されたイベントを Ruby ロジックで集計)を
# 手書き最小形で実証する。将来の `on_emit do |v| ... end` DSL は、この
# ボイラープレート(ffi_func drain + 駆動ループ)を codegen で隠蔽したもの。
#
# build:  bin/spinel-ebpf compile examples/observability/consume_poc.rb --build --ebpf-dispatch -o build
# run:    ./build/consume_poc        # -> 10 (=0+1+2+3+4) then 5 (event count)
#
# 仕組み:
#   - produce(5) は :ebpf + transparent dispatch (E028)。bpf_prog_test_run で
#     カーネル側 BPF プログラムを実行し、0..4 を per-unit ringbuf に spnl_emit。
#   - spnl_cdrain / spnl_cget は glue 提供の FFI(spinel->glue 方向)。ringbuf を
#     drain して静的バッファに集め、Ruby から値を取り出す。
#   - 集計は top-level ivar(@sum)= 共有 native global。consumer ロジックは
#     userspace なので verifier 制約なし(フル Ruby)。
module Consume
  ffi_func :spnl_cdrain, [:int], :int   # drain int-emit ringbuf, returns count
  ffi_func :spnl_cget,   [:int], :int   # value of buffered event i
end

@sum = 0

def produce(n)
  n.times { |i| spnl_emit(i) }
end

produce(5)
cnt = Consume.spnl_cdrain(200)
i = 0
while i < cnt
  @sum = @sum + Consume.spnl_cget(i)
  i = i + 1
end
puts @sum
puts cnt
