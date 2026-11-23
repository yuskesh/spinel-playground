# P012 S8+S10: fork + SO_REUSEPORT マルチワーカー backend + keepalive (E444)
#
# E443 のピボット: Thread ではなく fork (M003ka の実証パターン)。
#   - ingest worker × W: 各自 SO_REUSEPORT listen + 各自の DuckDB (:memory:) +
#     各自の segment (data/w<idx>-segment-N.parquet)。共有状態ゼロ。
#   - query server × 1 (親、port+1): 毎クエリ read_parquet('data/*.parquet') の glob で
#     全 worker の segment を読む。mem (未 rotate) 行は見えない = segment 境界が可視性境界。
#   - keepalive: HTTP/1.1 persistent (M003ka)。HTTP/1.0 клиент には Connection: Keep-Alive を echo。
#
# ビルド: /work/third_party/spinel/bin/spinel s8_backend_mt.rb
# 実行:   LD_LIBRARY_PATH=vendor/duckdb O11Y_WORKERS=4 ./s8_backend_mt 4318 50000 data

require_relative "../lib/decoder"

module Net
  ffi_cflags "../../src/runtime/sp_net_ext.c"
  ffi_func :sp_net_listen,       [:int, :int], :int   # (port, reuseport)
  ffi_func :sp_net_accept,       [:int],       :int
  ffi_func :sp_net_read_line,    [:int],       :str
  ffi_func :sp_net_write_str,    [:int, :str], :int
  ffi_func :sp_net_rl_recv_some, [:int, :int], :binstr
  ffi_func :sp_net_rl_close,     [:int],       :int
  ffi_func :sp_net_fork,         [],           :int
  ffi_func :sp_net_getpid,       [],           :int
end

module DUCK
  ffi_lib "duckdb"
  ffi_cflags "-Lvendor/duckdb"
  ffi_const :OK, 0
  ffi_func :duckdb_open,             [:str, :ptr], :int
  ffi_func :duckdb_connect,          [:ptr, :ptr], :int
  ffi_func :duckdb_query,            [:ptr, :str, :ptr], :int
  ffi_func :duckdb_row_count,        [:ptr], :long
  ffi_func :duckdb_value_int64,      [:ptr, :long, :long], :long
  ffi_func :duckdb_value_varchar,    [:ptr, :long, :long], :str
  ffi_func :duckdb_result_error,     [:ptr], :str
  ffi_func :duckdb_destroy_result,   [:ptr], :void
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

def duck_connect
  return nil unless DUCK.duckdb_open(":memory:", DUCK.db_out) == DUCK::OK
  db = DUCK.read_ptr(DUCK.db_out)
  return nil unless DUCK.duckdb_connect(db, DUCK.conn_out) == DUCK::OK
  DUCK.read_ptr(DUCK.conn_out)
end

def exec_sql(conn, sql)
  if DUCK.duckdb_query(conn, sql, DUCK.res) != DUCK::OK
    err = DUCK.duckdb_result_error(DUCK.res)
    DUCK.duckdb_destroy_result(DUCK.res)
    return err
  end
  DUCK.duckdb_destroy_result(DUCK.res)
  ""
end

def respond(fd, status, ctype, body, keep)
  txt = "HTTP/1.1 #{status}\r\n" \
        "Content-Type: #{ctype}\r\n" \
        "Content-Length: #{body.length}\r\n"
  txt = txt + "Connection: Keep-Alive\r\n" if keep
  Net.sp_net_write_str(fd, txt + "\r\n" + body)
end

# ---- ingest worker ----

class WorkerStore
  attr_reader :segments, :mem_rows, :ingested

  def initialize(conn, data_dir, idx, max_rows)
    @conn = conn
    @data_dir = data_dir
    @idx = idx
    @max_rows = max_rows
    @segments = 0
    @mem_rows = 0
    @ingested = 0
  end

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

  def rotate_if_needed
    return "" if @mem_rows < @max_rows
    path = @data_dir + "/w" + @idx.to_s + "-segment-" + (@segments + 1).to_s + ".parquet"
    err = exec_sql(@conn, "COPY logs TO '" + path + "' (FORMAT PARQUET)")
    return "rotate copy: " + err if err != ""
    err = exec_sql(@conn, "DELETE FROM logs")
    return "rotate delete: " + err if err != ""
    @segments += 1
    @mem_rows = 0
    ""
  end
end

def ingest_worker(port, idx, data_dir, max_rows)
  conn = duck_connect
  if conn == nil
    puts "[w#{idx}] duckdb open failed"
    exit 1
  end
  err = exec_sql(conn, "CREATE TABLE logs(" \
                 "ts BIGINT, service VARCHAR, severity BIGINT, severity_text VARCHAR, body VARCHAR)")
  if err != ""
    puts "[w#{idx}] schema: " + err
    exit 1
  end
  store = WorkerStore.new(conn, data_dir, idx, max_rows)

  lfd = Net.sp_net_listen(port, 1)   # reuseport=1: worker ごとに listen socket
  if lfd < 0
    puts "[w#{idx}] listen failed on #{port}"
    exit 1
  end
  puts "[w#{idx} pid=#{Net.sp_net_getpid}] ingest ready on #{port} (max_rows=#{max_rows})"

  loop do
    fd = Net.sp_net_accept(lfd)
    next if fd < 0
    # keepalive: 同一接続で連続リクエスト (M003ka)。先頭 read_line が "" = EOF。
    loop do
      req = Net.sp_net_read_line(fd)
      break if req.length == 0
      clen = 0
      keep = false
      loop do
        h = Net.sp_net_read_line(fd)
        break if h == ""
        hl = h.downcase
        clen = h[15..-1].strip.to_i if hl.start_with?("content-length:")
        keep = true if hl == "connection: keep-alive"
      end
      keep = true if req.end_with?("HTTP/1.1")
      body = ""
      while body.length < clen
        chunk = Net.sp_net_rl_recv_some(fd, clen - body.length)
        break if chunk.length == 0
        body = body + chunk
      end
      if req.start_with?("POST /v1/logs") && body.length == clen && clen > 0
        d = OtlpLogsDecoder.new
        n = d.decode(body)
        if d.errors > 0
          respond(fd, "400 Bad Request", "application/json",
                  "{\"error\":\"malformed protobuf: #{d.errors} decode errors\"}", keep)
        else
          err = store.append(d, 0, n)
          if err != ""
            respond(fd, "500 Internal Server Error", "application/json",
                    "{\"error\":\"" + err + "\"}", keep)
          else
            respond(fd, "200 OK", "application/x-protobuf", "", keep)
          end
        end
      elsif req.start_with?("GET /healthz")
        respond(fd, "200 OK", "application/json", "{\"ok\":true}", keep)
      else
        respond(fd, "404 Not Found", "application/json", "{\"error\":\"unknown path\"}", keep)
      end
      break unless keep
    end
    Net.sp_net_rl_close(fd)
    # 収支はリクエストごとに stdout へ出さない (ベンチで I/O が混ざる)。rotate 時のみ:
  end
end

# ---- query server (親プロセス、port+1) ----

QUERY_COLUMNS_JSON = "[{\"name\":\"ts\",\"type\":\"time_ns\"},{\"name\":\"service\",\"type\":\"string\"}," \
                     "{\"name\":\"severity\",\"type\":\"number\"},{\"name\":\"severity_text\",\"type\":\"string\"}," \
                     "{\"name\":\"body\",\"type\":\"string\"}]"

def run_query(conn, data_dir, start_ns, end_ns, service, severity_min, limit)
  src = "SELECT " + COLS + " FROM read_parquet('" + data_dir + "/*.parquet')"
  sql = "SELECT " + COLS + " FROM (" + src + ") WHERE ts >= ? AND ts < ?"
  sql = sql + " AND service = ?"   if service != ""
  sql = sql + " AND severity >= ?" if severity_min > 0
  sql = sql + " ORDER BY ts LIMIT " + limit.to_s

  if DUCK.duckdb_prepare(conn, sql, DUCK.stmt_out) != DUCK::OK
    stmt = DUCK.read_ptr(DUCK.stmt_out)
    err = DUCK.duckdb_prepare_error(stmt)
    DUCK.duckdb_destroy_prepare(DUCK.stmt_out)
    # segment がまだ 1 本も無い glob は prepare の IO エラーで現れる → 空結果として返す
    return ["", [], 0] if err.include?("No files found")
    return ["prepare: " + err, [], 0]
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

def json_escape(s)
  out = ""
  i = 0
  while i < s.length
    c = s[i]
    if c == "\"" || c == "\\"
      out = out + "\\" + c
    elsif c == "\n"
      out = out + "\\n"
    elsif c == "\r"
      out = out + "\\r"
    elsif c == "\t"
      out = out + "\\t"
    else
      out = out + c
    end
    i += 1
  end
  out
end

def rows_to_json(rows, fmt)
  parts = []
  rows.each do |r|
    if fmt == "objects"
      parts << "{\"ts_ms\":#{r[0] / 1000000},\"service\":\"#{json_escape(r[1])}\"," \
               "\"severity\":#{r[2]},\"severity_text\":\"#{json_escape(r[3])}\"," \
               "\"body\":\"#{json_escape(r[4])}\"}"
    else
      parts << "[#{r[0]},\"#{json_escape(r[1])}\",#{r[2]},\"#{json_escape(r[3])}\",\"#{json_escape(r[4])}\"]"
    end
  end
  "[" + parts.join(",") + "]"
end

def query_server(port, data_dir)
  conn = duck_connect
  if conn == nil
    puts "[query] duckdb open failed"
    exit 1
  end
  lfd = Net.sp_net_listen(port, 0)
  if lfd < 0
    puts "[query] listen failed on #{port}"
    exit 1
  end
  puts "[query pid=#{Net.sp_net_getpid}] ready on #{port} (src=#{data_dir}/*.parquet)"

  loop do
    fd = Net.sp_net_accept(lfd)
    next if fd < 0
    loop do
      req = Net.sp_net_read_line(fd)
      break if req.length == 0
      clen = 0
      keep = false
      loop do
        h = Net.sp_net_read_line(fd)
        break if h == ""
        hl = h.downcase
        clen = h[15..-1].strip.to_i if hl.start_with?("content-length:")
        keep = true if hl == "connection: keep-alive"
      end
      keep = true if req.end_with?("HTTP/1.1")
      body = ""
      while body.length < clen
        chunk = Net.sp_net_rl_recv_some(fd, clen - body.length)
        break if chunk.length == 0
        body = body + chunk
      end
      if req.start_with?("POST /api/v1/query")
        q = body.length > 0 ? JSON.parse(body) : {}
        start_ns = q["start"] != nil ? q["start"] : 0
        end_ns   = q["end"]   != nil ? q["end"]   : 4611686018427387904
        service  = q["service"] != nil ? q["service"] : ""
        sev_min  = q["severity_min"] != nil ? q["severity_min"] : 0
        limit    = q["limit"] != nil ? q["limit"] : 100
        fmt      = q["format"] != nil ? q["format"] : "columns"
        limit = 1 if limit < 1
        limit = 10000 if limit > 10000
        if fmt != "columns" && fmt != "objects"
          respond(fd, "400 Bad Request", "application/json",
                  "{\"error\":\"unknown format '#{fmt}' (supported: columns, objects)\"}", keep)
        else
          err, rows, _n = run_query(conn, data_dir, start_ns, end_ns, service, sev_min, limit)
          if err != ""
            respond(fd, "500 Internal Server Error", "application/json",
                    "{\"error\":\"" + json_escape(err) + "\"}", keep)
          elsif fmt == "objects"
            respond(fd, "200 OK", "application/json", "{\"rows\":" + rows_to_json(rows, fmt) + "}", keep)
          else
            respond(fd, "200 OK", "application/json",
                    "{\"columns\":" + QUERY_COLUMNS_JSON + ",\"rows\":" + rows_to_json(rows, fmt) + "}", keep)
          end
        end
      elsif req.start_with?("GET /healthz")
        respond(fd, "200 OK", "application/json", "{\"ok\":true}", keep)
      else
        respond(fd, "404 Not Found", "application/json", "{\"error\":\"unknown path\"}", keep)
      end
      break unless keep
    end
    Net.sp_net_rl_close(fd)
  end
end

require "json"

# ---- main ----

port     = ARGV.length >= 1 ? ARGV[0].to_i : 4318
max_rows = ARGV.length >= 2 ? ARGV[1].to_i : 100000
data_dir = ARGV.length >= 3 ? ARGV[2] : "data"
workers  = (ENV["O11Y_WORKERS"] != nil ? ENV["O11Y_WORKERS"] : "4").to_i
workers = 1 if workers < 1

puts "[main pid=#{Net.sp_net_getpid}] s8 backend: #{workers} ingest worker(s) on #{port}, query on #{port + 1}"

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
  ingest_worker(port, my_idx, data_dir, max_rows)
else
  query_server(port + 1, data_dir)
end
