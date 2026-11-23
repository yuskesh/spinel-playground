# E274: L2–L8 横断・単一レコード相関デモ (A 方式 = userspace 結合)。
#
# 1 つの spinel-compiled バイナリが「HTTP/1.0 server (L7、native) + TCP kprobe (L3/L4、eBPF)
# + OTLP 送出」を兼ね、**1 接続 = 1 span レコードに L3/L4 + L7 + L8 を同居**させる。
#
#   L3/L4 : client.address / server.port (span 既存) + net.tcp.established /
#           net.tcp.state_changes  ← tracepoint が 4-tuple keyed-hist に貯めた値を userspace が結合
#   L7    : http.request.method / url.path / http.route / http.response.status_code / latency (span duration)
#   L8    : tenant (X-Tenant ヘッダ or route フォールバック) + W3C traceparent 継承
#
# 機構:
#   - eBPF: `sock:inet_sock_set_state` tracepoint (E122/E127) で TCP 状態遷移の 4-tuple
#     (saddr/daddr/sport/dport) を読み、決定的 u64 キー (C 側 otlp_xlayer.c と byte 一致) にして
#     hist_observe_by。metric_id=1=state_changes (全遷移)、=2=established (ESTABLISHED 遷移、
#     接続ごとに 1 → 4-tuple join の成立証明)。
#   - userspace: accept fd から getsockname/getpeername で同一 4-tuple を導出し、同一キーで
#     keyed-hist map (bpf_hist_keyed) を引く新 FFI で L3/L4 値を取得 → span 属性に載せる。
#
#   ※ tracepoint 採用の理由: 本 Apple-container VM では kprobe (動的テキストパッチ) の attach が
#     hypervisor 下でハングする。static tracepoint は正常 attach するため、L3/L4 の 4-tuple 取得を
#     `tcp_retransmit_skb` kprobe から `inet_sock_set_state` tracepoint に切替 (task 許容、E274 参照)。
#     tracepoint attach は tracefs (/sys/kernel/tracing) の mount が前提 (E273)。
#
# build: bin/spinel-ebpf compile examples/observability/otlp/xlayer_correlate.rb --build -o build
# run:   OTLP_ENDPOINT=http://127.0.0.1:4318 SPINEL_HTTP_PORT=8080 ./build/xlayer_correlate
# test:  curl -H 'traceparent: 00-<32hex>-<16hex>-01' -H 'X-Tenant: acme' http://127.0.0.1:8080/hello
module Net
  ffi_func :sp_net_listen,    [:int, :int], :int
  ffi_func :sp_net_accept,    [:int],       :int
  ffi_func :sp_net_read_line, [:int],       :str
  ffi_func :sp_net_write_str, [:int, :str], :int
  ffi_func :sp_net_rl_close,  [:int],       :int
end

module Otlp
  ffi_func :spnl_otlp_now_unix_ns,        [],                                                          :int
  # E274: 横断相関付き HTTP server span (L7 + L3/L4 established/state_changes + L8 tenant を 1 span に)
  ffi_func :spnl_otlp_http_span_fd_x,       [:int, :str, :str, :str, :str, :int, :int, :int, :str, :int, :int, :str], :int
  # E274: accept fd の 4-tuple から keyed-hist の L3/L4 メトリクスを引く (kernel と同一キー導出)
  ffi_func :spnl_otlp_xlayer_established,    [:int],                                                    :int
  ffi_func :spnl_otlp_xlayer_state_changes,  [:int],                                                    :int
end

# ---- eBPF (L3/L4): 接続 4-tuple keyed の TCP 状態メトリクスを貯める ----
# sock:inet_sock_set_state (E122/E127) — TCP 状態遷移ごとに 4-tuple を named field で読む。
# server 側の accept された socket は saddr=server / daddr=client / sport=server_port /
# dport=client_port の向き。userspace の getsockname(=local=server)/getpeername(=peer=client) と
# 一致するので、下のキー導出 (ci=client, si=server, cp=client_port, sp=server_port) が両者で byte 一致。
#   - metric_id=1 : 当該 4-tuple の全状態遷移数 (state_changes)
#   - metric_id=2 : ESTABLISHED (newstate==1) 遷移数 = 接続確立ごとに 1 (established、join 証明)
# saddr/daddr は raw be32 (getsockname/getpeername の s_addr と一致)、sport/dport は host order
# (tracepoint が ntohs 済 = 8123 等、E123)。userspace 側は port を ntohs して合わせる。
def tracepoint__sock__inet_sock_set_state(saddr, daddr, sport, dport, newstate)
  ci = daddr & 0xFFFFFFFF   # client ip  (raw be, = getpeername s_addr)
  si = saddr & 0xFFFFFFFF   # server ip  (raw be, = getsockname s_addr)
  cp = dport & 0xFFFF       # client port(host,   = ntohs(getpeername port))
  sp = sport & 0xFFFF       # server port(host,   = ntohs(getsockname port))
  base = ci
  base = base * 1099511628211 + si
  base = base * 1099511628211 + cp
  base = base * 1099511628211 + sp
  # metric_id=1: 全状態遷移
  h1 = base * 1099511628211 + 1
  hist_observe_by(h1, 1)
  # metric_id=2: ESTABLISHED (TCP_ESTABLISHED == 1)
  if newstate == 1
    h2 = base * 1099511628211 + 2
    hist_observe_by(h2, 1)
  end
  0
end

# ---- L7 (native): HTTP server ----
def route_for(path)
  if path == "/hello"
    "/hello"
  else
    "/other"
  end
end

# L8: tenant を route から導出 (X-Tenant ヘッダが無いときのフォールバック)
def tenant_for(route)
  if route == "/hello"
    "public"
  else
    "unknown"
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

port = (ENV["SPINEL_HTTP_PORT"] || "8080").to_i
endpoint = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
listen_fd = Net.sp_net_listen(port, 0)
if listen_fd < 0
  puts "[xlayer] listen(" + port.to_s + ") failed"
  exit(1)
end
puts "[xlayer] HTTP/1.0 on 127.0.0.1:" + port.to_s + " -> OTLP " + endpoint

loop do
  client = Net.sp_net_accept(listen_fd)
  break if client < 0

  t0 = Otlp.spnl_otlp_now_unix_ns
  line = Net.sp_net_read_line(client)
  parts = line.split(" ")
  verb = parts[0]
  path = parts[1]

  # ヘッダ走査: traceparent (L7 相関) + X-Tenant (L8)
  tp = ""
  tenant = ""
  loop do
    hline = Net.sp_net_read_line(client)
    break if hline.length == 0
    hparts = hline.split(": ")
    if hparts.length >= 2
      if hparts[0] == "traceparent"
        tp = hparts[1]
      end
      if hparts[0] == "X-Tenant"
        tenant = hparts[1]
      end
    end
  end

  route = route_for(path)
  if tenant.length == 0
    tenant = tenant_for(route)
  end

  Net.sp_net_write_str(client, build_response("200 OK", "hello\n"))
  t1 = Otlp.spnl_otlp_now_unix_ns

  # 応答後・close 前 (fd 生存中) に L3/L4 を結合。tracepoint が同一 4-tuple キーで貯めた値を引く。
  est = Otlp.spnl_otlp_xlayer_established(client)
  chg = Otlp.spnl_otlp_xlayer_state_changes(client)

  # 1 span = L7 + L3/L4 (client.address/server.port + established/state_changes) + L8 (tenant) + trace 継承
  st = Otlp.spnl_otlp_http_span_fd_x(client, tp, verb, path, route, 200, t0, t1, tenant, est, chg, endpoint)
  Net.sp_net_rl_close(client)
  puts "[xlayer] " + verb + " " + path + " tenant=" + tenant + " established=" + est.to_s +
       " state_changes=" + chg.to_s + " tp=[" + tp + "] -> otlp " + st.to_s
end

Net.sp_net_rl_close(listen_fd)
