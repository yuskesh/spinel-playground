# DOOM on Spinel Extended

Decision [0006](decisions/0006-doom-hosted-import.md). The imported engine and
how to run it: [`../examples/doom/README.md`](../examples/doom/README.md).
Provenance and the import manifest: [provenance.md](provenance.md). The compatibility checkpoint that had
to pass first: [doom/task1-checkpoint.md](doom/task1-checkpoint.md).

Everything measured on this page was measured **on Debian x86_64 on 2026-09-11**
with `spinel cad0ad148af0`, LLVM/Clang 23.1.1 and `ruby 3.3.8`, unless a line
says otherwise. Figures carried in from the predecessor's own records are marked
as historical and were not re-measured here.

**Three of these files are also a test oracle.** `examples/doom/lib/doom/fixed.rb`,
`executor.rb` and `game.rb` are the ORIGINALS that the decision 0007 CORE
extractions under `tests/core-boundary/fixtures/{capabilities,framebuffer,slots}/`
are run against: those lanes load the Full code here unmodified and require the
extracted Ruby and the CORE objects to answer the same. A change to any of the
three must keep `capabilities.sh`, `framebuffer.sh`, `slots.sh` and
`artifacts.sh` green, or be made in the extractions at the same time. What was
extracted from which file is recorded in
[provenance](provenance.md#doom-capability-extractions-2026-09-12).

## What works today

- **The interactive SDL build works and agrees with the headless one.** Built on
  both hosts; `tests/doom/interactive.sh` drives it with a scripted input,
  records a demo, replays that through the headless build and requires the frame
  hashes to match. 350 frames identical on Debian (`offscreen` driver) and on
  macOS (`cocoa`). This scripted comparison is separate from the human control check below.
- **The C reference oracle runs.** `tools/doom/build-reference.sh` builds
  doomgeneric from the tracked patches; `tests/doom/compare.rb` compares the port
  against it and `tests/doom/gate-r007-golden.rb` compares a rebuilt reference
  against the recorded golden. Results and their limits:
  [doom/debian-oracle-observation.md](doom/debian-oracle-observation.md).
- **The DOOM sources are imported.** 46 files under `examples/doom/` and
  `tests/doom/cases/`, GPL-2.0 licence text and notices alongside them, and a
  manifest recording each file's original and local path and digest. Nothing in
  the build or the test suite reads any other checkout.
- **The five IWAD-independent checks run and pass**, against byte-exact recorded
  expectations, compiled by the pinned compiler and cross-checked against the
  reference Ruby. `tests/doom/run.sh`.
- **The runner is proven to reject**, with six negative controls that each
  require the specific diagnostic, not merely a non-zero exit.
  `tests/doom/negative-controls.sh`.
- **The shareware IWAD is fetched with its length and SHA-256 checked before
  publication**, into an untracked directory. `tools/doom/fetch-iwad.sh`.
- **The game itself runs headless on this pin.** DEMO1 replays in full — all
  5026 tics with the renderer on — and a 320×200 frame of E1M1 renders. This was
  measured as a *scratch compatibility probe*, not as product acceptance; see
  the caveat below.

## Acceptance and limits

On 2026-09-11 the owner confirmed movement, turning, firing, door interaction
and Escape exit in the macOS SDL window. After the IJKL mapping was added in
`4124dac`, the owner also confirmed the requested movement and simultaneous
I/J operation. This is human real-window evidence, separate from the scripted
350-frame Cocoa comparison. See [Mac acceptance](doom/mac-acceptance.md).

The C oracle also builds and runs on Debian. Its additional unexplained frame
differences remain failures; the Mac allowances do not accept them. See
[the host-specific observations](doom/debian-oracle-observation.md).

**The import has no sound, and that limits what real-key acceptance can
conclude.** In vanilla, a use press that reaches nothing plays `sfx_noway` —
the "oof" — so a player can tell "this is not a door" from "the door is
broken". Here both are silent, so a correct refusal and a defect are the same
experience: on 2026-09-18 a correct no-op at E1M1's fake-door recess (lines 0,
1 and 2: special 0, one-sided, midtexture DOOR3) was reported as a failure for
exactly that reason, and the diagnosis cost an afternoon. When a control seems
not to work, check what it should have reached before concluding the port is
wrong; silence is not evidence either way.

The hosted executable includes Spinel's runtime and collector. This import is
not a GC-free DOOM port. Audio, menus, saves and level transitions are outside
this import's scope. Historical scratch probes are not substitutes for the
current reference comparisons or the human control check. The original
arrow-key event translation remains unexplained; IJKL provides the requested
working controls without changing that diagnosis.

## Requirements

| | |
|---|---|
| toolchain | LLVM/Clang 23.1.1. `LLVM_PREFIX` defaults to `/opt/llvm-23.1.1`; its `bin/clang` compiles every generated program and every C helper. |
| compiler | the pinned `vendor/spinel`, built in this checkout. Not a sibling checkout, not a system install. |
| reference Ruby | any CRuby the fixtures run under; `ruby 3.3.8` here. `RUBY` overrides it. |
| IWAD | Doom **shareware 1.9**, `doom1.wad`, 4,196,020 bytes, SHA-256 `1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`. Never committed. |
| SHA-256 | one of `sha256sum` (Debian coreutils), `shasum` (macOS, Perl) or `openssl`. `tools/doom/sha256.sh` picks whichever is present and verifies it against a known vector before using it; `SP_SHA256_CMD` forces a choice. Neither Debian nor macOS ships both, so no single command is assumed. |
| SDL2 | required for the interactive build and SDL checks on either host. |

## Commands

Build the pinned compiler, then:

```sh
# the five IWAD-independent checks
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/run.sh

# prove the runner rejects what it should
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/negative-controls.sh

# fetch the IWAD into an untracked directory, digest checked before publication
tools/doom/fetch-iwad.sh
```

Optionally, to re-derive the imported files' original digests from a read-only
predecessor checkout — an audit, never part of the build or the tests:

```sh
DOOM_SRC_GIT=/path/to/spinel-llvm tools/doom/audit-origin.sh
```

Overrides, all explicit, all defaulting inside this checkout or into an owned
temporary directory: `LLVM_PREFIX`, `RUBY`, `BUILD_DIR`, `WORK_DIR`, `WAD`,
`SPINEL`, `CASES`. There is no source-path override: the sources are imported,
and neither the build nor the tests consult any other checkout.

### Playing through the CORE entries (`-core`)

`examples/doom/build.sh` builds the playable program. With `CORE_DIR` it links
decision 0008's three entries and their generated adapter, and the program then
accepts `-core`:

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 CORE_DIR=/path/with/doom_core_*.o \
  examples/doom/build.sh
build/doom/doom -iwad doom1.wad -playdemo DEMO1 -core
```

`CORE_DIR` holds the kernel's `doom_core_input.o`, `doom_core_step.o` and
`doom_core_render.o`, and the adapter's objects under `adapter/obj/`;
`tests/doom-core/harness/artifacts.sh` writes that layout.

With `-core`, the program builds the original objects as it always has, copies
their state into the session, and then runs **every tic only through the
entries**, in job mode 0. The original game and renderer are sealed at that
point: reaching either afterwards refuses by name. Without `CORE_DIR`, the
program links `native/sp_core_stub.c`, `-core` refuses at session open, and
every other path is unchanged.

`-core` is refused together with `-gpu` and with `-res` other than 320x200, and
it records at most 40000 tics. `tests/doom-core/native.sh` is the lane; measured
figures are in [building](building.md).

## Measured results (2026-09-11, Debian x86_64)

```
verify-sources: 46 imported files verified (5 changed on import)
doom-tests: 5 run, 5 pass, 0 fail                       exit 0
negative-controls: 8 run, 8 pass, 0 fail                exit 0
audit-origin: 46 originals re-derived; 41 byte-identical, 5 changed   (audit only)
```

Core non-regression on the unchanged compiler, re-run **after** the import, to
confirm this packaging work did not disturb core:

```
core-eligibility      50 tests   OK      exit 0
native-core/run.sh    18 passed  0 failed exit 0
native-core/driver.sh 43 passed  0 failed exit 0
native-core/ledger.sh 23 passed  0 failed exit 0
```

Scratch compatibility probe, headless, with the renderer on:

| run | result |
|---|---|
| `sim_demo DEMO1 5026` + renderer | exit 0, 8.1 s, 5026 frames, `P_Random` 25013 calls |
| the same under `SPINEL_GC_STRESS=1`, ×3 | exit 0, 23.0–23.3 s, **1,497,093 collections**, output byte-identical to the unstressed run |
| the same built with GCC 14.2.0 instead of Clang | byte-identical output |
| `render_frame E1M1` | exit 0, 33 subsectors / 34 walls / 791 columns, `frame.bin` 64000 bytes = 320×200 |

DEMO1's length of 5026 tics is measured, not assumed: the game's own clamp
reports it, and the WAD directory agrees (lump 20118 bytes, `DEMOMARKER` at
13 + 5026×4 = 20117).

## Reproduced from a clean checkout, with no second repository (2026-09-11)

The commands on this page were run against a **fresh clone** of the branch with
`DOOM_SRC`, `DOOM_SRC_GIT` and `DOOM_MANIFEST` removed from the environment and
no predecessor checkout reachable. Nothing was reused from the working checkout:
the clone built its own `vendor/spinel`.

```
git clone --branch feat/doom-hosted … && git submodule update --init --recursive
make -C vendor/spinel deps                              exit 0
make -C vendor/spinel -j$(nproc)                        exit 0
  spinel cad0ad148af0 (unreleased) [clang version 23.1.1 …]
tests/doom/run.sh                                       5 run, 5 pass, 0 fail   exit 0
  verify-sources: 46 imported files verified (5 changed on import)
tests/doom/negative-controls.sh                         6 run, 6 pass, 0 fail   exit 0
tools/doom/fetch-iwad.sh                                doom1.wad  4196020 bytes  sha256 1d7d43be…cac771
```

In that clone: 46 imported files tracked, `examples/doom/LICENSE` present
(17,984 bytes), 0 `.wad` files, 0 object or archive files, nothing untracked
outside `build/`, and no mention of a predecessor checkout anywhere in
`run.sh`, `negative-controls.sh` or `verify-sources.sh`.

An earlier reproduction passed a predecessor checkout to the runner. That run is
kept in the history but is **not** evidence of a completed import: a build that
reaches into another repository for its sources is not self-contained. This one
is the evidence.

Two things were learned by getting the recipe wrong, and both are worth keeping:

- Omitting `make -C vendor/spinel deps` fails the build on a missing `prism.h`.
  The documented order is not optional, and the reproduction recipe in
  [provenance.md](provenance.md) now states it.
- With no compiler present, five of the six negative controls reported **FAIL**,
  because they exited non-zero without producing the diagnostic that names their
  defect. That is the point of asserting the reason: judged on exit status alone
  they would have read as 6/6 green while testing nothing. `run.sh` likewise
  refuses with `no pinned compiler at … (build it first)` rather than skipping.

## Historical figures, not re-measured here

From the predecessor's own records for this port, carried for context only:

- DEMO1/DEMO2/DEMO3 — 10,996 tics — matching the C reference implementation's
  game logic, with full 320×200 frame agreement over most of the run and DEMO3
  matching completely.
- 35.01 tics/s in an SDL window, 1.663 ms median per tic against a 28.571 ms
  budget, with no allocation in the frame loop.

Neither was reproduced on this host. The Debian side has no C oracle and no GUI,
which is exactly why they are listed here rather than above.

## Inherited missing features

The port is the predecessor's and its scope is unchanged by this import: no
audio, no menus and no level transitions. This import adds no feature and sets
no performance target.

## Known compiler defects on this pin

Two were reproduced and identified during the Task 1 checkpoint. Neither is
fixed here and neither reaches this DOOM path; both are written up with a
reproducer, a control and a proposed minimum diff in
[doom/task1-checkpoint.md](doom/task1-checkpoint.md).

- `$0` / `$PROGRAM_NAME` is allocated on the GC string heap and never marked, so
  a collection while it is live leaves it dangling. No DOOM entry point reads
  `$0`, and none of their generated C contains `sp_program_name`.
- A cross-variant `Hash#merge` passes two freshly allocated, unrooted promotions
  as arguments. No DOOM entry point emits any `_merge` symbol.

One hazard is carried forward rather than closed: `sp_File_puts` is still
`strlen`-sized at this pin. DOOM is unaffected only because nothing it sends to
`print` / `puts` contains a NUL byte — a property of the data, not of the code.
Routing packed bytes through `puts` would truncate them silently.

A third defect is known and was not reduced to a minimal reproducer. It was
measured on 2026-09-18, with the pinned compiler built by clang 23.1.1.

- **The failure.** Calling `bytesize` on the value `Level#load_reject` stores in
  `@reject` compiles and fails at run time with `undefined method 'bytesize'
  for an instance of String`. The value is the REJECT lump, a `byteslice` of
  the WAD. It fails the same way whether it is read through
  `instance_variable_get(:@reject)`, through the class's own `reject` reader,
  or from a local variable. The library has recorded this since E052 §S22
  (`lib/doom/level.rb`, `load_reject`): it measures the slice before storing
  it, and its one other reader (`lib/doom/sight.rb`) uses only `getbyte`.
- **What passes.** A minimal class holding a String ivar, a
  `Wad#bytes_by_name` slice made the same way, and `DemoWriter`'s `@buf` all
  pass. The defect is attached to that value, not to how it is reached, and
  the reason is not known.
- **It spreads.** If one call site passes this value to a method, that
  method's parameter is widened, and every other caller then fails the same
  way on values that pass on their own. In a probe of sixteen field shapes,
  one such value made every byte-string case fail; built one at a time, only
  that case failed.
- **What to do.** Code generated for this compiler should keep each
  byte-string read in its own code, with no shared helper, so that a defect
  like this shows up as one field. Take the length of this value from the
  catalog rather than from `bytesize`, as the library itself does.

No compiler change is proposed. A working path exists.

## Holding two keys at once

A player reported being able to move, turn, fire, open doors and quit on macOS,
but was unsure whether **UP and LEFT can be held together**. The path from a key
to the game has three layers and they fail differently, so
`tests/doom/input-controls.sh` measures them separately rather than as one
verdict:

| layer | what it is | measured |
|---|---|---|
| 1 | a real key press becomes an SDL event | **not testable here** — the OS, the window server and SDL's input backend are in it |
| 2 | an SDL event becomes a bit in the shim's `keydown[256]` | `key-combination-probe.c` pushes synthetic events, pumps as the game does, reads the table back; the shim is linked unmodified |
| 3 | that table becomes a ticcmd | `ticcmd_combination.rb`, compiled by the pinned Spinel |
| end to end | the real game, driven by a script that holds both | the recorded demo's ticcmds are read back |

Measured on Debian, 2026-09-11, with the pinned compiler and Clang 23.1.1:

- **Layer 2, 15 cases, all as expected.** Two keys are held independently;
  releasing one does not clear the other; an auto-repeat event does not disturb
  the table.
- **Layer 3.** `up` alone gives `forward=25, turn=0`; `left` alone `forward=0,
  turn=640`; **`up+left` gives `forward=25, turn=640`** — both at once, the sum
  of the singles. Compiled and CRuby agree exactly. The turn is 320 for the
  first six tics and 640 after: `turnheld` carries across tics and
  `SLOWTURNTICS` is 6, so a probe that built fewer than six tics would report
  the transient as the value. The macOS side measured the same 25 and 320→640
  independently in CRuby.
- **End to end.** A script holding both across tics 70–139 produces a recorded
  demo with **70 tics carrying forward and turn simultaneously**, at exactly
  70–139, and the surrounding tics carry one or the other as scripted. Its
  `aturn` reads 768 rather than 640 because a demo stores the turn as
  `((v + 128) >> 8)` and reads it back `<< 8`: 640 becomes byte 3 and restores
  to 768. `quantize_angle!` does that deliberately so a `.lmp` is exactly what
  the running game did. 640 in memory and 768 in a recording are the same
  measurement on either side of that quantisation, not a disagreement.

### Measuring layer 1: `tools/doom/sdl-input-trace.c`

Layer 1 cannot be measured without a keyboard in front of the window, so the
instrument for it is a separate opt-in program rather than a test. It opens a
window, links the **real shim unmodified**, and writes every key event SDL
delivers beside the shim's `keydown` table after the pump that consumed it:

```sh
clang -O2 $(pkg-config --cflags sdl2) tools/doom/sdl-input-trace.c   examples/doom/native/sp_sdl_shim.c $(pkg-config --libs sdl2) -o sdl-input-trace
./sdl-input-trace --self-test          # prove the instrument records
./sdl-input-trace 20 trace.tsv         # then hold UP and LEFT at the window
```

Columns: `ms event sym scancode name repeat up left note`. What a trace settles,
for the up+left report: whether SDL delivered a KEYDOWN for both at all; whether
it delivered a KEYUP nobody pressed; whether the shim's table held both under
**real** input rather than under events this project generated; and how far
apart events arrived.

`--self-test` exists because an empty trace has two causes that look identical —
nothing arrived, or the program does not record. On a keyboardless host the
first is expected, and the second has to be ruled out for the empty file to mean
anything. It earned its place immediately: the first version peeked at the queue
and let the shim's pump consume, which loses events because that pump drains the
whole queue in one call. The self test recorded **none** of two pushed events.
The tracer now uses `SDL_AddEventWatch`, which sees every event as it is queued
and removes nothing, so the shim still consumes exactly what it would have.

On this host the self test passes and a 2-second trace records zero events,
which is the correct answer where there is no keyboard.

### The keys were changed to i / j / k / l

Requested by the owner after the trace below. `i` forward, `j` left, `k` back,
`l` right — **and the arrow keys still do the same thing**, because removing a
binding that works elsewhere to fix one that does not would trade one broken
machine for every other. Fire, use, Escape, the weapon digits and the strafe
keys are untouched.

This is a four-line change in `examples/doom/native/sp_sdl_shim.c`, which is an
imported file: the manifest records it as `modified=yes` with both digests and
`examples/doom/NOTICE.md` states what changed and why. The four letters return
the same DOOM codes as the arrows, so nothing below the shim is affected —
`G_BuildTiccmd` reads `gamekeydown[0xad]` and cannot tell which physical key set
it. They had been falling through to the letter arm and returning their own
ASCII codes, which no watched key uses, so no binding was lost.

`key-combination-probe.c` covers them: `i`+`j` held together, either side
released alone, `k`+`l` reaching DOWN and RIGHT, and — the case that matters for
calling the arrows aliases — an arrow and a letter setting and clearing the same
code. 26 cases, all as expected. A shim that had *replaced* the arrows would
pass every other case and fail that one.

**This does not explain the substitution the trace found.** It gives the player
keys that work while that stays open.

### The reported symptom, and what it rules in

The person's words: **forward needs the up key pressed twice, and pressing left
while moving forward stops the forward motion.**

Read against the code, that is not what layers 2 and 3 do. `TiccmdBuilder#build`
adds `forward` from `keydown[UP]` and `turn` from `keydown[LEFT]` in separate
statements with no path between them, so `LEFT` cannot zero `forward` there.
`read_keys` clears its `KeyState` and re-reads **the shim's current table** every
tic rather than accumulating events, so a held key cannot be lost between tics.
The shim sets `keydown[c]` only for the code in the event it is handling.

So if `forward` really stops when `LEFT` goes down, `keydown[UP]` was already 0
by then — and the question is what cleared it, or whether the `KEYDOWN` for UP
ever arrived. "Needs two presses" has the same shape: the first press producing
nothing is what an **unfocused window** looks like from the outside, since a
window without keyboard focus receives no key events at all.

That is a hypothesis and the trace is what would settle it, which is why the
tracer records `windowID` and every `FOCUS_GAINED` / `FOCUS_LOST`. It is **not**
a conclusion, and "the OS is at fault" is not a statement this project has
earned.

**One honest gap in my own coverage:** `read_keys` is the layer between the
shim's table and the `KeyState` the builder is given, and it is the one thing
here I have reasoned about rather than measured. The end-to-end script test
drives `script.apply` instead, so `read_keys` has no test. Its body is a clear
followed by a re-read of `WATCHED_KEYS`, which does contain `UP` and `LEFT`.

So layers 2, 3 and the game between them do support the combination. **This does
not diagnose the macOS report.** If a real window still misbehaves, that locates
the question in layer 1 — which is a place to look, not an answer, and nothing
here says the OS or the keyboard is at fault.

Per-tic timing from the same run, for the separate responsiveness concern:
`n=210, mean 1.077 ms, p50 1.096, p90 1.155, max 2.388` against a 28.571 ms
budget — the engine's own work is about 4% of a tic here. That is this host with
no window server, and says nothing about presentation cost on a real display.
