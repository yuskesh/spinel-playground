# TLS 平文 span: 暗号化された HTTPS 通信の中身を復号せず span 化 (E299)
#
# E298 の HTTP パーサに **SSL_write/SSL_read uprobe の平文**を流すだけ。curl 等 OpenSSL 系
# アプリの HTTPS を、**アプリを 1 行も変えず・鍵も復号もなしに** method/path/status +
# duration で Splunk APM に載せる (`sslsniff` の手法)。E298 の tcp path では :443 は暗号文
# しか見えない — この対照が「なぜ SSL uprobe が要るか」の証明。
#
# 仕組み (E298 の器を再利用、フック/キーだけ変える):
#   1. SSL_write(ssl, buf, num) uprobe: buf は**暗号化前の平文** = リクエスト。ssl_req_start が
#      E298 の http_pending + spnl_is_http_req をそのまま使い、**SSL* をキー**に記録 (sock でない)。
#   2. SSL_read(ssl, buf, num) uprobe entry: 復号後の平文が buf に入るのは**関数リターン後**なので
#      ssl_resp_stash が {ssl, buf} を tid で stash (E298 の recvmsg と同じ罠)。
#   3. SSL_read uretprobe: ssl_emit が stash を読み SSL* で相関し、E298 の http_events に 1 span emit。
#   method/path/status パースは E298 の userspace パーサ共通 (平文 HTTP なので同一)。
#
# semconv: E298 と同じ (`http.request.method`/`url.path`/`http.response.status_code`) + **`url.scheme=https`**
#   (sock が無い = TLS の印)。status>=500 → ERROR。span 名 "<METHOD> <path>"、kind=CLIENT。
#
# ★ 機微データを span に載せない: method/path/status のみ。**リクエストボディ・認証ヘッダ・
#   Cookie 等は span に入れない** (監査ログに秘密が漏れないよう、平文でも先頭のリクエスト行/
#   ステータス行だけを取り、ボディは読まない設計)。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_https.rb --build -o build/audit_https
#   SPNL_UPROBE_BINARY=/usr/lib/aarch64-linux-gnu/libssl.so.3 \   # OpenSSL の libssl
#   OTEL_SERVICE_NAME=spinel-e299-https \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_https/audit_https
#   # 別端末で `curl https://<host>/path` (OpenSSL) を叩くと、暗号化されているのに
#   # span に GET /path + status + duration が出る (url.scheme=https)。
#
# 限界 (Edoc):
#   - **Go crypto/tls は OpenSSL を使わない** (E295 の Go native と同じ構図) ので SSL_read/write
#     uprobe では捕まらない。BoringSSL/rustls/GnuTLS も別シンボル。**OpenSSL 系 (curl/wget/
#     python-requests(openssl)/nginx-openssl 等) が対象**。
#   - HTTP/2 多重化・pipelining は E300+ (E298 と同じ MVP 境界)。

module Otlp
  ffi_func :spnl_otlp_http_span_push, [:str], :int
end

def uprobe__SSL_write(ssl, buf, num)
  ssl_req_start(ssl, buf)   # 暗号化前の平文リクエスト (method/path)
  0
end

def uprobe__SSL_read(ssl, buf, num)
  ssl_resp_stash(ssl, buf)  # 受信バッファを stash (uretprobe で復号後を読む)
  0
end

def uretprobe__SSL_read(ret)
  ssl_emit(ret)             # 復号後の平文レスポンス (status) を読み相関 -> 1 span
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-https] TLS plaintext L7 RED (SSL_write/SSL_read uprobe) -> OTLP span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_http_span_push(ep)
  puts "[audit-https] https spans pushed -> " + ep + " HTTP " + st.to_s
end
