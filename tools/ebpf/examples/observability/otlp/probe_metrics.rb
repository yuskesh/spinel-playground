# B (E271): 既存プロセスに eBPF プローブを付けて観察し、OTLP メトリクスで送るデモ。
#
# kprobe (system-wide、pid フィルタも可) で do_sys_openat2 の latency を観測し、
# series key 0 に任意ラベル (function / probe) を付けて OTLP metrics
# (openat_calls = rate, openat_calls_latency_ns = latency) として push する。
# --instrument 非依存 (自己計装メソッドレジストリを使わない、汎用 keyed メトリクス)。
# uprobe で外部バイナリの関数を pid 指定で観測する場合も同じ push 経路で OTLP 化できる。
#
# build: bin/spinel-ebpf compile examples/observability/otlp/probe_metrics.rb --build -o build
# run:   OTLP_ENDPOINT=http://127.0.0.1:4318 PROBE_SECONDS=2 ./build/probe_metrics
module Otlp
  ffi_func :spnl_otlp_series_label, [:int, :str, :str], :int
  ffi_func :spnl_otlp_metric_push,  [:str, :str],       :int
end

def kprobe__do_sys_openat2(dfd, name)
  latency_start
end

def kretprobe__do_sys_openat2(ret)
  hist_observe_by(0, latency_end)
end

ep   = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
secs = (ENV["PROBE_SECONDS"] || "2").to_i

# series key 0 のラベル (任意。function/pid/comm 等を好きに付けられる)
Otlp.spnl_otlp_series_label(0, "function", "do_sys_openat2")
Otlp.spnl_otlp_series_label(0, "probe", "kprobe")
puts "[probe] observing do_sys_openat2 -> OTLP " + ep + " every " + secs.to_s + "s"

loop do
  sleep secs
  st = Otlp.spnl_otlp_metric_push("openat_calls", ep)
  puts "[probe] openat_calls pushed -> " + ep + " HTTP " + st.to_s
end
