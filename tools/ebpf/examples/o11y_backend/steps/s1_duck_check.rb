# P012 S1: spinel FFI × DuckDB 疎通 (E437)
#
# wrapper C を書かずに、upstream spinel の FFI DSL (ffi_lib / ffi_func /
# ffi_buffer + ffi_read_ptr) だけで DuckDB C API の往復を確認する:
#   open → connect → CREATE/INSERT → SELECT (集計 + 文字列) → destroy → close
#
# 実行 (container):
#   cd examples/o11y_backend
#   sh scripts/fetch-duckdb.sh
#   /work/third_party/spinel/bin/spinel s1_duck_check.rb
#   LD_LIBRARY_PATH=vendor/duckdb ./s1_duck_check
#
# 注意 (S1 限定の割り切り):
# - duckdb_value_varchar の返す malloc 済 char* は :str が Ruby String に
#   コピーした後に duckdb_free できない (元 ptr を失う) ので S1 では leak を
#   許容する。Phase 1 本体は設計 27 章の stable C wrapper に移す。
# - duckdb_result は struct を caller が確保する API。サイズは版依存なので
#   ffi_buffer で 256B を静的確保して余らせる (実サイズは ~48B)。

module DUCK
  ffi_lib "duckdb"
  ffi_cflags "-Lvendor/duckdb"

  ffi_const :OK, 0

  ffi_func :duckdb_library_version, [], :str
  ffi_func :duckdb_open,            [:str, :ptr], :int
  ffi_func :duckdb_connect,         [:ptr, :ptr], :int
  ffi_func :duckdb_query,           [:ptr, :str, :ptr], :int
  ffi_func :duckdb_row_count,       [:ptr], :long
  ffi_func :duckdb_column_count,    [:ptr], :int
  ffi_func :duckdb_value_int64,     [:ptr, :int, :int], :long  # int64 戻り: :int だと 32bit 切詰 (E439)
  ffi_func :duckdb_value_varchar,   [:ptr, :int, :int], :str
  ffi_func :duckdb_result_error,    [:ptr], :str
  ffi_func :duckdb_destroy_result,  [:ptr], :void
  ffi_func :duckdb_disconnect,      [:ptr], :void
  ffi_func :duckdb_close,           [:ptr], :void

  ffi_buffer :db_out,   8
  ffi_buffer :conn_out, 8
  ffi_buffer :res,      256
  ffi_read_ptr :read_ptr, 0
end

def die(msg)
  puts "S1 FAIL: " + msg
  exit 1
end

# 実行文 (結果を読まない)。失敗時は DuckDB 自身のエラー文言を出して die。
def exec_sql(conn, sql)
  if DUCK.duckdb_query(conn, sql, DUCK.res) != DUCK::OK
    err = DUCK.duckdb_result_error(DUCK.res)
    DUCK.duckdb_destroy_result(DUCK.res)
    die("query failed: " + sql + " (" + err + ")")
  end
  DUCK.duckdb_destroy_result(DUCK.res)
end

puts "duckdb library version: " + DUCK.duckdb_library_version

die("duckdb_open") unless DUCK.duckdb_open(":memory:", DUCK.db_out) == DUCK::OK
db = DUCK.read_ptr(DUCK.db_out)
die("db handle is NULL") if db == nil

die("duckdb_connect") unless DUCK.duckdb_connect(db, DUCK.conn_out) == DUCK::OK
conn = DUCK.read_ptr(DUCK.conn_out)
die("conn handle is NULL") if conn == nil

# 設計 7.1 章の logs schema の縮小版で往復する
exec_sql(conn, "CREATE TABLE logs(ts BIGINT, service VARCHAR, severity INTEGER, body VARCHAR)")
exec_sql(conn, "INSERT INTO logs VALUES" \
               " (1000, 'api',      17, 'connection timeout')," \
               " (2000, 'api',       9, 'request ok')," \
               " (3000, 'checkout', 21, 'payment failed')")

# 集計 (設計 13.1 章の例と同じ形: severity >= ERROR(17) を service で group)
if DUCK.duckdb_query(conn,
     "SELECT service, count(*) FROM logs WHERE severity >= 17 GROUP BY service ORDER BY service",
     DUCK.res) != DUCK::OK
  die("aggregate query failed: " + DUCK.duckdb_result_error(DUCK.res))
end
rows = DUCK.duckdb_row_count(DUCK.res)
cols = DUCK.duckdb_column_count(DUCK.res)
die("expected 2 rows x 2 cols, got #{rows} x #{cols}") unless rows == 2 && cols == 2

svc0 = DUCK.duckdb_value_varchar(DUCK.res, 0, 0)
cnt0 = DUCK.duckdb_value_int64(DUCK.res, 1, 0)
svc1 = DUCK.duckdb_value_varchar(DUCK.res, 0, 1)
cnt1 = DUCK.duckdb_value_int64(DUCK.res, 1, 1)
DUCK.duckdb_destroy_result(DUCK.res)

die("row0 mismatch: #{svc0}=#{cnt0}") unless svc0 == "api" && cnt0 == 1
die("row1 mismatch: #{svc1}=#{cnt1}") unless svc1 == "checkout" && cnt1 == 1

# 時間 range (設計 20 章の pruning の意味論と同じ形)
if DUCK.duckdb_query(conn,
     "SELECT count(*), min(ts), max(ts) FROM logs WHERE ts >= 1000 AND ts < 3000",
     DUCK.res) != DUCK::OK
  die("range query failed: " + DUCK.duckdb_result_error(DUCK.res))
end
n   = DUCK.duckdb_value_int64(DUCK.res, 0, 0)
tmin = DUCK.duckdb_value_int64(DUCK.res, 1, 0)
tmax = DUCK.duckdb_value_int64(DUCK.res, 2, 0)
DUCK.duckdb_destroy_result(DUCK.res)
die("range mismatch: n=#{n} min=#{tmin} max=#{tmax}") unless n == 2 && tmin == 1000 && tmax == 2000

DUCK.duckdb_disconnect(DUCK.conn_out)
DUCK.duckdb_close(DUCK.db_out)

puts "severity>=17 by service: api=#{cnt0} checkout=#{cnt1}"
puts "range [1000,3000): n=#{n} min=#{tmin} max=#{tmax}"
puts "S1 OK"
