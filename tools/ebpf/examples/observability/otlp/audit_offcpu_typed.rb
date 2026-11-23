# 型付き consumer で off-CPU 内訳を受ける — 「待たされたリクエストだけ」送る (E379 / ADR-017)
#
# audit_offcpu.rb (E300) の簡潔形は `spnl_otlp_offcpu_span_push(ep)` の 1 語で
# 「drain -> 全 record を span 化 -> 送信」まで行く。ここはその 1 語を分解して、
# **送る前に Ruby の判断を挟む**:
#
#     on_emit :offcpu do |ev| ... send_otlp(to_span(ev), @ep) ... end
#
# **span の中身は簡潔形と 1 バイトも変わらない** (`to_span` は egress 宣言どおりの span を
# 作るだけ、ADR-017 D2)。Ruby が持つ自由は「送るか / いつ / 何回」だけ。
#
# この channel の `ev` は、**フィールドをそのまま出すと span と食い違うもの**が 3 つある
# (だから typed 化が最後になった、E379)。3 つとも span 属性と同じ関数の出力に揃えてある:
#   ev.duration_ns … リクエスト窓 (recv -> send) 全体 = span の長さ
#   ev.offcpu_ns   … そのうち **走っていなかった** ns。**clamp 後** (min(offcpu, duration)) で、
#                    属性 spnl.offcpu_ns と同値。生フィールドではない — 待ちは sched_switch の
#                    合計、窓は recv/send の対で測るので、合計が窓を超える record は在り得る
#   ev.oncpu_ns    … 走っていた ns (= duration - offcpu)。**フィールドに無い計算値**、属性 spnl.oncpu_ns と同値
#   ev.wait_kind   … 何を待っていたか: "io" / "lock" / "sleep" / "net" / "other" / "none" (待ち無し) /
#                    "unknown" (stack map か kallsyms が読めない)。属性 spnl.wait.kind と同値
#   ev.method / ev.path / ev.status … L7 (http channel と同じ derivation、E378)
#   ev.pid / ev.comm / ev.cgid      … record のフィールド (cgid は層 2 enricher の入力 = k8s.*)
# `ev.wait_stack` (stack map の index) や `ev.hdr_ext` (生ヘッダ) は**出していない**:
# Ruby が持っても判断に使えない。契約を読むには:
#   spinel-ebpf describe examples/observability/otlp/audit_offcpu_typed.rb
#
# 何が嬉しいか (簡潔形との差): 「遅かったリクエストだけ」「待ちが I/O だったものだけ」を
# **カーネルからのイベントを取りこぼさずに** 選別して送れる。全部送って backend で絞るのと違い、
# 送信量そのものが減る (SaaS のイベント課金 / 帯域が効く場面)。
#
# ── ビルド & 実行 ───────────────────────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_offcpu_typed.rb --build -o build/audit_offcpu_typed
#   # 100ms 以上待たされたリクエストだけ送る:
#   OFFCPU_MIN_MS=100 OTLP_ENDPOINT=http://127.0.0.1:4318 \
#     ./build/audit_offcpu_typed/audit_offcpu_typed
#   # 「I/O 待ちだけ」に絞る (kind は kallsyms 分類、best-effort):
#   OFFCPU_MIN_MS=1 OFFCPU_WAIT_KIND=io OTLP_ENDPOINT=http://127.0.0.1:4318 \
#     ./build/audit_offcpu_typed/audit_offcpu_typed
#
# 注意 (E300 と同じ): system-wide / SERVER 視点 (recv=request, send=response) / 1 リクエスト =
# 1 ハンドラ tid が前提。sched_switch は高頻度フックなのでオーバーヘッドは要測定。
# wait_kind は最後の待ちの top-frame 分類 (best-effort)。
# 明示形が返す span は **リクエスト窓 (親)** 1 本 — 簡潔形が足す "off-CPU wait (<kind>)" の子 span は
# 出ない (待ちの値 spnl.offcpu_ns / spnl.wait.kind は親にも載っているので、見える値は同じ)。

# --- kernel 側: E300 と同じ producer (probe は簡潔形と共通) ------------------
def kprobe__tcp_recvmsg(sk, msg)
  offcpu_recv_stash(sk, msg)   # リクエスト受信バッファを stash
  0
end

def kretprobe__tcp_recvmsg(ret)
  offcpu_begin(ret)            # HTTP リクエストなら off-CPU 窓を開く
  0
end

def tracepoint__sched__sched_switch(prev_pid, prev_state, next_pid)
  offcpu_account(prev_pid, prev_state, next_pid)   # 窓中の voluntary off-CPU を積む
  0
end

def kprobe__tcp_sendmsg(sk, msg)
  offcpu_emit(sk, msg)         # レスポンス送出で窓を閉じ、内訳付き record を emit
  0
end

# --- userspace 側: offcpu channel を型付きで受ける --------------------------------
@ep       = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
            "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
@min_ns   = (ENV["OFFCPU_MIN_MS"] || "100").to_i * 1000000   # これ以上待った窓だけ送る
@only_kind = ENV["OFFCPU_WAIT_KIND"] || ""                   # "" = 待ちの種類で絞らない
@seen     = 0
@sent     = 0

# handle ではなく**値**を渡すヘルパ (`ev.wait_kind` の結果は普通の String)。
def kind_ok?(k)
  return true if @only_kind.length == 0
  k == @only_kind
end

on_emit :offcpu do |ev|
  @seen = @seen + 1
  next if ev.offcpu_ns < @min_ns        # CPU を回していただけの窓は送らない
  next unless kind_ok?(ev.wait_kind)    # 待ちの種類で絞る
  send_otlp(to_span(ev), @ep)           # <- offcpu に解決 (このブロックの ev)
  @sent = @sent + 1
  # 出力の値は span 属性と同値 (spnl.offcpu_ns / spnl.oncpu_ns / spnl.wait.kind)。
  puts "  [slow] " + ev.method + " " + ev.path + " -> " + ev.status.to_s +
       "  dur=" + (ev.duration_ns / 1000000).to_s + "ms" +
       " off=" + (ev.offcpu_ns / 1000000).to_s + "ms" +
       " on=" + (ev.oncpu_ns / 1000000).to_s + "ms" +
       " wait=" + ev.wait_kind + "  (" + ev.comm + ")"
end

secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[offcpu-typed] on_emit :offcpu (off-CPU >= " + (@min_ns / 1000000).to_s +
     "ms, wait_kind=\"" + @only_kind + "\") -> " + @ep

loop do
  sleep secs
  st = consume_records(200)
  puts "[offcpu-typed] sent " + @sent.to_s + "/" + @seen.to_s + "  HTTP " + st.to_s
end
