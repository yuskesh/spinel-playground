# L7 request/response レイテンシ span (他プロセスの TCP 通信の往復時間) — E297
#
# 「リクエストを送ってレスポンスが返るまで」を **プロトコル非依存**で測り、span の
# **duration = L7 往復レイテンシ** として Splunk APM に載せる。E294/E296 の connect span は
# duration=0 (接続イベント) だったが、E297 は **duration が本体**。
#
# 仕組み (E296 の sock-keyed 相関を send/recv に発展):
#   1. tcp_sendmsg (process ctx) で **リクエストの最初の送信時刻**を sock ptr キーで記録 (req_start)。
#      同一リクエストの複数 send は上書きしない (最初の 1 回だけ = リクエスト開始時刻)。
#   2. tcp_cleanup_rbuf (**データがアプリにコピーされた後** = レスポンスが見えた時) で
#      req_start を引き、delta = **往復レイテンシ**を span 化 (emit_l7)、エントリを削除
#      (次の send = 次のリクエスト)。
#
# なぜ tcp_cleanup_rbuf か (実測、E297):
#   - tcp_recvmsg の **entry** kprobe は「アプリが read を呼んだ時」= データ到着前にブロック
#     するので delta ≈ 0 (誤り)。tcp_recvmsg は static linkage で fexit も不可 (-EPERM)。
#   - tcp_cleanup_rbuf は tcp_recvmsg の内部で **データコピー後**に呼ばれる = 「レスポンスが
#     アプリに見えた時」= 意味的に正しい L7 recv 点。実測: 500ms 遅延サーバで duration≈500ms。
#
# MVP 境界: 1 リクエスト = 1 送信バースト、1 レスポンス = 直後の受信。**pipelining /
#   HTTP/2 多重化 (1 sock に複数リクエスト同時) は E298+**。まず単純 request/response で成立。
#
# semconv: レイテンシは **span の duration** が正道 (srtt=L4 継続 RTT とは別物)。process は
#   E296 と同じく send 時 (process ctx) の実プロセス。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_l7.rb --build -o build/audit_l7
#   OTEL_SERVICE_NAME=spinel-e297-l7 \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_l7/audit_l7
#   # 別端末で `curl http://<host>/` を叩くと、その request→response の往復が
#   # span (duration=実レイテンシ) になる。遅いエンドポイントほど duration が伸びる。
#
# 注意 (実測、E297 Edoc):
#   - system-wide なので client 側と server 側の両ソケットを拾う (両方とも実 send→recv 往復)。
#   - 多重化 (HTTP/2) は 1 sock に複数リクエストが同時に出るので MVP の「1 往復」定義が崩れる (E298+)。
#   - TLS 平文 (SSL_read/write) や L7 プロトコルパース (method/path/status) は E298+。

module Otlp
  ffi_func :spnl_otlp_l7_span_push, [:str], :int
end

def kprobe__tcp_sendmsg(sk, msg, size)
  req_start(sk)   # process ctx: リクエスト開始時刻を sock キーで記録
  0
end

def kprobe__tcp_cleanup_rbuf(sk, copied)
  if i32(copied) > 0   # copied は 32bit int。i32() で正しく読む (kprobe arg の上位32bitはゴミ)
    emit_l7(sk)        # データがアプリにコピーされた (レスポンスが見えた) -> 往復レイテンシを span 化
  end
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-l7] L7 request/response latency (tcp_sendmsg -> tcp_cleanup_rbuf) -> OTLP span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_l7_span_push(ep)
  puts "[audit-l7] l7 spans pushed -> " + ep + " HTTP " + st.to_s
end
