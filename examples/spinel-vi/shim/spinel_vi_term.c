#include "spinel_vi_term.h"

#include <stdarg.h>
#include <stddef.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <regex.h>
#include <sys/stat.h>
#include <sys/ioctl.h>

/* termbox2.h is included with TB_IMPL by app.rb before this file. */

/* `ffi_source` is emitted after ffi_struct typedefs.  app.rb supplies this
 * generated name only for the integrated Spinel build; keeping the assertion
 * opt-in lets this C seam still undergo standalone syntax checks. */
#ifdef SPINEL_VI_FFI_EVENT_TYPE
_Static_assert(sizeof(spinel_vi_event) == sizeof(SPINEL_VI_FFI_EVENT_TYPE),
               "spinel_vi_event must match ViTerm::Event size");
_Static_assert(offsetof(spinel_vi_event, type) ==
                   offsetof(SPINEL_VI_FFI_EVENT_TYPE, type),
               "spinel_vi_event.type offset");
_Static_assert(offsetof(spinel_vi_event, ch) ==
                   offsetof(SPINEL_VI_FFI_EVENT_TYPE, ch),
               "spinel_vi_event.ch offset");
_Static_assert(offsetof(spinel_vi_event, key) ==
                   offsetof(SPINEL_VI_FFI_EVENT_TYPE, key),
               "spinel_vi_event.key offset");
_Static_assert(offsetof(spinel_vi_event, mod) ==
                   offsetof(SPINEL_VI_FFI_EVENT_TYPE, mod),
               "spinel_vi_event.mod offset");
_Static_assert(offsetof(spinel_vi_event, width) ==
                   offsetof(SPINEL_VI_FFI_EVENT_TYPE, width),
               "spinel_vi_event.width offset");
_Static_assert(offsetof(spinel_vi_event, height) ==
                   offsetof(SPINEL_VI_FFI_EVENT_TYPE, height),
               "spinel_vi_event.height offset");
#endif

/* Phase 2 redraws a complete deterministic frame after every fake event. */
enum { SP_VI_FAKE_CAPACITY = 32, SP_VI_LOG_CAPACITY = 32768 };

static spinel_vi_event sp_vi_fake_events[SP_VI_FAKE_CAPACITY];
static int sp_vi_fake_head;
static int sp_vi_fake_tail;
static int sp_vi_open;
static int sp_vi_use_real;
/* Fake dimensions are deterministic; real values are captured immediately
 * after tb_init, before editor.rb draws its first frame. */
static int sp_vi_width = 80;
static int sp_vi_height = 24;
static char sp_vi_error_text[160];
static char sp_vi_file_error_text[160];
static char sp_vi_bre_error_text[160];
static char sp_vi_unicode_error_text[160];
static int sp_vi_bre_last_start = -1;
static int sp_vi_bre_last_end = -1;
static char *sp_vi_file_bytes;
static int sp_vi_file_status;
/* spinel-extended: the pinned runtime defines it (lib/sp_alloc.c); a second
   definition here made two variables that ld64 merged only with a warning. */
extern int sp_ffi_bin_len;
static char sp_vi_log_text[SP_VI_LOG_CAPACITY];
static size_t sp_vi_log_len;
static void sp_vi_log(const char *format, ...);

static void sp_vi_set_error(const char *what, int code) {
    snprintf(sp_vi_error_text, sizeof(sp_vi_error_text), "%s (%d)", what, code);
}

static void sp_vi_file_error_set(const char *what) {
    snprintf(sp_vi_file_error_text, sizeof(sp_vi_file_error_text), "%s", what);
}

int sp_vi_file_validate_path(const char *path) {
    struct stat st;
    if (path == NULL || lstat(path, &st) != 0) { sp_vi_file_error_set("lstat failed"); return -1; }
    if (S_ISLNK(st.st_mode)) { sp_vi_file_error_set("symlink is not supported"); return -1; }
    if (!S_ISREG(st.st_mode)) { sp_vi_file_error_set("regular file required"); return -1; }
    return 0;
}

const char *sp_vi_file_load_bytes(const char *path) {
    FILE *f; long size; size_t got;
    free(sp_vi_file_bytes); sp_vi_file_bytes = NULL; sp_ffi_bin_len = 0; sp_vi_file_status = -1;
    if (sp_vi_file_validate_path(path) != 0) return "";
    f = fopen(path, "rb");
    if (f == NULL || fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        if (f) fclose(f); sp_vi_file_error_set("file read setup failed"); return "";
    }
    sp_vi_file_bytes = malloc((size_t)size + 1);
    if (sp_vi_file_bytes == NULL) { fclose(f); sp_vi_file_error_set("file read allocation failed"); return ""; }
    got = fread(sp_vi_file_bytes, 1, (size_t)size, f);
    if (got != (size_t)size || fclose(f) != 0) { free(sp_vi_file_bytes); sp_vi_file_bytes = NULL; sp_vi_file_error_set("file read failed"); return ""; }
    sp_vi_file_bytes[size] = '\0'; sp_ffi_bin_len = (int)size; sp_vi_file_status = 0; return sp_vi_file_bytes;
}

int sp_vi_file_last_status(void) { return sp_vi_file_status; }

int sp_vi_file_validate_text(const char *text, size_t length) {
    const unsigned char *p = (const unsigned char *)text;
    const unsigned char *end = p + length;
    if (p == NULL) { sp_vi_file_error_set("text is null"); return -1; }
    while (p < end) {
        if (*p == 0) { sp_vi_file_error_set("NUL is not supported"); return -1; }
        if (*p == '\r') { sp_vi_file_error_set("CRLF is not supported; use LF"); return -1; }
        if (*p < 0x80) { p++; continue; }
        { int n = (*p & 0xe0) == 0xc0 ? 2 : (*p & 0xf0) == 0xe0 ? 3 : (*p & 0xf8) == 0xf0 ? 4 : 0; int i;
          if (n == 0 || p + n > end || (n == 2 && *p < 0xc2)) { sp_vi_file_error_set("invalid UTF-8"); return -1; }
          for (i = 1; i < n; i++) if ((p[i] & 0xc0) != 0x80) { sp_vi_file_error_set("invalid UTF-8"); return -1; }
          /* Reject every non-shortest UTF-8 form as well as the scalar-value
           * holes.  The continuation-byte loop above only establishes the
           * shape; these lead-byte constraints establish Unicode validity. */
          if ((p[0] == 0xe0 && p[1] < 0xa0) ||
              (p[0] == 0xed && p[1] >= 0xa0) ||
              (p[0] == 0xf0 && p[1] < 0x90) ||
              (p[0] == 0xf4 && p[1] > 0x8f) || p[0] > 0xf4) {
              sp_vi_file_error_set("invalid UTF-8"); return -1;
          }
          p += n;
        }
    }
    return 0;
}

int sp_vi_file_save(const char *path, const char *text, size_t length) {
    struct stat st; const char *slash; const char *base; char *tmp; char *dir; size_t n;
    int fd = -1, dfd = -1, renamed = 0, rc = -1; FILE *f = NULL;
    if (sp_vi_file_validate_path(path) != 0 || sp_vi_file_validate_text(text, length) != 0) return -1;
    if (lstat(path, &st) != 0) { sp_vi_file_error_set("lstat before save failed"); return -1; }
    slash = strrchr(path, '/'); base = slash ? slash + 1 : path;
    dir = slash ? strndup(path, (size_t)(slash - path)) : strdup(".");
    if (dir == NULL) { sp_vi_file_error_set("temporary directory allocation failed"); return -1; }
    n = strlen(dir) + strlen(base) + 24; tmp = malloc(n);
    if (tmp == NULL) { free(dir); sp_vi_file_error_set("temporary path allocation failed"); return -1; }
    snprintf(tmp, n, "%s/.%s.spinel-vi.XXXXXX", dir, base);
    if (getenv("SPINEL_VI_SAVE_FAIL") && strcmp(getenv("SPINEL_VI_SAVE_FAIL"), "open") == 0) { sp_vi_file_error_set("injected open failure"); goto out; }
    fd = mkstemp(tmp); if (fd < 0 || fchmod(fd, st.st_mode & 07777) != 0) { sp_vi_file_error_set("temporary open or mode preserve failed"); goto out; }
    f = fdopen(fd, "wb"); if (f == NULL) { sp_vi_file_error_set("fdopen failed"); goto out; } fd = -1;
    if (getenv("SPINEL_VI_SAVE_FAIL") && strcmp(getenv("SPINEL_VI_SAVE_FAIL"), "write") == 0) { sp_vi_file_error_set("injected write failure"); goto out; }
    if (fwrite(text, 1, length, f) != length || fflush(f) != 0) { sp_vi_file_error_set("write or flush failed"); goto out; }
    if (getenv("SPINEL_VI_SAVE_FAIL") && strcmp(getenv("SPINEL_VI_SAVE_FAIL"), "fsync") == 0) { sp_vi_file_error_set("injected file fsync failure"); goto out; }
    if (fsync(fileno(f)) != 0 || fclose(f) != 0) { f = NULL; sp_vi_file_error_set("file fsync or close failed"); goto out; } f = NULL;
    if (getenv("SPINEL_VI_SAVE_FAIL") && strcmp(getenv("SPINEL_VI_SAVE_FAIL"), "rename") == 0) { sp_vi_file_error_set("injected rename failure"); goto out; }
    if (rename(tmp, path) != 0) { sp_vi_file_error_set("rename failed"); goto out; } renamed = 1;
    dfd = open(dir, O_RDONLY);
    if (getenv("SPINEL_VI_SAVE_FAIL") && strcmp(getenv("SPINEL_VI_SAVE_FAIL"), "dir-fsync") == 0) {
        sp_vi_file_error_set("injected directory fsync failure after rename"); goto out;
    }
    if (dfd < 0 || fsync(dfd) != 0) { sp_vi_file_error_set("directory fsync failed after rename"); goto out; }
    rc = 0;
out:
    if (f) fclose(f); if (fd >= 0) close(fd); if (dfd >= 0) close(dfd);
    if (!renamed) unlink(tmp);
    free(tmp); free(dir); return rc;
}

const char *sp_vi_file_error(void) { return sp_vi_file_error_text; }

/* Do not retain regex_t across an FFI call.  The editor supplies a checked,
 * NUL-free text buffer and an in-range byte offset; each successful regcomp
 * is paired with regfree before this function returns. */
int sp_vi_bre_find(const char *pattern, const char *text, size_t offset) {
    regex_t regex;
    regmatch_t match;
    int status;
    sp_vi_bre_last_start = -1;
    sp_vi_bre_last_end = -1;
    if (pattern == NULL || text == NULL || offset > strlen(text)) {
        snprintf(sp_vi_bre_error_text, sizeof(sp_vi_bre_error_text),
                 "BRE requires pattern, text, and result");
        return -1;
    }
    status = regcomp(&regex, pattern, 0); /* POSIX Basic Regular Expression */
    if (status != 0) {
        regerror(status, &regex, sp_vi_bre_error_text, sizeof(sp_vi_bre_error_text));
        return -1;
    }
    status = regexec(&regex, text + offset, 1, &match, 0);
    if (status == 0) {
        sp_vi_bre_last_start = (int)(offset + (size_t)match.rm_so);
        sp_vi_bre_last_end = (int)(offset + (size_t)match.rm_eo);
        regfree(&regex);
        return 0;
    }
    if (status == REG_NOMATCH) {
        regfree(&regex);
        return 1;
    }
    regerror(status, &regex, sp_vi_bre_error_text, sizeof(sp_vi_bre_error_text));
    regfree(&regex);
    return -1;
}

int sp_vi_bre_start(void) { return sp_vi_bre_last_start; }
int sp_vi_bre_end(void) { return sp_vi_bre_last_end; }
const char *sp_vi_bre_error(void) { return sp_vi_bre_error_text; }

int sp_vi_unicode_display_supported(void) {
    return 1; /* libgrapheme 3.0.0 snapshot is compiled into this TU. */
}

int sp_vi_text_needs_unicode(const char *text, size_t length) {
    size_t i;
    if (text == NULL) return 0;
    for (i = 0; i < length; i++) if (((unsigned char)text[i]) >= 0x80) return 1;
    return 0;
}

const char *sp_vi_unicode_error(void) {
    return sp_vi_unicode_error_text[0] ? sp_vi_unicode_error_text :
        "Unicode display unavailable: libgrapheme snapshot is not installed; ASCII-only editor";
}

static int sp_vi_egc_codepoints(const char *text, size_t length,
                                uint_least32_t *out, size_t *out_count) {
    size_t i = 0, count = 0, used;
    while (i < length) {
        if (count == 16) return -1; /* no silent truncation of a long EGC */
        used = grapheme_decode_utf8(text + i, length - i, &out[count]);
        if (used == 0 || used > length - i || out[count] == GRAPHEME_INVALID_CODEPOINT) return -1;
        i += used;
        count++;
    }
    *out_count = count;
    return count == 0 ? -1 : 0;
}

size_t sp_vi_egc_next(const char *text, size_t length, size_t offset) {
    size_t n;
    if (text == NULL || offset >= length) return length;
    n = grapheme_next_character_break_utf8(text + offset, length - offset);
    return n == 0 || n > length - offset ? length : offset + n;
}

size_t sp_vi_egc_prev(const char *text, size_t length, size_t offset) {
    size_t at = 0, next;
    if (text == NULL || offset == 0) return 0;
    if (offset > length) offset = length;
    while (at < offset) {
        next = sp_vi_egc_next(text, length, at);
        if (next >= offset || next <= at) return at;
        at = next;
    }
    return at;
}

/* V5 deliberately accepts only widths that this seam can prove.  A base
 * codepoint plus zero-width combining marks is safe; ZWJ, regional-indicator,
 * keycap and modifier clusters are rejected instead of summing widths. */
int sp_vi_egc_width(const char *text, size_t length, size_t offset, int column) {
    uint_least32_t cp[16];
    size_t next, count, i, ri_count = 0, wide_count = 0;
    int width, has_zwj = 0, has_vs16 = 0, has_modifier = 0;
    if (text == NULL || offset >= length || column < 0) return -1;
    next = sp_vi_egc_next(text, length, offset);
    if (next <= offset || sp_vi_egc_codepoints(text + offset, next - offset, cp, &count) != 0) return -1;
    if (cp[0] == '\t' && count == 1) return 8 - (column % 8);
    if ((cp[0] < 0x20 || cp[0] == 0x7f) && count == 1) return 2;
    for (i = 0; i < count; i++) {
        if (cp[i] == 0x200d) has_zwj = 1;
        if (cp[i] == 0xfe0f) has_vs16 = 1;
        if (cp[i] >= 0x1f3fb && cp[i] <= 0x1f3ff) has_modifier = 1;
        if (cp[i] >= 0x1f1e6 && cp[i] <= 0x1f1ff) ri_count++;
        if (tb_wcwidth(cp[i]) == 2) wide_count++;
        if (cp[i] == 0x20e3) return -1; /* keycap presentation is terminal-specific */
    }
    /* A regional-indicator pair is one flag cell pair, never 2+2 cells. */
    if (ri_count == 2 && count == 2) return 2;
    if (ri_count != 0) return -1;
    /* Emoji ZWJ and skin-tone sequences are explicitly width 2.  Permit only
     * wide emoji bases, joiners, modifiers and zero-width selectors/marks. */
    if (has_zwj || has_modifier) {
        if (wide_count == 0) return -1;
        for (i = 0; i < count; i++) {
            if (cp[i] == 0x200d || (cp[i] >= 0x1f3fb && cp[i] <= 0x1f3ff) ||
                tb_wcwidth(cp[i]) == 0 || tb_wcwidth(cp[i]) == 2) continue;
            return -1;
        }
        return 2;
    }
    width = tb_wcwidth(cp[0]);
    if (width < 1 || width > 2) return -1;
    if (has_vs16) return 2; /* emoji presentation selector, not width addition */
    for (i = 1; i < count; i++) {
        if ((cp[i] >= 0x1f1e6 && cp[i] <= 0x1f1ff) || tb_wcwidth(cp[i]) != 0) return -1;
    }
    return width;
}

int sp_vi_unicode_validate_display(const char *text, size_t length) {
    size_t at = 0, next;
    int column = 0, width;
    sp_vi_unicode_error_text[0] = '\0';
    while (at < length) {
        if ((unsigned char)text[at] == '\n') { at++; column = 0; continue; }
        next = sp_vi_egc_next(text, length, at);
        width = sp_vi_egc_width(text, length, at, column);
        if (next <= at || width < 0) {
            snprintf(sp_vi_unicode_error_text, sizeof(sp_vi_unicode_error_text),
                     "Unicode display width is unsafe for this EGC; ASCII-only editor");
            return -1;
        }
        column += width;
        at = next;
    }
    return 0;
}

int sp_vi_term_put_egc(int x, int y, const char *text, size_t length,
                       uint32_t fg, uint32_t bg) {
    uint_least32_t cp[16];
    size_t count;
    int result;
    if (!sp_vi_open || sp_vi_egc_codepoints(text, length, cp, &count) != 0) return -1;
    if (cp[0] == '\t' && count == 1) {
        result = sp_vi_term_put(x, y, '>', fg, bg);
        return result == 0 ? sp_vi_term_put(x + 1, y, ' ', fg, bg) : result;
    }
    if ((cp[0] < 0x20 || cp[0] == 0x7f) && count == 1) {
        result = sp_vi_term_put(x, y, '^', fg, bg);
        return result == 0 ? sp_vi_term_put(x + 1, y,
            cp[0] == 0x7f ? '?' : cp[0] + '@', fg, bg) : result;
    }
    if (!sp_vi_use_real) {
        sp_vi_log("putegc\t%d\t%d\tU+%04X\t%zu\t%u\t%u\n", x, y,
                  (unsigned)cp[0], count, fg, bg);
        return 0;
    }
    result = tb_set_cell_ex(x, y, (uint32_t *)cp, count, (uintattr_t)fg, (uintattr_t)bg);
    if (result != 0) sp_vi_set_error("tb_set_cell_ex", result);
    return result;
}

static int sp_vi_event_type_from_termbox(uint8_t type) {
    switch (type) {
    case TB_EVENT_KEY:
        return SP_VI_EVENT_KEY;
    case TB_EVENT_RESIZE:
        return SP_VI_EVENT_RESIZE;
    case TB_EVENT_MOUSE:
        return SP_VI_EVENT_MOUSE;
    default:
        sp_vi_set_error("unsupported termbox2 event type", (int)type);
        return -1;
    }
}

static void sp_vi_log(const char *format, ...) {
    va_list args;
    int written;
    if (sp_vi_log_len >= sizeof(sp_vi_log_text) - 1) return;
    va_start(args, format);
    written = vsnprintf(sp_vi_log_text + sp_vi_log_len,
                        sizeof(sp_vi_log_text) - sp_vi_log_len, format, args);
    va_end(args);
    if (written < 0) return;
    if ((size_t)written >= sizeof(sp_vi_log_text) - sp_vi_log_len) {
        sp_vi_log_len = sizeof(sp_vi_log_text) - 1;
    } else {
        sp_vi_log_len += (size_t)written;
    }
}

int sp_vi_term_fake_reset(void) {
    sp_vi_fake_head = 0;
    sp_vi_fake_tail = 0;
    sp_vi_log_len = 0;
    sp_vi_log_text[0] = '\0';
    sp_vi_error_text[0] = '\0';
    return 0;
}

int sp_vi_term_fake_push(int type, uint32_t ch, uint16_t key, uint8_t mod,
                         int width, int height) {
    int next = (sp_vi_fake_tail + 1) % SP_VI_FAKE_CAPACITY;
    spinel_vi_event *event;
    if (next == sp_vi_fake_head) {
        sp_vi_set_error("fake event queue is full", -1);
        return -1;
    }
    event = &sp_vi_fake_events[sp_vi_fake_tail];
    event->type = type;
    event->ch = ch;
    event->key = key;
    event->mod = mod;
    event->width = width;
    event->height = height;
    sp_vi_fake_tail = next;
    return 0;
}

const char *sp_vi_term_fake_log(void) { return sp_vi_log_text; }

int sp_vi_term_backend(void) { return sp_vi_use_real; }

int sp_vi_term_width(void) { return sp_vi_open ? sp_vi_width : -1; }
int sp_vi_term_height(void) { return sp_vi_open ? sp_vi_height : -1; }

int sp_vi_term_init(void) {
    const char *selected = getenv("SPINEL_VI_BACKEND");
    int result;
    if (sp_vi_open) {
        sp_vi_set_error("terminal is already initialized", -1);
        return -1;
    }
    sp_vi_use_real = selected != NULL && strcmp(selected, "termbox2") == 0;
    if (!sp_vi_use_real) {
        sp_vi_width = 80;
        sp_vi_height = 24;
        sp_vi_open = 1;
        sp_vi_log("init\n");
        return 0;
    }
    /* The app's stdin/stdout are the terminal ownership boundary.  Using the
     * supplied fd avoids reopening /dev/tty, which is unavailable in some
     * supervised PTY runners while stdin is still a valid terminal. */
    result = tb_init_rwfd(STDIN_FILENO, STDOUT_FILENO);
    if (result != 0) {
        sp_vi_set_error("tb_init_rwfd", result);
        return result;
    }
    (void)tb_set_input_mode(TB_INPUT_ESC);
    sp_vi_width = tb_width();
    sp_vi_height = tb_height();
    if (sp_vi_width <= 0 || sp_vi_height <= 0) {
        /* A freshly allocated test PTY may have no winsize yet.  Do not make
         * terminal ownership fail in that case: use the deterministic base
         * until its first resize.  Normal interactive terminals take the
         * tb_width/tb_height path above before the first render. */
        sp_vi_width = 80;
        sp_vi_height = 24;
    }
    sp_vi_open = 1;
    return 0;
}

int sp_vi_term_poll(void *out_event) {
    spinel_vi_event *event = (spinel_vi_event *)out_event;
    if (!sp_vi_open || event == NULL) {
        sp_vi_set_error("poll without initialized terminal or event", -1);
        return -1;
    }
    memset(event, 0, sizeof(*event));
    if (!sp_vi_use_real) {
        if (sp_vi_fake_head == sp_vi_fake_tail) return 0;
        *event = sp_vi_fake_events[sp_vi_fake_head];
        sp_vi_fake_head = (sp_vi_fake_head + 1) % SP_VI_FAKE_CAPACITY;
        sp_vi_log("event\t%d\tU+%04X\t%u\t%u\t%d\t%d\n", event->type,
                  event->ch, event->key, event->mod, event->width, event->height);
        return 1;
    }
    {
        struct tb_event tb_event;
        int result = tb_poll_event(&tb_event);
        if (result < 0) {
            sp_vi_set_error("tb_poll_event", result);
            return result;
        }
        event->type = sp_vi_event_type_from_termbox(tb_event.type);
        if (event->type < 0) return -1;
        event->ch = tb_event.ch;
        event->key = tb_event.key;
        event->mod = tb_event.mod;
        event->width = tb_event.w;
        event->height = tb_event.h;
        if (event->type == SP_VI_EVENT_RESIZE && event->width > 0 && event->height > 0) {
            sp_vi_width = event->width;
            sp_vi_height = event->height;
        }
        return 1;
    }
}

int sp_vi_term_clear(uint32_t fg, uint32_t bg) {
    int result;
    (void)fg;
    (void)bg;
    if (!sp_vi_open) return -1;
    if (!sp_vi_use_real) {
        sp_vi_log("clear\n");
        return 0;
    }
    result = tb_clear();
    if (result != 0) sp_vi_set_error("tb_clear", result);
    return result;
}

int sp_vi_term_put(int x, int y, uint32_t ch, uint32_t fg, uint32_t bg) {
    int result;
    if (!sp_vi_open) return -1;
    if (!sp_vi_use_real) {
        sp_vi_log("put\t%d\t%d\tU+%04X\t%u\t%u\n", x, y, ch, fg, bg);
        return 0;
    }
    result = tb_set_cell(x, y, ch, (uintattr_t)fg, (uintattr_t)bg);
    if (result != 0) sp_vi_set_error("tb_set_cell", result);
    return result;
}

int sp_vi_term_set_cursor(int x, int y) {
    int result;
    if (!sp_vi_open) return -1;
    if (!sp_vi_use_real) {
        sp_vi_log("cursor\t%d\t%d\n", x, y);
        return 0;
    }
    result = tb_set_cursor(x, y);
    if (result != 0) sp_vi_set_error("tb_set_cursor", result);
    return result;
}

int sp_vi_term_present(void) {
    int result;
    if (!sp_vi_open) return -1;
    if (!sp_vi_use_real) {
        sp_vi_log("present\n");
        return 0;
    }
    result = tb_present();
    if (result != 0) sp_vi_set_error("tb_present", result);
    return result;
}

int sp_vi_term_cell_width(uint32_t ch) {
    return tb_wcwidth(ch);
}

int sp_vi_term_test_resize(int width, int height) {
    struct winsize size;
    if (!sp_vi_open || !sp_vi_use_real || width <= 0 || height <= 0) {
        sp_vi_set_error("test resize requires an initialized real terminal", -1);
        return -1;
    }
    memset(&size, 0, sizeof(size));
    size.ws_col = (unsigned short)width;
    size.ws_row = (unsigned short)height;
    if (ioctl(STDIN_FILENO, TIOCSWINSZ, &size) != 0) {
        sp_vi_set_error("TIOCSWINSZ", -1);
        return -1;
    }
    if (raise(SIGWINCH) != 0) {
        sp_vi_set_error("SIGWINCH", -1);
        return -1;
    }
    return 0;
}

void sp_vi_term_shutdown(void) {
    if (!sp_vi_open) return;
    if (!sp_vi_use_real) {
        sp_vi_log("shutdown\n");
    } else {
        (void)tb_shutdown();
    }
    sp_vi_open = 0;
}

const char *sp_vi_term_error(void) { return sp_vi_error_text; }
