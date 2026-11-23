# spinel-tier: full
# Shared terminal declaration for the Phase 0 probe and the Phase 2 editor.
# The C seam remains the only place where termbox2's API is visible.

module ViTerm
  ffi_cflags "-I" + File.expand_path("../shim", __dir__) +
             " -I" + File.expand_path("../vendor/termbox2", __dir__) +
             " -I" + File.expand_path("../vendor/libgrapheme", __dir__)
  ffi_source "#define TB_OPT_EGC\n" +
             "#define TB_IMPL\n" +
             "#include \"termbox2.h\"\n" +
             "#include \"spinel_vi_grapheme.c\"\n" +
             "#define SPINEL_VI_FFI_EVENT_TYPE sp_ffi_struct_ViTerm_Event\n" +
             "#include \"spinel_vi_term.c\"\n"

  ffi_const :EVENT_KEY, 1
  ffi_const :EVENT_RESIZE, 2
  ffi_struct :Event, [
    [:type, :int], [:ch, :uint32], [:key, :uint16], [:mod, :uint8],
    [:width, :int], [:height, :int]
  ]
  ffi_func :sp_vi_term_init, [], :int
  ffi_func :sp_vi_term_backend, [], :int
  ffi_func :sp_vi_term_width, [], :int
  ffi_func :sp_vi_term_height, [], :int
  ffi_func :sp_vi_term_poll, [:ptr], :int
  ffi_func :sp_vi_term_clear, [:uint32, :uint32], :int
  ffi_func :sp_vi_term_put, [:int, :int, :uint32, :uint32, :uint32], :int
  ffi_func :sp_vi_term_set_cursor, [:int, :int], :int
  ffi_func :sp_vi_term_present, [], :int
  ffi_func :sp_vi_term_cell_width, [:uint32], :int
  ffi_func :sp_vi_term_shutdown, [], :void
  ffi_func :sp_vi_term_error, [], :str
  ffi_func :sp_vi_file_validate_path, [:str], :int
  ffi_func :sp_vi_file_load_bytes, [:str], :binstr
  ffi_func :sp_vi_file_last_status, [], :int
  ffi_func :sp_vi_file_validate_text, [:str, :size_t], :int
  ffi_func :sp_vi_file_save, [:str, :str, :size_t], :int
  ffi_func :sp_vi_file_error, [], :str
  ffi_func :sp_vi_bre_find, [:str, :str, :size_t], :int
  ffi_func :sp_vi_bre_start, [], :int
  ffi_func :sp_vi_bre_end, [], :int
  ffi_func :sp_vi_bre_error, [], :str
  ffi_func :sp_vi_unicode_display_supported, [], :int
  ffi_func :sp_vi_text_needs_unicode, [:str, :size_t], :int
  ffi_func :sp_vi_unicode_error, [], :str
  ffi_func :sp_vi_egc_next, [:str, :size_t, :size_t], :size_t
  ffi_func :sp_vi_egc_prev, [:str, :size_t, :size_t], :size_t
  ffi_func :sp_vi_egc_width, [:str, :size_t, :size_t, :int], :int
  ffi_func :sp_vi_unicode_validate_display, [:str, :size_t], :int
  ffi_func :sp_vi_term_put_egc, [:int, :int, :str, :size_t, :uint32, :uint32], :int

  # This control/observation surface belongs to the deterministic fake only.
  ffi_func :sp_vi_term_fake_reset, [], :int
  ffi_func :sp_vi_term_fake_push,
           [:int, :uint32, :uint16, :uint8, :int, :int], :int
  ffi_func :sp_vi_term_fake_log, [], :str
  ffi_func :sp_vi_term_test_resize, [:int, :int], :int
end
