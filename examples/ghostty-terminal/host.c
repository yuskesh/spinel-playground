/* The page's imports, and the two places C has to own a layout or a by-value
 * struct: Ruby ffi_func declarations can name neither a wasm import module nor
 * a GhosttyString argument. The assertions pin the layouts ghostty.rb reads. */
#include <stddef.h>
#include <ghostty/vt.h>

_Static_assert(sizeof(GhosttyStyle) == 16 && offsetof(GhosttyStyle, flags) == 12, "GhosttyStyle layout");
_Static_assert(sizeof(GhosttyColorRgb) == 3, "GhosttyColorRgb layout");
_Static_assert(offsetof(GhosttyCodepointBuffer, ptr) == 0 && offsetof(GhosttyCodepointBuffer, cap) == 4,
               "GhosttyCodepointBuffer layout");

_Static_assert(sizeof(GhosttyTerminalScrollbar) == 24 && offsetof(GhosttyTerminalScrollbar, offset) == 8 &&
               offsetof(GhosttyTerminalScrollbar, len) == 16, "GhosttyTerminalScrollbar layout");

#define IMPORT(n) __attribute__((import_module("spinel_host"), import_name(n)))

IMPORT("term_read") extern int imp_read(void *buf, int cap, int timeout_ms);
IMPORT("remote") extern int imp_remote(void);
IMPORT("send") extern void imp_send(const void *data, size_t len);
IMPORT("resize_shell") extern void imp_resize_shell(int cols, int rows);
IMPORT("initial_cols") extern int imp_initial_cols(void);
IMPORT("initial_rows") extern int imp_initial_rows(void);
IMPORT("grid") extern void imp_grid(int cols, int rows);
IMPORT("scroll_position") extern void imp_scroll_position(int total, int offset, int rows);
IMPORT("cell_width") extern int imp_cell_width(void);
IMPORT("cell_height") extern int imp_cell_height(void);
IMPORT("note_cell") extern void imp_note_cell(int index, unsigned codepoint, int fg, int bg, int style);
IMPORT("glyph_cells") extern int imp_glyph_cells(unsigned codepoint, int style);
IMPORT("glyph_draw") extern int imp_glyph_draw(unsigned codepoint, int style, int x, int y, int width);
IMPORT("term_present") extern void imp_present(void *quads, int quads_len, void *glyphs, int glyphs_len, int x, int y, int visible);

int tw_read(void *buf, int cap, int timeout_ms) { return imp_read(buf, cap, timeout_ms); }
int tw_remote(void) { return imp_remote(); }
void tw_send(const char *data, size_t len) { imp_send(data, len); }

static void on_write_pty(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t len) {
  (void)terminal;
  (void)userdata;
  imp_send(data, len);
}

/* A function pointer is not something a Ruby FFI signature can pass. */
void tw_connect_replies(GhosttyTerminal terminal) {
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)on_write_pty);
}

/* GhosttyTerminalScrollViewport is passed by value. */
void tw_scroll(GhosttyTerminal terminal, int tag, int delta) {
  GhosttyTerminalScrollViewport behavior = { .tag = (GhosttyTerminalScrollViewportTag)tag, .value = { .delta = delta } };
  ghostty_terminal_scroll_viewport(terminal, behavior);
}

void tw_resize_shell(int cols, int rows) { imp_resize_shell(cols, rows); }
int tw_initial_cols(void) { return imp_initial_cols(); }
int tw_initial_rows(void) { return imp_initial_rows(); }
void tw_grid(int cols, int rows) { imp_grid(cols, rows); }
void tw_scroll_position(int total, int offset, int rows) { imp_scroll_position(total, offset, rows); }
int tw_cell_width(void) { return imp_cell_width(); }
int tw_cell_height(void) { return imp_cell_height(); }
void tw_note_cell(int index, unsigned codepoint, int fg, int bg, int style) { imp_note_cell(index, codepoint, fg, bg, style); }
int tw_glyph_cells(unsigned codepoint, int style) { return imp_glyph_cells(codepoint, style); }
int tw_glyph_draw(unsigned codepoint, int style, int x, int y, int width) { return imp_glyph_draw(codepoint, style, x, y, width); }
void tw_present(void *quads, int quads_len, void *glyphs, int glyphs_len, int x, int y, int visible) { imp_present(quads, quads_len, glyphs, glyphs_len, x, y, visible); }

int tw_key_event_set_text(GhosttyKeyEvent event, const char *text, size_t len) {
  ghostty_key_event_set_utf8(event, (GhosttyString){ .ptr = (const uint8_t *)text, .len = len });
  return 0;
}
