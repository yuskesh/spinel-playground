# 多チャネル型付き consumer — 1 つの probe が **DNS と HTTP を別々の span に** (E374 / ADR-017)
#
# E371 (audit_dns_typed.rb) は 1 channel だった。ここは 2 channel を同時に受ける:
#
#     on_emit :dns  do |ev| ... send_otlp(to_span(ev), @ep) ... end   # -> resolve span
#     on_emit :http do |ev| ... send_otlp(to_span(ev), @ep) ... end   # -> HTTP RED span
#
# **`to_span` は 1 語のまま** (channel ごとに名前が増えない、ADR-014 の層原則)。どの channel の
# span を作るかは、その `to_span` が **どの `on_emit :<ch>` ブロックの中で、そのブロックの
# block-param に適用されたか** から決まる (ADR-017 D3)。ブロックを跨いだ書き方 (handle を別の
# 変数に写す / helper に渡す) は **compile 時に落ちる** — 黙って違う channel の span を作らない。
# その場合は明示形 `dns_span(ev)` / `http_span(ev)` を使う (escape hatch、D3-4)。
#
# `ev` のプロパティ集合は channel 宣言由来 (src/codegen_c/record_schema.h -> 生成 accessor):
#   dns  : ev.pid / ev.comm / ev.cgid / ev.duration_ns / ev.qname
#   http : ev.pid / ev.comm / ev.dport / ev.duration_ns / ev.cgid / ev.method / ev.path / ev.status
# `ev.statu` のような typo は「有効なのは …」と名指しで compile error。契約を読むには:
#   spinel-ebpf describe examples/observability/otlp/audit_multi_typed.rb
#   spinel-ebpf capabilities            # userspace consumer DSL の節に to_span の解決規則
#
# **span の中身は簡潔形と同一** (to_span は egress 宣言どおりの span を作るだけ、ADR-017 D2)。
# Ruby が持つ自由は「送るか / いつ / 何回」— つまり下の 2 つのフィルタだけ。
#
# ── ビルド & 実行 ───────────────────────────────────────────────────────
#   bin/spinel-ebpf compile examples/observability/otlp/audit_multi_typed.rb --build -o build/audit_multi
#   OTLP_ENDPOINT=http://127.0.0.1:4318 ./build/audit_multi/audit_multi_typed
#   # 絞って送る (利益②の実演):
#   DNS_SUFFIX=.invalid HTTP_MIN_STATUS=500 OTLP_ENDPOINT=http://127.0.0.1:4318 \
#     ./build/audit_multi/audit_multi_typed

# --- kernel 側: DNS (E295) と HTTP (E298) の producer を 1 unit に同居させる -------
def kprobe__udp_sendmsg(sk, msg, len)
  if udp_dport(sk, msg) == 53   # この datagram の宛先 (socket の接続先ではない、E428)
    emit_dns(msg)
  end
  0
end

def kprobe__tcp_sendmsg(sk, msg, size)
  http_req_start(sk, msg)    # リクエスト先頭 64B (method/path) を sock キーで記録
  0
end

def kprobe__tcp_recvmsg(sk, msg)
  http_resp_stash(sk, msg)   # 受信バッファを tid で stash (中身は kretprobe でしか読めない)
  0
end

def kretprobe__tcp_recvmsg(ret)
  http_emit(ret)             # status を読み、sock で相関して 1 record
  0
end

# --- userspace 側: 2 channel を型付きで受ける ------------------------------------
@ep          = ENV["OTLP_ENDPOINT"] || ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||
               "https://ingest.jp0.observability.splunkcloud.com/v2/trace/otlp"
@suffix      = ENV["DNS_SUFFIX"] || ""          # "" = 全部送る
@min_status  = (ENV["HTTP_MIN_STATUS"] || "0").to_i
@dns_seen    = 0
@dns_sent    = 0
@http_seen   = 0
@http_sent   = 0

def interesting_name?(name)
  return true if @suffix.length == 0
  name.end_with?(@suffix)
end

on_emit :dns do |ev|
  @dns_seen = @dns_seen + 1
  next unless interesting_name?(ev.qname)
  send_otlp(to_span(ev), @ep)                    # <- dns に解決 (このブロックの ev)
  @dns_sent = @dns_sent + 1
  puts "  [dns ] " + ev.comm + "(" + ev.pid.to_s + ") -> " + ev.qname
end

on_emit :http do |ev|
  @http_seen = @http_seen + 1
  # 自分の exporter が出す POST /v1/traces は観測対象でない (system-wide フックの自己観測)。
  next if ev.path == "/v1/traces"
  next if ev.status < @min_status
  send_otlp(to_span(ev), @ep)                    # <- 同じ綴りだが http に解決
  @http_sent = @http_sent + 1
  puts "  [http] " + ev.method + " " + ev.path + " -> " + ev.status.to_s +
       " (" + (ev.duration_ns / 1000000).to_s + "ms)"
end

secs = (ENV["PROBE_SECONDS"] || "2").to_i
puts "[multi-typed] on_emit :dns + on_emit :http (suffix=\"" + @suffix +
     "\", min_status=" + @min_status.to_s + ") -> " + @ep

loop do
  sleep secs
  st = consume_records(200)
  puts "[multi-typed] dns " + @dns_sent.to_s + "/" + @dns_seen.to_s +
       "  http " + @http_sent.to_s + "/" + @http_seen.to_s + "  HTTP " + st.to_s
end
