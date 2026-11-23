# The real-key trace: what it showed, and what it did not

**Date:** 2026-09-11. macOS arm64, Clang 23.1.1, SDL2 2.32.10, `cocoa` driver,
`4836365`. The macOS side's exec `20635`; raw log at
`build/mac-real-input-trace.tsv` there. A person performed the instructed
sequence and ended with Escape; 9 events.

## The trace

| ms | event | sym | scancode | name | repeat |
|---|---|---|---|---|---|
| 17534 | KEYDOWN | 1073742055 | 231 | Right Command | 0 |
| 17705 | KEYUP | 1073742055 | 231 | Right Command | 0 |
| 20995 | KEYDOWN | 1073742055 | 231 | Right Command | 0 |
| 21397 | KEYDOWN | 1073742050 | 226 | Left Option | 0 |
| 21397 | KEYDOWN | 1073742055 | 231 | Right Command | **1** |
| 21720 | KEYUP | 1073742050 | 226 | Left Option | 0 |
| 21720 | KEYDOWN | 1073742055 | 231 | Right Command | **1** |
| 22211 | KEYUP | 1073742055 | 231 | Right Command | 0 |
| 27825 | KEYDOWN | 27 | 41 | Escape | 0 |

`up` and `left` are 0 on every row.

## The numbers are the diagnostic's, and they are right

Checked against SDL's own constants rather than taken on trust. A masked
keycode is `scancode | (1 << 30)` = `scancode | 1073741824`:

| | sym | scancode |
|---|---|---|
| `SDLK_RGUI` | 1073742055 | 231 |
| `SDLK_LALT` | 1073742050 | 226 |
| `SDLK_UP` | **1073741906** | **82** |
| `SDLK_LEFT` | **1073741904** | **80** |
| `SDLK_ESCAPE` | 27 | 41 |

So the trace's `1073742055/231` really is Right Command and `1073742050/226`
really is Left Option; `SDL_GetKeyName` returns the platform's own name, which
is why macOS says "Right Command" where Linux says "Right GUI". **No arrow-key
event appears anywhere in the log**, and Escape — which did arrive — matches its
constant exactly, so the diagnostic was reporting correctly when it reported
nothing for the arrows.

## What this establishes

- **The window was receiving keyboard input.** Nine events arrived and Escape
  ended the run. This is not a focus failure at the moment of the trace.
- **The shim never saw an arrow key**, so `up` and `left` stayed 0 — which is
  the correct behaviour for the events it was given, not a fault in it.
- **The keys that arrived were Right Command and Left Option.** Their timing
  maps one-for-one onto the instructed sequence: a press and release, then a
  hold, then a second key added, then that one released, then the first.

## What this does not establish

- **Where the arrow presses became modifier events.** A physical key, a
  remapping, a keyboard layout, or SDL's own backend could each produce this,
  and the trace cannot separate them. It is **not** established that the OS or
  the keyboard is at fault.
- **That this is the same thing the player saw in the game.** The reported
  symptoms were that forward needs two presses and that adding left stops it —
  which means forward *did* move on the second press. Nothing in this trace
  produced forward motion at all, so the trace session and the game session may
  not have exercised the same keys.
- **Nothing about `read_keys`, the builder or the frame path**, all of which
  were measured separately and agree.

## Two observations, neither a conclusion

- `Right Command` arrives with `repeat=1` twice, at 21397 and 21720. A modifier
  key auto-repeating is unusual. The shim ignores repeat events
  (`if (e.key.repeat) continue;`), so it changes nothing here, but it is a hint
  about what is producing these events.
- The macOS side reports one `IMKCFRunLoopWakeUpReliable` mach port error on
  stderr. That message is associated with input-method plumbing in processes
  that are not application bundles, and their UI automation separately refused
  this binary as an "Invalid app" — both consistent with a plain CLI executable
  rather than a bundle. **That is a correlation and a lead, not a cause.**
  Nothing here shows it affecting key delivery.

## What must not be done with this

**The game's key mapping must not be changed on the strength of this log.** One
session, one keyboard, one person, and an unexplained substitution between the
key pressed and the event delivered. Mapping Right Command to forward because it
arrived once would encode an accident.

The next thing worth knowing is whether the arrow keys produce arrow events at
all on that machine — in this program, and in any other. The tracer now prints
the expected `sym`/`scancode` for each arrow at the top of every trace, so a
session that hit the wrong keys is visible from the file alone, and its summary
distinguishes "no events arrived" from "events arrived but none were arrows".
