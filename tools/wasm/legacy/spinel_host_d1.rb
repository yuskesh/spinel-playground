# tools/wasm/spinel_host_d1.rb -- Workers D1 (SQL) from Ruby
# (R003 §2-4 layer 1, E055).  Opt-in:
#
#   require "spinel_host_d1"
#   SpinelHost::D1.exec("DB", "CREATE TABLE IF NOT EXISTS posts (...)")
#   st  = SpinelHost::D1.prepare("DB", "SELECT id, title FROM posts WHERE id = ?")
#   row = st.int(id).first                  # nil when nothing matched
#   row.str("title")                        # a String  (byte-exact)
#   row.int("id")                           # an Integer
#
# The database name is the *binding* name from wrangler.toml and must be listed
# in SPINEL_HOST_D1.
#
# ★ VALUES NEVER TOUCH THE SQL TEXT.  There is no method here that takes a
#   statement and a value together, so there is nothing to interpolate and
#   nothing to forget to escape.  D1's prepare() takes a single statement, so a
#   bound string cannot become a second one however it is spelled.
require "spinel_host"
require "spinel_host_table"

module SpinelHost
  ffi_func :sp_host_d1_bind_reset, [], :int
  ffi_func :sp_host_d1_bind_null,  [], :int
  ffi_func :sp_host_d1_bind_int,   [:int64], :int
  ffi_func :sp_host_d1_bind_real,  [:double], :int
  ffi_func :sp_host_d1_bind_text,  [:str, :int], :int
  ffi_func :sp_host_d1_bind_blob,  [:str, :int], :int
  ffi_func :sp_host_d1_exec,       [:str, :str], :int

  # The result of one statement.  A SELECT has rows; an INSERT / UPDATE /
  # DELETE has `changes` and `last_row_id` and no rows -- both are described,
  # so a write is never a silent success.  Rows are SpinelHost::Row
  # (spinel_host_table.rb), with typed accessors.
  class D1Result
    attr_reader :rows, :changes, :last_row_id, :duration_ms

    def initialize(rows, changes, last_row_id, duration_ms)
      @rows = rows
      @changes = changes
      @last_row_id = last_row_id
      @duration_ms = duration_ms
    end

    def size
      @rows.length
    end

    def empty?
      @rows.empty?
    end

    # ★ `each_row`, not `each`.  A user-defined `each` that yields ONE value
    #   collides with the built-in two-value `Hash#each` at the whole-program
    #   level on this target.  Defining it here made
    #   `SpinelHost.format_headers({...})` -- a function in spinel_host.rb that
    #   has worked since E014, and which does `headers.each do |k, v|` --
    #   return a String whose first `.bytesize` trapped with `memory access out
    #   of bounds`.  A different file, an unrelated function, no error at the
    #   definition site; bisected to this method one prelude member at a time.
    #   The same caution renames Row's accessors to `column_index` / `column?` /
    #   `fields` (spinel_host_table.rb): a prelude is linked into every program
    #   that requires it, so a name it defines is a name it takes away from
    #   everyone.
    #
    #   The body is an index loop rather than `@rows.each { yield }` for a
    #   second reason: nesting a yield inside a block is a shape this target
    #   has no coverage for, and the loop costs nothing.
    def each_row
      i = 0
      while i < @rows.length
        yield @rows[i]
        i += 1
      end
      self
    end

    def first
      @rows.empty? ? nil : @rows[0]
    end
  end

  # A prepared statement.  Values go in through the typed binders and NEVER
  # through the SQL string:
  #
  #   SpinelHost::D1.prepare("DB", "INSERT INTO posts (title, body) VALUES (?, ?)")
  #                 .text(title).text(body).run
  #
  # There is no method on this class that takes SQL and a value together, so
  # there is no interpolation to forget.  D1's prepare() takes a SINGLE
  # statement, so a bound string cannot become a second one however it is
  # spelled: `'; DROP TABLE posts; --` is five words in a TEXT column.
  class D1Stmt
    def initialize(database, sql)
      @database = database.to_s
      @sql = sql.to_s
      @count = 0
      SpinelHost.sp_host_d1_bind_reset
    end

    def int(value)
      SpinelHost.sp_host_d1_bind_int(value.to_i)
      @count += 1
      self
    end

    def float(value)
      SpinelHost.sp_host_d1_bind_real(value.to_f)
      @count += 1
      self
    end

    # Byte-exact, NUL included: the length is passed explicitly rather than
    # letting C strlen() decide where the value ends.
    def text(value)
      v = value.to_s
      SpinelHost.sp_host_d1_bind_text(v, v.bytesize)
      @count += 1
      self
    end

    def blob(value)
      v = value.to_s
      SpinelHost.sp_host_d1_bind_blob(v, v.bytesize)
      @count += 1
      self
    end

    def null
      SpinelHost.sp_host_d1_bind_null
      @count += 1
      self
    end

    def binds
      @count
    end

    # Run it.  Returns a D1Result whether or not the statement produced rows.
    def all
      n = SpinelHost.sp_host_d1_exec(@database, @sql)
      table = SpinelHost.read_table(n)
      meta = SpinelHost.parse_headers(SpinelHost.sp_host_res_headers)
      D1Result.new(table, meta["changes"].to_i, meta["last_row_id"].to_i,
                   meta["duration_ms"].to_f)
    end

    # The first row, or nil.  Not "the first row or an empty row": a query that
    # matched nothing and a query that matched a row of empty strings are
    # different facts.
    def first
      all.first
    end

    # For a write.  Returns the number of rows changed.
    def run
      all.changes
    end
  end

  # ---- reading the staged table ----------------------------------------------
  # Called by D1Stmt#all and R2.list.  Every cell is read into a local before
  # the next call is made: the C side rotates four drain buffers so that the
  # natural two-cell expression is safe anyway, but the wrapper does not rely on
  # that -- it is strictly sequenced (E014's "belt and braces" for the body and
  # header slots, applied to a grid).
  module D1
    def self.prepare(database, sql)
      D1Stmt.new(database, sql)
    end

    # Parameterless statements only -- DDL and the like.  There is deliberately
    # no `query(sql, params)` convenience: a method that takes SQL and values
    # in one call is the shape that invites interpolation, and an Array of
    # mixed-type params would widen to TY_POLY at every call site anyway (see
    # the note on Row).  Values go through prepare(...).text(x).
    def self.exec(database, sql)
      D1Stmt.new(database, sql).all
    end
  end
end
