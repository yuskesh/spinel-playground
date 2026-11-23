# GPU ホスト API 観測 (P013 Phase 0 / E471) — CUDA driver API の RED を uprobe で OTLP 化
#
# GPU の kernel 起動・転送は、デバイス側でなく **ホスト側の runtime API** に必ず現れる
# (cuLaunchKernel / cuMemcpyHtoD / cuMemcpyDtoH)。そこに uprobe を張れば、GPU ドライバにも
# アプリにも一切手を入れず、起動レート・転送レイテンシが OTLP metrics になる —
# incident_probe (E273) と同じ「観測注射」の GPU ホスト版。
#
#   SPNL_UPROBE_BINARY=<CUDA アプリ or libcuda.so>   (必須, E081)
#   OTLP_ENDPOINT=<collector / SaaS>                 (既定 http://127.0.0.1:4318)
#
# ⚠ 実 NVIDIA HW では SPNL_UPROBE_BINARY に libcuda.so を指す (シンボルはそこに居る)。
#   本リポジトリのハーネス (run_gpu_host_probe.sh) は同名シンボルを持つ mock バイナリで
#   配管全体 (実 uprobe fire → keyed latency → OTLP push → 受信側 decode) を検証する —
#   HW が来たら env を差し替えるだけ。
# ⚠ Metal (macOS) はこの経路の対象外: macOS に eBPF/uprobe は無い。Apple GPU の観測は
#   shim (module GPU) が自前のホスト側なので、必要なら shim 計装が別の道 (P013 note)。

module Otlp
  ffi_func :spnl_otlp_series_label, [:int, :str, :str], :int
  ffi_func :spnl_otlp_metric_push,  [:str, :str],       :int
end

# kernel 起動 — series 0
def uprobe__cuLaunchKernel(f)
  lat_start(0)
end

def uretprobe__cuLaunchKernel(ret)
  hist_observe_by(0, lat_end(0))
end

# Host -> Device 転送 — series 1
def uprobe__cuMemcpyHtoD(dst)
  lat_start(1)
end

def uretprobe__cuMemcpyHtoD(ret)
  hist_observe_by(1, lat_end(1))
end

# Device -> Host 転送 — series 2
def uprobe__cuMemcpyDtoH(dst)
  lat_start(2)
end

def uretprobe__cuMemcpyDtoH(ret)
  hist_observe_by(2, lat_end(2))
end

ep     = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
secs   = (ENV["PROBE_SECONDS"] || "2").to_i
rounds = (ENV["PROBE_ROUNDS"] || "0").to_i   # 0 = 無限 (Ctrl-C で外す)
target = ENV["SPNL_UPROBE_BINARY"] || "unknown"

Otlp.spnl_otlp_series_label(0, "api", "cuLaunchKernel")
Otlp.spnl_otlp_series_label(0, "class", "launch")
Otlp.spnl_otlp_series_label(1, "api", "cuMemcpyHtoD")
Otlp.spnl_otlp_series_label(1, "class", "h2d")
Otlp.spnl_otlp_series_label(2, "api", "cuMemcpyDtoH")
Otlp.spnl_otlp_series_label(2, "class", "d2h")
puts "[gpu-host] observing CUDA driver API in " + target + " -> OTLP " + ep

n = 0
loop do
  sleep secs
  st = Otlp.spnl_otlp_metric_push("gpu_host_calls", ep)
  puts "[gpu-host] gpu_host_calls pushed -> " + ep + " HTTP " + st.to_s
  n = n + 1
  break if rounds > 0 && n >= rounds
end
