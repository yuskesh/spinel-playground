# spinel-tier: full
# Spinel Vi Phase 0: the terminal seam only.  The editor core arrives in E101.
# Keep these declarations in this top-level entry point: current Spinel only
# collects `ffi_cflags` from that scope for the compiler invocation.
module ViTerm
  ffi_cflags "-I" + File.expand_path("shim", __dir__) +
             " -I" + File.expand_path("vendor/termbox2", __dir__) +
             " -I" + File.expand_path("vendor/libgrapheme", __dir__)
  ffi_source <<~C
    #define TB_OPT_EGC
    #define TB_IMPL
    #include "termbox2.h"
    #include "spinel_vi_grapheme.c"
    #define SPINEL_VI_FFI_EVENT_TYPE sp_ffi_struct_ViTerm_Event
    #include "spinel_vi_term.c"
  C

  ffi_const :EVENT_KEY, 1
  ffi_struct :Event, [
    [:type, :int], [:ch, :uint32], [:key, :uint16], [:mod, :uint8],
    [:width, :int], [:height, :int]
  ]
  ffi_func :sp_vi_term_init, [], :int
  ffi_func :sp_vi_term_backend, [], :int
  ffi_func :sp_vi_term_poll, [:ptr], :int
  ffi_func :sp_vi_term_clear, [:uint32, :uint32], :int
  ffi_func :sp_vi_term_put, [:int, :int, :uint32, :uint32, :uint32], :int
  ffi_func :sp_vi_term_set_cursor, [:int, :int], :int
  ffi_func :sp_vi_term_present, [], :int
  ffi_func :sp_vi_term_cell_width, [:uint32], :int
  ffi_func :sp_vi_term_shutdown, [], :void
  ffi_func :sp_vi_term_error, [], :str
  ffi_func :sp_vi_term_fake_reset, [], :int
  ffi_func :sp_vi_term_fake_push,
           [:int, :uint32, :uint16, :uint8, :int, :int], :int
  ffi_func :sp_vi_term_fake_log, [], :str
  ffi_func :sp_vi_term_test_resize, [:int, :int], :int
end

probe = ARGV.length > 0 ? ARGV[0] : ""
ViTerm.sp_vi_term_fake_reset
init = ViTerm.sp_vi_term_init
puts "init=#{init} backend=#{ViTerm.sp_vi_term_backend}"

if init == 0
  event = ViTerm.Event_new
  if probe == "--probe-input"
    i = 0
    while i < 3
      polled = ViTerm.sp_vi_term_poll(event)
      puts "input#{i}=poll=#{polled} type=#{ViTerm.Event_get_type(event)} ch=#{ViTerm.Event_get_ch(event)} key=#{ViTerm.Event_get_key(event)} mod=#{ViTerm.Event_get_mod(event)}"
      i += 1
    end
  elsif probe == "--probe-resize"
    requested = ViTerm.sp_vi_term_test_resize(91, 37)
    polled = ViTerm.sp_vi_term_poll(event)
    puts "resize-request=#{requested} poll=#{polled} type=#{ViTerm.Event_get_type(event)} width=#{ViTerm.Event_get_width(event)} height=#{ViTerm.Event_get_height(event)}"
  elsif probe == "--probe-widths"
    puts "width-ascii=#{ViTerm.sp_vi_term_cell_width(65)}"
    puts "width-hiragana=#{ViTerm.sp_vi_term_cell_width(12354)}"
    puts "width-combining=#{ViTerm.sp_vi_term_cell_width(769)}"
    puts "width-emoji=#{ViTerm.sp_vi_term_cell_width(128512)}"
  else
    if ViTerm.sp_vi_term_backend == 0
      # The fake event makes the default build deterministic; termbox2 receives
      # its key from the actual terminal instead.
      ViTerm.sp_vi_term_fake_push(ViTerm::EVENT_KEY, 120, 0, 0, 0, 0)
    end
    ViTerm.sp_vi_term_clear(0, 0)
    ViTerm.sp_vi_term_present
    polled = ViTerm.sp_vi_term_poll(event)
    puts "poll=#{polled} type=#{ViTerm.Event_get_type(event)} ch=#{ViTerm.Event_get_ch(event)}"
    if polled == 1 && ViTerm.Event_get_type(event) == ViTerm::EVENT_KEY
      ch = ViTerm.Event_get_ch(event)
      ch = 63 if ch == 0
      ViTerm.sp_vi_term_put(0, 0, ch, 0, 0)
      ViTerm.sp_vi_term_set_cursor(1, 0)
      ViTerm.sp_vi_term_present
    end
  end
  ViTerm.sp_vi_term_shutdown
  if ViTerm.sp_vi_term_backend == 0
    puts ViTerm.sp_vi_term_fake_log
  end
else
  puts "terminal-error=#{ViTerm.sp_vi_term_error}"
end
