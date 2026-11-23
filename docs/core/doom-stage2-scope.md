# DOOM Stage 2 scope

**Status: proposed.** This records what decision 0008's task 1 measured. It is
the input to the tasks that follow, not a claim that any of it is implemented.

Everything below is produced by `tools/doom/audit-core.rb`, which reads three
faces of the pinned contract reader over one frozen copy of the source. Run it
with:

```sh
ruby tools/doom/audit-core.rb --output DIR
sh tests/doom-core/audit.sh
```

The audit exits non-zero while anything is unresolved, unclassified or
unanchored, so the numbers here are not a snapshot that can drift away from the
code: if they stop being true, the audit fails.

## What was measured

| | |
| --- | --- |
| files the reader opened from `examples/doom/bin/doom.rb` | 36 |
| definitions | 1670 |
| call sites | 19650 |
| roots | 22 |
| definitions reached | 372 |
| ambiguous call sites | 0 |
| unresolved call sites | 0 |
| recursive components | 4 |
| instance variables the closure touches | 713 |
| configurations | 20 |

Since 2026-09-18, `bin/doom.rb -core` reaches Full's side of decision 0008's
route: `examples/doom/core/full/nativeprep.rb` and its session, catalog and
loop. That added 4 files, 597 definitions and 4586 call sites, which were 32,
1072 and 15046 before, and the configuration `-core`. It left the roots, the
definitions reached (371), the recursive components and the instance variables
unchanged. Those files hold no CORE definition; they read the original objects
before the first tic and call the entries after it.

## The three entries

0008 fixes three CORE entries. The roots are read off the per-tic loop in
`examples/doom/bin/doom.rb`, not chosen: every call in that loop body is either
a root here or named below as Full's.

| entry | roots | definitions reached |
| --- | --- | --- |
| `doom_core_input` | `TiccmdBuilder#build`, `TiccmdBuilder#quantize_angle!`, `KeyScript#apply`, `DemoWriter#write_tic` | 6 |
| `doom_core_step` | `Random#tic=`, `Random#m_random`, `Game#g_ticker`, `Game#run_thinkers`, `Game#dispatch_psp_action`, `Game#point_to_angle2`, `Game#take_message`, `StatusBar#ticker`, `Hud#ticker` | 240 |
| `doom_core_render` | `Renderer#clear_screen`, `Renderer#set_psprite`, `Renderer#set_psprite_flash`, `Renderer#extralight=`, `Renderer#render_player_view`, `Renderer#draw_jobs_cpu`, `StatusBar#draw`, `Hud#draw`, `Hires#blit_scale` | 150 |

24 definitions are reached by more than one entry.

The status bar and the HUD are in both: `ticker` advances them with the tic and
`draw` composes them into the frame. 0008 requires the render entry to close
over all CPU drawing including those two, and it does.

### What stays in Full, and why

- `video.pump`, `read_keys` and `video.present` go through
  `lib/doom/video.rb`, the only file in the example that touches SDL.
- `video.elapsed_us` and `video.delay_ms` read the clock. By the example's own
  convention nothing under `lib/doom/` reads a clock, which is what makes the
  simulation deterministic.
- The frame-hash and stats writes are instrumentation over a finished frame.
- All allocation. Every resident buffer is Full's, per 0007.

## Storage

The role of each instance variable is derived from where its accesses are, so
it cannot drift: read-only in the closure is `resource`, written and read is
`persistent` if anything outside the closure touches it and `scratch` if not,
written and not read is `output`.

| role | count |
| --- | --- |
| persistent | 367 |
| resource | 235 |
| output | 99 |
| scratch | 12 |

Two corrections are in those numbers, and both were found by a check rather
than by reading. **An element store is a write.** `@mobj_x[i] = v` READS the
ivar and writes through `[]=`, so counting only `InstanceVariableWriteNode`
made every array in the game look read-only — it classified the simulation's
own storage as something Full prepares. **Storage reached through an accessor
is still storage.** `lv.sector_floorheight` reads Level's geometry inside the
accessor `attr_reader` generated, a definition with no body that the walk never
enters, so all of Level's geometry and Lump's three fields were missing from
the inventory entirely. 0008 says no field may disappear through an unlisted
accessor; these were 63 that had, and their element stores are writes too: `lv.sector_floorheight[i] = h` in `move_plane` is a moving floor changing the level, not a read of it.

The second correction also produced a real contradiction, which is the sort of
thing these checks exist for: `Textures` was declared Full's, and
`Textures#animate` — reached from `Game#update_specials` in the tick — writes
`@texturetranslation` and `@flattranslation` every tic. It is declared
`shared` now, with that as the reason — and so is `Level`, because a moving
floor or ceiling writes the sector's height, pic and light every tic while
the render entry reads them.

Ownership is declared per class in `tools/doom/core-state.tsv`, which the audit
cannot derive and the Stage 2 schema needs. A class whose storage the closure
touches with no row there fails the audit, and storage the closure writes
cannot be declared Full's.

Each variable also carries a **disposition** — 0008 requires every reachable
ivar to be a stored field, an immutable prepared value, an eliminated
reference-only trace field, or a Full-only value with a reason. Most of that is
derived from the reader's own type for the storage; the 47 it types `poly`
(41) or `poly_array` (6) are the ones a person had to decide, and they are
decided one at a time in `tools/doom/core-fields.tsv`. A `poly` field with no
row there fails the audit rather than defaulting.

| disposition | variables |
| --- | --- |
| stored | 475 |
| prepared | 216 |
| full-only | 14 |
| eliminated | 8 |

This table last changed in 44d774a; 704573e moved the audit's own count to
eight eliminated the next day without touching it, and until this table had
rows in `tests/doom-core/audit.sh` nothing tied the two.

The ROLE decides between the first two for a numeric field: one the closure
only ever reads is not storage CORE keeps, it is a value Full prepared before
play. Measured on 2026-09-13 (91209fa), 57 of DOOM's arrays are assigned straight from a prepared table
(`Tables.finesine`, `Info.mobj_height`) and never allocated at all, and calling
them stored would have asked Full to allocate something it already has.

## Where each stored array's size comes from

0008's schema needs a `count` for every stored array, and that is the one thing
the reader cannot say: it answers `int_array`, not how many elements the
allocation asks for. So the allocation EXPRESSION is rendered from the tree —
the first argument of the `Array.new` or `Bytes.buffer` that creates the field
— and `tools/doom/core-counts.tsv` maps each (method, expression) pair to a
catalog name.

Keyed by the pair, because `n` is a local and means a different thing in each
method: `n = MAXMOBJS` in `Game#init_mobjs` and `n = data.bytesize / 26` in
`Level#load_sectors`. Eighty-two rows cover every allocation in the tree, and
the correspondence is a bijection the audit checks in both directions: an
allocation with no row is an array whose size nobody reviewed, and a row
matching no allocation is a row describing nothing.

| count kind | stored fields |
| --- | --- |
| fixed | 378 |
| limit | 54 |
| screen | 26 |
| level | 18 |
| table | 2 |

The thirteen Full-only ones are object references — `Wad`, `Level`, `Textures`,
`Sprites`, `Random`, `Jobs`, `JobExecutor`, `Game` — plus the WAD directory
array. CORE receives 0007 scalars and buffers, so it cannot hold any of them;
what it needs from a lump, a position and a size, Full passes as scalars or
prepares as a table.

| owner | variables |
| --- | --- |
| render | 308 |
| step | 257 |
| shared | 37 |
| full | 36 |
| input | 12 |

`Wad`, `Level`, `Textures` and `Sprites` are Full's: Full loads them from the
IWAD before any entry runs, both entries only read them, and the closure writes
none of them.

## Recursion

Four recursive components, recorded with their termination rule and the
proposed iterative representation in `tools/doom/core-cycles.tsv`. A component
with no row there fails the audit, so a new cycle cannot appear unnoticed.

| anchor | kind | members |
| --- | --- | --- |
| `Renderer#render_bsp_node` | bsp | 1 (self) |
| `Game#cross_bsp_node` | bsp | 1 (self) |
| `Game#recursive_sound` | sound | 1 (self) |
| `Game#dispatch_action` | action | 62 |

The three small ones are bounded by structure: the BSP tree is finite and
acyclic, and sound propagation marks each sector with the current validcount
before visiting its neighbours. Each becomes an explicit index stack or queue
that Full sizes from the map.

The 62-member component is not bounded by structure. It is the knot of thing
actions, weapon actions, blockmap iteration and damage, which recurs whenever
one action spawns or damages a thing that then acts. **Its iterative
representation is an open decision**, recorded here rather than discovered
during conversion.

## The Full boundary

A callee with no definition in DOOM's tree is a builtin. That is a statement
about the tree and not a permission: `tools/doom/core-builtins.tsv` answers
CORE reachability one entry at a time, and a builtin with no row stays
unresolved and fails the audit.

| verdict | call sites |
| --- | --- |
| core | 78 |
| obligation | 91 |
| full-boundary | 1 |

The core count was re-measured on 2026-10-18 for the move to upstream pin
3c4984057. The old pin 573aa44 gives 72 and leaves four call sites unresolved:
`abs` in `Game#cdiv` (game.rb:385, twice) and `@lumps.length` in `Wad#lump`
(wad.rb:65, twice). The new pin types `cdiv`'s receiver, and the audit now
reads the reader's `obj_array`, an Array of object references, as an array, so
all four are core. The 75 recorded before held at neither pin, and neither did
the 19632 call sites above; both pins count 19635. Since 888a00f
`Renderer#draw_column` also reads `@zonewin.getbyte`, one more core call site:
77, and 19636 call sites. Since d2f91c4 `render_gpu.rb` no longer writes the
screen's first byte back to itself (`scr.setbyte(0, scr.getbyte(0))`), which
removes two call sites: 19634. Since 0dfc2f7 `JobExecutor` keeps its `Jobs`
owner and reads the ring through the new `Jobs#zone_byte`, which the render
entry reaches: one definition more (1670, 372 reached, 150 for render), one
core call site more (its `@zonebuf.getbyte`: 78), and 19635 call sites, since
its two calls replace `jobs.zonebuf` in `JobExecutor#initialize`. Since fe94c61
`NativeSession#get` (full/native_session.rb) also sign-extends decision 0018's
`i8` and `i16` elements, `e == 5 || e == 7`: two call sites more, 19637; the
closure and what it reaches are unchanged. Since de13af3 and bd56ed3 (decision
0021) the generated preparation keeps one copy of the WAD's data and
`NativeSession` binds resources: two definitions fewer and one more (1669),
call sites unchanged. Since 9ad5c06 (decision 0022's input entry at 32 bits)
`NativeSession` keeps an i32 result cell, `result32`: one definition and one
call site more, 1670 and 19638. Since 4616036 (step and render at 32 bits) the
generated preparation's three `i32-bits` preparers test each word's range and
write its signed pattern: four call sites more each, 19650; the closure and
what it reaches are unchanged.

The 91 obligations are rewrites Stage 2 owes before conversion:

- **79 `raise` sites.** CORE has no exceptions. 0007's status ABI is
  `0 OK / 1 ARGUMENT / 2 ARITHMETIC / 3 BOUNDS / 4 CAPACITY` with
  `core_fail(:capacity)` the only constructor, so each site becomes a status
  return on a path the caller checks.
- **12 `loop` sites.** `Kernel#loop` carries a block whose body is part of the
  closure; rewritten as `while true` the body is ordinary statements the audit
  already follows. These are also every one of the closure's block edges.

The single full-boundary case is `Textures#nil?`: CORE has no object references
and cannot test one, so whether a resource is present is decided by Full before
the entry is called.

### Receivers the reader does not resolve

The reader types some receivers `poly`, meaning it resolved the expression but
not the class it produces. The audit refuses to guess — one surviving candidate
is not a resolution — so 12 sites have their receiver declared explicitly in
`tools/doom/core-receivers.tsv`, each with the source line that justifies it. A
row matching no call site fails the audit.

## Configurations

19 options, in bijection with what the entry's own tree accepts; an option with
no row, or a row for an option the source no longer accepts, fails the audit.
13 of them have no tracked command in this repository that exercises them,
which is recorded in `tools/doom/core-configurations.tsv` rather than left to
be discovered. The one that matters most for Stage 2 is `-res`: it sizes every
render buffer and selects the status-bar shadow path, so it is the option that
changes `doom_core_render`'s allocation.

## The predecessor fork

`tests/doom-core/fork/ledger.tsv` carries all 29 rows of the fork at
`ecbd0f2a` — sixteen defects, two later batches with no reproducer, seven
opt-in patches and five instruments — and `tests/doom-core/fork-compat.sh`
measures every row that has one against this repository's pin. Executed 12,
all agreeing with the ledger: **6 defects are still present and 6 are already
fixed.** Every reproduced one is deferred with a measured reason, so no
compiler candidate is proposed. The detail is in
[the fork review](doom-stage2-fork-review.md#measured-at-the-pin).

## Not done in task 1

Nothing outstanding: the audit exits 0 and every fork row is accounted for.
What follows is task 2 onward — the source packaging, the schema, and the
entries themselves.
