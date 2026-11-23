# ネットワーク監査 span (外部宛でも実プロセス): socket-keyed process 相関 (E296)
#
# E294 (audit_net.rb) の限界を解消する。E294 は inet_sock_set_state の ESTABLISHED を
# 1 record にしたが、**外部宛 connect の ESTABLISHED は softirq context で発火**するため
# bpf_get_current_comm が swapper/0 (pid 0) を返し、「誰が」が欠けていた (loopback は
# process context なので取れていた)。
#
# E296 の解: **connect を呼ぶのは常に process context** という性質を使う。
#   1. kprobe/tcp_v4_connect (process ctx) で sock ptr -> {pid, comm} を相関マップに記録
#      (sock_owner_set)。
#   2. inet_sock_set_state の ESTABLISHED (softirq) で emit_connect が **同じ sock ptr を
#      キーに相関マップを引いて**、swapper/0 を実プロセスに差し替える。
#      (skaddr == connect 時の sk であることは E296 feasibility で実測: 外部宛 10/10 hit)
#
# 相関は sock_owner_set を使うユニットでだけ働く (emit_connect 単独は E294 と byte-identical
# = 後方互換)。この sock-keyed マップは **E297 (send/recv の L7 latency ペアリング) の土台**に
# なる汎用インフラ: 接続の間プロセスを保持し、後続の任意プローブが sock ptr で引ける。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_net_correlated.rb --build -o build/audit_net_correlated
#   OTEL_SERVICE_NAME=spinel-e296-net \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_net_correlated/audit_net_correlated
#   # 別端末で外部宛 `curl https://1.1.1.1/` を叩くと、その connect が
#   # process.executable.name=curl (swapper/0 でなく) で span 化される。
#
# 注意 (実測、E296 Edoc):
#   - passive open (server 側 accept) は connect を通らないので相関エントリが無く、
#     従来どおり ESTABLISHED-context の process になる (これは「誰が接続したか」ではないので正しい)。
#   - process.executable.path / parent は connect kprobe で bpf_d_path が verifier 拒否
#     (-22、E286 の gate) のため kernel では取れない。comm 相関が本 Stage の成果。
#   - map ライフサイクル: 本 MVP は connect で書いたエントリを消さない (LRU 的に上限で回収)。
#     E297 では CLOSE で明示削除して「接続の間だけ保持」に締める。

module Otlp
  ffi_func :spnl_otlp_conn_span_push, [:str], :int
end

def kprobe__tcp_v4_connect(sk, uaddr, addr_len)
  sock_owner_set(sk)   # process ctx: この socket の持ち主を記録
  0
end

def tracepoint__sock__inet_sock_set_state(skaddr, daddr, dport, family, oldstate, newstate, daddr6_hi, daddr6_lo)
  if newstate == 1   # TCP_ESTABLISHED
    emit_connect(skaddr, daddr, dport, family, oldstate, daddr6_hi, daddr6_lo)   # sock ptr で相関 (E306: +direction +IPv6)
  end
  0
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-net-corr] TCP ESTABLISHED + connect correlation -> OTLP network span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_conn_span_push(ep)
  puts "[audit-net-corr] conn spans pushed -> " + ep + " HTTP " + st.to_s
end
