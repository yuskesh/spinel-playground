# Notices for `examples/doom/`

These files are GPL-derived and are redistributed here under the GNU General
Public License, version 2, whose text is in [LICENSE](LICENSE) beside this file.

Everything below is recorded from the sources themselves or from this
repository's own records. **No authorship, copyright holder or licence beyond
what the sources state is asserted or inferred here.** Where the imported files
carry a statement, it is quoted; where they do not, that absence is recorded as
an absence rather than filled in.

## Where these files came from

| | |
|---|---|
| source repository | `spinel-llvm`, the predecessor project |
| source revision | `f8ad13c6d9dc990b116ba1c842c7881232f29585` |
| original paths | `doom/lib/doom/*.rb`, `doom/bin/{doom,sim_demo,record_demo}.rb` |
| how obtained | read from Git objects with `git show`; that checkout was not modified |

Per-file original paths, original byte lengths and original SHA-256 digests are
recorded in [`../../tests/doom/manifest.tsv`](../../tests/doom/manifest.tsv),
alongside the local path and the local digest of each file, so a file that was
changed on import is distinguishable from one that was not.

**None of the 43 imported files in this directory is byte-identical to its
original any more.** On 2026-11-23 the Japanese comments in all 43 were
translated into English. That change touched comments only: each Ruby file
keeps its code tokens, and every file keeps its line count. Two statements of derivation stay in Japanese, in
`lib/doom/tables.rb` and `lib/doom/info.rb` (quoted under "What the sources
state about their own origin" below). Before that translation, 36 of the 43 were
byte-identical. The seven that also have changes in their code are
`bin/doom.rb`, `native/sp_sdl_shim.c` and, under `lib/doom/`, `render.rb`,
`statusbar.rb`, `render_gpu.rb`, `executor.rb` and `jobs.rb`, below; the
manifest records every changed file as `modified=yes` with both digests.

`lib/doom/render.rb` (originally `doom/lib/doom/render.rb`) **is changed**,
deliberately and after import, twice: 92989 bytes to 93890. The first change
(2026-09-23) is one read in `render_seg_loop`. When `rw_centerangle + xtoviewangle[x]` is exactly ANG180,
`angle` is 4096, one past `finetangent`'s last entry. Vanilla's
`R_RenderSegLoop` makes the same read in C and gets the next table in memory,
`finesine[0]`, so that is what it now reads there. The original read past the
table: `nil` in Ruby, and `NoMethodError` at the multiply that follows. That
stopped DEMO1 at tic 321 at `-res 960x600` and above
(`tools/raster/README.md`, "Fixed defect"). The table is not extended, because
the CORE render entry takes it as a buffer of exactly 4096. The CORE extraction
carries the same guard (`core/src/segs.rb`, and its copy in `rvcopies.rb`). The second, 888a00f
(2026-10-18), binds `@screen` to a local once in `clear_screen`, and passes
`draw_column` a flag to read the zone window `@zonewin` directly instead of
storing the window in the `@dc_srcbuf` slot. After the upstream pin update the
compiler's default String mode can snapshot a String stored in a second slot,
and this change avoids publishing one (`docs/provenance.md`).

`lib/doom/statusbar.rb` (originally `doom/lib/doom/statusbar.rb`) **is
changed** in the same commit, 888a00f: 20086 bytes to 20110.
`refresh_background` binds `@backing` to a local once before clearing it, for
the same reason.

`lib/doom/render_gpu.rb` (originally `doom/lib/doom/render_gpu.rb`) **is
changed**, d2f91c4 (2026-10-18): 8911 bytes to 8416. `sp_rg_frame` now declares
the zone ring and the screen `str_inout`, which borrows their storage and
republishes the String caches after the native call. The
`scr.setbyte(0, scr.getbyte(0))` that followed the call did that by hand and is
removed, and three comments are rewritten to match. The WAD stays read-only
`str`.

`lib/doom/executor.rb` and `lib/doom/jobs.rb` (originally under
`doom/lib/doom/`) **are changed**, 0dfc2f7 (2026-10-18): 12134 bytes to 12250
and 57015 to 57156. `JobExecutor` keeps its `Jobs` owner instead of storing
`jobs.zonebuf` at construction, and reads ring bytes through the new
`Jobs#zone_byte`. The updated compiler snapshots the ring when `JobExecutor`
stores it, so the masked-column jobs read the empty construction-time ring.

`bin/doom.rb` (originally `doom/bin/doom.rb`) **is changed**, deliberately and
after import: 120 lines added and none removed, 16686 bytes to 21980. The
addition is the `-core` option of decision 0008 — its usage text, six
`require_relative` lines for `lib/doom/specials`, `lib/doom/tables` and the four
files under `core/full/`, the argument arm that accepts `-core` and refuses it
with `-gpu` or a `-res` other than 320x200, and the two methods `core_play` and
`core_loop`, which run Full's preparation once and then every tic through the
three CORE entries only. Nothing of the original is edited or deleted, so without
`-core` the program takes the path it took when it was imported.

`native/sp_sdl_shim.c` (originally `doom/tools/sp_sdl_shim.c`), the SDL2
interface `lib/doom/video.rb` declares, **is changed** — the manifest records it
as `modified=yes` with both digests. The change is four `case` labels in
`doomkey()`:

```c
case SDLK_i:  return 0xad;   /* KEY_UPARROW    */
case SDLK_j:  return 0xac;   /* KEY_LEFTARROW  */
case SDLK_k:  return 0xaf;   /* KEY_DOWNARROW  */
case SDLK_l:  return 0xae;   /* KEY_RIGHTARROW */
```

Requested by the owner for decision 0006 task 4, after a real-key trace on
macOS showed arrow presses arriving as Right Command and Left Option. **Why they
arrived that way is not identified**, and this change does not decide it; it
gives the player keys that work while that question stands open.

The arrow cases are **kept as aliases**, not replaced. Both the arrow and the
letter set the same DOOM code, so nothing below the shim sees the difference —
`G_BuildTiccmd` reads `gamekeydown[0xad]` and has no idea which physical key set
it. `i`/`j`/`k`/`l` previously fell through to the letter arm and returned their
own ASCII codes, which no watched key uses, so no binding was lost.

Fire, use, Escape, the weapon digits and the strafe keys are untouched.

The other changed files on import are the five test programs under
`tests/doom/cases/`, and only their `require_relative` prefixes; see the notice
there.

`native/sp_rg_stub.c` is **not imported**. It is written here, and the manifest
records it as `kind=local` with no original. It provides the nine `sp_rg_*`
symbols `lib/doom/render_gpu.rb` declares, as a no-device stub — no IREE, no GPU
kernels, no MLIR. The predecessor's GPU shim was written against an IREE
experiment that is not imported, and its diagnostics named a build recipe that
does not exist here.

`bin/frame_ppm.rb` is **not imported** either; it is written here and recorded
as `kind=local`. It writes one frame that `bin/sim_demo.rb` dumped (an 8-bit
screen) as a PPM through `lib/doom/ppm.rb`, as `bin/dump_ppm.rb` does for WAD
pictures.

## What the sources state about their own origin

The predecessor's `doom/` tree contains **no `LICENSE` and no `COPYING` file**.
It carries `doom/README.md` and `doom/reference/README.md`, which are
documentation rather than licence notices. There was therefore no upstream
licence file to carry over, and the `LICENSE` beside this notice was added on
import rather than preserved from the source tree.

Two imported files carry a statement in their own header about where their
contents come from. Both are preserved verbatim in the files themselves, and
both are quoted here because they are the most direct statements of derivation
available:

- `lib/doom/info.rb` — "`tools/gen_info.py` が参照実装の `info.c`
  (id Software, GPL-2.0-or-later) を**コンパイルした `info.o`** から機械的に書き出す"
  — the three tables in it are emitted mechanically from the compiled object of
  id Software's `info.c`, stated there as GPL-2.0-or-later. The same header
  records that no code is carried over, only the tables.
- `lib/doom/tables.rb` — "`tools/gen_tables.py` が参照実装の `tables.c`
  (id Software, GPL-2.0-or-later) から機械的に書き出す" — the trigonometric
  tables are emitted mechanically from id Software's `tables.c`, stated there as
  GPL-2.0-or-later, because the values cannot be reproduced from a
  double-precision formula.

`lib/doom/render.rb` names the reference implementation's source files
(`r_main.c`, `r_bsp.c`, `r_segs.c`, `r_plane.c`, `r_things.c`) as what it
reproduces, without a licence statement of its own.

The remaining files carry no licence or copyright header. That is recorded here
as an observation about the sources; it is not a claim about their status.

## What the port is

A Ruby reimplementation of the DOOM engine, written against a specification
survey of the DOOM source release and of
[ozkl/doomgeneric](https://github.com/ozkl/doomgeneric), a Chocolate Doom
derivative. Behaviour is pinned to doomgeneric at
`dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`.

Two qualifications on that description, both from the sources:

- `info.rb` and `tables.rb` are **not** reimplementations. They are data emitted
  mechanically from id Software's GPL C sources, as their own headers state.
- No C source from the DOOM release or from doomgeneric is copied into this
  directory, and none is tracked anywhere in this repository.

## What is not here

No IWAD. Game data is never committed; `tools/doom/fetch-iwad.sh` fetches the
Doom shareware IWAD into an untracked directory with its length and SHA-256
checked before publication. No reference C source, no build output, no
experiment archive from the predecessor.

## Scope of this notice

This notice covers `examples/doom/` and the fixture copies in `tests/doom/cases/`.
It does not cover the doomgeneric patches that decision 0006's task 3 would
import: those are modifications of GPL C source rather than a reimplementation,
they are not present in this repository, and they need their own notice when and
if they arrive.
