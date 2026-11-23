/* doom/tools/sp_sdl_shim.c — the C shim of the SDL2 interface
 *
 * Corresponds 1:1 to the `ffi_func` declarations in `lib/doom/video.rb`. The same approach
 * as the IREE experiment's `sp_gpu_shim.c`:
 *
 *   - live resources pass as **int64 handles** (the Ruby side holds no pointers)
 *   - failure comes back as the return value (0 / negative); the message is fetched with `sp_sdl_error()`
 *   - **the conversion from 8-bit indices to RGB is done here (in C)**: writing the
 *     conversion of 64 000 pixels as a Ruby loop would keep the frame loop allocation-free
 *     but eat the 35 Hz budget. The Ruby side passes one `String` and
 *     **allocates not one byte**.
 *   - keys: **SDL's events are folded here into DOOM's key codes** and reflected in a
 *     table of 256 bools that plays `gamekeydown[]`. The Ruby side only looks up
 *     `sp_sdl_key(h, code)`, and can write the same shape as vanilla's
 *     `G_BuildTiccmd`.
 *
 * The clock (`SDL_GetTicks`) lives here too. `lib/doom/` reads no clock;
 *   only `bin/doom.rb`'s frame pacing reads it.
 */

#include <SDL2/SDL.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#define SP_SDL_MAXWIN 4

typedef struct {
    int              used;
    SDL_Window      *win;
    SDL_Renderer    *ren;
    SDL_Texture     *tex;
    int              w, h;
    uint32_t        *argb;          /* the w*h conversion target */
    uint32_t         pal[256];
    unsigned char    keydown[256];
    int              quit;
    Uint64           p0;            /* the origin of SDL_GetPerformanceCounter */
} SpSdlWin;

static SpSdlWin s_win[SP_SDL_MAXWIN];
static char     s_err[256];

static void seterr(const char *what) {
    snprintf(s_err, sizeof s_err, "%s: %s", what, SDL_GetError());
}

const char *sp_sdl_error(void) { return s_err; }

static SpSdlWin *get(int64_t h) {
    if (h < 1 || h > SP_SDL_MAXWIN) return NULL;
    SpSdlWin *w = &s_win[h - 1];
    return w->used ? w : NULL;
}

/* ---------------------------------------------------------------- lifecycle */

int64_t sp_sdl_open(const char *title, int w, int h, int scale) {
    int slot = -1;
    for (int i = 0; i < SP_SDL_MAXWIN; i++) if (!s_win[i].used) { slot = i; break; }
    if (slot < 0) { snprintf(s_err, sizeof s_err, "no free window slot"); return 0; }
    if (w <= 0 || h <= 0 || scale <= 0) { snprintf(s_err, sizeof s_err, "bad geometry"); return 0; }

    if (!SDL_WasInit(SDL_INIT_VIDEO) && SDL_Init(SDL_INIT_VIDEO) != 0) {
        seterr("SDL_Init"); return 0;
    }
    SpSdlWin *p = &s_win[slot];
    memset(p, 0, sizeof *p);
    p->w = w; p->h = h;
    p->win = SDL_CreateWindow(title ? title : "doom",
                              SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              w * scale, h * scale, SDL_WINDOW_SHOWN);
    if (!p->win) { seterr("SDL_CreateWindow"); return 0; }
    /* **No vsync.** DOOM's unit of time is 1/35 second, and synchronizing to the
     * display's 60/120 Hz would quantize tics so that "is it keeping 35 Hz" could
     * no longer be measured. The Ruby side paces by target times from a
     * fixed epoch. */
    p->ren = SDL_CreateRenderer(p->win, -1, SDL_RENDERER_ACCELERATED);
    if (!p->ren) p->ren = SDL_CreateRenderer(p->win, -1, SDL_RENDERER_SOFTWARE);
    if (!p->ren) { seterr("SDL_CreateRenderer"); SDL_DestroyWindow(p->win); return 0; }
    SDL_RenderSetLogicalSize(p->ren, w, h);
    p->tex = SDL_CreateTexture(p->ren, SDL_PIXELFORMAT_ARGB8888,
                               SDL_TEXTUREACCESS_STREAMING, w, h);
    if (!p->tex) { seterr("SDL_CreateTexture"); SDL_DestroyRenderer(p->ren);
                   SDL_DestroyWindow(p->win); return 0; }
    p->argb = (uint32_t *)malloc((size_t)w * (size_t)h * sizeof(uint32_t));
    if (!p->argb) { snprintf(s_err, sizeof s_err, "out of memory"); return 0; }
    memset(p->argb, 0, (size_t)w * (size_t)h * sizeof(uint32_t));
    for (int i = 0; i < 256; i++) p->pal[i] = 0xff000000u;
    p->p0 = SDL_GetPerformanceCounter();
    p->used = 1;
    s_err[0] = '\0';
    return slot + 1;
}

void sp_sdl_close(int64_t h) {
    SpSdlWin *p = get(h);
    if (!p) return;
    if (p->argb) free(p->argb);
    if (p->tex) SDL_DestroyTexture(p->tex);
    if (p->ren) SDL_DestroyRenderer(p->ren);
    if (p->win) SDL_DestroyWindow(p->win);
    memset(p, 0, sizeof *p);
}

/* ------------------------------------------------------------------ palette */

/* Takes one PLAYPAL plane (768 bytes = 256 * RGB). */
int sp_sdl_set_palette(int64_t h, const char *pal) {
    SpSdlWin *p = get(h);
    if (!p || !pal) { snprintf(s_err, sizeof s_err, "bad handle/palette"); return -1; }
    const unsigned char *q = (const unsigned char *)pal;
    for (int i = 0; i < 256; i++)
        p->pal[i] = 0xff000000u | ((uint32_t)q[i*3] << 16)
                                | ((uint32_t)q[i*3+1] << 8)
                                |  (uint32_t)q[i*3+2];
    return 0;
}

/* ------------------------------------------------------------------- present */

/* Expands an 8-bit index plane (w*h bytes) into RGB and puts out one frame. */
int sp_sdl_present(int64_t h, const char *indexed) {
    SpSdlWin *p = get(h);
    if (!p || !indexed) { snprintf(s_err, sizeof s_err, "bad handle/frame"); return -1; }
    const unsigned char *src = (const unsigned char *)indexed;
    uint32_t *dst = p->argb;
    const uint32_t *pal = p->pal;
    size_t n = (size_t)p->w * (size_t)p->h;
    for (size_t i = 0; i < n; i++) dst[i] = pal[src[i]];
    if (SDL_UpdateTexture(p->tex, NULL, p->argb, p->w * (int)sizeof(uint32_t)) != 0) {
        seterr("SDL_UpdateTexture"); return -1;
    }
    SDL_RenderClear(p->ren);
    SDL_RenderCopy(p->ren, p->tex, NULL, NULL);
    SDL_RenderPresent(p->ren);
    return 0;
}

/* For checking by eye: writes the last presented picture as BMP (evidence for headless checks). */
int sp_sdl_save_bmp(int64_t h, const char *path) {
    SpSdlWin *p = get(h);
    if (!p || !path) { snprintf(s_err, sizeof s_err, "bad handle/path"); return -1; }
    SDL_Surface *s = SDL_CreateRGBSurfaceFrom(p->argb, p->w, p->h, 32,
                                              p->w * (int)sizeof(uint32_t),
                                              0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000);
    if (!s) { seterr("SDL_CreateRGBSurfaceFrom"); return -1; }
    int rc = SDL_SaveBMP(s, path);
    SDL_FreeSurface(s);
    if (rc != 0) { seterr("SDL_SaveBMP"); return -1; }
    return 0;
}

/* --------------------------------------------------------------------- input */

/* Folds SDL's keys into DOOM's key codes (`doomdef.h`). The same table as doomgeneric's
 * `translateKey`, copied only for the range this port uses. */
static int doomkey(SDL_Keycode k) {
    switch (k) {
        case SDLK_RIGHT:     return 0xae;   /* KEY_RIGHTARROW */
        case SDLK_LEFT:      return 0xac;   /* KEY_LEFTARROW  */
        case SDLK_UP:        return 0xad;   /* KEY_UPARROW    */
        case SDLK_DOWN:      return 0xaf;   /* KEY_DOWNARROW  */

        /* ---- Spinel Extended local change (decision 0006 task 4) ----------
         * i / j / k / l drive movement, alongside the arrows.
         *
         * Requested by the owner after a real-key trace on macOS: the arrow
         * presses arrived as Right Command and Left Option, so the arrows were
         * not usable there.  Why they arrived that way is still unidentified
         * and is NOT what this change decides -- it gives the player keys that
         * work while that stands open.
         *
         * The arrows above are kept as aliases rather than replaced: removing a
         * binding that works elsewhere to fix one that does not would trade one
         * broken machine for every other.
         *
         * These four return the same DOOM codes as the arrows, so nothing below
         * the shim changes: G_BuildTiccmd still reads gamekeydown[0xad] and has
         * no idea which physical key set it.  i/j/k/l had been falling through
         * to the letter arm below, returning their own ASCII codes, which no
         * watched key uses -- so no binding is lost by claiming them.
         */
        case SDLK_i:         return 0xad;   /* KEY_UPARROW    */
        case SDLK_j:         return 0xac;   /* KEY_LEFTARROW  */
        case SDLK_k:         return 0xaf;   /* KEY_DOWNARROW  */
        case SDLK_l:         return 0xae;   /* KEY_RIGHTARROW */
        case SDLK_ESCAPE:    return 27;     /* KEY_ESCAPE     */
        case SDLK_RETURN:    return 13;     /* KEY_ENTER      */
        case SDLK_TAB:       return 9;      /* KEY_TAB        */
        case SDLK_BACKSPACE: return 0x7f;   /* KEY_BACKSPACE  */
        case SDLK_PAUSE:     return 0xff;   /* KEY_PAUSE      */
        case SDLK_EQUALS:    return 0x3d;
        case SDLK_MINUS:     return 0x2d;
        case SDLK_LSHIFT: case SDLK_RSHIFT: return 0xb6;   /* KEY_RSHIFT */
        case SDLK_LCTRL:  case SDLK_RCTRL:  return 0x9d;   /* KEY_RCTRL  */
        case SDLK_LALT:   case SDLK_RALT:   return 0xb8;   /* KEY_RALT   */
        case SDLK_SPACE:  return ' ';
        case SDLK_COMMA:  return ',';
        case SDLK_PERIOD: return '.';
        default:
            /* i/j/k/l are handled above and never reach here. */
            if (k >= SDLK_a && k <= SDLK_z) return (int)k;              /* lower case as it is */
            if (k >= SDLK_0 && k <= SDLK_9) return (int)k;
            return 0;
    }
}

/* Drains events and updates `keydown[]`. Returns 1 if closing was requested. */
int sp_sdl_pump(int64_t h) {
    SpSdlWin *p = get(h);
    if (!p) return 1;
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        if (e.type == SDL_QUIT) p->quit = 1;
        else if (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) {
            if (e.key.repeat) continue;
            int c = doomkey(e.key.keysym.sym);
            if (c > 0 && c < 256) p->keydown[c] = (e.type == SDL_KEYDOWN);
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) p->quit = 1;
        }
    }
    return p->quit;
}

int sp_sdl_key(int64_t h, int code) {
    SpSdlWin *p = get(h);
    if (!p || code < 0 || code > 255) return 0;
    return p->keydown[code] ? 1 : 0;
}

/* ---------------------------------------------------------------------- time */

/* Microseconds since opening. Milliseconds cannot measure the distribution of 1.2 ms
 * frames, so the frame pacing's instrument uses this. */
int64_t sp_sdl_us(int64_t h) {
    SpSdlWin *p = get(h);
    if (!p) return 0;
    Uint64 f = SDL_GetPerformanceFrequency();
    if (f == 0) return 0;
    return (int64_t)(((SDL_GetPerformanceCounter() - p->p0) * 1000000ull) / f);
}

void sp_sdl_delay(int ms) {
    if (ms > 0) SDL_Delay((Uint32)ms);
}
