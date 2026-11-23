# libghostty-vt in Ruby terms. The FFI stops here: nothing outside this file
# names a ghostty_ function, an option number or a struct offset.
module Ghostty
  module C
    ffi_func :ghostty_terminal_new, [:ptr, :ptr, :uint16, :uint16], :int
    ffi_func :ghostty_terminal_vt_write, [:ptr, :binstr, :size_t], :void
    ffi_func :ghostty_terminal_resize, [:ptr, :uint16, :uint16, :uint32, :uint32], :int
    ffi_func :ghostty_terminal_set, [:ptr, :int, :ptr], :int
    ffi_func :ghostty_terminal_get, [:ptr, :int, :ptr], :int
    ffi_func :tw_scroll, [:ptr, :int, :int], :void
    ffi_func :ghostty_render_state_new, [:ptr, :ptr], :int
    ffi_func :ghostty_render_state_update, [:ptr, :ptr], :int
    ffi_func :ghostty_render_state_get, [:ptr, :int, :ptr], :int
    ffi_func :ghostty_render_state_clean, [:ptr], :int
    ffi_func :ghostty_render_state_row_iterator_new, [:ptr, :ptr], :int
    ffi_func :ghostty_render_state_row_iterator_next_dirty, [:ptr, :ptr], :bool
    ffi_func :ghostty_render_state_row_get, [:ptr, :int, :ptr], :int
    ffi_func :ghostty_render_state_row_cells_new, [:ptr, :ptr], :int
    ffi_func :ghostty_render_state_row_cells_next, [:ptr], :bool
    ffi_func :ghostty_render_state_row_cells_get, [:ptr, :int, :ptr], :int
    ffi_func :ghostty_key_encoder_new, [:ptr, :ptr], :int
    ffi_func :ghostty_key_encoder_set_from_terminal, [:ptr, :ptr], :int
    ffi_func :ghostty_key_encoder_encode, [:ptr, :ptr, :ptr, :size_t, :ptr], :int
    ffi_func :ghostty_key_event_new, [:ptr, :ptr], :int
    ffi_func :ghostty_key_event_set_action, [:ptr, :int], :int
    ffi_func :ghostty_key_event_set_key, [:ptr, :int], :int
    ffi_func :ghostty_key_event_set_mods, [:ptr, :uint16], :int
    ffi_func :ghostty_key_event_set_unshifted_codepoint, [:ptr, :uint32], :int
    ffi_func :tw_key_event_set_text, [:ptr, :binstr, :size_t], :int

    ffi_buffer :out, 16
    ffi_buffer :iterator_slot, 8
    ffi_buffer :cells_slot, 8
    ffi_buffer :codepoints, 64
    ffi_buffer :codepoint_request, 16
    ffi_buffer :scrollbar, 24
    ffi_read_ptr :ptr_at, 0
    ffi_read_u32 :u32_at, 0
    ffi_read_u32 :u32_at_8, 8
    ffi_read_u32 :u32_at_16, 16
    ffi_read_u16 :u16_at, 0
    ffi_read_u8 :red_at, 0
    ffi_read_u8 :green_at, 1
    ffi_read_u8 :blue_at, 2
    ffi_read_u16 :style_flags_at, 12
    ffi_write_ptr :set_ptr, 0
    ffi_write_u32 :set_capacity, 4
    ffi_write_u32 :set_u32, 0

  end

  # A handle a ghostty_*_new call stores through the slot it is given.
  def self.new_handle
    yield C.out
    C.ptr_at(C.out)
  end

  def self.rgb_at(buffer)
    (C.red_at(buffer) << 16) | (C.green_at(buffer) << 8) | C.blue_at(buffer)
  end

  NO_VALUE = -4

  class Terminal
    SCROLLBACK_MAX_BYTES = 28
    SCROLLBACK_MAX_LINES = 29
    SCROLLBAR = 9
    SCROLL_TOP = 0
    SCROLL_BOTTOM = 1
    SCROLL_DELTA = 2

    attr_reader :handle

    def initialize(cols, rows, history_lines, history_bytes)
      @handle = Ghostty.new_handle { |slot| C.ghostty_terminal_new(nil, slot, cols, rows) }
      limit(SCROLLBACK_MAX_LINES, history_lines)
      limit(SCROLLBACK_MAX_BYTES, history_bytes)
    end

    def resize(cols, rows, cell_width, cell_height)
      C.ghostty_terminal_resize(@handle, cols, rows, cell_width, cell_height)
    end

    # Moves the view by rows: up is negative.
    def scroll_by(rows)
      C.tw_scroll(@handle, SCROLL_DELTA, rows)
    end

    def scroll_to_top
      C.tw_scroll(@handle, SCROLL_TOP, 0)
    end

    def scroll_to_bottom
      C.tw_scroll(@handle, SCROLL_BOTTOM, 0)
    end

    # Reads the scroll position that total_rows, view_offset and view_rows report.
    def read_scroll_position
      C.ghostty_terminal_get(@handle, SCROLLBAR, C.scrollbar)
    end

    def total_rows
      C.u32_at(C.scrollbar)
    end

    def view_offset
      C.u32_at_8(C.scrollbar)
    end

    def view_rows
      C.u32_at_16(C.scrollbar)
    end

    def write(text)
      C.ghostty_terminal_vt_write(@handle, text, text.bytesize)
    end

    private

    def limit(option, value)
      C.set_u32(C.out, value)
      C.ghostty_terminal_set(@handle, option, C.out)
    end
  end

  # A cell of the row being walked. One object is reused for the whole walk.
  class Cell
    BOLD = 1
    FAINT = 4
    ITALIC = 2
    INVERSE = 16
    INVISIBLE = 32
    STRIKETHROUGH = 64
    UNDERLINE_MASK = 0x700

    GRAPHEMES_LEN = 3
    GRAPHEMES_BUF = 4
    STYLE = 2
    BG = 5
    FG = 6
    HAS_STYLING = 8

    def initialize
      @handle = nil
      C.set_ptr(C.codepoint_request, C.codepoints)
      C.set_capacity(C.codepoint_request, 16)
    end

    def attach(handle)
      @handle = handle
    end

    def advance
      C.ghostty_render_state_row_cells_next(@handle)
    end

    def codepoint
      C.ghostty_render_state_row_cells_get(@handle, GRAPHEMES_LEN, C.out)
      return 0 if C.u32_at(C.out) == 0
      C.ghostty_render_state_row_cells_get(@handle, GRAPHEMES_BUF, C.codepoint_request)
      C.u32_at(C.codepoints)
    end

    def foreground(default)
      color(FG, default)
    end

    def background(default)
      color(BG, default)
    end

    def style_flags
      C.ghostty_render_state_row_cells_get(@handle, HAS_STYLING, C.out)
      return 0 if C.u32_at(C.out) & 255 == 0
      C.ghostty_render_state_row_cells_get(@handle, STYLE, C.out)
      C.style_flags_at(C.out)
    end

    private

    def color(what, default)
      return default if C.ghostty_render_state_row_cells_get(@handle, what, C.out) == NO_VALUE
      Ghostty.rgb_at(C.out)
    end
  end

  class RenderState
    ROW_ITERATOR = 4
    COLOR_BACKGROUND = 5
    COLOR_FOREGROUND = 6
    CURSOR_VISIBLE = 11
    CURSOR_HAS_VIEWPORT = 14
    CURSOR_X = 15
    CURSOR_Y = 16
    ROW_CELLS = 3

    def initialize(terminal)
      @terminal = terminal
      @handle = Ghostty.new_handle { |slot| C.ghostty_render_state_new(nil, slot) }
      C.ghostty_render_state_row_iterator_new(nil, C.iterator_slot)
      C.ghostty_render_state_row_cells_new(nil, C.cells_slot)
      @cell = Cell.new
    end

    def update
      C.ghostty_render_state_update(@handle, @terminal.handle)
    end

    def background
      rgb(COLOR_BACKGROUND)
    end

    def foreground
      rgb(COLOR_FOREGROUND)
    end

    def cursor_visible?
      flag(CURSOR_VISIBLE) && flag(CURSOR_HAS_VIEWPORT)
    end

    def cursor_x
      u16(CURSOR_X)
    end

    def cursor_y
      u16(CURSOR_Y)
    end

    # Yields the viewport row number and a cell positioned before its first column.
    def each_dirty_row
      C.ghostty_render_state_get(@handle, ROW_ITERATOR, C.iterator_slot)
      iterator = C.ptr_at(C.iterator_slot)
      while C.ghostty_render_state_row_iterator_next_dirty(iterator, C.out)
        y = C.u16_at(C.out)
        C.ghostty_render_state_row_get(iterator, ROW_CELLS, C.cells_slot)
        @cell.attach(C.ptr_at(C.cells_slot))
        yield y, @cell
      end
    end

    def clean
      C.ghostty_render_state_clean(@handle)
    end

    private

    def rgb(what)
      C.ghostty_render_state_get(@handle, what, C.out)
      Ghostty.rgb_at(C.out)
    end

    def u16(what)
      C.ghostty_render_state_get(@handle, what, C.out)
      C.u16_at(C.out)
    end

    def flag(what)
      C.ghostty_render_state_get(@handle, what, C.out)
      C.u32_at(C.out) & 255 != 0
    end
  end

  class KeyEncoder
    PRESS = 1
    CAPACITY = 64

    def initialize(terminal)
      @terminal = terminal
      @encoder = Ghostty.new_handle { |slot| C.ghostty_key_encoder_new(nil, slot) }
      @event = Ghostty.new_handle { |slot| C.ghostty_key_event_new(nil, slot) }
      @bytes = IO::Buffer.new(CAPACITY)
    end

    # The bytes a program reads for this key, in the terminal's current modes.
    def encode(mods, code, text)
      C.ghostty_key_event_set_action(@event, PRESS)
      C.ghostty_key_event_set_key(@event, KEY_CODES.fetch(code, 0))
      C.ghostty_key_event_set_mods(@event, mods)
      C.ghostty_key_event_set_unshifted_codepoint(@event, unshifted(code))
      C.tw_key_event_set_text(@event, text, text.bytesize)
      C.ghostty_key_encoder_set_from_terminal(@encoder, @terminal.handle)
      C.ghostty_key_encoder_encode(@encoder, @event, @bytes, CAPACITY, C.out)
      @bytes.get_string(0, C.u32_at(C.out))
    end

    private

    def unshifted(code)
      return code[3].downcase.ord if code.size == 4 && code.start_with?("Key")
      return code[5].ord if code.size == 6 && code.start_with?("Digit")
      0
    end
  end
end
