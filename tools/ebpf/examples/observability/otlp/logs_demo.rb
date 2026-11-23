# P003 S4: emit -> OTLP logs demo.
#
# produce(n) は transparent dispatch (E028) 経由で BPF を実行し、0,10,..,(n-1)*10 を
# per-unit emit ringbuf に spnl_emit する。spnl_otlp_log_push がそれを drain して各イベントを
# OTLP LogRecord (body=int) にし、Collector に POST する。--instrument 非依存の汎用パス。
#
# build: bin/spinel-ebpf compile examples/observability/otlp/logs_demo.rb --build --ebpf-dispatch -o build
# run:   OTLP_ENDPOINT=http://127.0.0.1:4318 ./build/logs_demo
module Otlp
  ffi_func :spnl_otlp_log_push, [:str], :int
end

def produce(n)
  n.times { |i| spnl_emit(i * 10) }
end

produce(5)
ep = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
st = Otlp.spnl_otlp_log_push(ep)
puts "[logs_demo] OTLP logs push -> " + ep + " HTTP " + st.to_s
