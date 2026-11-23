#ifndef SPINEL_VI_TERM_H
#define SPINEL_VI_TERM_H

#include <stdint.h>
#include <stddef.h>

/*
 * The only terminal ABI visible to Spinel.  This is deliberately not the
 * termbox2 event: termbox2's enums, macros, and extra mouse fields stop here.
 * `sp_vi_term_poll` receives a void pointer so the generated ffi_struct owns
 * the target layout; it must point at storage compatible with this record.
 * `type`, `width`, and `height` intentionally use C `int`, matching the
 * Phase 0 ffi_struct exactly (not a merely similar fixed-width typedef).
 */
typedef struct spinel_vi_event {
    int type;
    uint32_t ch;
    uint16_t key;
    uint8_t mod;
    int width;
    int height;
} spinel_vi_event;

/* Search is a call-scoped POSIX BRE operation.  `status` is 0 for a match,
 * 1 for REG_NOMATCH, and -1 for compile/execute failure.  Offsets are bytes
 * into the full, NUL-free editor buffer. */
typedef struct spinel_vi_bre_result {
    int status;
    int start;
    int end;
} spinel_vi_bre_result;

enum {
    SP_VI_EVENT_NONE = 0,
    SP_VI_EVENT_KEY = 1,
    SP_VI_EVENT_RESIZE = 2,
    SP_VI_EVENT_MOUSE = 3,
};

int sp_vi_term_init(void);
int sp_vi_term_backend(void); /* 0=fake, 1=termbox2 */
int sp_vi_term_width(void);  /* initial/current terminal columns */
int sp_vi_term_height(void); /* initial/current terminal rows */
int sp_vi_term_poll(void *out_event); /* 1=event, 0=none, <0=error */
int sp_vi_term_clear(uint32_t fg, uint32_t bg);
int sp_vi_term_put(int x, int y, uint32_t ch, uint32_t fg, uint32_t bg);
int sp_vi_term_set_cursor(int x, int y);
int sp_vi_term_present(void);
int sp_vi_term_cell_width(uint32_t ch); /* termbox2 snapshot table, not EGC */
void sp_vi_term_shutdown(void);
const char *sp_vi_term_error(void);

int sp_vi_file_validate_path(const char *path);
const char *sp_vi_file_load_bytes(const char *path);
int sp_vi_file_last_status(void);
int sp_vi_file_validate_text(const char *text, size_t length);
int sp_vi_file_save(const char *path, const char *text, size_t length);
const char *sp_vi_file_error(void);

int sp_vi_bre_find(const char *pattern, const char *text, size_t offset);
int sp_vi_bre_start(void);
int sp_vi_bre_end(void);
const char *sp_vi_bre_error(void);

/* Unicode editing is opt-in on the presence of the pinned libgrapheme
 * snapshot.  The checked-in ASCII build must reject non-ASCII display rather
 * than rendering UTF-8 bytes as unrelated terminal cells. */
int sp_vi_unicode_display_supported(void);
int sp_vi_text_needs_unicode(const char *text, size_t length);
const char *sp_vi_unicode_error(void);
size_t sp_vi_egc_next(const char *text, size_t length, size_t offset);
size_t sp_vi_egc_prev(const char *text, size_t length, size_t offset);
int sp_vi_egc_width(const char *text, size_t length, size_t offset, int column);
int sp_vi_unicode_validate_display(const char *text, size_t length);
int sp_vi_term_put_egc(int x, int y, const char *text, size_t length,
                       uint32_t fg, uint32_t bg);

/* Phase 0 copies termbox2's uint16_t key value unchanged.  The value is
 * opaque to Ruby: a portable/editor-level key vocabulary is deliberately a
 * later contract, not an accidental promise of this seam. */

/* Fake-only control and observation surface.  It is not used by the editor. */
int sp_vi_term_fake_reset(void);
int sp_vi_term_fake_push(int type, uint32_t ch, uint16_t key, uint8_t mod,
                         int width, int height);
const char *sp_vi_term_fake_log(void);
int sp_vi_term_test_resize(int width, int height); /* PTY probe only */

#endif
