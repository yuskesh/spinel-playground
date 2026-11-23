# ingestd — OTLP/HTTP logs を受けて Parquet segment に落とす ingest デーモン
#
# プロセス構成 (E444/E448/E449):
#
#   ingestd (親) ──fork──> ingest worker × N   … SO_REUSEPORT + epoll + keepalive
#              └─fork──> compactor × 1        … catalog 監視、live segment を周期 compact
#
#   worker:    POST /v1/logs → decode (lib/decoder) → DuckDB appender → max_rows で
#              Parquet に rotate → catalog (lib/catalog) に登録
#   compactor: live ≥ O11Y_COMPACT_MIN なら 1 本に COPY → 行数検算 → catalog.swap (txn)。
#              dead の物理削除は 1 周期遅延 (実行中 query への grace)
#   eBPF:      sk_reuseport__select (worker 選択、E450)。O11Y_BPF_SELECT=1 で attach
#
# ビルド (eBPF-mixed。FFI/package marker は E450 で CLI が scrape する):
#   cd examples/o11y_backend
#   ruby ../../bin/spinel-ebpf compile ingestd.rb --build -o build
# 実行:
#   LD_LIBRARY_PATH=vendor/duckdb O11Y_WORKERS=4 O11Y_BPF_SELECT=1 \
#     ./build/ingestd <port=4318> <max_rows=100000> <data_dir=data>
#
# env: O11Y_WORKERS (4) / O11Y_BPF_SELECT (0) / O11Y_COMPACT_MIN (8) / O11Y_COMPACT_SEC (3)
#      O11Y_GRPC_PORT (4317) — OTLP/gRPC (h2c) の受け口 (E451)。SDK の既定 endpoint に合わせる
#      O11Y_TLS_CERT / O11Y_TLS_KEY — 両方設定すると 4317/4318 が TLS 終端になる (E453、
#        ALPN で h2 / http1.1 をポートごとに固定。平文と TLS の同時提供はしない)

require_relative "lib/net"
require_relative "lib/http"
require_relative "lib/duck"
require_relative "lib/catalog"
require_relative "lib/decoder"
require_relative "lib/h2"
require_relative "lib/gzip"
require_relative "lib/tls"

# ---- eBPF: SO_REUSEPORT worker 選択 (E043/E413/E450) ----
# kernel の 5-tuple hash % 4 で接続を worker に振る。O11Y_WORKERS と modulo の 4 を
# 揃えること — 空 slot への選択は kernel 既定分散に黙って落ちる (E413 D3)。

module ReuseportBpf
  ffi_func :sp_bpf_reuseport_register, [:int, :int], :int
  ffi_func :sp_bpf_reuseport_attach,   [:int, :str], :int
end

SK_PASS = 0

def sk_reuseport__select
  idx = reuseport_hash % 4
  worker_select(idx)
  SK_PASS
end

# ---- segment writer: mem table への append と Parquet への rotate ----

class SegmentWriter
  attr_reader :ingested, :mem_rows

  def initialize(conn, catalog, data_dir, worker_idx, max_rows)
    @conn = conn
    @catalog = catalog
    @data_dir = data_dir
    @worker_idx = worker_idx
    @max_rows = max_rows
    @segments = 0
    @mem_rows = 0
    @ingested = 0
  end

  # decoder の列 (from..to-1 行) を appender で流し込む。エラー文字列 ("" = 成功)。
  def append(d, from, to)
    return "appender_create failed" unless
      DUCK.duckdb_appender_create(@conn, "main", "logs", DUCK.app_out) == DUCK::OK
    app = DUCK.read_ptr(DUCK.app_out)
    i = from
    while i < to
      bad = DUCK.duckdb_append_int64(app, d.ts[i]) != DUCK::OK ||
            DUCK.duckdb_append_varchar(app, d.service[i]) != DUCK::OK ||
            DUCK.duckdb_append_int64(app, d.severity[i]) != DUCK::OK ||
            DUCK.duckdb_append_varchar(app, d.severity_text[i]) != DUCK::OK ||
            DUCK.duckdb_append_varchar(app, d.body[i]) != DUCK::OK ||
            DUCK.duckdb_appender_end_row(app) != DUCK::OK
      if bad
        msg = DUCK.duckdb_appender_error(app)
        DUCK.duckdb_appender_destroy(DUCK.app_out)
        return "append: " + msg
      end
      i += 1
    end
    return "appender flush failed" unless DUCK.duckdb_appender_destroy(DUCK.app_out) == DUCK::OK
    @mem_rows += (to - from)
    @ingested += (to - from)
    rotate_if_needed
  end

  def rotate_if_needed
    return "" if @mem_rows < @max_rows
    path = @data_dir + "/w" + @worker_idx.to_s + "-segment-" + (@segments + 1).to_s + ".parquet"
    err = exec_sql(@conn, "COPY logs TO '" + path + "' (FORMAT PARQUET)")
    return "rotate copy: " + err if err != ""
    err = exec_sql(@conn, "DELETE FROM logs")
    return "rotate delete: " + err if err != ""
    err = @catalog.register(path, @mem_rows)
    return "rotate register: " + err if err != ""
    @segments += 1
    @mem_rows = 0
    ""
  end
end

# ---- ingest worker: epoll event loop (E449、M003ev パターン) ----

# 共通: body 検証 → (gzip inflate) → decode → append。[status, error_json ("" = 成功)]。
# transport (平文/TLS) 非依存 — 応答の書き出しだけ handle_ingest / handle_ingest_tls が持つ。
def ingest_apply(clen, encoding, body, store)
  if body.length != clen || clen == 0
    return ["400 Bad Request", "body length mismatch (got #{body.length}B, content-length #{clen}B)"]
  end
  if encoding == "gzip"
    body = GZ.o11y_gunzip(body, body.length)
    gerr = GZ.o11y_gunzip_err
    if gerr != 0
      return ["400 Bad Request", "gzip inflate failed (code #{gerr}; corrupted or truncated body?)"]
    end
  elsif encoding != "" && encoding != "identity"
    return ["415 Unsupported Media Type",
            "Content-Encoding '#{encoding}' not supported (supported: gzip, identity)"]
  end
  d = OtlpLogsDecoder.new
  n = d.decode(body)
  if d.errors > 0
    return ["400 Bad Request", "malformed protobuf: #{d.errors} decode errors after #{n} records"]
  end
  err = store.append(d, 0, n)
  return ["500 Internal Server Error", err] if err != ""
  ["200 OK", ""]
end

# 1 リクエストの処理 (平文)。routing とエラー応答をここに集約。
def handle_ingest(fd, head, body, store)
  keep = head.keep
  if head.line.start_with?("POST /v1/logs")
    status, emsg = ingest_apply(head.clen, head.encoding, body, store)
    if emsg != ""
      http_json_error(fd, status, emsg, keep)
    else
      http_respond(fd, "200 OK", "application/x-protobuf", "", keep)
    end
  elsif head.line.start_with?("GET /healthz")
    http_json(fd, "200 OK", "{\"ok\":true}", keep)
  else
    http_json_error(fd, "404 Not Found",
                    "unknown path (have: POST /v1/logs, GET /healthz)", keep)
  end
end

# 同上 (TLS)。plain 側と対で保守する。
def handle_ingest_tls(fd, head, body, store)
  keep = head.keep
  if head.line.start_with?("POST /v1/logs")
    status, emsg = ingest_apply(head.clen, head.encoding, body, store)
    if emsg != ""
      https_json_error(fd, status, emsg, keep)
    else
      https_respond(fd, "200 OK", "application/x-protobuf", "", keep)
    end
  elsif head.line.start_with?("GET /healthz")
    https_json(fd, "200 OK", "{\"ok\":true}", keep)
  else
    https_json_error(fd, "404 Not Found",
                     "unknown path (have: POST /v1/logs, GET /healthz)", keep)
  end
end

# readable になった TLS-HTTP 接続 (E453)
def serve_https(fd, efd, store)
  head = https_read_head(fd)
  if head == nil
    Net.sp_net_epoll_del(efd, fd)
    TLS.otls_close(fd)
    return
  end
  body = https_read_body(fd, head.clen)
  handle_ingest_tls(fd, head, body, store)
  unless head.keep
    Net.sp_net_epoll_del(efd, fd)
    TLS.otls_close(fd)
  end
end

# ---- OTLP/gRPC 受信 (E451): h2c 上の unary Export ----

GRPC_LOGS_PATH = "/opentelemetry.proto.collector.logs.v1.LogsService/Export"

# gRPC message frame (5-byte prefix) を検証して decode → store。応答は trailer の grpc-status。
def handle_grpc(fd, stream, path, body, store)
  if path != GRPC_LOGS_PATH
    H2.h2_respond_grpc(fd, stream, GRPC_UNIMPLEMENTED,
                       "unknown method '" + path + "' (have: " + GRPC_LOGS_PATH + ")")
    return
  end
  if body.length < 5
    H2.h2_respond_grpc(fd, stream, GRPC_INVALID_ARGUMENT,
                       "gRPC frame shorter than 5-byte prefix (#{body.length}B)")
    return
  end
  flag = body.getbyte(0)
  mlen = (body.getbyte(1) << 24) | (body.getbyte(2) << 16) |
         (body.getbyte(3) << 8) | body.getbyte(4)
  if mlen != body.length - 5
    H2.h2_respond_grpc(fd, stream, GRPC_INVALID_ARGUMENT,
                       "length prefix #{mlen} != payload #{body.length - 5}")
    return
  end
  msg = body.byteslice(5, mlen)
  if flag != 0
    # E452: compressed frame。encoding は gzip のみ対応 (それ以外は loud に)
    enc = H2.h2_req_encoding(fd)
    if enc != "gzip"
      H2.h2_respond_grpc(fd, stream, GRPC_UNIMPLEMENTED,
                         "compressed frame with grpc-encoding '#{enc}' not supported (supported: gzip, identity)")
      return
    end
    msg = GZ.o11y_gunzip(msg, msg.length)
    gerr = GZ.o11y_gunzip_err
    if gerr != 0
      H2.h2_respond_grpc(fd, stream, GRPC_INVALID_ARGUMENT,
                         "gzip inflate failed (code #{gerr}; corrupted or truncated frame?)")
      return
    end
  end
  d = OtlpLogsDecoder.new
  n = d.decode(msg)
  if d.errors > 0
    H2.h2_respond_grpc(fd, stream, GRPC_INVALID_ARGUMENT,
                       "malformed protobuf: #{d.errors} decode errors after #{n} records")
    return
  end
  err = store.append(d, 0, n)
  if err != ""
    H2.h2_respond_grpc(fd, stream, GRPC_INTERNAL, err)
  else
    H2.h2_respond_grpc(fd, stream, GRPC_OK, "")
  end
end

# readable になった h2 接続を進める: feed → 完成リクエストを全部処理
def serve_h2(fd, efd, store)
  if H2.h2_feed(fd) < 0
    Net.sp_net_epoll_del(efd, fd)
    H2.h2_close(fd)
    return
  end
  loop do
    stream = H2.h2_next_stream(fd)
    break if stream < 0
    path = H2.h2_req_path(fd)
    body = H2.h2_req_body(fd)   # :binstr は呼び出し時にコピー
    handle_grpc(fd, stream, path, body, store)   # encoding は handle 内で先頭から読む
    H2.h2_req_pop(fd)
  end
end

def ingest_worker(port, grpc_port, worker_idx, data_dir, max_rows, tls_on)
  conn = duck_connect
  if conn == nil
    puts "[w#{worker_idx}] duckdb open failed"
    exit 1
  end
  err = exec_sql(conn, "CREATE TABLE logs(" \
                 "ts BIGINT, service VARCHAR, severity BIGINT, severity_text VARCHAR, body VARCHAR)")
  if err != ""
    puts "[w#{worker_idx}] schema: " + err
    exit 1
  end
  catalog = Catalog.new
  cerr = catalog.open(data_dir + "/catalog.db")
  if cerr != ""
    puts "[w#{worker_idx}] catalog: " + cerr
    exit 1
  end
  store = SegmentWriter.new(conn, catalog, data_dir, worker_idx, max_rows)

  lfd = Net.sp_net_listen(port, 1)   # reuseport=1: worker ごとに listen socket
  if lfd < 0
    puts "[w#{worker_idx}] listen failed on #{port}"
    exit 1
  end
  ReuseportBpf.sp_bpf_reuseport_register(lfd, worker_idx)
  if worker_idx == 0 && (ENV["O11Y_BPF_SELECT"] != nil ? ENV["O11Y_BPF_SELECT"] : "0") != "0"
    rc = ReuseportBpf.sp_bpf_reuseport_attach(lfd, "sk_reuseport__select")
    if rc < 0
      puts "[w0] reuseport BPF attach failed rc=#{rc} (continuing with the kernel default spread)"
    else
      puts "[w0] reuseport BPF prog attached (hash % 4)"
    end
  end
  grpc_lfd = Net.sp_net_listen(grpc_port, 1)
  if grpc_lfd < 0
    puts "[w#{worker_idx}] listen failed on grpc port #{grpc_port}"
    exit 1
  end
  puts "[w#{worker_idx} pid=#{Net.sp_net_getpid}] ingest ready on #{port} (grpc #{grpc_port}, max_rows=#{max_rows})"

  efd = Net.sp_net_epoll_create
  if efd < 0
    puts "[w#{worker_idx}] epoll_create failed"
    exit 1
  end
  Net.sp_net_epoll_add(efd, lfd)
  Net.sp_net_epoll_add(efd, grpc_lfd)

  # epoll が readable と言った fd への読みはブロッキング (M003ev と同じ簡略化 —
  # 低速クライアントの部分読みは将来課題)。keepalive 接続は登録を維持して多重化。
  loop do
    fd = Net.sp_net_epoll_wait_one(efd)
    next if fd < 0
    if fd == lfd
      c = Net.sp_net_accept(lfd)
      if c >= 0
        if tls_on
          if TLS.otls_accept(c, 0) == 0
            Net.sp_net_epoll_add(efd, c)
          else
            Net.sp_net_rl_close(c)   # handshake 失敗 (平文が来た等)。表に載る前なので raw close
          end
        else
          Net.sp_net_epoll_add(efd, c)
        end
      end
      next
    end
    if fd == grpc_lfd
      c = Net.sp_net_accept(grpc_lfd)
      if c >= 0
        ok = true
        ok = TLS.otls_accept(c, 1) == 0 if tls_on
        if ok && H2.h2_open(c) == 0
          Net.sp_net_epoll_add(efd, c)
        elsif TLS.otls_is(c) == 1
          TLS.otls_close(c)
        else
          Net.sp_net_rl_close(c)
        end
      end
      next
    end
    if H2.h2_is_open(fd) == 1
      serve_h2(fd, efd, store)
      next
    end
    if TLS.otls_is(fd) == 1
      serve_https(fd, efd, store)
      next
    end
    head = http_read_head(fd)
    if head == nil
      Net.sp_net_epoll_del(efd, fd)
      Net.sp_net_rl_close(fd)
      next
    end
    body = http_read_body(fd, head.clen)
    handle_ingest(fd, head, body, store)
    unless head.keep
      Net.sp_net_epoll_del(efd, fd)
      Net.sp_net_rl_close(fd)
    end
  end
end

# ---- compactor: 常駐 compaction (E448) ----

def compactor_loop(data_dir, min_segments, interval_sec)
  conn = duck_connect
  if conn == nil
    puts "[compactor] duckdb open failed"
    exit 1
  end
  catalog = Catalog.new
  cerr = catalog.open(data_dir + "/catalog.db")
  if cerr != ""
    puts "[compactor] catalog: " + cerr
    exit 1
  end
  puts "[compactor pid=#{Net.sp_net_getpid}] every #{interval_sec}s, threshold #{min_segments}"

  gen = 0
  loop do
    sleep interval_sec

    # 1) 前周期に dead 化した segment を物理削除 (grace = 1 周期)
    derr, deads = catalog.dead_paths
    if derr == ""
      deads.each do |p|
        ps = p.to_s                 # tuple 経由の poly 要素 → File API は typed string が要る
        File.delete(ps) if File.exist?(ps)
        catalog.purge_dead(ps)
      end
    end

    # 2) live が閾値以上なら全 live を 1 本に (COPY → 検算 → rename → catalog.swap の txn)
    lerr, lives = catalog.live
    next if lerr != "" || lives.length < min_segments
    paths = lives.map { |r| r[0].to_s }
    want = 0
    lives.each { |r| want += r[1] }

    gen += 1
    tmp = data_dir + "/compacted-g" + gen.to_s + ".tmp"
    out = data_dir + "/compacted-g" + gen.to_s + ".parquet"
    list = paths.map { |p| "'" + p + "'" }.join(",")
    err = exec_sql(conn, "COPY (SELECT ts, service, severity, severity_text, body FROM " \
                         "read_parquet([" + list + "]) ORDER BY ts) TO '" + tmp + "' (FORMAT PARQUET)")
    if err != ""
      puts "[compactor] copy failed: " + err
      next
    end
    verr, got = duck_scalar(conn, "SELECT count(*) FROM read_parquet('" + tmp + "')")
    if verr != "" || got != want
      puts "[compactor] verify failed: rows=#{got} want=#{want} #{verr}"
      File.delete(tmp) if File.exist?(tmp)
      next
    end
    File.rename(tmp, out)
    serr = catalog.swap(paths, out, want)
    if serr != ""
      puts "[compactor] swap failed: " + serr
      next
    end
    puts "[compactor] #{paths.length} segments -> #{out} (#{want} rows)"
  end
end

# ---- main: 設定と fork トポロジ ----

port     = ARGV.length >= 1 ? ARGV[0].to_i : 4318
max_rows = ARGV.length >= 2 ? ARGV[1].to_i : 100000
data_dir = ARGV.length >= 3 ? ARGV[2] : "data"
grpc_port = (ENV["O11Y_GRPC_PORT"] != nil ? ENV["O11Y_GRPC_PORT"] : "4317").to_i
tls_cert = ENV["O11Y_TLS_CERT"] != nil ? ENV["O11Y_TLS_CERT"] : ""
tls_key  = ENV["O11Y_TLS_KEY"]  != nil ? ENV["O11Y_TLS_KEY"]  : ""
tls_on = tls_cert != "" && tls_key != ""
if (tls_cert != "") != (tls_key != "")
  puts "[main] O11Y_TLS_CERT and O11Y_TLS_KEY must be set together (got cert=#{tls_cert != ""} key=#{tls_key != ""})"
  exit 1
end
workers  = (ENV["O11Y_WORKERS"] != nil ? ENV["O11Y_WORKERS"] : "4").to_i
workers = 1 if workers < 1
compact_min = (ENV["O11Y_COMPACT_MIN"] != nil ? ENV["O11Y_COMPACT_MIN"] : "8").to_i
compact_sec = (ENV["O11Y_COMPACT_SEC"] != nil ? ENV["O11Y_COMPACT_SEC"] : "3").to_i

# 親が catalog schema を先に確定してから fork (DDL 競合の回避)
boot = Catalog.new
berr = boot.open(data_dir + "/catalog.db")
if berr != ""
  puts "[main] catalog init: " + berr
  exit 1
end

if tls_on
  # 親で 1 回だけ init (config は fork で継承される)。失敗コードは cert/key の区別つき
  irc = TLS.otls_init(tls_cert, tls_key)
  if irc != 0
    reason = irc == -2 ? "cert parse failed: #{tls_cert}" :
             irc == -3 ? "key parse failed: #{tls_key}" : "init failed (rc=#{irc})"
    puts "[main] TLS " + reason
    exit 1
  end
end
mode = tls_on ? "TLS" : "plaintext"
puts "[main pid=#{Net.sp_net_getpid}] ingestd: #{workers} worker(s) on #{port} (http, #{mode}) / #{grpc_port} (grpc, #{mode}) + compactor"

my_idx = -1
i = 0
while i < workers
  pid = Net.sp_net_fork
  if pid < 0
    puts "[main] fork failed"
    exit 1
  end
  if pid == 0
    my_idx = i
    break
  end
  i += 1
end

if my_idx >= 0
  ingest_worker(port, grpc_port, my_idx, data_dir, max_rows, tls_on)
else
  compactor_loop(data_dir, compact_min, compact_sec)
end
