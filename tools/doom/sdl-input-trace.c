/* tools/doom/sdl-input-trace.c — what does a real key press deliver?
 *
 * The layer nobody has measured is the one between a physical key and an SDL
 * event: the OS, the window server and SDL's input backend.  It cannot be
 * measured on a host with no keyboard in front of it, and it cannot be measured
 * by pushing synthetic events, because synthetic events are what it would have
 * produced if it worked.
 *
 * So this opens a window, uses the REAL shim -- sp_sdl_open, sp_sdl_pump,
 * sp_sdl_key, linked unmodified -- and writes down every key event SDL
 * delivers, together with the shim's keydown table after each pump.  A person
 * presses keys at it.  The trace then says, for the up+left question:
 *
 *   - whether SDL delivered a KEYDOWN for both keys at all;
 *   - whether it delivered a KEYUP nobody pressed;
 *   - whether the shim's table held both, which is layer 2 under real input
 *     rather than under events this project generated;
 *   - how far apart the events arrived, for the responsiveness question.
 *
 * It is a diagnostic and is opt-in by being a separate program: the game does
 * not link it, nothing calls it, and a normal build is unchanged.  It does not
 * decide anything.  A trace showing both keys down means the answer is further
 * down; a trace missing an event means it is further up.  Which of the OS, the
 * window server or SDL is responsible is not something this can say.
 *
 *   sdl-input-trace [seconds] [out.tsv]      default 20 seconds, stdout
 *   sdl-input-trace --self-test              push synthetic events and check
 *                                            that they are recorded
 *
 * The self test exists because an empty trace has two causes that look the
 * same: nothing arrived, or this program does not record.  On a host with no
 * keyboard the first is expected, and without the second being ruled out the
 * empty file says nothing.  It pushes the same up/left sequence the synthetic
 * probe uses and requires the trace to contain it.
 *
 * Columns: ms  event  sym  scancode  name  scancode_name  repeat  winid  up  left  note
 *
 * `event` is KEYDOWN, KEYUP, WINDOW or QUIT; for WINDOW rows `name` is the
 * window event -- FOCUS_GAINED, FOCUS_LOST, ENTER, LEAVE and so on -- and those
 * are recorded because a window without keyboard focus receives no key events,
 * which from inside the game looks exactly like a key nobody pressed.
 * `up` and `left` are the shim's table, read through sp_sdl_key, after the pump
 * that consumed the event.  Escape ends it, as in the game.
 *
 * Events are captured with SDL_AddEventWatch rather than by peeking the queue.
 * A first version peeked and then let the shim's pump consume, which loses
 * events: the shim's pump drains the WHOLE queue in one call, so at most one
 * peek per batch ever saw anything.  The self test caught that -- it recorded
 * none of two pushed events -- which is what a self test is for.  A watch sees
 * every event as it is queued and takes nothing out of the queue, so the shim
 * still consumes exactly what it would have.
 */

#include <SDL2/SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int64_t sp_sdl_open(const char *title, int w, int h, int scale);
extern void    sp_sdl_close(int64_t h);
extern int     sp_sdl_pump(int64_t h);
extern int     sp_sdl_key(int64_t h, int code);
extern const char *sp_sdl_error(void);

#define KEY_UP   0xad
#define KEY_LEFT 0xac

/* Events seen by the watch since the last pump.  Small and fixed: a person
 * cannot produce hundreds of key events between two pumps, and a ring that
 * silently wrapped would be worse than one that says it dropped. */
#define TRACE_MAX 512
static struct {
    Uint32 type; SDL_Keycode sym; SDL_Scancode sc; Uint8 repeat;
    Uint32 winid; Uint8 winev; Uint64 ms;
} g_buf[TRACE_MAX];
static int g_n, g_dropped;
static Uint64 g_t0;

/* Counters for the summary.  g_left_down_while_up_held starts negative so
 * "LEFT never went down" is distinguishable from "it went down and UP was 0". */
static int g_up_down, g_up_up, g_left_down, g_left_up;
static int g_focus_gained, g_focus_lost, g_both_rows;
static int g_left_down_while_up_held = -1;
static int g_key_events, g_arrow_events;

/* The keys this diagnostic is about, printed at startup so a trace says what it
 * was looking for.  A session where the wrong physical keys were pressed is
 * then obvious from the file alone, rather than needing someone to remember
 * which numbers are arrows. */
static void legend(FILE *out)
{
    static const struct { const char *label; SDL_Keycode k; } rows[] = {
        { "UP",    SDLK_UP },    { "LEFT",  SDLK_LEFT },
        { "DOWN",  SDLK_DOWN },  { "RIGHT", SDLK_RIGHT },
        /* The letter bindings the shim now also accepts for movement. */
        { "i(=UP)", SDLK_i },    { "j(=LEFT)", SDLK_j },
        { "k(=DOWN)", SDLK_k },  { "l(=RIGHT)", SDLK_l },
        { "ESCAPE", SDLK_ESCAPE },
    };
    unsigned i;
    for (i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        SDL_Scancode sc = SDL_GetScancodeFromKey(rows[i].k);
        fprintf(out, "# expect %-6s sym=%d scancode=%d name=%s\n",
                rows[i].label, (int)rows[i].k, (int)sc, SDL_GetKeyName(rows[i].k));
    }
    fprintf(out, "# a masked keycode is scancode | %d\n", (int)SDLK_SCANCODE_MASK);
}

/* "a movement key" now means an arrow or one of i/j/k/l: the summary should not
 * say "no movement keys arrived" about a session where the letters were used. */
static int is_arrow(SDL_Keycode k)
{
    return k == SDLK_UP || k == SDLK_DOWN || k == SDLK_LEFT || k == SDLK_RIGHT ||
           k == SDLK_i  || k == SDLK_j    || k == SDLK_k    || k == SDLK_l;
}

/* Window events are recorded too, and focus is the reason.  A window that does
 * not hold keyboard focus receives no key events at all, which from inside the
 * game is indistinguishable from a key that was never pressed -- and "the first
 * press does nothing, the second works" is what an unfocused window looks like
 * from the outside.  Whether that is what is happening is for the trace to say,
 * not for this comment to assume. */
static int SDLCALL watch(void *userdata, SDL_Event *e)
{
    (void)userdata;
    if (e->type != SDL_KEYDOWN && e->type != SDL_KEYUP &&
        e->type != SDL_QUIT && e->type != SDL_WINDOWEVENT) return 1;
    if (g_n >= TRACE_MAX) { g_dropped++; return 1; }
    memset(&g_buf[g_n], 0, sizeof g_buf[0]);
    g_buf[g_n].type = e->type;
    if (e->type == SDL_KEYDOWN || e->type == SDL_KEYUP) {
        g_buf[g_n].sym = e->key.keysym.sym;
        g_buf[g_n].sc = e->key.keysym.scancode;
        g_buf[g_n].repeat = e->key.repeat;
        g_buf[g_n].winid = e->key.windowID;
    } else if (e->type == SDL_WINDOWEVENT) {
        g_buf[g_n].winid = e->window.windowID;
        g_buf[g_n].winev = e->window.event;
    }
    g_buf[g_n].ms = SDL_GetTicks64() - g_t0;
    g_n++;
    return 1;   /* leave it in the queue for the shim */
}

static const char *winev_name(Uint8 ev)
{
    switch (ev) {
        case SDL_WINDOWEVENT_SHOWN:         return "SHOWN";
        case SDL_WINDOWEVENT_HIDDEN:        return "HIDDEN";
        case SDL_WINDOWEVENT_EXPOSED:       return "EXPOSED";
        case SDL_WINDOWEVENT_ENTER:         return "ENTER";
        case SDL_WINDOWEVENT_LEAVE:         return "LEAVE";
        case SDL_WINDOWEVENT_FOCUS_GAINED:  return "FOCUS_GAINED";
        case SDL_WINDOWEVENT_FOCUS_LOST:    return "FOCUS_LOST";
        case SDL_WINDOWEVENT_TAKE_FOCUS:    return "TAKE_FOCUS";
        case SDL_WINDOWEVENT_CLOSE:         return "CLOSE";
        default:                            return "other";
    }
}

static int flush(FILE *out, int64_t h)
{
    int i, up = sp_sdl_key(h, KEY_UP), left = sp_sdl_key(h, KEY_LEFT);
    for (i = 0; i < g_n; i++) {
        const char *kind =
            g_buf[i].type == SDL_KEYDOWN    ? "KEYDOWN" :
            g_buf[i].type == SDL_KEYUP      ? "KEYUP"   :
            g_buf[i].type == SDL_WINDOWEVENT ? "WINDOW" : "QUIT";
        const char *name = (g_buf[i].type == SDL_KEYDOWN || g_buf[i].type == SDL_KEYUP)
                           ? SDL_GetKeyName(g_buf[i].sym)
                           : (g_buf[i].type == SDL_WINDOWEVENT ? winev_name(g_buf[i].winev) : "-");
        fprintf(out, "%lu\t%s\t%d\t%d\t%s\t%s\t%d\t%u\t%d\t%d\t%s\n",
                (unsigned long)g_buf[i].ms, kind, (int)g_buf[i].sym, (int)g_buf[i].sc,
                name,
                (g_buf[i].type == SDL_KEYDOWN || g_buf[i].type == SDL_KEYUP)
                    ? SDL_GetScancodeName(g_buf[i].sc) : "-",
                (int)g_buf[i].repeat, (unsigned)g_buf[i].winid, up, left,
                (up && left) ? "both-held" : "");

        if (g_buf[i].type == SDL_KEYDOWN || g_buf[i].type == SDL_KEYUP) {
            g_key_events++;
            if (is_arrow(g_buf[i].sym)) g_arrow_events++;
        }
        if (g_buf[i].type == SDL_KEYDOWN && !g_buf[i].repeat) {
            if (g_buf[i].sym == SDLK_UP) g_up_down++;
            if (g_buf[i].sym == SDLK_LEFT) {
                g_left_down++;
                if (g_left_down_while_up_held < 0) g_left_down_while_up_held = up;
            }
        }
        if (g_buf[i].type == SDL_KEYUP) {
            if (g_buf[i].sym == SDLK_UP) g_up_up++;
            if (g_buf[i].sym == SDLK_LEFT) g_left_up++;
        }
        if (g_buf[i].type == SDL_WINDOWEVENT) {
            if (g_buf[i].winev == SDL_WINDOWEVENT_FOCUS_GAINED) g_focus_gained++;
            if (g_buf[i].winev == SDL_WINDOWEVENT_FOCUS_LOST) g_focus_lost++;
        }
        if (up && left) g_both_rows++;
    }
    fflush(out);
    i = g_n; g_n = 0;
    return i;
}

static void push_synth(SDL_Keycode sym, int down)
{
    SDL_Event e;
    memset(&e, 0, sizeof e);
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.type = e.type;
    e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.repeat = 0;
    e.key.keysym.sym = sym;
    e.key.keysym.scancode = SDL_GetScancodeFromKey(sym);
    SDL_PushEvent(&e);
}

/* Drive the same loop the trace uses, with events this program supplies, and
 * require them to come out the far end.  Proves the instrument records. */
static int self_test(void)
{
    int64_t h;
    int seen;

    g_t0 = SDL_GetTicks64();
    h = sp_sdl_open("self test", 320, 200, 1);
    if (h <= 0) { fprintf(stderr, "self-test: sp_sdl_open failed: %s\n", sp_sdl_error()); return 2; }
    SDL_AddEventWatch(watch, NULL);

    push_synth(SDLK_UP, 1);
    push_synth(SDLK_LEFT, 1);
    sp_sdl_pump(h);
    seen = g_n;
    {
        int up = sp_sdl_key(h, KEY_UP), left = sp_sdl_key(h, KEY_LEFT);
        SDL_DelEventWatch(watch, NULL);
        sp_sdl_close(h);
        if (seen != 2) {
            fprintf(stderr, "self-test: recorded %d of 2 pushed events -- the tracer does not record\n", seen);
            return 1;
        }
        if (!up || !left) {
            fprintf(stderr, "self-test: both keys were pushed but the table held up=%d left=%d\n", up, left);
            return 1;
        }
    }
    printf("self-test: ok (2 events recorded, both keys held)\n");
    printf("self-test: so an empty trace on this host means no events arrived,\n");
    printf("self-test: not that this program fails to record them.\n");
    return 0;
}

int main(int argc, char **argv)
{
    int seconds;
    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return self_test();
    seconds = argc > 1 ? atoi(argv[1]) : 20;
    FILE *out = stdout;
    int64_t h;
    Uint64 t0;
    int quit = 0, events = 0;

    if (argc > 2) {
        out = fopen(argv[2], "w");
        if (!out) { fprintf(stderr, "trace: cannot write %s\n", argv[2]); return 2; }
    }
    if (seconds <= 0) seconds = 20;

    g_t0 = SDL_GetTicks64();
    /* The watch goes on before the window exists, so a FOCUS_GAINED delivered
     * at creation is recorded.  A first version added it after sp_sdl_open and
     * would have missed exactly that -- and whether focus was ever gained is
     * one of the things a trace is for. */
    SDL_AddEventWatch(watch, NULL);
    h = sp_sdl_open("doom input trace -- hold UP and LEFT, Escape to finish", 320, 200, 2);
    if (h <= 0) { fprintf(stderr, "trace: sp_sdl_open failed: %s\n", sp_sdl_error()); return 2; }

    legend(out);
    fprintf(out, "#ms\tevent\tsym\tscancode\tname\tscancode_name\trepeat\twinid\tup\tleft\tnote\n");
    fflush(out);
    fprintf(stderr,
        "trace: window open for %d seconds.  Escape finishes early.\n"
        "trace: please do exactly this, pausing about a second between steps:\n"
        "trace:   1. press i (forward) once and release it\n"
        "trace:   2. press i again and release it\n"
        "trace:   3. hold i down and keep holding\n"
        "trace:   4. while i is still held, press j (left) and hold both\n"
        "trace:   5. release j, keeping i held\n"
        "trace:   6. release i\n"
        "trace: the arrow keys do the same thing and are worth a second pass.\n"
        "trace: the report is that forward needs two presses and that adding LEFT\n"
        "trace: stops it, so steps 1-2 and 4 are the ones that matter.\n", seconds);

    t0 = g_t0;
    while (!quit && (int)((SDL_GetTicks64() - t0) / 1000) < seconds) {
        quit |= sp_sdl_pump(h);   /* consumes exactly as the game does */
        events += flush(out, h);
        SDL_Delay(1);
    }
    quit |= sp_sdl_pump(h);
    events += flush(out, h);
    SDL_DelEventWatch(watch, NULL);
    if (g_dropped)
        fprintf(stderr, "trace: %d event(s) dropped -- the buffer between two pumps filled\n", g_dropped);

    /* A short reading of the trace, aimed at the two things reported.  The TSV
     * stays the evidence; this is only so the answer is not buried in it.  It
     * counts rather than concludes: "no KEYDOWN arrived" and "the OS is at
     * fault" are different statements and only the first is here. */
    fprintf(stderr, "trace: ---- summary ----\n");
    fprintf(stderr, "trace: UP    KEYDOWN %d, KEYUP %d\n", g_up_down, g_up_up);
    fprintf(stderr, "trace: LEFT  KEYDOWN %d, KEYUP %d\n", g_left_down, g_left_up);
    fprintf(stderr, "trace: focus gained %d, lost %d\n", g_focus_gained, g_focus_lost);
    if (g_left_down_while_up_held >= 0)
        fprintf(stderr, "trace: when LEFT first went down, the shim held UP=%d\n",
                g_left_down_while_up_held);
    else
        fprintf(stderr, "trace: LEFT never went down while the trace ran\n");
    if (g_both_rows > 0)
        fprintf(stderr, "trace: %d row(s) had UP and LEFT held together\n", g_both_rows);
    else
        fprintf(stderr, "trace: no row ever had UP and LEFT held together\n");
    fprintf(stderr, "trace: key events %d, of which movement keys %d\n", g_key_events, g_arrow_events);
    if (g_key_events > 0 && g_arrow_events == 0)
        fprintf(stderr, "trace: note: key events ARRIVED but none of them were movement keys.\n"
                        "trace:       The window was receiving input; the keys pressed were not\n"
                        "trace:       the ones this diagnostic watches.  Compare the sym and\n"
                        "trace:       scancode columns against the `# expect` lines at the top.\n");
    if (g_up_down > 0 && g_focus_gained == 0)
        fprintf(stderr, "trace: note: key events arrived but no FOCUS_GAINED was seen\n");
    if (g_up_down == 0 && g_focus_gained == 0)
        fprintf(stderr, "trace: note: neither key events nor focus events arrived\n");

    sp_sdl_close(h);
    fprintf(stderr, "trace: %d key event(s) recorded over %ld ms\n",
            events, (long)(SDL_GetTicks64() - t0));
    if (out != stdout) fclose(out);
    return 0;
}
