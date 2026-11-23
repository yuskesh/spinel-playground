# spinel-tier: full
#
# The editor core intentionally knows nothing about terminals, files, Unicode,
# or vi commands. Every offset in this file is a byte offset. Phase 5 owns
# grapheme boundaries; callers must not mistake these offsets for characters.

module SpinelVi
  SOURCE_ORIGINAL = 0
  SOURCE_ADDED = 1

  # Source is one of SOURCE_ORIGINAL / SOURCE_ADDED. Offsets and lengths are
  # byte counts. Pieces are never zero-length in a normalized PieceTable.
Piece = Data.define(:piece_source, :piece_offset, :piece_length)

  class LineIndex
    def initialize(text)
      rebuild(text)
    end

    # Rebuild is deliberately simple in Phase 1. The public contract is kept
    # separate from PieceTable so an incremental implementation can replace it
    # later without changing editor callers.
    def rebuild(text)
      @starts = [0]
      @length = text.bytesize
      i = 0
      while i < @length
        @starts.push(i + 1) if text.getbyte(i) == 10 # LF
        i += 1
      end
    end

    def line_count
      @starts.length
    end

    # Lines are zero-based. line_end is the byte offset immediately after the
    # visible content, so a trailing LF is excluded from a line's content.
    def line_start(line)
      check_line(line)
      @starts[line]
    end

    def line_end(line)
      check_line(line)
      if line + 1 < @starts.length
        @starts[line + 1] - 1
      else
        @length
      end
    end

    # Position at EOF belongs to the final line. This makes an empty buffer
    # have one editable line and handles a trailing LF as its final empty line.
    def line_at(offset)
      if offset < 0 || offset > @length
        raise IndexError, "line lookup outside buffer"
      end

      line = 0
      while line + 1 < @starts.length && @starts[line + 1] <= offset
        line += 1
      end
      line
    end

    private

    def check_line(line)
      if line < 0 || line >= @starts.length
        raise IndexError, "line outside buffer"
      end
    end
  end

  class PieceTable
    attr_reader :original, :added, :pieces, :line_index

    def initialize(text)
      @original = text.dup.freeze
      @added = ""
      # A Piece literal fixes the logical element type before an empty input
      # becomes observable as the canonical [] representation.
      @pieces = [make_piece(SOURCE_ORIGINAL, 0, @original.bytesize)]
      @pieces.clear if @original.bytesize == 0
      @length = @original.bytesize
      @line_index = LineIndex.new(@original)
      check_invariants
    end

    def length
      @length
    end

    def empty?
      @length == 0
    end

    def materialize
      out = ""
      i = 0
      while i < @pieces.length
        piece = @pieces[i]
        out += source_text(piece).byteslice(piece.piece_offset, piece.piece_length)
        i += 1
      end
      out
    end

    def slice(offset, count)
      check_range(offset, count)
      return "" if count == 0

      finish = offset + count
      out = ""
      cursor = 0
      i = 0
      while i < @pieces.length
        piece = @pieces[i]
        piece_finish = cursor + piece.piece_length
        if piece_finish > offset && cursor < finish
          from = offset > cursor ? offset - cursor : 0
          to = finish < piece_finish ? finish - cursor : piece.piece_length
          out += source_text(piece).byteslice(piece.piece_offset + from, to - from)
        end
        cursor = piece_finish
        i += 1
      end
      out
    end

    def insert(offset, text)
      check_position(offset)
      return self if text.bytesize == 0

      added_offset = @added.bytesize
      @added += text
      rewrite(offset, 0, added_offset, text.bytesize)
      self
    end

    def delete(offset, count)
      check_range(offset, count)
      return self if count == 0

      rewrite(offset, count, 0, 0)
      self
    end

    def find_piece(offset)
      if offset < 0 || offset >= @length
        raise IndexError, "piece lookup outside buffer"
      end

      cursor = 0
      i = 0
      while i < @pieces.length
        next_cursor = cursor + @pieces[i].piece_length
        return i if offset < next_cursor
        cursor = next_cursor
        i += 1
      end
      raise RuntimeError, "piece table invariant violated"
    end

    def check_invariants
      total = 0
      previous = nil
      i = 0
      while i < @pieces.length
        piece = @pieces[i]
        if piece.piece_source != SOURCE_ORIGINAL && piece.piece_source != SOURCE_ADDED
          raise RuntimeError, "piece has unknown source"
        end
        if piece.piece_offset < 0 || piece.piece_length <= 0
          raise RuntimeError, "piece has invalid range"
        end
        if piece.piece_offset + piece.piece_length > source_text(piece).bytesize
          raise RuntimeError, "piece extends beyond source"
        end
        if !previous.nil? && previous.piece_source == piece.piece_source &&
           previous.piece_offset + previous.piece_length == piece.piece_offset
          raise RuntimeError, "adjacent pieces were not coalesced"
        end
        total += piece.piece_length
        previous = piece
        i += 1
      end
      if total != @length
        raise RuntimeError, "piece lengths do not cover buffer"
      end
      if @length == 0 && @pieces.length != 0
        raise RuntimeError, "empty buffer has pieces"
      end
      if @length > 0 && @pieces.length == 0
        raise RuntimeError, "nonempty buffer has no pieces"
      end
      true
    end


    private

    def source_text(piece)
      if piece.piece_source == SOURCE_ORIGINAL
        @original
      elsif piece.piece_source == SOURCE_ADDED
        @added
      else
        raise RuntimeError, "piece has unknown source"
      end
    end

    def check_position(offset)
      if offset < 0 || offset > @length
        raise IndexError, "position outside buffer"
      end
    end

    def check_range(offset, count)
      if count < 0
        raise IndexError, "negative range length"
      end
      check_position(offset)
      if count > @length - offset
        raise IndexError, "range outside buffer"
      end
    end

    def rewrite(offset, removed, added_offset, added_length)
      finish = offset + removed
      next_pieces = @pieces.dup
      next_pieces.clear
      inserted = false
      cursor = 0
      i = 0
      while i < @pieces.length
        piece = @pieces[i]
        piece_finish = cursor + piece.piece_length
        if piece_finish <= offset
          next_pieces.push(piece)
        elsif cursor >= finish
          if !inserted
            append_added(next_pieces, added_offset, added_length)
            inserted = true
          end
          next_pieces.push(piece)
        else
          if cursor < offset
            next_pieces.push(make_piece(piece.piece_source, piece.piece_offset,
                                        offset - cursor))
          end
          if piece_finish > finish
            if !inserted
              append_added(next_pieces, added_offset, added_length)
              inserted = true
            end
            right_offset = piece.piece_offset + (finish - cursor)
            next_pieces.push(make_piece(piece.piece_source, right_offset,
                                        piece_finish - finish))
          end
        end
        cursor = piece_finish
        i += 1
      end
      append_added(next_pieces, added_offset, added_length) if !inserted
      @pieces = coalesce(next_pieces)
      @length = @length - removed + added_length
      @line_index.rebuild(materialize)
      check_invariants
    end

    def append_added(pieces, offset, length)
      pieces.push(make_piece(SOURCE_ADDED, offset, length)) if length > 0
    end

    def coalesce(input)
      output = input.dup
      output.clear
      i = 0
      while i < input.length
        piece = input[i]
        if output.length > 0
          previous = output[output.length - 1]
          if previous.piece_source == piece.piece_source &&
             previous.piece_offset + previous.piece_length == piece.piece_offset
            output[output.length - 1] = make_piece(previous.piece_source,
                                                    previous.piece_offset,
                                                    previous.piece_length + piece.piece_length)
          else
            output.push(piece)
          end
        else
          output.push(piece)
        end
        i += 1
      end
      output
    end

    # All Piece fields are byte integers by contract. This single full-program
    # type boundary rejects non-integers loudly before fixing Data's layout.
    # Range validity remains check_invariants' responsibility: initialize("")
    # deliberately creates then clears a zero-length sentinel.
    def make_piece(source, offset, length)
      if !source.is_a?(Integer) || !offset.is_a?(Integer) || !length.is_a?(Integer)
        raise TypeError, "piece source, offset, and length must be Integer"
      end
      Piece.new(source.to_i, offset.to_i, length.to_i)
    end
  end

  class Cursor
    attr_reader :offset

    def initialize(offset = 0)
      if offset < 0
        raise IndexError, "cursor before buffer"
      end
      @offset = offset
    end

    def move_to(offset, table)
      if offset < 0 || offset > table.length
        raise IndexError, "cursor outside buffer"
      end
      @offset = offset
      self
    end

    def move_by(delta, table)
      move_to(@offset + delta, table)
    end

    def line(table)
      table.line_index.line_at(@offset)
    end

    def column(table)
      @offset - table.line_index.line_start(line(table))
    end
  end
end
