# tools/wasm/spinel_host_table.rb -- the staged *table*: what a query or a
# listing answers with (E055).  Required by spinel_host_r2.rb and
# spinel_host_d1.rb; there is no reason to require it directly.
#
# E014 left one question open for this phase: `list` and a query answer with a
# SHAPE (an array, a grid) and not with a blob, so the staging slot needed a
# representation for one.  The answer is an ADDRESSED table rather than a
# serialized frame -- (row, col) -> tag + bytes, read through synchronous
# accessors.  The reasoning is in tools/wasm/sp_wasm_host.c; the short form is
# that nothing is ever parsed, so nothing can ever be mis-parsed: a BLOB with a
# NUL in it, a SQL NULL next to an empty string, and a TEXT cell containing the
# delimiter all just work.
#
# ★ Kept in its own file for the same reason R2 and D1 are: `require
#   "spinel_host"` must cost exactly what it cost in E014.  A program that
#   requires only the core pays nothing for any of this (measured: +8.8 KB of
#   module when they were all one file).
require "spinel_host"

module SpinelHost
  # Cell type tags.  Written as bare integers, not constants, because the tag
  # is compared in exactly four places:
  #
  #   0 NULL   1 INT   2 REAL   3 TEXT   4 BLOB
  #
  # The tag is what keeps SQL NULL distinct from a zero-length TEXT.  Both
  # arrive as "" -- only the tag tells them apart, which is R003 §3-1's rule
  # ("absent" and "empty" must not collapse) applied to a single cell.
  ffi_func :sp_host_tbl_rows,      [], :int
  ffi_func :sp_host_tbl_cols,      [], :int
  ffi_func :sp_host_tbl_col_name,  [:int], :str
  ffi_func :sp_host_tbl_cell_type, [:int, :int], :int
  ffi_func :sp_host_tbl_cell,      [:int, :int], :binstr

  # One row of a result -- a D1 query's, or an R2 listing's.
  #
  # ★ THE TYPE ARGUMENT.  A row is held as two monomorphic Arrays -- the cells'
  #   bytes (Array of String) and their tags (Array of Integer) -- and never as
  #   a Hash of mixed values.  That is deliberate, and it is why the accessors
  #   are typed:
  #
  #     row.str("title")   -> String    the call site's type is TY_STRING
  #     row.int("id")      -> Integer   the call site's type is TY_INT
  #     row.float("score") -> Float     the call site's type is TY_FLOAT
  #
  #   Spinel infers types for the whole program, and an inferred type is what
  #   decides whether a value is a machine word or a boxed sp_RbVal (R001 §1.5).
  #   A `row["id"]` that could be any of Integer / Float / String / nil widens
  #   to TY_POLY and boxes -- at every call site, for every row, forever.  A
  #   typed accessor stays unboxed no matter what the column actually holds,
  #   and the tag is still there for the program to ask about (`null?`, `tag`).
  #
  #   The cost is that the caller says what it expects.  For SQL that is not a
  #   cost: the schema already said.
  #
  # ★ The method names avoid `index`, `key?`, `to_h` and `each` on purpose.  A
  #   name a prelude defines is a name it takes away from every program that
  #   requires it, and a user-defined one-argument `each` collided with the
  #   built-in two-argument `Hash#each` badly enough to make an unrelated
  #   function in spinel_host.rb trap (E055 §10a).
  class Row
    attr_reader :columns

    def initialize(columns, cells, tags)
      @columns = columns
      @cells = cells
      @tags = tags
    end

    def column_index(name)
      want = name.to_s
      i = 0
      while i < @columns.length
        return i if @columns[i] == want
        i += 1
      end
      -1
    end

    def column?(name)
      column_index(name) >= 0
    end

    # The cell's bytes, verbatim.  A BLOB comes back byte-exact (NUL included);
    # a NULL comes back as "" and `null?` is how that is told from an empty
    # TEXT.  An unknown column name raises rather than answering "" -- asking
    # for a column that is not in the result is a program error, and R003 §3-1
    # forbids answering it with a value that looks like data.
    def str(name)
      i = column_index(name)
      raise ArgumentError, "no column #{name} in (#{@columns.join(", ")})" if i < 0
      @cells[i]
    end

    def int(name)
      str(name).to_i
    end

    def float(name)
      str(name).to_f
    end

    def null?(name)
      i = column_index(name)
      raise ArgumentError, "no column #{name} in (#{@columns.join(", ")})" if i < 0
      @tags[i] == 0
    end

    # 0 NULL / 1 INT / 2 REAL / 3 TEXT / 4 BLOB -- what SQLite stored, not what
    # the column was declared as (SQLite is dynamically typed per value).
    def tag(name)
      i = column_index(name)
      raise ArgumentError, "no column #{name} in (#{@columns.join(", ")})" if i < 0
      @tags[i]
    end

    def blob?(name)
      tag(name) == 4
    end

    def fields
      out = {}
      i = 0
      while i < @columns.length
        out[@columns[i]] = @cells[i]
        i += 1
      end
      out
    end
  end

  # Decode the staged table into `rows` Row objects.  Called by D1Stmt#all and
  # R2.list.  Every cell is read into a local before the next call is made: the
  # C side rotates four drain buffers so that the natural two-cell expression is
  # safe anyway, but this does not rely on that -- it is strictly sequenced
  # (E014's "belt and braces" for the body and header slots, applied to a grid).
  def self.read_table(rows)
    out = []
    return out if rows <= 0

    ncols = SpinelHost.sp_host_tbl_cols
    columns = []
    c = 0
    while c < ncols
      columns << SpinelHost.sp_host_tbl_col_name(c)
      c += 1
    end

    r = 0
    while r < rows
      cells = []
      tags = []
      c = 0
      while c < ncols
        tag = SpinelHost.sp_host_tbl_cell_type(r, c)
        value = SpinelHost.sp_host_tbl_cell(r, c)
        tags << tag
        cells << value
        c += 1
      end
      out << Row.new(columns, cells, tags)
      r += 1
    end
    out
  end
end
