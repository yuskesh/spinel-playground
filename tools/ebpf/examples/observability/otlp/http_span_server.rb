# P003: HTTP server span + W3C traceparent 伝播のデモ。
#
# spinel-compiled な HTTP/1.0 server (native、eBPF 非依存)。各リクエストで:
#   1. 受信ヘッダから traceparent を取り出す (あれば trace を継続、無ければ新規 trace)
#   2. ハンドラ前後の wall-clock を計測
#   3. SERVER span (http.request.method / url.path / http.response.status_code) を OTLP traces で送る
#
# build: bin/spinel-ebpf compile examples/observability/otlp/http_span_server.rb --build -o build
# run:   OTLP_ENDPOINT=http://127.0.0.1:4318 SPINEL_HTTP_PORT=8080 ./build/http_span_server
# test:  curl -H 'traceparent: 00-<32hex>-<16hex>-01' http://127.0.0.1:8080/hello
module Net
  ffi_func :sp_net_listen,    [:int, :int], :int
  ffi_func :sp_net_accept,    [:int],       :int
  ffi_func :sp_net_read_line, [:int],       :str
  ffi_func :sp_net_write_str, [:int, :str], :int
  ffi_func :sp_net_rl_close,  [:int],       :int
end

module Otlp
  ffi_func :spnl_otlp_now_unix_ns,        [],                                                 :int
  # E272: fd から server/client アドレスを自動導出 + route (span 名/http.route) を渡す
  ffi_func :spnl_otlp_http_span_fd,       [:int, :str, :str, :str, :str, :int, :int, :int, :str], :int
  # E272 S2: 蓄積した http.server.request.duration (秒・OBI 同一バケット) を push
  ffi_func :spnl_otlp_http_metrics_push,  [:str],                                             :int
end

# 低カーディナリティな route (span 名 / http.route 属性 / duration メトリクスのキー) を返す。
def route_for(path)
  if path == "/hello"
    "/hello"
  else
    "/other"
  end
end

def build_response(status, body)
  "HTTP/1.0 " + status + "\r\n" +
  "Content-Type: text/plain\r\n" +
  "Content-Length: " + body.length.to_s + "\r\n" +
  "Connection: close\r\n" +
  "\r\n" +
  body
end

# ヘッダを空行まで読み、traceparent の値を返す (無ければ "")。
def read_headers_traceparent(fd)
  tp = ""
  loop do
    line = Net.sp_net_read_line(fd)
    break if line.length == 0
    parts = line.split(": ")
    if parts.length >= 2 && parts[0] == "traceparent"
      tp = parts[1]
    end
  end
  tp
end

port = (ENV["SPINEL_HTTP_PORT"] || "8080").to_i
endpoint = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
listen_fd = Net.sp_net_listen(port, 0)
if listen_fd < 0
  puts "[span-server] listen(" + port.to_s + ") failed"
  exit(1)
end
puts "[span-server] HTTP/1.0 on 127.0.0.1:" + port.to_s + " -> OTLP " + endpoint

loop do
  client = Net.sp_net_accept(listen_fd)
  break if client < 0

  t0 = Otlp.spnl_otlp_now_unix_ns
  line = Net.sp_net_read_line(client)
  parts = line.split(" ")
  verb = parts[0]
  path = parts[1]
  tp = read_headers_traceparent(client)
  route = route_for(path)

  Net.sp_net_write_str(client, build_response("200 OK", "hello\n"))
  t1 = Otlp.spnl_otlp_now_unix_ns

  # client を閉じる前に span 化 (getsockname/getpeername で server/client アドレスを導出)
  st = Otlp.spnl_otlp_http_span_fd(client, tp, verb, path, route, 200, t0, t1, endpoint)
  Net.sp_net_rl_close(client)
  # E272 S2: リクエスト毎に http.server.request.duration (累積 Histogram) を push
  Otlp.spnl_otlp_http_metrics_push(endpoint)
  puts "[span-server] " + verb + " " + path + " route=" + route + " tp=[" + tp + "] -> otlp HTTP " + st.to_s
end

Net.sp_net_rl_close(listen_fd)
