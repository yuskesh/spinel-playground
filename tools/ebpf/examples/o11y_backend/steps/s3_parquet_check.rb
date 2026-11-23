# P012 S3: DuckDB appender → Parquet segment → 読み戻し (E439)
#
# 設計 8/9 章の判断 (libarrow 無し) の実証: decode 済みの列 (E438) を DuckDB
# appender で流し込み、COPY TO (FORMAT PARQUET) で segment を書き、
# 「別接続の read_parquet」で読み戻して一致を確認する。
# (独立実装の対照 = 素の duckdb CLI での読み戻しは runner スクリプト側で行う)
#
#   /work/third_party/spinel/bin/spinel s3_parquet_check.rb
#   LD_LIBRARY_PATH=vendor/duckdb ./s3_parquet_check tests/payload_logs.bin tests/out_segment.parquet

require_relative "../lib/decoder"

module DUCK
  ffi_lib "duckdb"
  ffi_cflags "-Lvendor/duckdb"

  ffi_const :OK, 0

  ffi_func :duckdb_open,             [:str, :ptr], :int
  ffi_func :duckdb_connect,          [:ptr, :ptr], :int
  ffi_func :duckdb_query,            [:ptr, :str, :ptr], :int
  ffi_func :duckdb_row_count,        [:ptr], :long
  ffi_func :duckdb_value_int64,      [:ptr, :int, :int], :long  # int64 戻り: :int だと 32bit 切詰 (E439)
  ffi_func :duckdb_value_varchar,    [:ptr, :int, :int], :str
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

  ffi_buffer :db_out,   8
  ffi_buffer :conn_out, 8
  ffi_buffer :app_out,  8
  ffi_buffer :res,      256
  ffi_read_ptr :read_ptr, 0
end

def die(msg)
  puts "S3 FAIL: " + msg
  exit 1
end

def exec_sql(conn, sql)
  if DUCK.duckdb_query(conn, sql, DUCK.res) != DUCK::OK
    err = DUCK.duckdb_result_error(DUCK.res)
    DUCK.duckdb_destroy_result(DUCK.res)
    die("query failed: " + sql + " (" + err + ")")
  end
  DUCK.duckdb_destroy_result(DUCK.res)
end

payload_path = ARGV.length >= 1 ? ARGV[0] : "tests/payload_logs.bin"
segment_path = ARGV.length >= 2 ? ARGV[1] : "tests/out_segment.parquet"

# ---- decode (E438 の fixture を 3 batch 分) ----
payload = File.binread(payload_path)
store = OtlpLogsDecoder.new
batches = 3
i = 0
while i < batches
  store.decode(payload)
  i += 1
end
die("decode errors=#{store.errors}") unless store.errors == 0
nrows = store.ts.length
die("expected 9 rows, got #{nrows}") unless nrows == 9

# ---- open + schema (設計 7.1 章の縮小版、int 列は BIGINT に統一) ----
die("open") unless DUCK.duckdb_open(":memory:", DUCK.db_out) == DUCK::OK
db = DUCK.read_ptr(DUCK.db_out)
die("connect") unless DUCK.duckdb_connect(db, DUCK.conn_out) == DUCK::OK
conn = DUCK.read_ptr(DUCK.conn_out)

exec_sql(conn, "CREATE TABLE logs(" \
               "ts BIGINT, service VARCHAR, severity BIGINT, severity_text VARCHAR, body VARCHAR)")

# ---- appender: 列 store → 行 append (FFI 呼び出し回数は S6 の測定対象) ----
die("appender_create") unless DUCK.duckdb_appender_create(conn, "main", "logs", DUCK.app_out) == DUCK::OK
app = DUCK.read_ptr(DUCK.app_out)
i = 0
while i < nrows
  bad = DUCK.duckdb_append_int64(app, store.ts[i]) != DUCK::OK ||
        DUCK.duckdb_append_varchar(app, store.service[i]) != DUCK::OK ||
        DUCK.duckdb_append_int64(app, store.severity[i]) != DUCK::OK ||
        DUCK.duckdb_append_varchar(app, store.severity_text[i]) != DUCK::OK ||
        DUCK.duckdb_append_varchar(app, store.body[i]) != DUCK::OK ||
        DUCK.duckdb_appender_end_row(app) != DUCK::OK
  die("append row #{i}: " + DUCK.duckdb_appender_error(app)) if bad
  i += 1
end
die("appender_destroy (flush)") unless DUCK.duckdb_appender_destroy(DUCK.app_out) == DUCK::OK

# ---- segment 書き出し (パスはリテラル連結だが値は CLI 引数 — S4 以降は bind 経由に統一) ----
exec_sql(conn, "COPY logs TO '" + segment_path + "' (FORMAT PARQUET)")
DUCK.duckdb_disconnect(DUCK.conn_out)
DUCK.duckdb_close(DUCK.db_out)

# ---- 読み戻し: 完全に新しい instance + read_parquet ----
die("reopen") unless DUCK.duckdb_open(":memory:", DUCK.db_out) == DUCK::OK
db2 = DUCK.read_ptr(DUCK.db_out)
die("reconnect") unless DUCK.duckdb_connect(db2, DUCK.conn_out) == DUCK::OK
conn2 = DUCK.read_ptr(DUCK.conn_out)

if DUCK.duckdb_query(conn2,
     "SELECT count(*), sum(severity), min(ts), max(ts) FROM read_parquet('" + segment_path + "')",
     DUCK.res) != DUCK::OK
  die("readback failed: " + DUCK.duckdb_result_error(DUCK.res))
end
cnt  = DUCK.duckdb_value_int64(DUCK.res, 0, 0)
ssum = DUCK.duckdb_value_int64(DUCK.res, 1, 0)
tmin = DUCK.duckdb_value_int64(DUCK.res, 2, 0)
tmax = DUCK.duckdb_value_int64(DUCK.res, 3, 0)
DUCK.duckdb_destroy_result(DUCK.res)

# 期待値: 3 batches x (9+17+21)=47 → cnt=9 ssum=141
die("readback mismatch: cnt=#{cnt} ssum=#{ssum} tmin=#{tmin} tmax=#{tmax}") unless
  cnt == 9 && ssum == 141 && tmin == 1700000001000000000 && tmax == 1700000003000000000

if DUCK.duckdb_query(conn2,
     "SELECT service, count(*) FROM read_parquet('" + segment_path + "')" \
     " WHERE severity >= 17 GROUP BY service ORDER BY service",
     DUCK.res) != DUCK::OK
  die("group query failed: " + DUCK.duckdb_result_error(DUCK.res))
end
rows = DUCK.duckdb_row_count(DUCK.res)
die("expected 2 groups, got #{rows}") unless rows == 2
svc0 = DUCK.duckdb_value_varchar(DUCK.res, 0, 0)
cnt0 = DUCK.duckdb_value_int64(DUCK.res, 1, 0)
svc1 = DUCK.duckdb_value_varchar(DUCK.res, 0, 1)
cnt1 = DUCK.duckdb_value_int64(DUCK.res, 1, 1)
DUCK.duckdb_destroy_result(DUCK.res)
die("groups mismatch: #{svc0}=#{cnt0} #{svc1}=#{cnt1}") unless
  svc0 == "api" && cnt0 == 3 && svc1 == "checkout" && cnt1 == 3

DUCK.duckdb_disconnect(DUCK.conn_out)
DUCK.duckdb_close(DUCK.db_out)

puts "segment: #{segment_path} rows=#{cnt} sev_sum=#{ssum}"
puts "severity>=17 by service: #{svc0}=#{cnt0} #{svc1}=#{cnt1}"
puts "S3 OK"
