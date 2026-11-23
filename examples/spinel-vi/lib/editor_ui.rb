# spinel-tier: full
# ASCII-only Phase 2 state machine and screen model.  Byte offsets come from
# editor_core.rb; grapheme movement, search, undo, and file I/O are later work.

require_relative "editor_core"
require_relative "file_store"

module SpinelVi
  MODE_NORMAL = 0
  MODE_INSERT = 1
  MODE_COMMAND = 2
  COMMAND_EX = 0
  COMMAND_SEARCH = 1
  Transaction = Data.define(:before_text, :cursor, :after_text, :after_cursor)

  class Editor
    attr_reader :table, :cursor, :mode, :top_line, :width, :height, :command
    attr_reader :notice, :running, :search_pattern, :match_start, :match_end

    def initialize(width = 80, height = 24, path = "", text = "")
      if !text.is_a?(String) || !path.is_a?(String)
        raise TypeError, "editor path and text must be String"
      end
      @table = PieceTable.new(text)
      @cursor = Cursor.new
      @mode = MODE_NORMAL
      @top_line = 0
      @width = width
      @height = height
      @command = ""
      @command_kind = COMMAND_EX
      @notice = ""
      @running = true
      @path = path
      @undo = []
      @redo = []
      @saved = @table.materialize
      @register = ""
      @pending = 0
      @insert_before = nil
      @preferred_column = -1
      @search_pattern = ""
      @match_start = -1
      @match_end = -1
    end

    def resize(width, height)
      @width = width > 0 ? width : 1
      @height = height > 0 ? height : 1
      keep_cursor_visible
    end

    def handle_key(ch, key)
      if @mode == MODE_NORMAL
        handle_normal(ch, key)
      elsif @mode == MODE_INSERT
        handle_insert(ch, key)
      else
        handle_command(ch, key)
      end
      keep_cursor_visible
    end

    # The terminal-independent screen rows are homogeneous Array<String>.
    # Cursor coordinates have separate accessors: returning a heterogeneous
    # [rows, x, y] tuple would widen the caller in Spinel.
    def screen_rows
      content_rows = content_height
      rows = []
      row = 0
      while row < content_rows
        line = @top_line + row
        if line < @table.line_index.line_count
          start = @table.line_index.line_start(line)
          finish = @table.line_index.line_end(line)
          rows.push(clip(@table.slice(start, finish - start)))
        else
          rows.push("~")
        end
        row += 1
      end
      rows.push(clip(status_line)) if @height >= 2
      rows.push(clip(command_line)) if @height >= 1
      rows
    end

    def screen_cursor_x
      cursor_x
    end

    def screen_cursor_y
      cursor_y
    end

    private

    def handle_normal(ch, key)
      if (@pending == 100 && ch != 100) || (@pending == 121 && ch != 121)
        @pending = 0
        @notice = "operator cancelled"
        return
      end
      if escape?(ch, key)
        @notice = ""
      elsif ch == 104 # h
        move_left
      elsif ch == 106 # j
        move_down
      elsif ch == 107 # k
        move_up
      elsif ch == 108 # l
        move_right
      elsif ch == 105 # i
        begin_transaction
        @mode = MODE_INSERT
        @notice = ""
      elsif ch == 97 # a
        begin_transaction
        move_right
        @mode = MODE_INSERT
        @notice = ""
      elsif ch == 111 # o
        begin_transaction
        open_below
      elsif ch == 120 # x
        begin_transaction
        delete_at_cursor
        end_transaction
      elsif ch == 100 # d
        @pending = @pending == 100 ? 0 : 100
        delete_line if @pending == 0
      elsif ch == 121 # y
        @pending = @pending == 121 ? 0 : 121
        yank_line if @pending == 0
      elsif ch == 112 # p
        paste_register
      elsif ch == 117 # u
        undo
      elsif key == 18
        redo_edit
      elsif ch == 110 # n
        repeat_search
      elsif ch == 47 # /
        @mode = MODE_COMMAND
        @command_kind = COMMAND_SEARCH
        @command = ""
        @notice = ""
      elsif ch == 58 # :
        @mode = MODE_COMMAND
        @command_kind = COMMAND_EX
        @command = ""
        @notice = ""
      end
    end

    def handle_insert(ch, key)
      if escape?(ch, key)
        @mode = MODE_NORMAL
        end_transaction
      elsif enter?(ch, key)
        @table.insert(@cursor.offset, "\n")
        @cursor.move_by(1, @table)
      elsif backspace?(ch, key)
        if @cursor.offset > 0
          before = ViTerm.sp_vi_egc_prev(@table.materialize, @table.length, @cursor.offset)
          @table.delete(before, @cursor.offset - before)
          @cursor.move_to(before, @table)
          @preferred_column = -1
        end
      elsif ch > 0 && ch < 128
        @table.insert(@cursor.offset, ch.chr)
        @cursor.move_by(1, @table)
      elsif ch > 0
        @notice = "ASCII only"
      end
    end

    def handle_command(ch, key)
      if escape?(ch, key)
        @mode = MODE_NORMAL
        @command = ""
        @command_kind = COMMAND_EX
      elsif enter?(ch, key)
        if @command_kind == COMMAND_SEARCH
          finish_search
        else
          finish_command
        end
      elsif backspace?(ch, key)
        @command = prefix_bytes(@command, @command.bytesize - 1)
      elsif ch > 0 && ch < 128
        @command += ch.chr
      elsif ch > 0
        @notice = "ASCII only"
      end
    end

    def finish_command
      if @command == "w" || @command == "wq"
        if @path.bytesize == 0
          @notice = "write requires a file path"
        elsif FileStore.save(@path, @table.materialize) == 0
          @saved = @table.materialize
          @notice = "written"
          @running = false if @command == "wq"
        else
          @notice = "write failed: " + FileStore.error
        end
      elsif @command == "q"
        @running = false if !dirty?
        @notice = "unsaved changes (use :q!)" if dirty?
      elsif @command == "q!"
        @running = false
      else
        @notice = "not implemented: :" + @command
      end
      @mode = MODE_NORMAL
      @command = ""
      @command_kind = COMMAND_EX
    end

    def finish_search
      if @command.bytesize == 0
        @notice = "empty search"
      else
        search_from(@command, @cursor.offset, false)
      end
      @mode = MODE_NORMAL
      @command = ""
      @command_kind = COMMAND_EX
    end

    def repeat_search
      if @search_pattern.bytesize == 0
        @notice = "no previous search"
        return
      end
      offset = if @match_start == @match_end && @match_end < @table.length
                 @match_end + 1
               elsif @match_start == @match_end
                 0
               else
                 @match_end
               end
      search_from(@search_pattern, offset, @match_start == @match_end && @match_end == @table.length)
    end

    # A no-match from a nonzero byte offset wraps exactly once to byte zero.
    # In particular, a zero-length match advances its next start byte before
    # this method is called, so repeated `n` cannot spin on one byte range.
    def search_from(pattern, offset, wrapped)
      rc = ViTerm.sp_vi_bre_find(pattern, @table.materialize, offset)
      if rc == 0
        @cursor.move_to(ViTerm.sp_vi_bre_start, @table)
        @match_start = ViTerm.sp_vi_bre_start
        @match_end = ViTerm.sp_vi_bre_end
        @search_pattern = pattern
        @notice = wrapped ? "search wrapped" : "match"
        return true
      end
      if rc == 1 && offset > 0 && !wrapped
        return search_from(pattern, 0, true)
      end
      @notice = rc == 1 ? "pattern not found" : "search error: " + ViTerm.sp_vi_bre_error
      false
    end

    def move_left
      start = @table.line_index.line_start(@cursor.line(@table))
      if @cursor.offset > start
        @cursor.move_to(ViTerm.sp_vi_egc_prev(@table.materialize, @table.length, @cursor.offset), @table)
        @preferred_column = -1
      end
    end

    def move_right
      finish = @table.line_index.line_end(@cursor.line(@table))
      if @cursor.offset < finish
        @cursor.move_to(ViTerm.sp_vi_egc_next(@table.materialize, @table.length, @cursor.offset), @table)
        @preferred_column = -1
      end
    end

    def move_up
      line = @cursor.line(@table)
      move_to_line(line - 1, preferred_column) if line > 0
    end

    def move_down
      line = @cursor.line(@table)
      if line + 1 < @table.line_index.line_count
        move_to_line(line + 1, preferred_column)
      end
    end

    def move_to_line(line, column)
      start = @table.line_index.line_start(line)
      finish = @table.line_index.line_end(line)
      at = start
      cells = 0
      while at < finish
        width = ViTerm.sp_vi_egc_width(@table.materialize, @table.length, at, cells)
        next_at = ViTerm.sp_vi_egc_next(@table.materialize, @table.length, at)
        break if width < 0 || cells + width > column
        cells += width
        at = next_at
      end
      @cursor.move_to(at, @table)
    end

    def open_below
      line = @cursor.line(@table)
      at = @table.line_index.line_end(line)
      @table.insert(at, "\n")
      @cursor.move_to(at + 1, @table)
      @mode = MODE_INSERT
      @notice = ""
    end

    def begin_transaction
      @insert_before = Transaction.new(@table.materialize, @cursor.offset, "", 0)
    end

    def end_transaction
      return if @insert_before.nil?
      after = @table.materialize
      if @insert_before.before_text != after
        @undo.push(Transaction.new(@insert_before.before_text, @insert_before.cursor, after, @cursor.offset))
        @redo.clear
      end
      @insert_before = nil
    end

    def undo
      return if @undo.length == 0
      t = @undo.pop; @table = PieceTable.new(t.before_text); @cursor.move_to(t.cursor, @table); @redo.push(t)
    end

    def redo_edit
      return if @redo.length == 0
      t = @redo.pop; @table = PieceTable.new(t.after_text); @cursor.move_to(t.after_cursor, @table); @undo.push(t)
    end

    def delete_line
      begin_transaction
      line = @cursor.line(@table)
      start = @table.line_index.line_start(line)
      finish = @table.line_index.line_end(line)
      length = @table.length
      finish += 1 if finish < length && @table.slice(finish, 1) == "\n"
      @register = @table.slice(start, finish - start)
      @table.delete(start, finish - start)
      target = start > length ? length : start
      target = @table.length if target > @table.length
      @cursor.move_to(target, @table)
      end_transaction
    end

    def yank_line
      start = @table.line_index.line_start(@cursor.line(@table)); finish = @table.line_index.line_end(@cursor.line(@table))
      finish += 1 if finish < @table.length && @table.slice(finish, 1) == "\n"; @register = @table.slice(start, finish - start)
    end

    def paste_register
      return if @register.bytesize == 0
      begin_transaction; at = @table.line_index.line_end(@cursor.line(@table)); at += 1 if at < @table.length && @table.slice(at, 1) == "\n"
      text = @register; text = "\n" + text if at == @table.length && at > 0 && @table.slice(at - 1, 1) != "\n"
      @table.insert(at, text); @cursor.move_to(at, @table); end_transaction
    end

    def dirty?
      @saved != @table.materialize
    end

    def delete_at_cursor
      if @cursor.offset < @table.length
        finish = ViTerm.sp_vi_egc_next(@table.materialize, @table.length, @cursor.offset)
        @table.delete(@cursor.offset, finish - @cursor.offset)
        @preferred_column = -1
      end
    end

    def content_height
      return 0 if @height < 3
      @height - 2
    end

    def keep_cursor_visible
      line = @cursor.line(@table)
      rows = content_height
      if rows == 0
        @top_line = line
      elsif line < @top_line
        @top_line = line
      elsif line >= @top_line + rows
        @top_line = line - rows + 1
      end
    end

    def cursor_x
      column = display_column
      column = @width - 1 if column >= @width
      column = 0 if column < 0
      column
    end

    def cursor_y
      y = @cursor.line(@table) - @top_line
      return -1 if y < 0 || y >= content_height
      y
    end

    def status_line
      name = if @mode == MODE_INSERT
               "INSERT"
             elsif @mode == MODE_COMMAND
               "COMMAND"
             else
               "NORMAL"
             end
      "-- " + name + " -- " + (@cursor.line(@table) + 1).to_s + ":" +
        (@cursor.column(@table) + 1).to_s + " " + @notice
    end

    def command_line
      if @mode != MODE_COMMAND
        ""
      elsif @command_kind == COMMAND_SEARCH
        "/" + @command
      else
        ":" + @command
      end
    end

    def clip(text)
      out = ""
      at = 0
      cells = 0
      while at < text.bytesize
        width = ViTerm.sp_vi_egc_width(text, text.bytesize, at, cells)
        next_at = ViTerm.sp_vi_egc_next(text, text.bytesize, at)
        break if width < 0 || cells + width > @width
        out += range_bytes(text, at, next_at - at)
        cells += width
        at = next_at
      end
      out
    end

    def display_column
      start = @table.line_index.line_start(@cursor.line(@table))
      at = start
      cells = 0
      text = @table.materialize
      while at < @cursor.offset
        width = ViTerm.sp_vi_egc_width(text, text.bytesize, at, cells)
        next_at = ViTerm.sp_vi_egc_next(text, text.bytesize, at)
        break if width < 0 || next_at > @cursor.offset
        cells += width
        at = next_at
      end
      cells
    end

    def preferred_column
      @preferred_column = display_column if @preferred_column < 0
      @preferred_column
    end

    # Keep screen rendering on the direct byte primitives that are already
    # exercised by E101; String#byteslice on this UI call site is not lowered
    # by the current Spinel runtime.
    def prefix_bytes(text, count)
      range_bytes(text, 0, count)
    end

    def range_bytes(text, start, count)
      out = ""
      i = 0
      limit = count
      limit = 0 if limit < 0
      limit = text.bytesize - start if limit > text.bytesize - start
      while i < limit
        out += text.getbyte(start + i).chr
        i += 1
      end
      out
    end

    def escape?(ch, key)
      ch == 27 || key == 27
    end

    def enter?(ch, key)
      ch == 13 || ch == 10 || key == 13
    end

    def backspace?(ch, key)
      ch == 8 || ch == 127 || key == 8 || key == 127
    end
  end
end
