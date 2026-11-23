# DNS 監査 span: 「どのプロセスが何を名前解決したか」を resolver 非依存で Splunk APM に (E295)
#
# libc getaddrinfo uprobe (E129) は glibc caller しか捕まえず Go native resolver / musl /
# DoH を落とす。本 example は **socket 層 :53** を見るので **resolver 非依存** (Go native も拾う)。
# `udp_sendmsg` kprobe で :53 宛の DNS query を捕まえ (process context、softirq 問題なし)、
# emit_dns で DNS payload を 1 packed record に (raw copy、QNAME は userspace パース =
# verifier の state 爆発を避ける)。
#
# span: name="resolve <hostname>"、実 ktime→unix 時刻、属性
#   dns.question.name (semconv 標準) / process.executable.name (comm、semconv)
#
# 注意 (実測、E295 / E428 Edoc):
#   - resolver 非依存が肝。同じ Go 解決が libc uprobe には出ず socket :53 には出る (対照実験で実証)。
#   - **「非依存」の範囲は E428 で測り直した**: resolver の実装言語だけでなく、
#     connect の有無・iovec の本数にも依存しない (E428 以前は connect 済み かつ 単一
#     バッファの送信しか拾えていなかった)。読めないのは bytes が user memory に無い
#     送信 (splice = ITER_BVEC) だけで、そのとき span を捏造せず drain が
#     `unreadable_payload` として 1 件と報告する。
#   - **本 example は query の捕捉** (「誰が何を解決したか」)。send→recv の解決レイテンシは
#     recv 側 payload access の都合で本 Stage 未実装 (query span の duration=0)。libc uprobe
#     (getaddrinfo entry→exit) は latency を取れるが glibc 限定 = 補完関係。
#   - DoH/DoT (TCP 443) はこの :53 UDP フックでは見えない (別途)。キャッシュヒットは query が
#     出ないので不可視。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_dns.rb --build -o build/audit_dns
#   OTEL_SERVICE_NAME=spinel-e295-dns \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_dns/audit_dns
#   # 別端末で `getent hosts x` / `curl` / Go(CGO_ENABLED=0) の LookupHost を叩くと span 化。

module Otlp
  ffi_func :spnl_otlp_dns_span_push, [:str], :int
end

def kprobe__udp_sendmsg(sk, msg, len)
  # udp_dport is the destination of THIS datagram, not of the socket (E428).
  # An unconnected sender -- one that passes the address on every send, which is
  # how dnsmasq forwards upstream -- leaves the socket's peer port at 0, so
  # `sock_dport(sk) == 53` is simply false and the probe reports nothing at all.
  # Both spellings return host order, so the port is written as the port (E395);
  # the raw __be16 read would have to be compared against 13568 (0x3500).
  if udp_dport(sk, msg) == 53
    emit_dns(msg)
  end
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-dns] udp_sendmsg :53 (resolver-independent) -> OTLP resolve span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_dns_span_push(ep)
  puts "[audit-dns] dns spans pushed -> " + ep + " HTTP " + st.to_s
end
