# 共有: segment catalog (SQLite、設計 12 章の control plane の初実装、E448)
#
# 目的: 「どの segment が生きているか」の単一正本。E446 の compaction race
# (glob の delete→rename 窓) を、catalog の transaction + 遅延 purge で解消する。
#
# 状態遷移: (登録) live → (compaction で置換) dead → (次周期に file 削除 + 行削除)
# 並行性: ingest worker × N + compactor + query server が別プロセスで同じ DB を
# 触るため WAL + busy_timeout(5s)。書き込み txn は短く保つ。

module SQLITE
  ffi_lib "sqlite3"
  ffi_const :OK, 0
  ffi_const :ROW, 100
  ffi_const :DONE, 101
  ffi_func :sqlite3_open,         [:str, :ptr], :int
  ffi_func :sqlite3_busy_timeout, [:ptr, :int], :int
  ffi_func :sqlite3_prepare_v2,   [:ptr, :str, :int, :ptr, :ptr], :int
  ffi_func :sqlite3_step,         [:ptr], :int
  ffi_func :sqlite3_column_int64, [:ptr, :int], :long
  ffi_func :sqlite3_column_text,  [:ptr, :int], :str
  ffi_func :sqlite3_bind_int64,   [:ptr, :int, :long], :int
  # 第 5 引数は destructor。SQLITE_TRANSIENT = (void*)-1 を :long の -1 で渡す
  ffi_func :sqlite3_bind_text,    [:ptr, :int, :str, :int, :long], :int
  ffi_func :sqlite3_finalize,     [:ptr], :int
  ffi_func :sqlite3_errmsg,       [:ptr], :str
  ffi_buffer :db_out,   8
  ffi_buffer :stmt_out, 8
  ffi_buffer :tail_out, 8
  ffi_read_ptr :read_ptr, 0
end

class Catalog
  def initialize
    @db = nil
  end

  def errmsg
    "sqlite: " + SQLITE.sqlite3_errmsg(@db)
  end

  # binds: [["s", v] | ["i", v], ...]。結果行は [各列 (want_types: "s"/"i")]。
  # 戻り: [err, rows]
  def q(sql, binds, want_types)
    if SQLITE.sqlite3_prepare_v2(@db, sql, -1, SQLITE.stmt_out, SQLITE.tail_out) != SQLITE::OK
      return [errmsg + " in: " + sql, []]
    end
    stmt = SQLITE.read_ptr(SQLITE.stmt_out)
    i = 0
    while i < binds.length
      b = binds[i]
      if b[0] == "i"
        SQLITE.sqlite3_bind_int64(stmt, i + 1, b[1])
      else
        SQLITE.sqlite3_bind_text(stmt, i + 1, b[1], -1, -1)
      end
      i += 1
    end
    rows = []
    loop do
      rc = SQLITE.sqlite3_step(stmt)
      break if rc == SQLITE::DONE
      if rc != SQLITE::ROW
        e = errmsg
        SQLITE.sqlite3_finalize(stmt)
        return [e + " in: " + sql, []]
      end
      row = []
      c = 0
      while c < want_types.length
        row << (want_types[c] == "i" ? SQLITE.sqlite3_column_int64(stmt, c) :
                                       SQLITE.sqlite3_column_text(stmt, c))
        c += 1
      end
      rows << row
    end
    SQLITE.sqlite3_finalize(stmt)
    ["", rows]
  end

  def exec(sql, binds)
    err, _rows = q(sql, binds, [])
    err
  end

  # 戻り: err ("" = 成功)
  def open(path)
    return "sqlite3_open failed" unless SQLITE.sqlite3_open(path, SQLITE.db_out) == SQLITE::OK
    @db = SQLITE.read_ptr(SQLITE.db_out)
    SQLITE.sqlite3_busy_timeout(@db, 5000)
    err = exec("PRAGMA journal_mode=WAL", [])   # 返る 1 行は q() が読み捨てる
    return err if err != ""
    exec("CREATE TABLE IF NOT EXISTS segments(" \
         "path TEXT PRIMARY KEY, rows INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'live')", [])
  end

  def register(path, nrows)
    exec("INSERT INTO segments(path, rows, state) VALUES(?, ?, 'live')",
         [["s", path], ["i", nrows]])
  end

  # [err, [[path, rows], ...]]
  def live
    q("SELECT path, rows FROM segments WHERE state = 'live' ORDER BY path", [], ["s", "i"])
  end

  # [err, [path, ...]]
  def dead_paths
    err, rows = q("SELECT path FROM segments WHERE state = 'dead'", [], ["s"])
    [err, rows.map { |r| r[0].to_s }]
  end

  def purge_dead(path)
    exec("DELETE FROM segments WHERE path = ? AND state = 'dead'", [["s", path]])
  end

  # compaction の原子的置換: olds → dead、new → live を 1 txn で
  def swap(old_paths, new_path, new_rows)
    err = exec("BEGIN IMMEDIATE", [])
    return err if err != ""
    old_paths.each do |p|
      err = exec("UPDATE segments SET state = 'dead' WHERE path = ?", [["s", p]])
      if err != ""
        exec("ROLLBACK", [])
        return err
      end
    end
    err = register(new_path, new_rows)
    if err != ""
      exec("ROLLBACK", [])
      return err
    end
    exec("COMMIT", [])
  end
end
