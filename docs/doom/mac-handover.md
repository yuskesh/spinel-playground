# Running the DOOM oracle on macOS — exact commands

Everything below is in the branch `feat/doom-hosted` at commit **`4fb5a02`**.
Nothing here needs the predecessor checkout.

## 1. Build the reference

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 tools/doom/build-reference.sh
```

| variable | default | notes |
|---|---|---|
| `LLVM_PREFIX` | — | `$LLVM_PREFIX/bin/clang` becomes the reference's compiler. Set but missing `bin/clang` is a **refusal**, not a fallback. |
| `CC` | from `LLVM_PREFIX`, else `cc` | overrides `LLVM_PREFIX`. With neither set the script warns loudly that no toolchain was selected. |
| `BUILD_DIR` | `<root>/build/doom-reference` | the clone and every build output live here, outside the repository |
| `DG_REPO` | `https://github.com/ozkl/doomgeneric` | |
| `DG_SHA` | `dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284` | |
| `MAKE_JOBS` | `4` | |

**A version of this script before `cd3d1cb` read neither `CC` nor
`LLVM_PREFIX`.** It took `Makefile.headless`'s own `CC?=cc`, so
`LLVM_PREFIX=… build-reference.sh` built with the system compiler while looking
as though it had selected one. The macOS side caught that on `361721b`; their
own build was correct because they passed an absolute `CC`. It is fixed, and the
compiler is now announced before the build and written to
`$BUILD_DIR/reference-provenance.txt` beside the binary:

```
cc=/opt/llvm-23.1.1/bin/clang
cc_version=clang version 23.1.1 (…)
cc_selected_by=derived from LLVM_PREFIX=/opt/llvm-23.1.1
doomgeneric_sha=dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284
patches_verified=6
host=Linux x86_64
```

Two builds of this source have been measured to differ in two frames of DEMO1,
so a run whose compiler is unrecorded cannot be compared with one whose is.

It verifies all six tracked patches against `tests/doom/reference/manifest.tsv`
in both directions before cloning, applies them in order, and builds. Output:
`$BUILD_DIR/doomgeneric/doomgeneric/doomgeneric_headless`; the build log is
`$BUILD_DIR/build.log`.

It refuses to touch a non-empty `$BUILD_DIR/doomgeneric` it did not create
itself. If you have an existing clone there, point `BUILD_DIR` elsewhere.

## 2. Get the IWAD

```sh
tools/doom/fetch-iwad.sh          # -> build/doom-wad/doom1.wad, digest checked
```

## 3. Run the reference

**The two dump streams must go to different paths.** The R007 harness writes
`$DG_HASH_OUT` (default `frames.tsv` in the working directory) and the E052 hook
writes `$DG_E052_DIR/frames.tsv`. Pointed at the same file they interleave
4-column and 5-column rows into one stream — that happened here, and the
comparator caught it as `row 0 has 6 fields, the header declares 5`.

```sh
BIN=build/doom-reference/doomgeneric/doomgeneric/doomgeneric_headless
mkdir -p build/ref/e052 build/ref/r007
( cd build/ref \
  && DG_HASH_OUT="$PWD/r007/frames.tsv" \
     DG_E052_DIR="$PWD/e052" \
     DG_E052_MAX_TIC=5026 \
     DG_E052_WHAT=rand,player,mobj,frame \
     "$OLDPWD/$BIN" -iwad "$OLDPWD/build/doom-wad/doom1.wad" -timedemo demo1 )
```

Outputs: `build/ref/e052/{rand,player,mobjs,frames}.tsv` and
`build/ref/r007/frames.tsv`.

**On exit 255 — an earlier version of this page was wrong about it.** I wrote
that 255 is the dump hook stopping at `DG_E052_MAX_TIC`. It is not: the macOS
side traced it to `g_game.c:G_CheckDemoStatus`, which calls `I_Error` when the
demo ends, and `i_system.c` then does `exit(-1)`. So 255 means the reference
reached the end of the demo — and **a 255 must not be read as success in
general**, because `I_Error` is also how the reference reports a real error.

The evidence that the run completed is the stderr line

```
timed 5026 gametics …
```

with the count matching the demo's length. Check that, not the status.

Demo lengths, measured from the WAD directory: **DEMO1 5026**, **DEMO2 3836**,
**DEMO3 2134** tics. For DEMO2/DEMO3 substitute `demo2` / `demo3` and the
matching `DG_E052_MAX_TIC`.

## 4. Run the port

```sh
vendor/spinel/bin/spinel examples/doom/bin/sim_demo.rb \
  --cc=/opt/llvm-23.1.1/bin/clang -o build/sim_demo
mkdir -p build/port
build/sim_demo build/doom-wad/doom1.wad DEMO1 5026 build/port rand,player,mobj,frame
```

`sim_demo` clamps to the demo's real length, so a larger tic count is safe.

## 5. Compare — two separate gates

```sh
# the port against the reference (E052 five-column layout, correct FNV basis)
ruby tests/doom/compare.rb \
  --reference build/ref/e052 --candidate build/port --ntics 5026 --report-all

# G0: the rebuilt reference against the recorded golden
#     (R007 four-column layout, nonstandard FNV basis)
ruby tests/doom/gate-r007-golden.rb --built build/ref/r007/frames.tsv --report-all
```

**Do not cross them.** Both files have a column named `fnv1a64` at index 2 and
they are different hash functions: the R007 harness uses the offset basis
`1469598103934665603`, one digit short, and the E052 hook uses the correct
`14695981039346656037`. `gate-r007-golden.rb` refuses the five-column layout on
the header for this reason.

`--report-all` lists every divergence in allowance-file format. It writes no
file and does not change the exit status.

## What this host measured, for comparison

Debian x86_64, `cc (Debian 14.2.0-19) 14.2.0`, no CommonCrypto (so the reference's
`sha256` column is `-` here and is reported as not compared).

| | |
|---|---|
| `rand` | 25013 P_Random calls identical, call sites checked |
| `player` | 5026 rows identical |
| `mobjs` | 1099388 rows identical |
| `frames` / `frames200` | 5021 / 5024 identical; **diverge at gametics 2046, 4480, 4486** |
| G0 | 5065 frames, ids identical; **diverge at frames 4518 and 4524 = gametics 4480 and 4486** |

G0 says 4480 and 4486 are where the two *reference builds* disagree with each
other. 2046 is not.

**A prediction, written before your measurement so it can be wrong:** a macOS
E052 comparison will show the port diverging at **2046** and agreeing at 4480
and 4486. If it shows anything else, the reasoning in
[debian-oracle-observation.md](debian-oracle-observation.md) is incomplete and
that is the interesting part.

The allowance files are still unwritten, but the reason has changed: the
selected toolchain **has** produced its list — DEMO1 2046 and 4486, DEMO2 631,
2325 and 2925, DEMO3 none — and those are exactly the tics the predecessor's
E053 and E054 records attribute to the reference reading its own zone
allocator's pointers and allocation history. What is missing is the **values**,
which this host cannot supply honestly because its reference disagrees with the
selected one at 4486.

So the one thing still needed from macOS is the `--report-all` output for DEMO1
and DEMO2:

```sh
ruby tests/doom/compare.rb --reference build/ref/e052 --candidate build/port \
  --ntics 5026 --report-all        # four lines expected: 2046 and 4486, two streams each
ruby tests/doom/compare.rb --reference <demo2 ref> --candidate <demo2 port> \
  --ntics 3836 --report-all        # six lines: 631, 2325, 2925, two streams each
```

Those lines are already in allowance format. With them the files are a
transcription rather than a judgement. Neither gate has a path that writes one.

See [frame-divergence-baseline.md](frame-divergence-baseline.md) for the
correspondence between the historical cause records and the 2026-09
measurements, and for why this host's extra tics (DEMO1 4480, DEMO2 3604) are
held rather than declared.

## The suites, for a clean-checkout check

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/run.sh                  # 5/5
LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/negative-controls.sh    # 8/8
RUBY=ruby tests/doom/gate-r007-controls.sh                               # 8/8
RUBY=ruby tests/doom/compare-controls.sh build/port 5026                 # 23/23
```

## The interactive build and the scripted comparison

```sh
LLVM_PREFIX=/opt/llvm-23.1.1 examples/doom/build.sh
WAD="$PWD/build/doom-wad/doom1.wad" LLVM_PREFIX=/opt/llvm-23.1.1 tests/doom/interactive.sh
```

`build.sh` finds SDL2 through pkg-config, or takes `SDL2_CFLAGS` and
`SDL2_LIBS`. It probes for `libcrypt` rather than naming it: it is a separate
library on glibc and part of libSystem on macOS, and naming it unconditionally
is what produced `ld: library crypt not found` there. `OUT` must be a file path,
not a directory, and staging is a `mktemp -d` beside `OUT` so concurrent builds
do not delete each other and publishing is a rename on one filesystem.

`interactive.sh` decides SKIP from an **availability probe** —
`tests/doom/native/sdl-probe.c`, which calls `SDL_Init(SDL_INIT_VIDEO)` and
nothing else — not from a failing game run. Once the probe succeeds, every later
failure is a FAIL. The video driver is never guessed: SDL chooses unless
`SDL_VIDEODRIVER` is set, and setting it to `dummy` is an explicit request for a
headless comparison, which the run labels as **not** a real-window check.

Measured here (Debian, no window server, SDL chose `offscreen`):
`350 frames identical between the SDL and headless paths`, and the same with
`SDL_VIDEODRIVER=dummy`.

**The real-window check is not replaced by any of this.** A script fills the
same `gamekeydown[]` array SDL fills, so everything downstream of the key table
is exercised and nothing upstream of it.

### Controls for these two

```sh
tests/doom/interactive-controls.sh      # 7/7: frame-stream rules, and OUT refusals
```

Including the one that mattered: **both streams truncated the same way** used to
pass, because the files were equal and almost nothing had been compared. Both
must now carry exactly the requested tics, keyed `0..TICS-1`.

## The real-window check: confirmed by the owner

On 2026-09-11 the owner confirmed movement, turning, firing, door interaction
and Escape exit. The owner then confirmed IJKL movement and simultaneous I/J
operation with the Mac build of `4124dac`. The earlier automation limitation
was resolved for acceptance by human operation, not by treating scripted
input or screenshots as real-key evidence. See [Mac acceptance](mac-acceptance.md).

`tests/doom/interactive-controls.sh` needs no SDL, no WAD, no compiler and no
`SPINEL`; it runs with `/usr/bin:/bin` on PATH and nothing else set. Case 7 once
reached for `/opt/llvm-23.1.1` and so failed on macOS for the wrong reason —
`build.sh` now answers the question about its arguments before consulting any
dependency, and the control asserts that refusal is the *first* thing it says.
