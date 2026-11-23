# off-CPU / kernel-wait を L7 span に相関: 「span が遅い理由 = 何を待っていたか」を span に (E300)
#
# E297-299 は「イベントを span 化」だった。E300 は **L7 リクエストの処理時間の内訳 (どこで待ったか)**
# を出す。「/slow が 309ms 遅いのは実は disk I/O を待っていた / ロック競合だった / CPU を回していた」まで
# 見せる。eBPF 固有で OBI/Pixie も弱い領域。E091 off-CPU + E297/E298 の request-window の結合。
#
# 仕組み (SERVER 視点、1 スレッド 1 リクエスト):
#   1. tcp_recvmsg (リクエスト到着): offcpu_recv_stash が受信バッファを stash、offcpu_begin (kretprobe)
#      が HTTP リクエストなら **その処理 tid の off-CPU 窓を開く** (start + req[64])。
#   2. sched:sched_switch: offcpu_account が、窓が開いている tid について **voluntary off-CPU
#      (prev_state != 0) の合計**を積み、**待ちの kernel stack** (なぜ寝たか) を捕まえる。
#   3. tcp_sendmsg (レスポンス送出): offcpu_emit が窓を閉じ、method/path/status/duration に
#      **spnl.offcpu_ns / spnl.oncpu_ns (= duration - offcpu) / spnl.wait.kind** を足して span 化。
#
# これで L7 span が「遅い + なぜ遅い」を持つ = RED の Duration に内訳が付く。実測:
#   /sleep (nanosleep 300ms) -> offcpu≈duration, wait.kind=sleep
#   /spin  (CPU 300ms)        -> offcpu≈0,        wait.kind=none  (= CPU-bound)
#   /io    (fsync)            -> offcpu が I/O 待ち分  (wait.kind=io、ストレージ次第)
#
# semconv: `spnl.offcpu_ns`/`spnl.oncpu_ns`/`spnl.wait.kind` は独自 (semconv に該当なし、明記)。
#   http.* は E298 と共通。span.kind=SERVER (リクエストハンドラを観測)。status>=500 -> ERROR。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_offcpu.rb --build -o build/audit_offcpu
#   OTEL_SERVICE_NAME=spinel-e300-offcpu \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_offcpu/audit_offcpu
#   # 観測対象は OpenSSL でない平文 HTTP サーバ (nginx/gunicorn 等)。遅い span を APM で開くと
#   # 待ち内訳 (off-CPU=I/O/sleep か、on-CPU=CPU-bound か) が見える。
#
# 注意 (実測、E300 Edoc):
#   - system-wide。SERVER 視点 (recv=request, send=response)。1 リクエスト=1 ハンドラ tid が前提。
#   - sched_switch は全 CPU スイッチで発火する高頻度フック。オーバーヘッドは要測定 (性能は未検証)。
#   - フルスタック (flame graph) は E301+。wait.kind は最後の待ちのスタックを top-frame 分類 (best-effort)。

module Otlp
  ffi_func :spnl_otlp_offcpu_span_push, [:str], :int
end

def kprobe__tcp_recvmsg(sk, msg)
  offcpu_recv_stash(sk, msg)   # リクエスト受信バッファを stash
  0
end

def kretprobe__tcp_recvmsg(ret)
  offcpu_begin(ret)            # HTTP リクエストなら off-CPU 窓を開く
  0
end

def tracepoint__sched__sched_switch(prev_pid, prev_state, next_pid)
  offcpu_account(prev_pid, prev_state, next_pid)   # 窓中の voluntary off-CPU を積む
  0
end

def kprobe__tcp_sendmsg(sk, msg)
  offcpu_emit(sk, msg)         # レスポンス送出で窓を閉じ、内訳付き span を emit
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-offcpu] L7 request off-CPU breakdown (why slow) -> OTLP span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_offcpu_span_push(ep)
  puts "[audit-offcpu] offcpu spans pushed -> " + ep + " HTTP " + st.to_s
end
