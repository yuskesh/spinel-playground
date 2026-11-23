# P012 S11: segment compaction (E446)
#
# 設計 22 章: policy は Ruby、scan/rewrite は DuckDB。小さい segment 群を 1 本に
# まとめ、query の glob open コスト (E445 で特定した支配項) を削る。
#
# 手順: compacted を .tmp に書く → 元 segment を unlink → .tmp を rename。
# 削除→rename の間に走った query は compact 対象分を見落とす (瞬間的な欠け)。
# 重複 (二重計上) よりは欠けを選ぶ。恒久解は segment catalog (設計 12 章、Phase 3)。
#
#   LD_LIBRARY_PATH=vendor/duckdb ./s11_compact data8 logs-compacted-1
#
# 出力: compact した segment 数と行数。glob が .parquet のみを拾う前提で .tmp は不可視。

module DUCK
  ffi_lib "duckdb"
  ffi_cflags "-Lvendor/duckdb"
  ffi_const :OK, 0
  ffi_func :duckdb_open,           [:str, :ptr], :int
  ffi_func :duckdb_connect,        [:ptr, :ptr], :int
  ffi_func :duckdb_query,          [:ptr, :str, :ptr], :int
  ffi_func :duckdb_row_count,      [:ptr], :long
  ffi_func :duckdb_value_int64,    [:ptr, :long, :long], :long
  ffi_func :duckdb_value_varchar,  [:ptr, :long, :long], :str
  ffi_func :duckdb_result_error,   [:ptr], :str
  ffi_func :duckdb_destroy_result, [:ptr], :void
  ffi_buffer :db_out,   8
  ffi_buffer :conn_out, 8
  ffi_buffer :res,      256
  ffi_read_ptr :read_ptr, 0
end

def die(msg)
  puts "S11 FAIL: " + msg
  exit 1
end

data_dir = ARGV.length >= 1 ? ARGV[0] : "data"
out_name = ARGV.length >= 2 ? ARGV[1] : "compacted-1"

die("open") unless DUCK.duckdb_open(":memory:", DUCK.db_out) == DUCK::OK
db = DUCK.read_ptr(DUCK.db_out)
die("connect") unless DUCK.duckdb_connect(db, DUCK.conn_out) == DUCK::OK
conn = DUCK.read_ptr(DUCK.conn_out)

# 対象 segment の列挙は DuckDB の glob に任せる (Dir API 非依存)
if DUCK.duckdb_query(conn, "SELECT DISTINCT filename FROM read_parquet('" + data_dir +
                           "/*.parquet', filename=true) ORDER BY filename", DUCK.res) != DUCK::OK
  die("list: " + DUCK.duckdb_result_error(DUCK.res))
end
n = DUCK.duckdb_row_count(DUCK.res)
files = []
i = 0
while i < n
  files << DUCK.duckdb_value_varchar(DUCK.res, 0, i)
  i += 1
end
DUCK.duckdb_destroy_result(DUCK.res)
die("nothing to compact (#{n} segments)") if n < 2

tmp = data_dir + "/" + out_name + ".tmp"
out = data_dir + "/" + out_name + ".parquet"
if DUCK.duckdb_query(conn, "COPY (SELECT ts, service, severity, severity_text, body FROM read_parquet('" +
                           data_dir + "/*.parquet') ORDER BY ts) TO '" + tmp +
                           "' (FORMAT PARQUET)", DUCK.res) != DUCK::OK
  die("copy: " + DUCK.duckdb_result_error(DUCK.res))
end
DUCK.duckdb_destroy_result(DUCK.res)

# 行数検算 (compact 前の総数と .tmp の総数が一致してから消す)
if DUCK.duckdb_query(conn, "SELECT (SELECT count(*) FROM read_parquet('" + data_dir + "/*.parquet'))," +
                           " (SELECT count(*) FROM read_parquet('" + tmp + "'))", DUCK.res) != DUCK::OK
  die("verify: " + DUCK.duckdb_result_error(DUCK.res))
end
before = DUCK.duckdb_value_int64(DUCK.res, 0, 0)
after  = DUCK.duckdb_value_int64(DUCK.res, 1, 0)
DUCK.duckdb_destroy_result(DUCK.res)
die("row count mismatch: glob=#{before} tmp=#{after}") unless before == after

files.each { |f| File.delete(f) }
File.rename(tmp, out)
puts "compacted #{n} segments -> #{out} (#{after} rows)"
