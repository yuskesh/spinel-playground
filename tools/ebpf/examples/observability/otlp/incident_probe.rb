# インシデント対応「ワンショット観測注射」— 既存プロセスを uprobe → RED を Splunk 直送 (E273)
#
# 障害中の本番プロセスに、エージェント常駐も再デプロイもなしで eBPF プローブを一時的に
# 「注射」し、対象関数の呼び出しレート + レイテンシ (RED) を OTLP metrics として送る。
# 見終わったら Ctrl-C で外すだけ。Collector も不要 (Splunk Observability Cloud に直送可)。
#
#   uprobe/uretprobe   … 対象バイナリ内の関数 (下記 handle_request) を入口/出口で hook。
#                        対象バイナリ/PID は実行時 env で選ぶ:
#                          SPNL_UPROBE_BINARY=/path/to/target   (必須, E081)
#                          SPNL_UPROBE_PID=<pid>                (任意, 既定 -1 = system-wide, E081/E087)
#                        観測する「関数名」は uprobe__ の接尾で固定 (別関数を見るなら再コンパイル)。
#   latency_start/end  … tid keyed の entry->exit 差分 (E083)。
#   hist_observe_by(0)  … series key 0 の log2 keyed-hist に latency を積む (E085)。overflow 免疫。
#   spnl_otlp_series_label / spnl_otlp_metric_push … series 0 にラベルを付けて OTLP metrics 化 (E271)。
#
# ── ビルド (container 内) ───────────────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/incident_probe.rb --build -o build/incident
#
# ── Splunk 直送 (実運用: サクッと一時観測) ───────────────────────────────
#   # static ビルドして対象ホストに scp し、Collector なしで SaaS に直送:
#   SPNL_STATIC=1 bin/spinel-ebpf compile examples/observability/otlp/incident_probe.rb --build -o build/incident
#   scp build/incident/incident_probe user@host.example:/tmp/
#   ssh user@host.example \
#     'SPNL_UPROBE_BINARY=/usr/bin/myapp \
#      OTLP_ENDPOINT=https://ingest.us1.signalfx.com \
#      OTEL_EXPORTER_OTLP_HEADERS="x-sf-token=$SPLUNK_TOKEN" \
#      OTEL_EXPORTER_OTLP_COMPRESSION=gzip \
#      sudo -E /tmp/incident_probe'
#   # → incident_calls (rate) と incident_calls_latency_ns (ExponentialHistogram) が
#   #   Splunk に {function, target} ラベル付きで流れる。置いて、見て、消す。
#   # 本番常設は Collector 経由を推奨 (ADR-013): 直送は短時間のインシデント調査向け。

module Otlp
  ffi_func :spnl_otlp_series_label, [:int, :str, :str], :int
  ffi_func :spnl_otlp_metric_push,  [:str, :str],       :int
end

# 対象関数の入口/出口。デモの検証ターゲットは C の handle_request()。
# 別の関数を観測したい場合はこのメソッド名 (uprobe__/uretprobe__ の接尾) を変えて再コンパイル。
def uprobe__handle_request(arg0)
  latency_start
end

def uretprobe__handle_request(ret)
  hist_observe_by(0, latency_end)
end

ep     = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
secs   = (ENV["PROBE_SECONDS"] || "2").to_i
target = ENV["SPNL_UPROBE_BINARY"] || "unknown"

# series key 0 に RED のラベルを付与 (OTLP data point の attributes になる)。
Otlp.spnl_otlp_series_label(0, "function", "handle_request")
Otlp.spnl_otlp_series_label(0, "target", target)
puts "[incident] observing handle_request in " + target + " -> OTLP " + ep + " every " + secs.to_s + "s"

loop do
  sleep secs
  st = Otlp.spnl_otlp_metric_push("incident_calls", ep)
  puts "[incident] incident_calls pushed -> " + ep + " HTTP " + st.to_s
end
