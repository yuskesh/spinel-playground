# E242: userspace consumer DSL (on_emit). spinel-ebpf が on_emit/consume_events
# をプレーン Ruby に lower し、glue の drain FFI を挟む。手書き版 consume_poc.rb と
# 同じ結果(@sum=10)を、ボイラープレートなしの DSL で得る。
#
# build: bin/spinel-ebpf compile examples/observability/consume_dsl.rb --build --ebpf-dispatch -o build
# run:   ./build/consume_dsl    # -> 10  (= 0+1+2+3+4)
@sum = 0

def produce(n)
  n.times { |i| spnl_emit(i) }    # :ebpf, dispatch で 0..n-1 を emit
end

on_emit do |v|                    # userspace consumer (emit 1 件ごと)
  @sum = @sum + v
end

produce(5)
consume_events(200)               # drain + 各イベントを on_emit ハンドラへ
puts @sum
