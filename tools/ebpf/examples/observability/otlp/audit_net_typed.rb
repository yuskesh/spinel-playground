# 型付き consumer で network connect を受ける — 「どこへ / どちら向き」で絞る (E375 / ADR-017)
#
# audit_net.rb (E294) の簡潔形は `spnl_otlp_conn_span_push(ep)` の 1 語で
# 「drain -> 全 record を span 化 -> 送信」まで行く。ここはその 1 語を分解して、
# **送る前に Ruby の判断を挟む**:
#
#     on_emit :conn do |ev| ... send_otlp(to_span(ev), @ep) ... end
#
# **span の中身は簡潔形と 1 バイトも変わらない** (`to_span` は egress 宣言どおりの span を
# 作るだけ、ADR-017 D2)。Ruby が持つ自由は「送るか / いつ / 何回」だけ。
#
# `ev` のプロパティ集合は channel 宣言由来 (src/codegen_c/record_schema.h -> 生成 accessor):
#   ev.pid / ev.comm / ev.dport / ev.cgid   … record のフィールド
#   ev.peer       … "<address>:<port>"。**v4/v6 の分岐は C 側で済んでいる**
#   ev.direction  … "active" (自分から張った) / "passive" (受けた) / "other"
#   ev.srtt_us    … 平滑化 RTT [us]。**span 属性 net.peer.srtt_us と同値** (E376)。
#                   kernel の生値は 1/8 us スケールだが、その単位換算は C 側 (層 2) の仕事
# `ev.daddr` のような生バイトは**出していない**: family を見て daddr か daddr6_hi/lo かを
# 選ぶのは「意味」の仕事で、それは層 2 (C) が持つ (ADR-017 D1)。Ruby は `ev.peer` と書く。
# typo (`ev.peor`) は「有効なのは …」と名指しで compile error。契約を読むには:
#   spinel-ebpf describe examples/observability/otlp/audit_net_typed.rb
#
# ── ビルド & 実行 ───────────────────────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_net_typed.rb --build -o build/audit_net_typed
#   OTLP_ENDPOINT=http://127.0.0.1:4318 ./build/audit_net_typed/audit_net_typed
#   # 絞って送る (自分の exporter 宛を捨て、outbound だけ送る):
#   CONN_DIRECTION=active CONN_SKIP_PORT=4318 OTLP_ENDPOINT=http://127.0.0.1:4318 \
#     ./build/audit_net_typed/audit_net_typed

# --- kernel 側: E294/E306 と同じ producer (probe は簡潔形と共通) ------------------
def tracepoint__sock__inet_sock_set_state(skaddr, daddr, dport, family, oldstate, newstate, daddr6_hi, daddr6_lo)
  if newstate == 1   # TCP_ESTABLISHED
    emit_connect(skaddr, daddr, dport, family, oldstate, daddr6_hi, daddr6_lo)   # E306: +direction +IPv6
  end
  0
end

# --- userspace 側: conn channel を型付きで受ける ----------------------------------
@ep        = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
             "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
@only_dir  = ENV["CONN_DIRECTION"] || ""            # "" = 向きで絞らない
@skip_port = (ENV["CONN_SKIP_PORT"] || "0").to_i    # 0 = 落とさない (実 connect の dport は 0 にならない)
@seen      = 0
@sent      = 0

# handle ではなく**値**を渡すヘルパ (`ev.direction` の結果は普通の String)。
def direction_ok?(d)
  return true if @only_dir.length == 0
  d == @only_dir
end

on_emit :conn do |ev|
  @seen = @seen + 1
  next if ev.dport == @skip_port                    # 自分の exporter の connect = 自己観測
  next unless direction_ok?(ev.direction)           # outbound だけ / inbound だけ
  send_otlp(to_span(ev), @ep)                       # <- conn に解決 (このブロックの ev)
  @sent = @sent + 1
  # ev.srtt_us は **us** = span 属性 net.peer.srtt_us と同値 (E376: 同じ関数の出力)。
  puts "  [conn] " + ev.comm + "(" + ev.pid.to_s + ") -> " + ev.peer +
       " " + ev.direction + " srtt=" + ev.srtt_us.to_s + "us"
end

secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[conn-typed] on_emit :conn (direction=\"" + @only_dir + "\", skip_port=" +
     @skip_port.to_s + ") -> " + @ep

loop do
  sleep secs
  st = consume_records(200)
  puts "[conn-typed] sent " + @sent.to_s + "/" + @seen.to_s + "  HTTP " + st.to_s
end
