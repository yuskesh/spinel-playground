# DNS 解決レイテンシ span: 「どのプロセスが何を、何 ms で名前解決したか」を resolver 非依存で (E311)
#
# E295 (audit_dns.rb) は DNS query の **捕捉のみ** (span duration=0)。本 example は
# send→recv を **transaction ID** で相関し、span の **duration = DNS 解決 RTT** にする。
# 1 UDP socket に A+AAAA の 2 query が飛んでも txid で分離できる (多重化を ID で解く)。
#
# 3 フック (E298 の TCP と同型、UDP 版):
#   1. kprobe/udp_sendmsg  : :53 宛 query の txid を読み (sock<<16|txid) で開始時刻を記録 (dns_req_start)
#   2. kprobe/udp_recvmsg  : 応答 payload は copy 後にしか無いので {sk, buf} を tid で stash (dns_resp_stash)
#   3. kretprobe/udp_recvmsg: 応答の txid を読み相関 → duration_ns 付き dns_event を emit (dns_emit)
#
# span: name="resolve <hostname>"、属性 dns.question.name / process.executable.name +
#   **spnl.dns.latency_ns** (RTT)、span duration = RTT。QNAME は応答にエコーされた質問節を
#   userspace でパース (E295 と同じ、verifier state 爆発を避ける)。
#
# 注意 (実測、E311):
#   - resolver 非依存 (socket 層 :53、Go native も拾う。E295 の対照実験を継承)。
#   - **cache hit は不可視** (query が出ない)。**応答なし (SERVFAIL/timeout/drop) は duration 付かず**
#     (pending は LRU で枯れる)。DoH/DoT (:443 TCP) はこの :53 UDP フック外。
#   - 1 解決で A+AAAA = 2 query = 2 span (それぞれ独立の RTT)。
#   - emit_dns (E295 query-only) とは別 builtin、共存可 (duration 0)。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_dns_latency.rb --build -o build/audit_dns_latency
#   OTEL_SERVICE_NAME=spinel-e311-dns \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_dns_latency/audit_dns_latency
#   # 別端末で `getent hosts <unique-name>` / curl / Go(CGO_ENABLED=0) を叩くと RTT 付き span 化。

module Otlp
  ffi_func :spnl_otlp_dns_span_push, [:str], :int
end

def kprobe__udp_sendmsg(sk, msg, len)
  if udp_dport(sk, msg) == 53   # the destination of THIS datagram (E428)
    dns_req_start(sk, msg)
  end
  0
end

# The receive side cannot ask the same question. `msg_name` here is an OUTPUT --
# the kernel writes the sender's address into it after the copy -- so the only
# thing available at entry is the socket's connected peer. That means the RTT
# half of this probe still needs a resolver that connect()s; an unconnected
# forwarder gets its queries recorded (above) but never a duration. E428 names
# this rather than hiding it: sock_dport is the right accessor here, and its
# limit is the real one.
def kprobe__udp_recvmsg(sk, msg, len, flags, addr_len)
  if sock_dport(sk) == 53
    dns_resp_stash(sk, msg)
  end
  0
end

def kretprobe__udp_recvmsg(ret)
  dns_emit(ret)   # ret>0 guarded inside; correlates by response txid -> DNS RTT
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-dns-lat] udp_sendmsg/udp_recvmsg :53 (txid-correlated RTT) -> OTLP resolve span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_dns_span_push(ep)
  puts "[audit-dns-lat] dns spans pushed -> " + ep + " HTTP " + st.to_s
end
