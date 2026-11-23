# P012 S4: Minimal Log Backend (E440)
#
# S2 (OTLP/HTTP 受信) + S3 (Parquet segment) + Query API を 1 バイナリに束ねる。
#   POST /v1/logs       — OTLP logs 取り込み → DuckDB mem table (max_rows で Parquet へ rotate)
#   POST /api/v1/query  — JSON filter (start/end/service/severity_min/limit) → columns+rows JSON
#   GET  /healthz
#
# 設計 13 章の規律: ユーザー入力は必ず bind (?) 経由。SQL への文字列連結は
# server 生成のリテラル (segment パス・検証済み limit 整数) のみ。
#
# ビルド (sp_net_rl_* のため bin/spinel-ebpf):
#   cd examples/o11y_backend
#   ruby /work/bin/spinel-ebpf compile s4_backend.rb --native-only --build -o build
# 実行:
#   mkdir -p data && LD_LIBRARY_PATH=vendor/duckdb ./build/s4_backend <port> <max_reqs> <max_rows> <data_dir>

require "json"
require_relative "../lib/decoder"

module Net
  # sp_net_rl_* は spinel-ebpf 所有の shim TU (E193 externalize)。upstream spinel の
  # driver でビルドするため、TU を ffi_cflags 経由で cc の入力に足す (パスは
  # examples/o11y_backend からの相対)。
  ffi_cflags "../../src/runtime/sp_net_ext.c"
  ffi_func :sp_net_listen,       [:int, :int], :int
  ffi_func :sp_net_accept,       [:int],       :int
  ffi_func :sp_net_read_line,    [:int],       :str
  ffi_func :sp_net_write_str,    [:int, :str], :int
  ffi_func :sp_net_rl_recv_some, [:int, :int], :binstr
  ffi_func :sp_net_rl_close,     [:int],       :int
end

module DUCK
  ffi_lib "duckdb"
  ffi_cflags "-Lvendor/duckdb"

  ffi_const :OK, 0

  ffi_func :duckdb_open,             [:str, :ptr], :int
  ffi_func :duckdb_connect,          [:ptr, :ptr], :int
  ffi_func :duckdb_query,            [:ptr, :str, :ptr], :int
  ffi_func :duckdb_row_count,        [:ptr], :long
  ffi_func :duckdb_value_int64,      [:ptr, :long, :long], :long  # 64bit は :long (E439)
  ffi_func :duckdb_value_varchar,    [:ptr, :long, :long], :str
  ffi_func :duckdb_result_error,     [:ptr], :str
  ffi_func :duckdb_destroy_result,   [:ptr], :void
  ffi_func :duckdb_disconnect,       [:ptr], :void
  ffi_func :duckdb_close,            [:ptr], :void

  ffi_func :duckdb_appender_create,  [:ptr, :str, :str, :ptr], :int
  ffi_func :duckdb_append_int64,     [:ptr, :long], :int
  ffi_func :duckdb_append_varchar,   [:ptr, :str], :int
  ffi_func :duckdb_appender_end_row, [:ptr], :int
  ffi_func :duckdb_appender_error,   [:ptr], :str
  ffi_func :duckdb_appender_destroy, [:ptr], :int

  ffi_func :duckdb_prepare,          [:ptr, :str, :ptr], :int
  ffi_func :duckdb_prepare_error,    [:ptr], :str
  ffi_func :duckdb_bind_int64,       [:ptr, :long, :long], :int
  ffi_func :duckdb_bind_varchar,     [:ptr, :long, :str], :int
  ffi_func :duckdb_execute_prepared, [:ptr, :ptr], :int
  ffi_func :duckdb_destroy_prepare,  [:ptr], :void

  ffi_buffer :db_out,   8
  ffi_buffer :conn_out, 8
  ffi_buffer :app_out,  8
  ffi_buffer :stmt_out, 8
  ffi_buffer :res,      256
  ffi_read_ptr :read_ptr, 0
end

COLS = "ts, service, severity, severity_text, body"

def respond(fd, status, ctype, body)
  txt = "HTTP/1.1 #{status}\r\n" \
        "Content-Type: #{ctype}\r\n" \
        "Content-Length: #{body.length}\r\n" \
        "Connection: close\r\n\r\n" + body
  Net.sp_net_write_str(fd, txt)
end

def json_error(fd, status, msg)
  respond(fd, status, "application/json", { "error" => msg }.to_json)
end

# ---- storage ----

class LogStore
  attr_reader :segments, :mem_rows, :ingested

  def initialize(conn, data_dir, max_rows)
    @conn = conn
    @data_dir = data_dir
    @max_rows = max_rows
    @segments = []
    @mem_rows = 0
    @ingested = 0
  end

  def exec(sql)
    if DUCK.duckdb_query(@conn, sql, DUCK.res) != DUCK::OK
      err = DUCK.duckdb_result_error(DUCK.res)
      DUCK.duckdb_destroy_result(DUCK.res)
      return err
    end
    DUCK.duckdb_destroy_result(DUCK.res)
    ""
  end

  # decoder の列 (from..to-1 行) を mem table へ append。エラー文字列 ("" = 成功)。
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
    n = to - from
    @mem_rows += n
    @ingested += n
    rotate_if_needed
  end

  # segment close (設計 10 章の rows 条件のみ)。パスは server 生成 (ユーザー入力なし)。
  def rotate_if_needed
    return "" if @mem_rows < @max_rows
    path = @data_dir + "/segment-" + (@segments.length + 1).to_s + ".parquet"
    err = exec("COPY logs TO '" + path + "' (FORMAT PARQUET)")
    return "rotate copy: " + err if err != ""
    err = exec("DELETE FROM logs")
    return "rotate delete: " + err if err != ""
    @segments << path
    @mem_rows = 0
    puts "segment closed: #{path}"
    ""
  end

  # mem + 全 segment の union (server 生成リテラルのみ)
  def source_sql
    s = "SELECT " + COLS + " FROM logs"
    @segments.each do |p|
      s = s + " UNION ALL SELECT " + COLS + " FROM read_parquet('" + p + "')"
    end
    s
  end
end

# ---- query API ----

# filter は bind のみ。limit は検証済み整数の埋め込み (bind 不可の位置ではないが単純化)。
def run_query(conn, store, start_ns, end_ns, service, severity_min, limit)
  sql = "SELECT " + COLS + " FROM (" + store.source_sql + ")" \
        " WHERE ts >= ? AND ts < ?"
  sql = sql + " AND service = ?"    if service != ""
  sql = sql + " AND severity >= ?"  if severity_min > 0
  sql = sql + " ORDER BY ts LIMIT " + limit.to_s

  if DUCK.duckdb_prepare(conn, sql, DUCK.stmt_out) != DUCK::OK
    stmt = DUCK.read_ptr(DUCK.stmt_out)
    err = "prepare: " + DUCK.duckdb_prepare_error(stmt)
    DUCK.duckdb_destroy_prepare(DUCK.stmt_out)
    return [err, [] , 0]
  end
  stmt = DUCK.read_ptr(DUCK.stmt_out)
  idx = 1
  DUCK.duckdb_bind_int64(stmt, idx, start_ns); idx += 1
  DUCK.duckdb_bind_int64(stmt, idx, end_ns);   idx += 1
  if service != ""
    DUCK.duckdb_bind_varchar(stmt, idx, service); idx += 1
  end
  if severity_min > 0
    DUCK.duckdb_bind_int64(stmt, idx, severity_min); idx += 1
  end

  if DUCK.duckdb_execute_prepared(stmt, DUCK.res) != DUCK::OK
    err = "execute: " + DUCK.duckdb_result_error(DUCK.res)
    DUCK.duckdb_destroy_result(DUCK.res)
    DUCK.duckdb_destroy_prepare(DUCK.stmt_out)
    return [err, [], 0]
  end

  n = DUCK.duckdb_row_count(DUCK.res)
  rows = []
  r = 0
  while r < n
    rows << [DUCK.duckdb_value_int64(DUCK.res, 0, r),
             DUCK.duckdb_value_varchar(DUCK.res, 1, r),
             DUCK.duckdb_value_int64(DUCK.res, 2, r),
             DUCK.duckdb_value_varchar(DUCK.res, 3, r),
             DUCK.duckdb_value_varchar(DUCK.res, 4, r)]
    r += 1
  end
  DUCK.duckdb_destroy_result(DUCK.res)
  DUCK.duckdb_destroy_prepare(DUCK.stmt_out)
  ["", rows, n]
end

QUERY_COLUMNS = [
  { "name" => "ts",            "type" => "time_ns" },
  { "name" => "service",       "type" => "string" },
  { "name" => "severity",      "type" => "number" },
  { "name" => "severity_text", "type" => "string" },
  { "name" => "body",          "type" => "string" }
]

# ---- main ----

port     = ARGV.length >= 1 ? ARGV[0].to_i : 4318
max_reqs = ARGV.length >= 2 ? ARGV[1].to_i : 0
max_rows = ARGV.length >= 3 ? ARGV[2].to_i : 100000
data_dir = ARGV.length >= 4 ? ARGV[3] : "data"

die_msg = ""
if DUCK.duckdb_open(":memory:", DUCK.db_out) != DUCK::OK
  puts "s4_backend: duckdb_open failed"
  exit 1
end
db = DUCK.read_ptr(DUCK.db_out)
DUCK.duckdb_connect(db, DUCK.conn_out)
conn = DUCK.read_ptr(DUCK.conn_out)
if conn == nil
  puts "s4_backend: duckdb_connect failed"
  exit 1
end

store = LogStore.new(conn, data_dir, max_rows)
err = store.exec("CREATE TABLE logs(" \
                 "ts BIGINT, service VARCHAR, severity BIGINT, severity_text VARCHAR, body VARCHAR)")
if err != ""
  puts "s4_backend: schema: " + err
  exit 1
end

lfd = Net.sp_net_listen(port, 64)
if lfd < 0
  puts "s4_backend: listen failed on port #{port} (bind error — port in use?)"
  exit 1
end
puts "s4_backend: listening on #{port} (max_reqs=#{max_reqs} max_rows=#{max_rows} data=#{data_dir})"

served = 0
while max_reqs == 0 || served < max_reqs
  fd = Net.sp_net_accept(lfd)
  next if fd < 0

  req = Net.sp_net_read_line(fd)
  clen = 0
  while true
    h = Net.sp_net_read_line(fd)
    break if h == ""
    clen = h[15..-1].strip.to_i if h.downcase.start_with?("content-length:")
  end
  body = ""
  while body.length < clen
    chunk = Net.sp_net_rl_recv_some(fd, clen - body.length)
    break if chunk.length == 0
    body = body + chunk
  end

  if req.start_with?("POST /v1/logs")
    if body.length != clen || clen == 0
      json_error(fd, "400 Bad Request", "body length mismatch (got #{body.length}B, content-length #{clen}B)")
    else
      d = OtlpLogsDecoder.new           # per-request decoder (エラー計上を隔離)
      n = d.decode(body)
      if d.errors > 0
        json_error(fd, "400 Bad Request", "malformed protobuf: #{d.errors} decode errors after #{n} records")
      else
        err = store.append(d, 0, n)
        if err != ""
          json_error(fd, "500 Internal Server Error", err)
        else
          puts "ingest: +#{n} (mem=#{store.mem_rows} segments=#{store.segments.length})"
          respond(fd, "200 OK", "application/x-protobuf", "")
        end
      end
    end
  elsif req.start_with?("POST /api/v1/query")
    q = body.length > 0 ? JSON.parse(body) : {}
    start_ns = q["start"] != nil ? q["start"] : 0
    end_ns   = q["end"]   != nil ? q["end"]   : 4611686018427387904
    service  = q["service"] != nil ? q["service"] : ""
    sev_min  = q["severity_min"] != nil ? q["severity_min"] : 0
    limit    = q["limit"] != nil ? q["limit"] : 100
    limit = 1 if limit < 1
    limit = 10000 if limit > 10000
    fmt = q["format"] != nil ? q["format"] : "columns"
    if fmt != "columns" && fmt != "objects"
      json_error(fd, "400 Bad Request",
                 "unknown format '#{fmt}' (supported: columns, objects)")
      Net.sp_net_rl_close(fd)
      served += 1
      next
    end
    err, rows, n = run_query(conn, store, start_ns, end_ns, service, sev_min, limit)
    if err != ""
      json_error(fd, "500 Internal Server Error", err)
    else
      puts "query: #{n} rows (service=#{service} sev_min=#{sev_min} fmt=#{fmt})"
      if fmt == "objects"
        # Grafana Infinity 向け: array-of-objects + ms 時刻 (E441)
        objs = []
        rows.each do |r|
          objs << { "ts_ms" => r[0] / 1000000, "service" => r[1], "severity" => r[2],
                    "severity_text" => r[3], "body" => r[4] }
        end
        respond(fd, "200 OK", "application/json", { "rows" => objs }.to_json)
      else
        respond(fd, "200 OK", "application/json",
                { "columns" => QUERY_COLUMNS, "rows" => rows }.to_json)
      end
    end
  elsif req.start_with?("GET /healthz")
    respond(fd, "200 OK", "application/json", "{\"ok\":true}")
  else
    json_error(fd, "404 Not Found", "unknown path (have: POST /v1/logs, POST /api/v1/query, GET /healthz)")
  end
  Net.sp_net_rl_close(fd)
  served += 1
end

puts "final: ingested=#{store.ingested} mem=#{store.mem_rows} segments=#{store.segments.length}"
