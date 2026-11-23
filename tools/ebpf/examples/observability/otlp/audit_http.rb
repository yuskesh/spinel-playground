# ゼロコード HTTP L7 RED: 他プロセスの HTTP を method/path/status + duration で span 化 (E298)
#
# OBI/Beyla の中核を Ruby で。アプリを 1 行も変えずに、他プロセスの HTTP 通信を **RED**
# (Rate=span 数 / Error=status>=500 / Duration=往復時間) で Splunk APM に載せる。
# E297 の send/recv 相関の上に **HTTP パーサ**を足しただけ。
#
# 仕組み (E297 の sock-keyed 相関を再利用):
#   1. tcp_sendmsg (process ctx): http_req_start が送信バッファ先頭 64B を読み、HTTP リクエスト
#      (本物の method、"HTTP" レスポンスや非 HTTP は除外) なら {start, method/path 生バイト} を
#      sock キーで記録。**server 側の response-send は "HTTP" 始まりなので match しない** →
#      client のリクエストだけを拾う。非 HTTP は span を出さない (誤検出なし)。
#   2. tcp_recvmsg entry: http_resp_stash が {sk, 受信バッファ先頭} を tid キーで stash
#      (レスポンスバイトはコピー後にしか無いので kretprobe で読む。tcp_recvmsg は static
#      linkage で fexit 不可、E297)。
#   3. kretprobe/tcp_recvmsg: http_emit が stash した受信バッファ (status) を読み、sock で
#      リクエストと相関し、**1 span** (method + path + status + duration) を emit。
#      method/path/status のパースは userspace (kernel は bounded copy、DNS/E295 と同型)。
#
# semconv (OBI/Beyla 相互運用): `http.request.method` / `url.path` / `http.response.status_code`
#   (semconv 標準) + `network.peer.address/port` + `process.executable.name`。span 名 "<METHOD> <path>"、
#   kind=CLIENT (curl 視点)、**status>=500 → Span.status=ERROR** (APM で赤、RED の error 軸)。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_http.rb --build -o build/audit_http
#   OTEL_SERVICE_NAME=spinel-e298-http \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_http/audit_http
#   # 別端末で `curl http://<host>/path` を叩くと HTTP GET /path span (status/duration 付き) が出る。
#   # 500 を返すエンドポイントを叩くと span が ERROR (赤) に。
#
# 注意 (実測、E298 Edoc):
#   - system-wide なので client 側の request→response を 1 span に。server 側は method filter で除外。
#   - keep-alive で複数リクエストが 1 sock に順次来る場合、各 request→response が 1 span (E297 の MVP 境界)。
#   - HTTP/2 多重化・pipelining (1 sock に複数リクエスト同時) は E299+。TLS 平文 (SSL_read/write) も E299+。
#   - http.response.status_code は本実装では文字列属性 (汎用 span 経路)。int 化は将来。

module Otlp
  ffi_func :spnl_otlp_http_span_push, [:str], :int
end

def kprobe__tcp_sendmsg(sk, msg, size)
  http_req_start(sk, msg)   # リクエストの method/path を捕捉 (HTTP のみ)
  0
end

def kprobe__tcp_recvmsg(sk, msg)
  http_resp_stash(sk, msg)  # 受信バッファを stash (kretprobe で読む)
  0
end

def kretprobe__tcp_recvmsg(ret)
  http_emit(ret)            # status を読み、相関して 1 span (method/path/status/duration)
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-http] HTTP L7 RED (tcp_sendmsg + kretprobe/tcp_recvmsg) -> OTLP span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_http_span_push(ep)
  puts "[audit-http] http spans pushed -> " + ep + " HTTP " + st.to_s
end
