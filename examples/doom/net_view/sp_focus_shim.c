/* examples/doom/net_view/sp_focus_shim.c -- whether the viewer's window has
 * the keyboard (decision 0025 point 13).
 *
 * net_view.rb sends every key released while its window does not have the
 * keyboard's focus. The viewer opens one window, so SDL's keyboard focus
 * being any window at all is that window having it. Kept apart from
 * ../native/sp_sdl_shim.c, which bin/doom.rb shares and which has no use for
 * it.
 */

#include <SDL2/SDL.h>

/* 1 when a window of this process has the keyboard's focus, 0 otherwise */
int sp_view_focused(void) { return SDL_GetKeyboardFocus() != NULL ? 1 : 0; }
