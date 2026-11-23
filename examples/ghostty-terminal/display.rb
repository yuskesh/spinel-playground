# What the page is asked to do. Everything else about drawing is decided here.
module Browser
  ffi_func :tw_read, [:ptr, :int, :int], :int
  ffi_func :tw_cell_width, [], :int
  ffi_func :tw_cell_height, [], :int
  ffi_func :tw_glyph_cells, [:uint32, :int], :int
  ffi_func :tw_glyph_draw, [:uint32, :int, :int, :int, :int], :int
  ffi_func :tw_note_cell, [:int, :uint32, :int, :int, :int], :void
  ffi_func :tw_remote, [], :int
  ffi_func :tw_send, [:binstr, :size_t], :void
  ffi_func :tw_connect_replies, [:ptr], :void
  ffi_func :tw_resize_shell, [:int, :int], :void
  ffi_func :tw_initial_cols, [], :int
  ffi_func :tw_initial_rows, [], :int
  ffi_func :tw_grid, [:int, :int], :void
  ffi_func :tw_scroll_position, [:int, :int, :int], :void
  ffi_func :tw_present, [:ptr, :int, :ptr, :int, :int, :int, :int], :void
end

module Rgb
  def self.red(rgb)
    ((rgb >> 16) & 255) / 255.0
  end

  def self.green(rgb)
    ((rgb >> 8) & 255) / 255.0
  end

  def self.blue(rgb)
    (rgb & 255) / 255.0
  end
end

Glyph = Struct.new(:x, :y, :width, :height, :colored)

# Decides where each glyph lives in the page's atlas texture.
class Atlas
  SIZE = 2048
  STYLE_MASK = 3

  attr_reader :generation

  def initialize(cell_width, cell_height)
    @cell_width = cell_width
    @cell_height = cell_height
    @glyphs = {}
    @x = 0
    @y = 0
    @generation = 0
    @blank = Glyph.new(0, 0, 0, 0, false)
  end

  def lookup(codepoint, style)
    return @blank if codepoint == 0 || codepoint == 32
    style &= STYLE_MASK
    key = codepoint * 4 + style
    @glyphs[key] ||= rasterize(codepoint, style)
  end

  attr_reader :blank

  private

  def rasterize(codepoint, style)
    width = Browser.tw_glyph_cells(codepoint, style) * @cell_width
    if @x + width > SIZE
      @x = 0
      @y += @cell_height
    end
    reset if @y + @cell_height > SIZE
    colored = Browser.tw_glyph_draw(codepoint, style, @x, @y, width) != 0
    glyph = Glyph.new(@x, @y, width, @cell_height, colored)
    @x += width
    glyph
  end

  def reset
    @glyphs.clear
    @x = 0
    @y = 0
    @generation += 1
  end
end

# A vertex buffer of floats, written in order from a chosen place.
class Vertices
  attr_reader :bytes, :size

  def initialize(size)
    @size = size
    @bytes = IO::Buffer.new(size)
    @at = 0
  end

  def seek(offset)
    @at = offset
  end

  def put(value)
    @bytes.set_value(:f32, @at, value)
    @at += 4
  end
end

CORNERS = [[0, 0], [1, 0], [0, 1], [0, 1], [1, 0], [1, 1]].freeze

# The solid rectangles behind the text, as the vertex buffer quad.rb reads.
# Every cell owns three fixed slots, so a change rewrites only that cell.
class Quads < Vertices
  SLOTS = 3
  SLOT_BYTES = CORNERS.size * 20

  def initialize(cols, rows, cell_width, cell_height)
    super(cols * rows * SLOTS * SLOT_BYTES)
    @cols = cols
    @cell_width = cell_width
    @cell_height = cell_height
  end

  # Fills a slot with the band of its cell from top, height pixels tall.
  def fill(index, slot, top, height, rgb)
    left = (index % @cols) * @cell_width
    upper = (index / @cols) * @cell_height + top
    seek((index * SLOTS + slot) * SLOT_BYTES)
    CORNERS.each do |x, y|
      put((left + x * @cell_width).to_f)
      put((upper + y * height).to_f)
      put(Rgb.red(rgb))
      put(Rgb.green(rgb))
      put(Rgb.blue(rgb))
    end
  end

  def clear(index, slot)
    fill(index, slot, 0, 0, 0)
  end
end

# The textured rectangles of the text, as the vertex buffer glyph.rb reads.
# Every cell owns one fixed slot; a blank cell has an empty rectangle.
class GlyphQuads < Vertices
  SLOT_BYTES = CORNERS.size * 36
  FAINT_ALPHA = 0.55

  def initialize(cols, rows, cell_width, cell_height)
    super(cols * rows * SLOT_BYTES)
    @cols = cols
    @cell_width = cell_width
    @cell_height = cell_height
    @atlas_size = Atlas::SIZE.to_f
  end

  def fill(index, glyph, rgb, faint)
    left = (index % @cols) * @cell_width
    top = (index / @cols) * @cell_height
    seek(index * SLOT_BYTES)
    CORNERS.each do |x, y|
      put((left + x * glyph.width).to_f)
      put((top + y * glyph.height).to_f)
      put((glyph.x + x * glyph.width) / @atlas_size)
      put((glyph.y + y * glyph.height) / @atlas_size)
      put(Rgb.red(rgb))
      put(Rgb.green(rgb))
      put(Rgb.blue(rgb))
      put(glyph.colored ? 1.0 : 0.0)
      put(faint ? FAINT_ALPHA : 1.0)
    end
  end
end

# What one cell of the screen currently shows.
class Tile
  attr_reader :codepoint, :style, :foreground, :background
  attr_accessor :glyph

  def initialize(glyph)
    @codepoint = 0
    @style = 0
    @foreground = 0
    @background = 0
    @glyph = glyph
  end

  # Answers whether anything was different.
  def change(codepoint, style, foreground, background)
    return false if codepoint == @codepoint && style == @style &&
                    foreground == @foreground && background == @background
    @codepoint = codepoint
    @style = style
    @foreground = foreground
    @background = background
    true
  end

  def swap_colors
    @foreground, @background = @background, @foreground
  end

  def underlined?
    @style & Ghostty::Cell::UNDERLINE_MASK != 0
  end

  def struck?
    @style & Ghostty::Cell::STRIKETHROUGH != 0
  end

  def faint?
    @style & Ghostty::Cell::FAINT != 0
  end
end

# Keeps one Tile per cell, and turns each change into the two vertex buffers.
class Display
  BACK = 0
  UNDERLINE = 1
  STRIKE = 2

  def initialize(terminal, cols, rows)
    @state = Ghostty::RenderState.new(terminal)
    @cell_width = Browser.tw_cell_width
    @cell_height = Browser.tw_cell_height
    @line = [1, @cell_height / 16].max
    @atlas = Atlas.new(@cell_width, @cell_height)
    resize(cols, rows)
  end

  attr_reader :cell_width, :cell_height

  # Every cell is new, so everything is drawn again by the next present.
  def resize(cols, rows)
    @cols = cols
    @rows = rows
    @quads = Quads.new(cols, rows, @cell_width, @cell_height)
    @glyphs = GlyphQuads.new(cols, rows, @cell_width, @cell_height)
    @tiles = Array.new(cols * rows) { Tile.new(@atlas.blank) }
    @cursor = -1
    Browser.tw_grid(cols, rows)
  end

  def present
    @state.update
    background = @state.background
    foreground = @state.foreground
    toggle_cursor
    generation = @atlas.generation
    @state.each_dirty_row do |y, cell|
      store_row(y, cell, background, foreground)
    end
    @state.clean
    refresh_glyphs unless @atlas.generation == generation
    @cursor = @state.cursor_visible? ? @state.cursor_y * @cols + @state.cursor_x : -1
    toggle_cursor
    Browser.tw_present(@quads.bytes, @quads.size, @glyphs.bytes, @glyphs.size, @state.cursor_x, @state.cursor_y, @cursor >= 0 ? 1 : 0)
  end

  private

  def store_row(y, cell, background, foreground)
    @cols.times do |x|
      break unless cell.advance
      store_cell(y * @cols + x, cell, background, foreground)
    end
  end

  def store_cell(index, cell, background, foreground)
    style = cell.style_flags
    codepoint = style & Ghostty::Cell::INVISIBLE != 0 ? 0 : cell.codepoint
    fg = cell.foreground(foreground)
    bg = cell.background(background)
    fg, bg = bg, fg if style & Ghostty::Cell::INVERSE != 0
    tile = @tiles[index]
    return unless tile.change(codepoint, style, fg, bg)
    tile.glyph = @atlas.lookup(codepoint, style)
    draw(index, tile)
  end

  # The atlas was rebuilt part-way through: every tile's glyph is stale.
  def refresh_glyphs
    @tiles.each_with_index do |tile, index|
      tile.glyph = @atlas.lookup(tile.codepoint, tile.style)
      draw(index, tile)
    end
  end

  # The block cursor is the cell drawn with its colours exchanged.
  def toggle_cursor
    return if @cursor < 0
    tile = @tiles[@cursor]
    tile.swap_colors
    draw(@cursor, tile)
  end

  def draw(index, tile)
    Browser.tw_note_cell(index, tile.codepoint, tile.foreground, tile.background, tile.style)
    @glyphs.fill(index, tile.glyph, tile.foreground, tile.faint?)
    @quads.fill(index, BACK, 0, @cell_height, tile.background)
    if tile.underlined?
      @quads.fill(index, UNDERLINE, @cell_height - 2 * @line, @line, tile.foreground)
    else
      @quads.clear(index, UNDERLINE)
    end
    if tile.struck?
      @quads.fill(index, STRIKE, @cell_height * 11 / 20, @line, tile.foreground)
    else
      @quads.clear(index, STRIKE)
    end
  end
end

# The terminal as an application sees it: write text, draw, read keys.
class Screen
  HISTORY_LINES = 10_000
  HISTORY_BYTES = 1 << 25
  EVENT_BYTES = 65536
  NOTHING = 0
  KEY = 1
  DATA = 2
  RESIZE = 3
  SCROLL = 4
  CLOSED = -1
  SHIFT = 1

  attr_reader :cols, :rows, :key_bytes

  def initialize
    @cols = Browser.tw_initial_cols
    @rows = Browser.tw_initial_rows
    @terminal = Ghostty::Terminal.new(@cols, @rows, HISTORY_LINES, HISTORY_BYTES)
    @display = Display.new(@terminal, @cols, @rows)
    @keyboard = Ghostty::KeyEncoder.new(@terminal)
    @event = IO::Buffer.new(EVENT_BYTES)
    @length = 0
    @key_bytes = ""
    @reported = [-1, -1, -1]
  end

  def write(text)
    @terminal.write(text)
  end

  def puts(text)
    write(text + "\r\n")
  end

  def present
    @display.present
    report_scroll_position
  end

  # A key's bytes, or "" when timeout_ms passed first (-1 waits for ever).
  def read(timeout_ms = -1)
    wait(timeout_ms) == KEY ? key_bytes : ""
  end

  # Waits for one input and answers its kind. The terminal's own inputs are
  # handled here: a program only learns that the size changed, and that a key
  # meant for it arrived.
  def wait(timeout_ms = -1)
    @length = Browser.tw_read(@event, EVENT_BYTES, timeout_ms)
    return CLOSED if @length < 0
    return NOTHING if @length == 0
    kind = @event.get_value(:U8, 0)
    case kind
    when RESIZE then resize
    when SCROLL then scroll(payload.to_i)
    when KEY then return take_key
    end
    kind == SCROLL ? NOTHING : kind
  end

  def payload
    @event.get_string(1, @length - 1)
  end

  # What the terminal answers to a program's queries goes to the page.
  def connect_replies
    Browser.tw_connect_replies(@terminal.handle)
  end

  private

  def resize
    cols, rows = payload.split(" ").map(&:to_i)
    @cols = cols
    @rows = rows
    @terminal.resize(cols, rows, @display.cell_width, @display.cell_height)
    @display.resize(cols, rows)
    present
  end

  def scroll(rows)
    @terminal.scroll_by(rows)
    present
  end

  # Shift with the paging keys moves the view; any other key returns to the
  # bottom if it would reach the program.
  def take_key
    head, text = payload.split("\n", 2)
    mods, code = head.split(" ")
    if mods.to_i & SHIFT != 0 && page_key(code)
      present
      return NOTHING
    end
    @key_bytes = @keyboard.encode(mods.to_i, code, text || "")
    return_to_bottom unless @key_bytes.empty?
    KEY
  end

  def page_key(code)
    case code
    when "PageUp" then @terminal.scroll_by(1 - @rows)
    when "PageDown" then @terminal.scroll_by(@rows - 1)
    when "Home" then @terminal.scroll_to_top
    when "End" then @terminal.scroll_to_bottom
    else return false
    end
    true
  end

  def return_to_bottom
    @terminal.read_scroll_position
    return if @terminal.view_offset + @terminal.view_rows >= @terminal.total_rows
    @terminal.scroll_to_bottom
    present
  end

  def report_scroll_position
    @terminal.read_scroll_position
    now = [@terminal.total_rows, @terminal.view_offset, @terminal.view_rows]
    return if now == @reported
    @reported = now
    Browser.tw_scroll_position(now[0], now[1], now[2])
  end
end
