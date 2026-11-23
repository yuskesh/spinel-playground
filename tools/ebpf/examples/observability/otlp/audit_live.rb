# live 監査 span: 実 LSM file_open の実パス・実親を span にして Splunk APM に直送 (E293)
#
# E292 は代表値を C 定数で渡す demo だった。本 example は **実際に起きた file_open** の
# 実パス・実行ファイル名・親の実行パスを **eBPF (LSM file_open) が取り**、userspace が
# span に組み立てて送る (E274 型の userspace 結合、codegen は emit_parent_path のみ拡張)。
#
# LSM file_open hook で、marker comm ("spnlaud" = 本 probe) のプロセスの open だけを:
#   emit_path(file)     -> file.path                     (semconv、実際に開いたファイル)
#   emit_comm           -> process.executable.name       (semconv、実プロセス comm)
#   emit_parent_path    -> process.parent.executable.path (独自 key、実親の実行パス)
# の 3 record を str ringbuf に fixed order で emit。observe (allow=0 を返す、記録のみ)。
#
# userspace は spnl_otlp_audit_span_push で ringbuf を drain し、3 record 三つ組を 1 span に。
# span 時刻は hdr の実 ktime → unix (E292 の 1970 = FFI :int 境界での ns 切り詰めを回避)。
#
# ── ビルド & 送信 (Splunk jp0 に直送、self-attach) ───────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_live.rb --build -o build/audit_live
#   OTEL_SERVICE_NAME=spinel-e293-audit \
#   OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp \
#   OTEL_EXPORTER_OTLP_HEADERS="X-SF-Token=$(cat ~/.spinel_splunk_token)" \
#     ./build/audit_live/audit_live
#   # marker comm "spnlaud" のプロセスが開いたファイルの実監査 span が APM に出る。
#   # (別端末で `exec -a spnlaud cat /etc/hostname` 等を叩くと、その実 open が span 化される)

module Otlp
  ffi_func :spnl_otlp_audit_span_push, [:str], :int
end

@events = 0

def lsm__file_open(file, ret)
  if comm_hash == 28276558962520179   # "spnlaud" LE — 本 probe が観測対象
    @events = @events + 1
    emit_path(file)        # file.path
    emit_comm              # process.executable.name
    emit_parent_path       # process.parent.executable.path
  end
  0                        # observe: allow (記録のみ、deny しない)
end

ep   = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
       "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit-live] LSM file_open (marker comm spnlaud) -> OTLP audit span " + ep

loop do
  sleep secs
  st = Otlp.spnl_otlp_audit_span_push(ep)
  puts "[audit-live] audit spans pushed -> " + ep + " HTTP " + st.to_s
end
