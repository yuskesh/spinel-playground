# The CORE source tree

The Ruby that decision 0008's three CORE entries are compiled from. It is not
a second copy of the game: each unit here is an extraction from
`examples/doom/lib/doom/`, carried over with its origin, and the Full tree
stays the one place the game is maintained.

A CORE entry is compiled from **one file**. The units here are several, so
`tools/doom/pack-core.rb` makes one out of them:

```sh
ruby tools/doom/pack-core.rb \
  --manifest examples/doom/core/sources.tsv \
  --root examples/doom/core \
  --output build/doom-core/packed.rb \
  --map build/doom-core/map.tsv
```

`sources.tsv` is the manifest and **its order is the packing order**. The map
says which packed lines came from which unit, so a diagnostic against the
packed file can be read back to the source it belongs to.

The three entries are packed from `entries/units.tsv`, **one entry at a time**
(decision 0022 §2.6). Each has a `#width` line there, `int64` or `target`, and
`--entry NAME` packs that entry at that width. An entry at `int64` is packed
at `int64` by its width line, since the units no longer declare it. An entry at
`target` is packed from the units its `#units` line names, or from every unit
without one; a 32-bit body refuses every top-level constant past 32 bits in its
file, closure or not. All three entries are at `target`: `doom_core_input` from
`inputport.rb` and `doomentry.rb`, `doom_core_step` and `doom_core_render` from
every unit. Their results and non-count scalars are `i32` (the owner's
decision in 0022), `viewangle` among them as its signed bit pattern, and
`tools/doom/core-entries.rb` writes them so.

The sources compute at the target's width. C's wrapping arithmetic is the word
intrinsics of decision 0022 (`core_w32_add`, `core_w32_sub`, `core_w32_mul`,
`core_w32_neg`, `core_fixed_mul`, `core_fixed_div`); an angle, unsigned in C,
is held as its signed i32 bit pattern, and where C reads it as unsigned -- a
comparison, a right shift into a table index -- the source uses `core_u32_lt`,
`core_u32_le`, `core_u32_gt`, `core_u32_ge` and `core_u32_shr`. The constant
tables once packed past 32 bits (`ST_RND_*`, `KN_WALK_*`, `SS_USE_*`,
`RL_CHECKCOORD_*`) are 32-bit words. `src/fixed.rb`'s helpers stay for the int64
units the entries do not pack.

## What a unit may contain

Definitions and nothing else. The packer refuses a unit that runs something at
the top level, that loads another file, that carries `__END__`, that is not
UTF-8, or that defines a name another unit already defines — and it refuses a
`.rb` file under this directory that `sources.tsv` does not list, because a
source tree with an unpacked unit in it is a package that quietly lost code.

The names keep a prefix (`fixed_mul`, not `mul`) because a packed file is one
namespace. `Doom::Fixed.mul` and `Doom::Fixed.div` are told apart by their
module; `mul` and `div` alone would not be.

## The resident state

`state.tsv`, `access.tsv` and `prepared.tsv` are **generated** by
`tools/doom/emit-schema.rb` from the audit's state-use inventory, and
`catalog.tsv` is measured from one configuration. Do not edit any of them: a
field that moves in the source moves here, and `tools/doom/audit-core.rb` is
what decides whether the move is allowed.

```sh
ruby tools/doom/audit-core.rb --output build/doom-core
ruby tools/doom/emit-schema.rb --inventory build/doom-core/state-use.tsv \
  --setup-writes build/doom-core/setup-writes.tsv \
  --schema examples/doom/core/state.tsv --access examples/doom/core/access.tsv \
  --prepared examples/doom/core/prepared.tsv --catalog examples/doom/core/catalog.tsv
cat examples/doom/core/catalog.tsv examples/doom/core/prepared.tsv > build/doom-core/catalog.tsv
ruby tools/doom/state-schema.rb --schema examples/doom/core/state.tsv \
  --access examples/doom/core/access.tsv --catalog build/doom-core/catalog.tsv \
  --output build/doom-core/state
```

694 fields: 246 scalars sharing one i64 buffer with generated indices, and 448
arrays each with its own allocation. The snapshot is schema-ordered
little-endian data with no padding, no addresses and no scratch —
29,605,444 bytes for E1M1 at 320x200, which is what `state-schema.rb`
reports on the last line of the run above. The size is a consequence of the
counts and moves as they are corrected: it was 22,220,825 bytes while prepared
arrays were declared one element long, and the 24,526,169 once recorded here
was stale by the time the WAD data and the atlases took their real lengths,
44,984,736 before the executor's banks became aliases of Jobs' banks,
43,796,896 before `hud_text_ofs` (42 i64, where each HUD message starts),
43,797,260 with the entries' added fields (43,797,232 was recorded here, and
stale), and 131,328 bytes more than now until Jobs' span rows were counted
by the view, as the program's Jobs is, rather than by the screen. The
43,665,932 recorded here went stale when decision 0018 narrowed the entries'
buffers; it was 37,997,484 after that, until decision 0021 made the WAD one
buffer (`hud_data` and `status_bar_data` are aliases of `renderer_wad_data`).
Nothing in the suite pins this number, which is how it went stale.

`catalog.tsv` is **E1M1 at 320x200** and every number in it was measured —
the level counts by loading the map, the texture and flat counts through
`Doom::Textures`, the screen products by computing what the renderer computes
at `s = 1`, the limits from the constants the source declares. A different map
or resolution is a different catalog, which is the point of naming counts
rather than fixing them. The IWAD is not in this repository and is not a build
input; this file is the measurement taken from one.

## The width table

`widths.tsv` is **generated** by `tools/doom/core-widths.rb` and records, for
each of the 392 buffers the three entries take, the element type
[decision 0018](../../../docs/decisions/0018-narrow-buffer-elements.md) gives
it and the evidence: `static:` with every store that bounds the field, from
`tools/doom/core-store-widths.rb`, or `observed:` with the demos whose ranges
`tools/doom/core-ranges.rb` read through the compiled entries after each tic,
joined with every value the three entries stored during
`tests/doom-core/verify.sh`'s port runs, recorded by
`tools/doom/core-store-ranges.rb`. The `core_state` slots are not rows; they
stay `i64`. `tools/doom/emit-schema.rb` takes each buffer's element from this
table, so `state.tsv`, the entry contracts and Full's allocation follow it;
`tools/doom/source-elements.rb` keeps the source fixtures' contracts in line.

`widths-repr.tsv` names the buffers whose element is a representation rather
than the smallest type of their range (decision 0022 section 2.4): the four
angle cells, `game_mobj_angle`, `level_seg_angle`, `renderer_xtoviewangle` and
`jobs_span`, are `i32-bits`. Their measured values must fit 32 bits read one way
(all unsigned or all signed), and their element is `i32`, holding the word's
signed pattern; their rows' evidence ends with `;i32-bits:0022-2.4`. Full's
preparation (`Resources.prepared`, `Reference`, the generated `nativeprep.rb`)
writes a word it holds as 0..2**32-1 into such a cell as that pattern, and
`tools/doom/session-image.rb` refuses an i64 cell the entries are handed that
does not fit i32.

`tests/doom-core/widths.sh`, which `tests/doom-core/verify.sh` runs over the
library it builds and the stores its port runs recorded, re-measures the table
and fails on a value outside a row's element. A failing row is not edited: the
lane's output says how to regenerate the table from its measurements.

## The session image

[Decision 0021](../../../docs/decisions/0021-doom-core-on-frdm-imxrt1186.md)
holds a session at open as an image a board can carry.
`tools/doom/session-image.rb` writes it from the playable program's session at
open (the canonical snapshot and catalog that
`tests/doom-core/native/bound.rb` and `native/open.rb` write). It keeps only
what the three entries receive: the buffers named in `entries/fields.tsv`,
`core_state`, and the `derived:` index tables. A schema field no entry receives,
such as `wad_data`, is left out. The image is four files:

| file | contents |
|---|---|
| `resources.bin` | each `resource` buffer in schema order, then the four derived index tables as `i64` slot numbers. Each starts at a multiple of 8. Read in place: from the NOR on the board, through a read-only mapping on the host |
| `writable.bin` | `core_state` first (one `i64` per scalar slot, in schema order), then each persistent and output buffer, each at a multiple of 8. Copied to RAM once |
| `image.tsv` | one row per buffer: `name role element count part offset bytes`. `part` is `resource`, `derived`, `core_state`, `writable` or `scratch`. `offset` is in bytes, within the file that part lives in. A `#parts` line gives each file's size. Scratch has no initial contents, so its offsets are in a separate zeroed region and it is in no file |
| `image.sha256` | the sha256 of the other three, in `sha256sum -c` format |

Bytes are little-endian at each buffer's own element width. For DEMO1's map
(E1M5, 320x200) the measured image is:

- `resources.bin`: 6,141,872 bytes, 201 resources and 4 derived tables;
- `writable.bin`: 2,611,221 bytes, 246 slots and 184 buffers;
- scratch: 48,518 bytes, 7 buffers, in no file.

`tests/doom-core/bound-resources.sh` builds the image and binds every resource
in it read-only. It then requires DEMO1 to play the same frames as over
allocated storage.

## The reference route

`full/session.rb` allocates the declared buffers once and releases each once;
`full/resources.rb` measures the catalog from a WAD and a configuration;
`full/reference.rb` reads every field the schema names out of the objects
`bin/doom.rb` builds. `tests/doom-core/state.sh` runs all three and compares
the two snapshots before the first tick.

Measured on E1M1 at 320x200 (these counts are reported by `state.sh`; the
older numbers once written here were stale):

* The reference reads and encodes all 674 layout fields. (It refused 15 for
  their shape until the audit stopped giving a field another class's
  allocation of the same ivar name, 7 until the random trace was eliminated,
  and 2 until the source aliases became a selector and a base, below.)
* **558 prepared fields** are produced by Full and agree with the original,
  cell for cell. Among them are the stored, mutable fields whose pre-tick value
  Full carries, `initial prepared:NAME` with their role unchanged: 232 the audit
  has no initial for (`UNDERIVED`), and 109 that Full's setup writes after
  allocating them.
* Which fields setup writes is the audit's `setup-writes.tsv`: a walk from the
  calls `bin/doom.rb` makes before its loop, recording every write other than
  the allocation itself. A builtin call is not taken to write nothing: its
  effect comes from `tools/doom/core-builtin-effects.tsv`, and one that changes
  its receiver is attributed to the field that receiver is -- directly, through
  a local, through a parameter, or through what a method returns. Every call
  it cannot account for is listed as a gap. It has none, and `emit-schema.rb`
  refuses a walk that does, or a file that does not end with the walk's
  `#complete` counts. A stored field that
  setup does not write keeps its allocation fill -- 117 of them -- and all 117
  agree with the original. The rule is that static fact, not the comparison.
* Scalars share `core_state`, which Full assembles slot by slot from
  `slots.tsv` (`field`, `index`, `initial`, `origin`) and hands to the session as
  `prepared:core_state`. It used to be one fill of 0, which dropped any scalar's
  own initial.
* No field is held at its fill any longer (`tools/doom/core-initials-held.tsv`
  is empty). The source aliases `@dc_srcbuf` and `@ds_source` are carried as a
  selector and a base (`renderer_dc_srcres/_srcbase`, `renderer_ds_srcres/_srcbase`,
  opening at RES_NONE -1 and 0), converted from the original by Full and by the
  reference separately; see docs/core/doom-source-alias.md.
* 8 fields are **eliminated** as a reference-only trace, 0008's own category:
  `Random`'s `@log_tic`, `@log_before`, `@log_after`, `@log_value`,
  `@log_site`, `@log_n`, `@trace` and `@tic`. Only `bin/sim_demo.rb` turns the
  trace on; the CORE port has none. The audit's inventory still lists them,
  and `tick.sh` runs the original with the trace off and on to show the draws
  and all four counters are the same either way.
* The 12 scratch fields are not in the snapshot. `state.sh` checks that the
  original defines none of their ivars before the first tick, for this
  configuration, and the audit's `scratch-defined.tsv` shows, per read, that
  each is written earlier in the same call -- by an unconditional write before
  the read, or before every self-call into the reading definition.
* The stored lane is then **117 fields**, all of which agree.
* A buffer the render entry writes by HANDING IT to a method that stores into
  it is storage the entry writes: the audit follows a written parameter back to
  the argument at each call (`argument-writes.tsv`, with what it could not
  follow named and failing the run). That is how the direct zone window
  `renderer_zonewin` and the job ring `jobs_zonebuf` -- rewritten every masked
  column through `Wad#zone_window_into` -- are stored fields and `inout` for
  `doom_core_render`, not resources Full prepares.
* The job ring is ONE allocation owned by Jobs. The hosted executor keeps
  that Jobs owner and reads bytes through `Jobs#zone_byte`, rather than
  holding a String snapshot. `tick.sh` checks owner identity and rejects
  a copied owner; the five array banks retain their checked schema aliases.
  Removing the obsolete ring alias changes no allocation, size or CORE ABI.

The walk covers the setup of the compared configuration: no demo playback
(`Demo.new`) and the GPU raster constructed but not opened. Another
configuration's setup calls would need roots of their own.

## Units

| unit | extracted from | what it holds |
| --- | --- | --- |
| `src/fixed.rb` | `examples/doom/lib/doom/fixed.rb` | the 16.16 fixed-point helpers and the binary angle measure |
| `src/thinkers.rb` | `examples/doom/lib/doom/game.rb` | the thinker slot list: take, link, unlink, free and mark-removed, over borrowed buffers |
| `src/bspwalk.rb` | `examples/doom/lib/doom/sight.rb`, `examples/doom/lib/doom/enemy.rb`, `examples/doom/lib/doom/level.rb` | the BSP descent and the sound flood without recursion, and both side predicates -- `dc_sight_side` and `dc_point_on_side`, which are not the same function |
| `src/random.rb` | `examples/doom/lib/doom/random.rb` | `P_Random`, `M_Random` and `M_ClearRandom` over two separate indices and two counters |
| `src/source.rb` | `examples/doom/lib/doom/render.rb`, `examples/doom/lib/doom/executor.rb` | the column and span sources as a selector and a base: producers that set both on every path, and the direct and queued consumers that read only through them (docs/core/doom-source-alias.md) |
| `src/zone.rb` | `examples/doom/lib/doom/wad.rb`, `examples/doom/lib/doom/jobs.rb` | the zone windows: the 128 bytes a masked column reads past the end of its lump, written into the direct window or the job ring, the ring's slot allocator, and `Jobs#reset`'s per-frame counters |
| `src/jobs.rb` | `examples/doom/lib/doom/jobs.rb` | the job banks' pushes -- a wall, span or masked record and its schedule entry, CAPACITY when a bank or the schedule is full -- and the two phase marks; `Jobs#check` is not here |
| `src/checks.rb` | `examples/doom/lib/doom/jobs.rb` | the per-frame interval tables and statistics `Jobs#check` builds after its per-job checks, on the path job mode 2 takes (`strict` false): per-column and per-row job counts, slot tables, overlaps and maxima, CAPACITY when a column's table is full; `Jobs#check` itself and the `strict` raises are not here |
| `src/planespan.rb` | `examples/doom/lib/doom/render.rb`, `examples/doom/lib/doom/texture.rb` | a visplane's span emission: `make_spans` over the column extents, `map_plane`'s per-row cache, distance, steps and light, the packed span source, and the span drawn (job mode 0) or pushed (modes 1 and 2); `draw_planes`, `clear_planes` and the view setup are not here |
| `src/planes.rb` | `examples/doom/lib/doom/render.rb` | the planes' walk -- each visplane's source, height, light, sentinel columns and every column through `make_spans`, and a sky plane's texture columns, drawn (job mode 0) or pushed as wall jobs (modes 1 and 2) -- and `clear_planes`, the frame's clip arrays, plane counters, row cache and base scales through `fixed_div`; the BSP walk that builds the visplanes is not here |
| `src/statusbar.rb` | `examples/doom/lib/doom/statusbar.rb` | the status bar's per-frame drawing: the background refresh, the numbers, the arms, the face and the key boxes, each redrawn only when it changed, over the widget memory and the tables `examples/doom/core/state.tsv` declares; the ticker that decides the face and the key boxes is not here |
| `src/hud.rb` | `examples/doom/lib/doom/hud.rb` | the HUD's message line: the current message's glyphs at the top of the screen, over the joined message bytes and their offsets; the ticker that picks and expires the message is not here |
| `src/leaves.rb` | `examples/doom/lib/doom/render.rb` | seventeen of the renderer's leaf definitions: the angle and distance arithmetic (`point_to_angle` with `slope_div`, `point_to_dist`, `scale_from_global_angle`, `abs_angle`), `light_index`, `clip_value`, `point_on_seg_side`, the visplane lookup and extension (`find_plane`, `check_plane`, `clear_plane_top`), the solid-seg list's `clear_clip_segs` and `crunch`, the BSP walk's `check_bbox`, and the sprites' `add_sprites` with the `project_sprite` it calls, and `sort_vissprites`; their callers are not here |
| `src/segs.rb` | `examples/doom/lib/doom/render.rb` | the walls' seg loop, `render_seg_loop`: the plane marks, the clip arrays, the masked column's openings and each tier's column, set up as `set_texture_column` does and then drawn (job mode 0) or pushed (modes 1 and 2) as `draw_column` does; walls never take `draw_column`'s fuzz path, which is not here, and its caller `store_wall_range` is not here |
| `src/stepcore.rb` | `examples/doom/lib/doom/` (the step entry's files) | the step entry's shared vocabulary -- the `gx` index table of scalar slots, the packed random table, the thinker slots over cells -- and its leaves; written in the port-first pass, compiled through `dc_sp_stepall` and not yet compared with the original |
| `src/executor.rb` | `examples/doom/lib/doom/executor.rb` | the job executor's run: a frame's wall, span and masked (fuzz included) jobs in schedule order, over borrowed banks and the one ring; `Jobs#check`, which the original runs first, is not here |
| `src/stepwork.rb` | `examples/doom/lib/doom/game.rb`, `inter.rb`, `specials.rb`, `enemy.rb`, `mapmove.rb`, `statusbar.rb` | the step entry's ordinary definitions: the ones its other units call and that call nothing recursive |
| `src/stepmap.rb` | `examples/doom/lib/doom/game.rb`, `level.rb`, `mapmove.rb`, `sight.rb`, `specials.rb`, `inter.rb`, `enemy.rb` | the step entry's map walks, pickups and sound: `point_in_subsector` and `point_on_side`, the blockmap and line traversals, the pickup paths and the sound flood |
| `src/stepspec.rb` | `examples/doom/lib/doom/game.rb`, `mapmove.rb`, `sight.rb`, `specials.rb`, `inter.rb`, `enemy.rb` | the step entry's sight checks, spawning and sector specials |
| `src/stepaux.rb` | `examples/doom/lib/doom/enemy.rb`, `mapmove.rb`, `specials.rb`, `pspr.rb` | what the action knot needs besides itself: its constants, its small tables and `#ptr_use_traverse` |
| `src/stepplay.rb` | `examples/doom/lib/doom/game.rb`, `mapmove.rb`, `specials.rb`, `enemy.rb`, `pspr.rb` | the constants of the step entry above the action knot, and the thinker sweep (`Game#free_thinker`) |
| `src/stepknot.rb` | **generated** by `tools/doom/knot-cps.rb` from `knot/`, which is from `examples/doom/lib/doom/enemy.rb`, `pspr.rb`, `mapmove.rb`, `game.rb`, `inter.rb`, `specials.rb` | the 62-member recursive component below `Game#g_ticker`, lowered to a resumable state machine over one work stack; edit `knot/` and re-run the generator, never this file. Its capacity is a declared configuration and every push carries its check (decision 0008's clarification of 2026-09-18) |
| `src/rview.rb` | `examples/doom/lib/doom/render.rb`, `jobs.rb` (`Jobs#check`), `executor.rb` (`JobExecutor#run`), `hires.rb` (`Hires.blit_scale`) | the render entry's spine: the view setup, the BSP walk, the walls, the sprites and the column dispatch |
| `src/rvcopies.rb` | **generated** by `tools/doom/core-copies.rb` from the units above | the definitions `src/rview.rb` reaches, renamed under `dc_rv_`: the kernel admits no call into an entry's closure from outside it, and each original is also reached by another entry |
| `src/rvgpu.rb` | `examples/doom/lib/doom/render.rb` (`Renderer#draw_jobs_cpu`) | the CPU executor's run when the GPU refuses a frame. `bin/doom.rb` reaches it only under `-gpu`, which renders in job mode 4; the native program renders in job mode 0 |
| `src/inputport.rb` | `examples/doom/lib/doom/input.rb`, `record.rb` (`DemoWriter#write_tic`) | the input entry: the key state, the scripted keys, the tic command built from them, and the demo record of that tic |
| `src/doomentry.rb` | **generated** by `tools/doom/core-entries.rb` | decision 0008's three entries -- `doom_core_input`, `doom_core_step`, `doom_core_render` -- each one the body `bin/doom.rb`'s loop runs between its own calls. Each parameter's resident field is in `entries/fields.tsv` and each contract is `entries/NAME.contract` |

`examples/doom/core/full/` is Full's side — the session wrapper, resource
preparation and the reference route — and is deliberately not under the
packing root: none of it is packed into anything CORE compiles.

## What is and is not built here yet

The packed file compiles and runs: measured, the five helpers give
`-1 / -393216 / -3 / -98304 / 4294967295` through the hosted compiler and CRuby
gives the same five.

Individual units DO compile as CORE objects through the kernel tool with an
explicit contract: `tests/doom-core/state.sh` builds the thinker slot list that
way and `tests/doom-core/tick.sh` builds `src/random.rb` that way, each linked
against a C driver and run. What follows is about the other route.

They are **not** yet compilable as CORE objects through
`tools/core/spinel-core-build --core`, and that is expected at this task rather
than a defect. Measured on main c2e4eac8 (after decision 0042), the driver
refuses each of the five helpers in the packed file, and none of them for its
arithmetic any more: every refusal reports `binding-environment`, because the
packed file's top level holds constant assignments where `--core` admits only
definitions and calls into the selected closure. Some add their own reasons
(`fixed_div` reads the `I32_*` constants, `runtime-state`; `fixed_cdiv` has
`nullable-integer` parameters). The driver infers from the hosted source and
has no declaration to work from. Before 0042 it refused four of them
`unproved-arithmetic`, which 0042 stage 2 removed by proving `<<` and `>>`. Decision 0007's stage 1 proved these same
bodies with declarations beside them —
`tests/core-boundary/fixtures/capabilities/src/*.contract` gives each entry its
result and parameter domains, and `tests/core-boundary/capabilities.sh`
measures them against CRuby running the same definitions. Those declarations
arrive with 0008's task 3; this task delivers the packing.

`src/source.rb`, `src/zone.rb`, `src/executor.rb`, `src/jobs.rb`, `src/checks.rb`, `src/planespan.rb`, `src/planes.rb`, `src/statusbar.rb`, `src/hud.rb`, `src/leaves.rb` and `src/segs.rb`, added after that measurement, are not among
the four. They ARE compiled through the kernel tool:
`tests/doom-core/fixtures/source/` declares thirty-nine entries over them (packing `src/fixed.rb` too), and `tests/doom-core/tick.sh` builds them, runs them in
the game and at every buffer's edge (docs/core/doom-source-alias.md). `src/executor.rb`
`src/jobs.rb`, `src/checks.rb`, `src/planespan.rb`, `src/planes.rb`, `src/statusbar.rb`, `src/hud.rb`, `src/leaves.rb` and `src/segs.rb` have not been tried through the driver. Through
the driver, measured, `src/source.rb` is refused for all seven of its
definitions; among the reasons it reports are indexing a buffer
(`heap-operation`), reading the `RES_*` constants (`runtime-state`),
`unproved-arithmetic` and `unsupported-node`.
