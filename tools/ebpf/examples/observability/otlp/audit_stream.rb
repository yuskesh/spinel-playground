# カーネル監査ストリーム → OTLP logs (Splunk = SIEM) (E273)
#
# カーネル発の「改竄しにくい」セキュリティ監査イベントを OTLP logs (LogRecord) として
# Splunk (SIEM) に流す。ユーザ空間のログと違い、eBPF が kernel hook で直接観測するため
# アプリ側のログ改竄・欠落の影響を受けにくい。2 経路を 1 つの str リングバッファに束ねる:
#
#   (a) LSM file_open        … ファイルを開いたプロセスの comm を emit_comm (E101/E102)。
#                              LSM は観測だけでなく enforce も可能 (deny=非0 を返す、E102 で実証)。
#                              本デモは監査目的なので 0 (allow) を返して観測のみ。
#   (b) tracepoint execve    … 実行されたプログラムのパスを spnl_emit_str(filename) (E021/E119)。
#                              「何が exec されたか」の低ノイズな SIEM シグナル。
#
# 両者とも per-unit の str リングバッファ (<unit>_str_events) に積まれ、
# spnl_otlp_log_push_str が drain して OTLP LogRecord (body=文字列) にし push する。
#
# 注: LSM file_open が実際に fire するには kernel の起動 lsm= に bpf が含まれる必要がある
#     (7.1.1-ebpf は lsm=...,bpf 有効、E102)。含まれない kernel では load はできるが fire しない。
#
# ── ビルド (container 内) ───────────────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_stream.rb --build -o build/audit
#   SPNL_CGROUP_PATH=/sys/fs/cgroup ./build/audit/audit_stream   # LSM/tracepoint は自動 attach
#
# ── 送信先 (OTLP logs) ──────────────────────────────────────────────────
#   標準 OTLP Collector (`/v1/logs`) に直送: resourceLogs[].logRecords[].body に
#   comm / exec パスが流れる (E286 で mock receiver 着弾を実証)。
#     OTLP_ENDPOINT=http://<collector>:4318  ./build/audit/audit_stream
#
#   【E291 の実測】**Splunk Observability Cloud には OTLP logs を直送できない**:
#   O11y Cloud の direct ingest は traces (/v2/trace/otlp) と metrics (/v2/datapoint/otlp)
#   のみで logs endpoint が無く (実測: /v1/logs 等すべて 404)、native Log Observer は
#   2024-01 に廃止 (現行 Log Observer Connect は Splunk Platform のログを *参照* するだけ)。
#   Splunk に logs を載せるには OTel Collector で OTLP→HEC 変換 → Splunk Platform HEC が必要
#   (我々は OTLP しか吐かないので Collector 経由が前提)。詳細は E291。
#   Splunk O11y に *直送* したいなら監査を **traces (span)** で表現するのが筋 (E290 で APM 実表示)。
#   # 現状 body は単一値 (comm または path)。event 種別を属性で分けるのは将来課題。

module Otlp
  ffi_func :spnl_otlp_log_push_str, [:str], :int
end

# (a) 誰が (comm) どのファイルを (完全パス) 開いたか。allow (0) を返して観測のみ。
#     emit_path (E286) は bpf_d_path で `struct file *` から完全パスを取る。
#     E286 以前は comm しか出せず「cat が何かを開いた」までしか分からなかった。
def lsm__file_open(file, ret)
  emit_comm
  emit_path(file)
  0
end

# (b) 何が exec されたか (実行パス)。execve の第1引数 filename は userspace ptr。
def tracepoint__syscalls__sys_enter_execve(filename, argv, envp)
  spnl_emit_str(filename)
end

ep   = ENV["OTLP_ENDPOINT"] || "http://127.0.0.1:4318"
secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[audit] kernel security events (file_open comm + execve path) -> OTLP logs " + ep + " every " + secs.to_s + "s"

loop do
  sleep secs
  st = Otlp.spnl_otlp_log_push_str(ep)
  puts "[audit] audit logs pushed -> " + ep + " HTTP " + st.to_s
end
