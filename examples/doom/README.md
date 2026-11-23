# DOOM, compiled by Spinel

A Ruby implementation of the DOOM engine, compiled ahead of time by the pinned
Spinel compiler. Licence and origin: [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md). Project-level documentation, measured results and the
current limits: [`../../docs/doom.md`](../../docs/doom.md).

## What is here

```
lib/doom/     33 files — the engine: WAD reading, BSP, rendering, game logic
bin/          3 entry points
```

| entry point | what it does |
|---|---|
| `bin/doom.rb` | the interactive game. Needs SDL2. Built on Debian and macOS; real-key operation was confirmed by the owner on macOS. |
| `bin/sim_demo.rb` | replays a demo lump headless and writes per-tic state, and optionally frame hashes. |
| `bin/record_demo.rb` | records a demo lump. |

The tests that run against this library live in
[`../../tests/doom/`](../../tests/doom/), because the acceptance runner belongs
with the other suites. They are part of the same import and share this notice.

## Running the checks

These are the checks that currently pass, and the only DOOM commands this
repository claims. Build the pinned compiler first — see
[`../../docs/building.md`](../../docs/building.md):

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/run.sh
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/negative-controls.sh
```

They need nothing but this checkout. The five cases are IWAD-independent: none
of them reads a WAD file.

## Running the game headless

`sim_demo` needs an IWAD, which is never committed. Fetch one first — the script
checks its length and SHA-256 before publishing it:

```sh
tools/doom/fetch-iwad.sh
vendor/spinel/bin/spinel examples/doom/bin/sim_demo.rb \
  --cc=/opt/llvm-23.1.1/bin/clang -o build/sim_demo
build/sim_demo build/doom-wad/doom1.wad DEMO1 5026 build/out rand,player,mobj,frame
```

`DEMO1` is 5026 tics; the program clamps to the demo's real length, so asking
for more is safe. The last argument selects what to write: `rand`, `player`,
`mobj` and `frame`, comma-separated. `frame` runs the renderer and is about ten
times slower than the rest.

**This is not an accepted check.** It runs, and its output is deterministic
across repeat runs, two C toolchains and `SPINEL_GC_STRESS=1` — but there is no
reference oracle on Debian to compare frames against, so correctness is not
established here. The C-oracle comparison is macOS-owned. See
[`../../docs/doom.md`](../../docs/doom.md) for what is and is not established.

## Controls

| | |
|---|---|
| move / turn | **`i` forward, `j` left, `k` back, `l` right** — and the arrow keys, which do the same thing |
| fire | right control |
| use / open doors | space |
| run | right shift |
| strafe | right alt; `,` and `.` strafe directly |
| weapons | `1`–`8` |
| quit | Escape |

`i`/`j`/`k`/`l` were added for decision 0006 task 4 because on the macOS machine
this was tested on, arrow presses arrived at SDL as Right Command and Left
Option. That substitution is **not explained** — see
[`../../docs/doom/real-input-trace.md`](../../docs/doom/real-input-trace.md) —
and the arrows are kept working rather than replaced, so a machine where they
arrive correctly is unaffected.

## Not supported

No audio, no menus, no level transitions. These are absent from the port as
imported; nothing here removed them and nothing here adds them. No performance
target is claimed.
