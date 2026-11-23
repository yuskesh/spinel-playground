# 監査 (deny/path/lineage) を OTLP span で Splunk O11y に直送 (E292)
#
# Splunk Observability Cloud は OTLP logs を直送できない (E291: logs endpoint 無し、
# native Log Observer 廃止)。監査を Splunk O11y に *直送* して APM/Trace Analyzer で
# 見たいなら **span (traces)** で表現するのが唯一の道。本 example は
# 「親 X の子 Y が file Z を開いた (verdict)」を 1 span 化して送る。
#
# データ源 (本番): E286 emit_path / E289 parent_path_eq・ppid が kernel (LSM file_open) で
# 取った値を userspace が span 属性に載せる ((A) userspace 結合、codegen 無改変)。
# 本 example は経路実証なので代表値を直接渡す (kernel emit の drain 統合は E274 型の拡張)。
#
# 属性 (semconv 準拠 / 独自 を明記):
#   process.executable.path        (semconv v1.37.0) … 開いた実行ファイル
#   file.path                      (semconv v1.37.0) … 対象ファイル
#   process.parent.executable.path (**独自 key**; semconv は process.parent_pid のみ) … 親
#   verdict                        (**独自 key**; allow/deny)
# deny=1 の span は Span.status=ERROR (APM で赤く色分け)。
#
# ── ビルド & 送信 (Splunk jp0 に直送) ────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_span_demo.rb --build -o build/audit_span
#   OTEL_SERVICE_NAME=spinel-e292-audit \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_span/audit_span_demo
#   # → APM の Trace Analyzer で service.name=spinel-e292-audit、file.path で filter。

module Otlp
  ffi_func :spnl_otlp_now_unix_ns, [], :int
  # (traceparent, exe, parent_exe, file, verdict, deny, t0, t1, endpoint) -> HTTP status
  ffi_func :spnl_otlp_audit_file_span,
           [:str, :str, :str, :str, :str, :int, :int, :int, :str], :int
end

ep = ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
     ENV["OTLP_ENDPOINT"] ||
     "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"

# (1) deny: 親 /usr/sbin/nginx の子 /bin/cat が /etc/shadow を開こうとして拒否 (E289 の親パス基準 deny)
t0 = Otlp.spnl_otlp_now_unix_ns
t1 = Otlp.spnl_otlp_now_unix_ns
st1 = Otlp.spnl_otlp_audit_file_span(
  "", "/bin/cat", "/usr/sbin/nginx", "/etc/shadow", "deny", 1, t0, t1, ep)
puts "[audit-span] deny  file_open /etc/shadow (parent=/usr/sbin/nginx) -> HTTP " + st1.to_s

# (2) allow (observe): 通常の httpd が /var/www/index.html を開いた (記録のみ)
t2 = Otlp.spnl_otlp_now_unix_ns
t3 = Otlp.spnl_otlp_now_unix_ns
st2 = Otlp.spnl_otlp_audit_file_span(
  "", "/usr/sbin/httpd", "/sbin/init", "/var/www/index.html", "allow", 0, t2, t3, ep)
puts "[audit-span] allow file_open /var/www/index.html -> HTTP " + st2.to_s
