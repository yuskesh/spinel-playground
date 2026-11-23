/* tests/doom/native/key-combination-probe.c — does the SDL shim hold two keys
 * down at once?
 *
 * Answers the layer the scripted-input test cannot reach.  A script fills the
 * same `gamekeydown[]` table SDL fills, so it exercises everything BELOW that
 * table and nothing above it.  This probe drives the layer above: it pushes
 * synthetic SDL key events into the queue with SDL_PushEvent, calls
 * sp_sdl_pump() exactly as bin/doom.rb does, and reads the table back through
 * sp_sdl_key().
 *
 * It links the shim unmodified.  The shim is imported byte-identical and adding
 * a test hook to it would both break that and change the thing under test.
 *
 * What it still does NOT establish: that a real key press produces the SDL
 * event in the first place.  Between a keyboard and SDL_PushEvent sit the OS,
 * the window server and SDL's own input backend, and none of them is here.
 * This says what the shim does with the events it is given.
 *
 * It also covers the i/j/k/l bindings added for decision 0006 task 4, and that
 * the arrows still work alongside them rather than having been replaced.
 *
 * Output: one line per case, `case <name> up=<0|1> left=<0|1>`, then a verdict.
 * Exit 0 if every case matched its expectation, 1 otherwise.
 */

#include <SDL2/SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern int64_t sp_sdl_open(const char *title, int w, int h, int scale);
extern void    sp_sdl_close(int64_t h);
extern int     sp_sdl_pump(int64_t h);
extern int     sp_sdl_key(int64_t h, int code);
extern const char *sp_sdl_error(void);

#define KEY_UP   0xad
#define KEY_LEFT 0xac

static void push(SDL_Keycode sym, int down)
{
    SDL_Event e;
    memset(&e, 0, sizeof e);
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.type = e.type;
    e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.repeat = 0;
    e.key.keysym.sym = sym;
    e.key.keysym.scancode = SDL_GetScancodeFromKey(sym);
    if (SDL_PushEvent(&e) < 0)
        fprintf(stderr, "probe: SDL_PushEvent failed: %s\n", SDL_GetError());
}

static int fails;

static void expect(int64_t h, const char *name, int want_up, int want_left)
{
    int up, left;
    sp_sdl_pump(h);
    up = sp_sdl_key(h, KEY_UP);
    left = sp_sdl_key(h, KEY_LEFT);
    printf("case %-22s up=%d left=%d", name, up, left);
    if (up == want_up && left == want_left) {
        printf("  ok\n");
    } else {
        printf("  FAIL (wanted up=%d left=%d)\n", want_up, want_left);
        fails++;
    }
}

int main(void)
{
    int64_t h = sp_sdl_open("key-combination-probe", 320, 200, 1);
    if (h <= 0) {
        fprintf(stderr, "probe: sp_sdl_open failed: %s\n", sp_sdl_error());
        return 2;
    }

    /* Nothing held. */
    expect(h, "start", 0, 0);

    /* Up alone. */
    push(SDLK_UP, 1);
    expect(h, "up down", 1, 0);
    push(SDLK_UP, 0);
    expect(h, "up up", 0, 0);

    /* Left alone. */
    push(SDLK_LEFT, 1);
    expect(h, "left down", 0, 1);
    push(SDLK_LEFT, 0);
    expect(h, "left up", 0, 0);

    /* Both at once, pressed in one pump and in separate pumps. */
    push(SDLK_UP, 1);
    push(SDLK_LEFT, 1);
    expect(h, "up+left, one pump", 1, 1);
    push(SDLK_UP, 0);
    push(SDLK_LEFT, 0);
    expect(h, "both released", 0, 0);

    push(SDLK_UP, 1);
    expect(h, "up down (staggered)", 1, 0);
    push(SDLK_LEFT, 1);
    expect(h, "left added", 1, 1);

    /* Releasing one side must not clear the other -- the case the report is
     * actually about. */
    push(SDLK_LEFT, 0);
    expect(h, "left released, up held", 1, 0);
    push(SDLK_LEFT, 1);
    expect(h, "left re-added", 1, 1);
    push(SDLK_UP, 0);
    expect(h, "up released, left held", 0, 1);
    push(SDLK_LEFT, 0);
    expect(h, "both clear", 0, 0);

    /* ---- the i/j/k/l bindings, added for decision 0006 task 4 -------------
     * They must reach the same DOOM codes as the arrows, hold together, and
     * release independently -- the same properties the arrows were checked for,
     * because a second binding that only half works is worse than none. */
    push(SDLK_i, 1);
    expect(h, "i down (= up)", 1, 0);
    push(SDLK_j, 1);
    expect(h, "i+j, both", 1, 1);
    push(SDLK_j, 0);
    expect(h, "j released, i held", 1, 0);
    push(SDLK_i, 0);
    push(SDLK_j, 1);
    expect(h, "j alone (= left)", 0, 1);
    push(SDLK_j, 0);
    expect(h, "j released", 0, 0);

    /* The arrows are aliases, not replacements: an arrow and a letter must be
     * able to set and clear the same code.  A shim that had replaced the arrows
     * would pass every case above and fail this one. */
    push(SDLK_i, 1);
    expect(h, "i held", 1, 0);
    push(SDLK_UP, 0);
    expect(h, "UP released clears i's code", 0, 0);
    push(SDLK_UP, 1);
    push(SDLK_j, 1);
    expect(h, "UP + j together", 1, 1);
    push(SDLK_UP, 0);
    push(SDLK_j, 0);
    expect(h, "both cleared", 0, 0);

    /* k and l reach DOWN and RIGHT.  Checked through sp_sdl_key directly
     * because the up/left columns above cannot see them. */
    push(SDLK_k, 1);
    push(SDLK_l, 1);
    sp_sdl_pump(h);
    {
        int down = sp_sdl_key(h, 0xaf), right = sp_sdl_key(h, 0xae);
        printf("case %-22s down=%d right=%d", "k+l", down, right);
        if (down == 1 && right == 1) printf("  ok\n");
        else { printf("  FAIL (wanted down=1 right=1)\n"); fails++; }
    }
    push(SDLK_k, 0);
    push(SDLK_l, 0);
    sp_sdl_pump(h);
    {
        int down = sp_sdl_key(h, 0xaf), right = sp_sdl_key(h, 0xae);
        printf("case %-22s down=%d right=%d", "k+l released", down, right);
        if (down == 0 && right == 0) printf("  ok\n");
        else { printf("  FAIL (wanted down=0 right=0)\n"); fails++; }
    }

    /* An auto-repeat event is skipped by the shim; the table must keep its
     * state rather than being disturbed by one. */
    push(SDLK_UP, 1);
    push(SDLK_LEFT, 1);
    expect(h, "both held", 1, 1);
    {
        SDL_Event e;
        memset(&e, 0, sizeof e);
        e.type = SDL_KEYDOWN;
        e.key.type = SDL_KEYDOWN;
        e.key.state = SDL_PRESSED;
        e.key.repeat = 1;
        e.key.keysym.sym = SDLK_UP;
        SDL_PushEvent(&e);
    }
    expect(h, "after an auto-repeat", 1, 1);

    sp_sdl_close(h);
    printf("key-combination-probe: %s\n", fails ? "FAIL" : "all cases as expected");
    return fails ? 1 : 0;
}
