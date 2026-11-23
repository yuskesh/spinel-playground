# spinel-tier: full
# Phase 2 product entry point.  `app.rb` remains the narrow Phase 0 seam probe.

# Spinel currently gathers linker flags from the entry scope.  The terminal
# declarations themselves stay in lib/terminal.rb so both editor code and the
# C seam have one ABI definition.
module ViTerm
  ffi_cflags "-I" + File.expand_path("shim", __dir__) +
             " -I" + File.expand_path("vendor/termbox2", __dir__)
end
require_relative "lib/terminal"
require_relative "lib/editor_ui"

def fake_key(ch, key = 0)
  ViTerm.sp_vi_term_fake_push(ViTerm::EVENT_KEY, ch, key, 0, 0, 0)
end

def install_fake_trace
  ViTerm.sp_vi_term_fake_push(ViTerm::EVENT_RESIZE, 0, 0, 0, 12, 5)
  fake_key(105) # i
  fake_key(65)  # A
  fake_key(66)  # B
  fake_key(0, 13)
  fake_key(67)  # C
  fake_key(0, 27)
  fake_key(106) # j
  fake_key(107) # k
  fake_key(108) # l
  fake_key(97)  # a
  fake_key(69)  # E
  fake_key(0, 27)
  fake_key(104) # h
  fake_key(120) # x
  fake_key(111) # o
  fake_key(68)  # D
  fake_key(0, 27)
  fake_key(58)  # :
  fake_key(120) # x (command text; commands are deliberately unimplemented)
  fake_key(0, 13)
end

# E103 exercises command semantics through precisely the same fake event ABI
# and renderer as the Phase 2 trace.  The three variants keep each scenario
# below the fake queue capacity while retaining checkpoint-rich screen logs.
def install_fake_command_trace
  fake_key(100); fake_key(100) # dd
  fake_key(100); fake_key(108) # pending d then l: cancel
  fake_key(117)                # undo
  fake_key(0, 18)              # Ctrl-R redo
  fake_key(121); fake_key(121); fake_key(112) # yy p
  fake_key(105); fake_key(65); fake_key(0, 27) # i A Esc
  fake_key(58); fake_key(119); fake_key(0, 13) # :w
  fake_key(105); fake_key(66); fake_key(0, 27) # i B Esc
  fake_key(58); fake_key(113); fake_key(0, 13) # :q (dirty refusal)
  fake_key(58); fake_key(113); fake_key(33); fake_key(0, 13) # :q!
end

def install_fake_wq_trace
  fake_key(58); fake_key(119); fake_key(113); fake_key(0, 13)
end

def install_fake_redo_trace
  fake_key(105); fake_key(66); fake_key(0, 27) # i B Esc
  fake_key(117)                                # undo
  fake_key(105); fake_key(67); fake_key(0, 27) # i C Esc
  fake_key(0, 18)                              # discarded redo
end

def install_fake_search_trace
  fake_key(47); fake_key(102); fake_key(111); fake_key(111); fake_key(0, 13) # /foo
  fake_key(110); fake_key(110) # n, n (second match then wrap)
  fake_key(47); fake_key(97); fake_key(42); fake_key(0, 13) # /a* zero-length
  fake_key(110); fake_key(110); fake_key(110); fake_key(110) # byte progress + wrap
  fake_key(47); fake_key(91); fake_key(0, 13) # invalid BRE
end

def install_fake_unicode_trace
  fake_key(108) # l: e + combining acute as one EGC
  fake_key(106) # j: preferred cell column 1 on Aあ
  fake_key(106) # j: clamp to the end of A
  fake_key(107) # k: restore preferred column 1
  fake_key(107) # k: first line, after e + combining acute
  fake_key(104) # h: EGC start
  fake_key(120) # x: delete e + combining acute together
  fake_key(108) # l: after あ
  fake_key(105) # i
  fake_key(0, 8) # backspace: delete あ as one EGC
  fake_key(0, 27) # Esc
end

def install_fake_unicode_narrow_trace
  ViTerm.sp_vi_term_fake_push(ViTerm::EVENT_RESIZE, 0, 0, 0, 2, 5)
end

def render(editor)
  rows = editor.screen_rows
  x = editor.screen_cursor_x
  y = editor.screen_cursor_y
  ViTerm.sp_vi_term_clear(0, 0)
  row = 0
  while row < rows.length
    text = rows[row]
    byte = 0
    column = 0
    while byte < text.bytesize
      width = ViTerm.sp_vi_egc_width(text, text.bytesize, byte, column)
      next_byte = ViTerm.sp_vi_egc_next(text, text.bytesize, byte)
      break if width < 0 || column + width > editor.width
      if next_byte == byte + 1 && text.getbyte(byte) >= 32 && text.getbyte(byte) < 127
        ViTerm.sp_vi_term_put(column, row, text.getbyte(byte), 0, 0)
      else
        cluster = ""
        i = byte
        while i < next_byte
          cluster += text.getbyte(i).chr
          i += 1
        end
        ViTerm.sp_vi_term_put_egc(column, row, cluster, cluster.bytesize, 0, 0)
      end
      column += width
      byte = next_byte
    end
    row += 1
  end
  ViTerm.sp_vi_term_set_cursor(x, y) if y >= 0
  ViTerm.sp_vi_term_present
end

trace_kind = ARGV.length > 0 ? ARGV[0] : ""
trace = trace_kind == "--fake-trace"
command_trace = trace_kind == "--fake-command-trace"
wq_trace = trace_kind == "--fake-wq-trace"
redo_trace = trace_kind == "--fake-redo-trace"
search_trace = trace_kind == "--fake-search-trace"
unicode_trace = trace_kind == "--fake-unicode-trace"
unicode_narrow_trace = trace_kind == "--fake-unicode-narrow-trace"
size_trace = trace_kind == "--fake-size-trace"
path = if command_trace || wq_trace
         ARGV.length > 1 ? ARGV[1] : ""
       elsif search_trace
         ARGV.length > 1 ? ARGV[1] : ""
       elsif unicode_trace
         ARGV.length > 1 ? ARGV[1] : ""
       elsif unicode_narrow_trace
         ARGV.length > 1 ? ARGV[1] : ""
       elsif trace || redo_trace || size_trace
         ""
       else
         # PTY probes pass only --event-limit=N; it is a runner control, not
         # an editor file path.  Treating it as a path would turn the smoke
         # gate into an unrelated lstat failure before the first event.
         ARGV.length > 0 && !ARGV[0].start_with?("--event-limit=") ? ARGV[0] : ""
       end
limit = 0
if ARGV.length > 0 && ARGV[0].start_with?("--event-limit=")
  limit = ARGV[0].byteslice(14, ARGV[0].bytesize - 14).to_i
end

ViTerm.sp_vi_term_fake_reset
install_fake_trace if trace
install_fake_command_trace if command_trace
install_fake_wq_trace if wq_trace
install_fake_redo_trace if redo_trace
install_fake_search_trace if search_trace
install_fake_unicode_trace if unicode_trace
install_fake_unicode_narrow_trace if unicode_narrow_trace
limit = 21 if trace
initial = path.bytesize == 0 ? "" : SpinelVi::FileStore.load(path)
if ViTerm.sp_vi_text_needs_unicode(initial, initial.bytesize) != 0 &&
   (ViTerm.sp_vi_unicode_display_supported == 0 ||
    ViTerm.sp_vi_unicode_validate_display(initial, initial.bytesize) != 0)
  puts "unicode-error=" + ViTerm.sp_vi_unicode_error
else
  init = ViTerm.sp_vi_term_init
  if init != 0
    puts "terminal-error=" + ViTerm.sp_vi_term_error
  else
    # The status and command rows remain an intentional two-row reservation in
    # Editor#screen_rows.  Only the initial terminal size stops being a fixed
    # 80x24 guess: real termbox2 reports it immediately after initialization.
    editor = SpinelVi::Editor.new(ViTerm.sp_vi_term_width,
                                  ViTerm.sp_vi_term_height, path, initial)
    puts "initial-size=#{editor.width}x#{editor.height}" if size_trace
    render(editor)
    event = ViTerm.Event_new
    seen = 0
    while editor.running
      polled = ViTerm.sp_vi_term_poll(event)
      break if polled <= 0
      kind = ViTerm.Event_get_type(event)
      if kind == ViTerm::EVENT_RESIZE
        editor.resize(ViTerm.Event_get_width(event), ViTerm.Event_get_height(event))
      elsif kind == ViTerm::EVENT_KEY
        editor.handle_key(ViTerm.Event_get_ch(event), ViTerm.Event_get_key(event))
      end
      render(editor)
      seen += 1
      # These checkpoints make the preferred-cell-column contract observable:
      # moving from e + acute to Aあ retains column 1, then clamps at A's end.
      if unicode_trace && (seen == 2 || seen == 3)
        puts "unicode-step\t#{seen}\tcursor=#{editor.cursor.offset}\tline=#{editor.cursor.line(editor.table)}\tcolumn=#{editor.screen_cursor_x}"
      end
      break if limit > 0 && seen >= limit
    end
    ViTerm.sp_vi_term_shutdown
    if search_trace
      # The final invalid-BRE checkpoint proves that search never edits text and
      # leaves the preceding zero-length match/cursor state intact.
      puts "search-final\ttext=#{editor.table.materialize.inspect}\tcursor=#{editor.cursor.offset}\tmatch=#{editor.match_start},#{editor.match_end}\tnotice=#{editor.notice.inspect}"
    end
    if unicode_trace
      puts "unicode-final\ttext=#{editor.table.materialize.inspect}\tcursor=#{editor.cursor.offset}\tline=#{editor.cursor.line(editor.table)}\tcolumn=#{editor.screen_cursor_x}"
    end
    puts ViTerm.sp_vi_term_fake_log if ViTerm.sp_vi_term_backend == 0
  end
end
