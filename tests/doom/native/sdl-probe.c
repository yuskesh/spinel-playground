/* tests/doom/native/sdl-probe.c — can SDL open a video device here?
 *
 * Exists so that "no display" and "the game broke" are answered by different
 * things.  Deciding from a failing game run -- looking for the word SDL in its
 * log -- turns every real SDL fault into a successful skip, which is the one
 * outcome a test must never produce.
 *
 * Exit 0: SDL_Init(SDL_INIT_VIDEO) succeeded, so anything that fails later is
 *         a failure of the program under test.
 * Exit 1: it did not, and the reason is printed.  That is a skip.
 * Exit 2: usage or an internal problem, which is neither.
 *
 * It honours SDL_VIDEODRIVER like any SDL program, so probing with the dummy
 * driver answers the question for the dummy driver.
 */

#include <SDL2/SDL.h>
#include <stdio.h>

int main(void)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "sdl-probe: SDL_Init(SDL_INIT_VIDEO) failed: %s\n", SDL_GetError());
        return 1;
    }
    {
        const char *drv = SDL_GetCurrentVideoDriver();
        printf("%s\n", drv ? drv : "(none)");
    }
    SDL_Quit();
    return 0;
}
