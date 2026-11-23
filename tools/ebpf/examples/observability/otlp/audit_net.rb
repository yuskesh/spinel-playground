# ネットワーク監査 span: 「どのプロセスがどこへ通信したか + L4 srtt」を Splunk APM に (E294)
#
# file 監査 (E292/E293) の network 版。TCP の ESTABLISHED 遷移を `inet_sock_set_state`
# tracepoint で捕まえ、**1 event = 1 packed record** (emit_connect) にする。単一 tracepoint
# fire が (skaddr, daddr, dport, family) を atomic に運ぶので、E293 の str 三つ組 desync
# 問題は構造的に存在しない (network は並行 connect が多いので、これが E294 の技術的な肝)。
#
# emit_connect が per-record に詰める:
#   pid / comm (bpf_get_current_pid_tgid / _comm、init-ns pid の罠は E182/E288)
#   daddr / dport (remote endpoint、daddr は raw be32、dport は host order)
#   family (2=INET / 10=INET6)
#   srtt_us (tcp_sock->srtt_us を CO-RE。1/8 us スケール → userspace で /8 して us)
#
# userspace は spnl_otlp_conn_span_push で drain し、1 record を 1 network span に:
#   name="connect <daddr>:<dport>"、実 ktime→unix 時刻 (E293 で 1970 を解消済)
#   属性: network.peer.address / network.peer.port / network.transport=tcp /
#         network.type=ipv4|ipv6 (semconv 標準) + net.peer.srtt_us (独自 key) +
#         process.executable.name=comm (semconv)
#
# 注意 (実測、E294 Edoc):
#   - active connect の ESTABLISHED は softirq context で発火し得る → 外部宛は
#     pid=0/comm=swapper になる。loopback/同一ホストは接続プロセスが取れる。
#   - direction (active/passive): oldstate を渡し、userspace が SYN_SENT→active /
#     SYN_RECV→passive を判定して span 属性 spnl.conn.direction に載せる。
#   - IPv6: daddr6_hi/lo (tracepoint daddr_v6[16] を u64 2 分割) を渡し、family==
#     AF_INET6 のとき userspace が network.peer.address を v6 表記で組み立てる。
#   - 8 param handler (skaddr,daddr,dport,family,oldstate,newstate,daddr6_hi,daddr6_lo)
#     は E306 caps 形で BPF の 5-arg 制限を突破する。
#   - L4 srtt は「読む」。L7 request/response RTT (SSL uprobe) は別 Stage (E294-c)。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_net.rb --build -o build/audit_net
#   OTEL_SERVICE_NAME=spinel-e294-net \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_net/audit_net
#   # 別端末で `curl http://127.0.0.1:<port>` 等を叩くと、その connect が span 化される。

module Otlp
  ffi_func :spnl_otlp_conn_span_push, [:str], :int
end

def tracepoint__sock__inet_sock_set_state(skaddr, daddr, dport, family, oldstate, newstate, daddr6_hi, daddr6_lo)
  if newstate == 1   # TCP_ESTABLISHED
    emit_connect(skaddr, daddr, dport, family, oldstate, daddr6_hi, daddr6_lo)   # E306: +direction +IPv6
  end
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-net] TCP ESTABLISHED (inet_sock_set_state) -> OTLP network span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_conn_span_push(ep)
  puts "[audit-net] conn spans pushed -> " + ep + " HTTP " + st.to_s
end
