# DNS 監査 span — **型付き consumer 版** (E371 / S4)。audit_dns.rb と同じことを、
# 「1 語の不透明 push」ではなく **record を受け取る Ruby のループ**として書く。
#
# 簡潔形 (audit_dns.rb) はこう書く:
#
#     Otlp.spnl_otlp_dns_span_push(ep)     # drain + span 化 + 送信を 1 語に潰す
#
# 明示形 (本ファイル) はそれを 3 つの語に分解する:
#
#     on_emit :dns do |ev|                 # ① 型付き受信 (ev.qname / ev.comm / ev.pid / …)
#       next unless interesting?(ev.qname) # ② 自前ロジックを挟める ← これが利益②
#       send_otlp(to_span(ev), @ep)        # ③ 変換 (egress 宣言どおり) と送信
#     end
#
# `ev` の**プロパティ集合は宣言由来** (src/codegen_c/record_schema.h -> 生成 accessor)。
# `ev.qnam` のような typo は compile 時に「有効なのは ev.pid, ev.comm, ev.cgid,
# ev.duration_ns, ev.qname」と名指しで落ちる (link error でも silent な 0 でもない)。
# 契約を読むには: `spinel-ebpf describe examples/observability/otlp/audit_dns_typed.rb`
#
# **span は簡潔形と 1 バイトも変わらない**: to_span は簡潔形と同じ builder
# (dns_fill_span) を通るので、属性 (dns.question.name / process.executable.name /
# spnl.dns.latency_ns)・SpanKind・時刻は同一。違うのは「どの record を送るか」だけ。
#
# 注意 (E295 から不変): socket 層 :53 を見るので resolver 非依存 (Go native も拾う)。
# DoH/DoT (TCP 443) とキャッシュヒットは見えない。emit_dns は query 捕捉なので
# duration=0 (latency 付きは E311 の dns_req_start/dns_emit 3 フック組)。
#
# ── ビルド & 実行 ───────────────────────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_dns_typed.rb --build -o build/audit_dns_typed
#   OTLP_ENDPOINT=http://127.0.0.1:4318 ./build/audit_dns_typed/audit_dns_typed
#   # 特定ドメインだけ送る (利益②の実演):
#   DNS_SUFFIX=.invalid OTLP_ENDPOINT=http://127.0.0.1:4318 ./build/audit_dns_typed/audit_dns_typed

def kprobe__udp_sendmsg(sk, msg, len)
  if udp_dport(sk, msg) == 53   # この datagram の宛先 (socket の接続先ではない、E428)
    emit_dns(msg)
  end
  0
end

# 既定を https にしておく: build 時の TLS リンク判定は「生成 C に https:// リテラルが
# あるか」なので (ADR-013 T3、bin/spinel-ebpf)、既定が http だと env で https を渡しても
# mbedTLS が非リンクで送れない。簡潔形 (audit_dns.rb) と同じ既定に揃える。
#
# なお Splunk に実送信するときは **env OTEL_EXPORTER_OTLP_TRACES_ENDPOINT で渡すこと**。
# 既定値 (この文字列) をそのまま使うと path 込み verbatim の分岐 (E290) を通らず
# signal path が付いて 404 になる — これは簡潔形も同じ挙動 (S4 で実測、typed 固有ではない)。
@ep     = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
          "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
@suffix = ENV["DNS_SUFFIX"] || ""     # "" = 全部送る (簡潔形と同じ挙動)
@seen   = 0
@sent   = 0

# 固定 FFI では書きようが無かった「送る前の判断」。ev.qname は record 宣言の
# 派生プロパティ (raw[64] の DNS ラベル walk) で、普通の Ruby の String。
def interesting?(name)
  return true if @suffix.length == 0
  name.end_with?(@suffix)
end

on_emit :dns do |ev|
  @seen = @seen + 1
  next unless interesting?(ev.qname)
  send_otlp(to_span(ev), @ep)
  @sent = @sent + 1
  puts "  [send] " + ev.comm + "(" + ev.pid.to_s + ") -> " + ev.qname
end

secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[typed-dns] udp_sendmsg :53 -> on_emit :dns (suffix=\"" + @suffix + "\") -> " + @ep

loop do
  sleep secs
  st = consume_records(200)
  puts "[typed-dns] seen=" + @seen.to_s + " sent=" + @sent.to_s + " HTTP " + st.to_s
end
