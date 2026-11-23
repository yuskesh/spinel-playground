# The two source aliases, and a proposal to replace them with a number

**Status: DECIDED; the representation is IN THE SCHEMA, and the CORE producers
and consumers are written and run in the game.** `@dc_srcbuf` folds into `renderer_dc_srcres`/`renderer_dc_srcbase`
and `@ds_source` becomes `renderer_ds_srcres`/`renderer_ds_srcbase`
(`tools/doom/core-representations.tsv`); Full (`Resources::SourceSelect`) and the
reference each convert the original's buffer choice, the four cells open at
RES_NONE -1 / base 0, and `tests/doom-core/source-select.rb` runs the original
renderer and checks every consumer reads the same bytes through selector and
base. `examples/doom/core/src/source.rb` is the port -- producers that set
both on every path, consumers that read only through them -- and
`tests/doom-core/source-port.rb` runs it beside the original in job modes 0
and 2 with the removed-producer controls ("The CORE port, run", below); the
same port COMPILED as CORE entries runs there too, is run over the resident
layout and through the 0007 adapter registry, and has every buffer face
checked at its edge -- except the status bar's, the HUD's and the renderer
leaves' entries, which have no edge cases yet ("The port, compiled"). What is NOT done:
DOOM's own render entry calling them, and job mode 4.
Nothing here is a pending question
unless it says so under "Three things that must hold". No public contract,
classification grammar or acceptance condition is changed by this document;
where the proposal would need one, it is marked and the decision is referred
back rather than taken here.

## What the two fields are

`tools/doom/audit-core.rb` refuses two fields because nothing allocates them
and nothing in `tools/doom/core-acquired.tsv` says how long they are:

    Renderer@@ds_source   (stored, typed string, allocated nowhere)
    Renderer@@dc_srcbuf   (stored, typed string, allocated nowhere)

Both begin as `""` and are rebound during rendering to bytes owned by another
field. Every site, from `examples/doom/lib/doom/render.rb`:

| line | field | bound to | kind of source |
|---|---|---|---|
| 302 | `@ds_source` | `""` | — |
| 424 | `@dc_srcbuf` | `""` | — |
| 1328 | `@ds_source` | `@textures.flatdata(@pl_picnum[pl])` | prepared flat atlas |
| 1370 | `@dc_srcbuf` | a sky column buffer | prepared texture atlas |
| 1919 | `@dc_srcbuf` | `@textures.texdata(tex)` | prepared texture atlas |
| 2350 | `@dc_srcbuf` | `@wad_data` | prepared whole IWAD |
| 2364 | `@dc_srcbuf` | `@zonewin` | **scratch**, see below |

and the two consumers:

| line | reads | as |
|---|---|---|
| 1467 | `src = @ds_source` | `src.getbyte(spot)` in `draw_span` |
| 1937-1938 | `buf = @dc_srcbuf`, `ofs = @dc_srcofs` | `buf.getbyte(ofs + ...)` in `draw_column` |

So neither field has a length. Each is a CHOICE OF REFERENT plus an offset —
`@dc_srcofs` sits beside `@dc_srcbuf` and is already an ordinary integer
field.

`@zonewin` is not prepared like the others. It is allocated as scratch at
`render.rb:203` (`Bytes.buffer(128, 0)`) and filled per frame by
`Wad#zone_window` (`wad.rb:146-160`) for masked columns that read past the end
of a lump. Treating all five sources as immutable prepared values would be
wrong, and the proposal below keeps the distinction.

## Why "exclude it from the schema" was refused

An earlier proposal was to mark the two as aliases and leave them out of the
schema. That was refused on review, and the reason is right: 0008's plan
asks to "account for every reachable field and source alias"
(`0008-doom-core-migration-plan.md:304-306`), and `0008-doom-core-migration.md:99-105`
requires the audit to classify EVERY ivar reachable from the roots. Removing
the field does not account for the choice of referent; it deletes the
question. Which buffer was selected is part of the state a tick reaches, and a
canonical comparison that cannot see it cannot say two ticks agree.

Equally, `0008-doom-core-migration.md:161-178` refuses retained pointers and
rebinding/alias locals outright, so the field cannot survive migration in its
present form either. It has to become something that is not a pointer.

## The proposal

Replace each aliasing field with ORDINARY NUMBERS: a selector naming one of
the resources the schema already declares, and a base offset into it.

| removed field | replaced by | element |
|---|---|---|
| `Renderer@@dc_srcbuf` | `Renderer@@dc_srcres` (selector) + `Renderer@@dc_srcbase` (the Job side's existing base, set on every path) | i64 |
| `Renderer@@ds_source` | `Renderer@@ds_srcres` (selector) + `Renderer@@ds_srcbase` (new) | i64 |

### Disposition and role are two different answers

An earlier draft of this document asked "stored or scratch?" as if it were one
question. It is two. `stored` is one of the AUDIT DISPOSITIONS in
`0008-doom-core-migration.md:99-105` -- stored field, immutable prepared
value, eliminated reference-only trace field, Full-only value. `scratch` is a
STORAGE ROLE, alongside `resource`, `persistent` and `output`, which
`audit-core.rb` derives from where a field is read and written.

The proposal is therefore:

| field | disposition | role | why |
|---|---|---|---|
| `dc_srcres`, `dc_srcbase` | stored | scratch | written and read inside one column, never read by another entry |
| `ds_srcres`, `ds_srcbase` | stored | scratch | written and read inside one span |

They are STORED -- they appear in the schema with a count and an initial
value, and the canonical comparison keeps them. The role is what says nothing
outside the render entry reads them. Neither answer lets the field be omitted:
see "what the comparison keeps" below.

### The selector values already exist -- do not renumber them

`jobs.rb:110-113` declares them:

    RES_ATLAS = 0   texture column atlas (static, 128-byte windows)
    RES_WAD   = 1   raw WAD bytes (masked post, not 128-aligned)
    RES_ZONE  = 2   zone window ring (per frame, 128-aligned)
    RES_FLAT  = 3   flat atlas (static, 4096-byte faces)

`RES_FLAT` is the answer for `@ds_source`; an earlier draft asked whether one
was needed and it was already there. Nothing is renumbered, and no new status
is introduced.

**The empty initial reference needs a value that is not one of these.**
`RES_ATLAS` is 0, so zero cannot mean "nothing selected". The proposal is
`RES_NONE = -1`, matching the negative sentinel this codebase already uses for
an unused slot (`@activeplats = Array.new(MAXPLATS, -1)`, `specials.rb:69`).
`render.rb:302` and `424` set the empty string today; they set `RES_NONE` and
base 0 instead. No new CORE status and no exception path: `RES_NONE` reaching
a consumer is a defect in the producer, and the controls below are what catch
it.

### Every producer, with what it sets today

| site | producer | sets today | must also set |
|---|---|---|---|
| 302 | `Renderer#initialize` | `@ds_source = ""` | `@ds_srcres = RES_NONE`, `@ds_srcbase = 0` |
| 424 | `Renderer#initialize` | `@dc_srcbuf = ""`, `@dc_srcofs = 0` | `@dc_srcres = RES_NONE`, `@dc_srcbase = 0` |
| 472-473 | `Renderer#initialize` | `@dc_srcres = RES_ATLAS`, `@dc_srcbase = 0` | (Job-side today; folds into the above) |
| 1328 | `draw_planes` | `@ds_source = flatdata(picnum)` | `@ds_srcres = RES_FLAT`, `@ds_srcbase = @textures.flat_atlas_base(@curpicnum)` |
| 1370-1373 | sky column | `@dc_srcbuf`, `@dc_srcofs = c`, `@dc_srcbase` **only if `@jobmode != 0`** | `@dc_srcres = RES_ATLAS` and `@dc_srcbase = atlas_base(tex) + c`, both unconditionally |
| 1919-1926 | `set_texture_column` | `@dc_srcbuf`, `@dc_srcofs = c`, `@dc_srcbase` **only if `@jobmode != 0`** | `@dc_srcres = RES_ATLAS` and `@dc_srcbase = atlas_base(tex) + c`, both unconditionally |
| 2350-2354 | masked, post fits in the lump | `@dc_srcbuf = @wad_data`, `@dc_srcofs = p+3`, `@dc_srcres = RES_WAD`, `@dc_srcbase = p+3` | nothing; this branch already sets both |
| 2355-2361 | masked, **Job path** (`@jobmode != 0`) | `@dc_srcres = RES_ZONE`, `@dc_srcbase = zb` (a RING slot) | nothing; it sets no `@dc_srcbuf` because the Job reads the ring later |
| 2362-2365 | masked, **direct path** (`else`) | `@dc_srcbuf = @zonewin`, `@dc_srcofs = 0` | `@dc_srcres = RES_ZONE`, base 0 -- it sets NO selector today |

An earlier draft collapsed the last three into one row and said the masked
producer needed nothing added. That was wrong twice: the Job branch and the
direct branch are different branches of the same `if`, they select different
storage (`@jobs.zonebuf` ring slot against the single reused `@zonewin`), and
the direct branch sets no selector at all.

**The base is `@dc_srcbase`, on the sky and wall paths too.** `@dc_srcofs` is
`c`, an offset within `texdata(tex)` -- the buffer itself already selected the
texture -- so a consumer reading it against the whole atlas would read the
wrong texture. `render.rb:1373` and `1926` already compute the atlas base,
`atlas_base(tex) + c`, into `@dc_srcbase`, but only when `@jobmode != 0`; the
port sets it unconditionally. `@dc_srcofs` keeps its original meaning and is
read only to CONVERT the original's choice (`Resources::SourceSelect`, the
reference); no transformed consumer reads it, and it does not become a base.
(An earlier draft reinterpreted `@dc_srcofs` as the base; "Settled on review"
replaced that.)

### Every consumer

| site | consumer | today | becomes |
|---|---|---|---|
| 1467-1476 | `draw_span` | `src = @ds_source`, `src.getbyte(spot)` | select on `@ds_srcres`, read at `@ds_srcbase + spot` |
| 1937-1947 | `draw_column` | `buf = @dc_srcbuf`, `buf.getbyte(ofs + ...)` | select on `@dc_srcres`, read at `@dc_srcbase + ...` |
| 1987 | `emit_column` | passes `@dc_srcres`, `@dc_srcbase` to `push_masked` | unchanged once every producer sets them |

The span shape is already proven on the Job side and is the model for the
direct side: `render.rb:1462` passes `flat_atlas_base(@curpicnum)` into
`push_span`, `jobs.rb:415-425` stores it as `SP_SRCOFS`, and
`executor.rb:242-252` reads `src.getbyte(ofs + spot)` out of `@flatatlas`.
`position` is the packed coordinate that makes `spot` WITHIN a flat; it is not
the base and cannot serve as one. An earlier draft asked whether `position`
already carried the offset -- it does not, which is why `@ds_srcbase` is a new
field rather than a reinterpretation.

### Lifetimes, which are not all the same

`RES_ATLAS`, `RES_FLAT` and `RES_WAD` name immutable prepared resources. The
other two are not:

* the DIRECT path's `@zonewin` (`render.rb:203`, `Bytes.buffer(128, 0)`,
  filled by `Wad#zone_window`, `wad.rb:146-160`) is a single reused scratch
  buffer. It is consumed by `draw_column` immediately, in the same column, so
  one buffer suffices.
* the JOB path's ring slot (`@jobs.alloc_zone_window`, `render.rb:2358-2360`)
  must stay live until the deferred Job runs, which is why a ring exists at
  all rather than the one buffer.

A selector whose domain includes mutable scratch is not the same object as one
that only names prepared resources, and the implementation must keep the two
`RES_ZONE` cases apart: same selector value, different storage and different
lifetime. This proposal does not change the ring's lifetime rule; it records
that the selector alone does not express it.

### What the canonical comparison keeps

An earlier draft said these fields "hold no meaning across a tick boundary"
and also that two ticks reading different sources must not compare equal.
Those contradict, and the second is the requirement. The correction:

* the selector and base are compared wherever they are DEFINED, including at
  an entry boundary. A defined value is compared whatever its role; the
  standing exclusion is for UNDEFINED scratch only, and calling a field
  `scratch` does not make its defined cells undefined.
* within a live producer/consumer pair, what must be compared is the selector,
  the base, and the pixels the pair produces -- all three, because two of them
  agreeing while the third differs is a difference.

Today the two fields are `u8` with the invented count 1, so a snapshot keeps
one byte of the referent and nothing about WHICH referent. Two ticks reading
different resources compare equal. Giving them the largest possible length is
not a fix either: it duplicates bytes the atlas and WAD fields already carry
and still records no choice.

### Controls the implementation must carry

* the last valid index and the first invalid index of each of the four
  resources, which is where `0008-doom-core-migration-plan.md:385-386` asks
  for resource offset and end checks;
* two ticks differing ONLY in the selector, which must not compare equal --
  the control today's representation cannot pass;
* the direct-CPU path and the Job path for the same column and the same span,
  which must agree pixel for pixel;
* a deferred Job holding `RES_ZONE` whose ring slot would be reused before it
  runs, kept distinct from the direct `@zonewin` case;
* a consumer reached with `RES_NONE`, to show the producers set a selector on
  every path rather than relying on the initial value.

### What this proposal does not do

It does not widen any descriptor count by a scalar length. It adds no registry
same-id duplication, no subview, no poison exception and no new CORE status.
The selector is an ordinary i64 field in the existing schema grammar, choosing
among resources the schema already declares; it is not a retained pointer and
carries no address. 0007's type, ownership, borrow, alias, status and registry
contracts are unchanged. If the implementation turns out to need any of that,
the diff goes back for a decision rather than being taken here.

## Settled on review

* `RES_NONE = -1`. `RES_ATLAS`..`RES_FLAT` keep 0..3 unchanged.
* **One base per column, and it is the existing `dc_srcbase`.** `@dc_srcofs`
  is not reinterpreted as an atlas base; keeping both an offset that changed
  meaning and a separate base would be two things to maintain and two things
  to get out of step. The direct-CPU consumer and `emit_column` both read
  `@dc_srcbase`.
* `@dc_srcofs` and the two alias fields do not vanish silently: their
  correspondence to the replacements is recorded in this document and in the
  `origin` column of the schema, which is what `0008-doom-core-migration.md:99-105`
  requires `origin` to carry.

| producer | selector | base |
|---|---|---|
| sky column (1370-1373), wall column (1919-1926) | `RES_ATLAS` | `atlas_base(tex) + c` |
| masked, post inside the lump (2350-2354) | `RES_WAD` | `p + 3` |
| masked, Job boundary (2355-2361) | `RES_ZONE` | `zb`, a ring slot |
| masked, direct boundary (2362-2365) | `RES_ZONE` | `0` |
| span (1328, 1462) | `RES_FLAT` | `flat_atlas_base(@curpicnum)` in `@ds_srcbase` |

This is a naming and in-application layout decision. It approves no new 0007
contract, and the original Full reference is unchanged: the comparison is
between the original and the converted representation, stated below.

## Three things that must hold before this is implemented

### A. What a consumer does with `RES_NONE`

"A producer that fails to set it is a defect and a test will find it" is not a
definition of consumer behaviour. Two things are needed instead:

* **Structure.** Every consumer must be reachable only through a producer that
  set a selector and a base. `draw_column` (1937) and `draw_span` (1467) are
  each called from a bounded set of sites, and this document must list them
  and show each sets both -- not by adding a Ruby analyser, but by enumerating
  the call sites and checking them.
* **Controls that name the failure.** Removing a producer's assignment, and
  skipping one branch of the masked `if`, must each be refused BY NAME rather
  than producing a wrong pixel.

If that structure cannot be established -- if `RES_NONE` can reach a consumer
at run time -- then the mapping to an EXISTING CORE status must be proposed
here and approved before implementation. No success fallback, no new status,
no silent default.

#### The call sites, enumerated (original tree at 704573e)

From the audit's `closure.tsv` (callers by resolved target) and the source.
Render phases, set in `render_player_view` (`render.rb:671-679`, `2162`):
0 walls (`render_bsp_node`), 1 planes (`draw_planes`), 2 masked segs and
sprites (`draw_masked`), 3 player sprites.

| consumer | reached from | phase | what dominates the call today, in the same block |
|---|---|---|---|
| `draw_column` (1932) | `render_seg_loop` 1862 (mid), 1876 (top), 1895 (bottom) | 0 | `set_texture_column(tex, col)` on the line before, same branch: `@dc_srcbuf = texdata(tex)`, `@dc_srcofs = c`, `@dc_srcbase` only if `@jobmode != 0` |
| `draw_column` | `draw_sky_plane` 1375 | 1 | inside `if yl <= yh`: `@dc_srcbuf = buf` (1370, `buf = texdata(skytexture)` at 1355), `@dc_srcofs = c` (1372), `@dc_srcbase` only if `@jobmode != 0` (1373) |
| `draw_column` | `draw_masked_column` 2369 (reached from `draw_vissprite` 2298 and `draw_masked_texture_column` 2522) | 2, 3 | `if yl <= yh`: every branch of the `if / elsif / else` (2349-2366) sets a source -- `@dc_srcbuf/@dc_srcofs` + `@dc_srcres = RES_WAD`, `@dc_srcbase = p + 3`; or (jobmode) `@dc_srcres = RES_ZONE`, `@dc_srcbase = zb`; or (direct) `@dc_srcbuf = @zonewin`, `@dc_srcofs = 0` |
| `emit_column` (1968) | `draw_column` 1933, first statement, when `@jobmode != 0` | all | `@phase < 2` pushes a WALL job with `@dc_srcbase` only (atlas implied); otherwise a MASKED job with `@dc_srcres`, `@dc_srcbase` -- and in phases 2-3 `draw_column` is reached only through `draw_masked_column`, whose Job branches set both |
| `draw_span` (1456) | `map_plane` 1442 <- `make_spans` 1384, 1388 <- `draw_planes` 1343 | 1 | `@ds_source = flatdata(@pl_picnum[pl])` at 1328, straight-line earlier in the same loop iteration as the `make_spans` loop; sky planes `next` before it (1322-1326). Job path: `push_span(..., flat_atlas_base(@curpicnum), ...)` at 1462 |

What that shows for the REPRESENTATION (not the original, which is unchanged):

* every consumer call is dominated, in its own block, by a statement that
  chooses the source for that call. So each producer site in the table under
  "Settled on review" can set `(selector, base)` at the same place, and no
  path reaches a consumer with only the initial value -- provided the producer
  assignments become UNCONDITIONAL.
* **the conditional assignments are the defect to remove**, not a case to
  tolerate: `@dc_srcbase` is set only under `@jobmode != 0` at 1373 and 1926,
  and `@dc_srcres` is set once to `RES_ATLAS` at 472 and afterwards only by the
  masked branches. In the original that is harmless -- the direct path reads
  `@dc_srcbuf/@dc_srcofs`, a WALL job ignores `@dc_srcres` -- but a
  representation that reads `(selector, base)` on BOTH paths would see a
  stale `RES_WAD`/`RES_ZONE` from the last masked column when a later wall or
  sky column runs. The producers must set `RES_ATLAS` and the base on every
  path.
* so `RES_NONE` does not need a CORE status mapping on this enumeration. The
  controls below are what keep it true.

What must be checked mechanically once the port exists, not only read here:
the port's producers for these five sites each set both fields unconditionally
before the consumer call; a copy with one producer assignment removed, and one
with a masked branch skipped, must each be refused by name (the pixel
comparison alone is not the control); and a consumer reached with `RES_NONE`
must be reported, not drawn.

### B. Scratch is excluded wholesale today, and "defined values remain" is not
### yet true

`tools/doom/state-schema.rb:337` builds the canonical snapshot as

    fields.reject { |f| f["role"] == "scratch" }

so EVERY scratch field is excluded by its ROLE, not by whether its cells are
defined. Writing "a defined value is compared whatever its role" into a
document does not change that; the schema change and the controls have to come
with it.

RETRACTED, AND WHAT REPLACES IT. An earlier revision of this section said
that none of the underived initials can be derived and that all of them must
therefore be carried as prepared data. That was wrong twice. The shapes it
rested on came from a collector that missed every
`InstanceVariableOperatorWriteNode`, and even corrected they are facts about
what THIS analysis reads, not proofs that no derivation exists. And running
Full's initialisation to measure the state is NOT circular: measuring a fixed
Full independently of the schema and comparing it through the new
prepared -> session -> canonical path is what
`0008-doom-core-migration-plan.md:310-313` asks for. What must stay separate
is copying one snapshot to both sides, which evidences transport and nothing
else.

Measured when this section was first written (historical; see below for
where it stands):

* 12 fields are `scratch`, every one of them a scalar with a declared initial
  of 0 (`game_bombdamage`, `game_bombsource`, `game_bombspot`,
  `game_crushchange`, `game_nofit`, `game_sightzstart`, `game_strace_dx/dy/x/y`,
  `game_t2x`, `game_t2y`). All 12 are outside the canonical comparison.
* **and their `0` was not known to be measured**: a field with no allocation
  site got an invented initial of 0, as counts once got `fixed:1`.

So the schema could not tell a DEFINED initial cell from an ASSUMED one, and
(B) had to take the fill side first.

Where it stands at 704573e:

* the fill side is taken. A field the audit has no initial for is `UNDERIVED`,
  not 0; a stored field that is `UNDERIVED` or that Full's setup writes after
  allocating it is `prepared:NAME`, carried from Full's own initialisation; a
  kept fill rests on the audit's setup walk (`setup-writes.tsv`).
* for the 12 scratch fields, two things are measured rather than taken from
  the role: `state.sh` checks the original defines none of their ivars before
  the first tick (this configuration), and the audit's `scratch-defined.tsv`
  shows each read inside an entry follows a write in the same call.
* the canonical snapshot still excludes by role (`state-schema.rb`), but a
  scratch field that WAS defined before the first tick fails `state.sh`'s
  check by name -- so a selector or base given an initial `RES_NONE` / 0 by the
  constructor, as the representation proposes, could not be excluded that way
  unnoticed. Making them compared is part of the implementation.

What (B) then requires: compare the initial `RES_NONE` and base 0, the defined
values at an entry boundary, and the selector, base and pixels at
producer/consumer time -- with exclusion limited to scratch explicitly named
as undefined, rather than to the role as a whole.

### C. `RES_ZONE` names two different stores, chosen by consumer context

| consumer context | storage | base |
|---|---|---|
| direct CPU (`draw_column`) | `renderer_zonewin` -- one reused 128-byte buffer, `render.rb:203`, filled by `Wad#zone_window` (`wad.rb:146-160`) | 0 |
| deferred Job (`JobExecutor`) | `jobs_zonebuf` -- the ring, `@jobs.alloc_zone_window` | the ring slot `zb` |

This is a RULE the implementation follows, not a caution in a comment. It must
be checked two ways: that the right store is selected for the context, and
that a deferred Job holding a ring slot consumes it before the slot is reused.

#### What the original does, read at 704573e

* **Which store.** The Job executor chooses by the job's own field:
  `buf = @masked[b + MC_SRCRES] == RES_ZONE ? @zonebuf : @waddata`
  (`executor.rb:285`), `@zonebuf` being `jobs.zonebuf` (`executor.rb:54`). A
  masked job's source is only ever `RES_WAD` or `RES_ZONE`; walls and spans are
  other job kinds with their own resources. The direct path never reaches the
  executor: `draw_masked_column` fills `@zonewin` with `Wad#zone_window` and
  calls `draw_column` in the same branch (`render.rb:2362-2369`), which reads it
  before returning.
* **When a ring slot can be reused.** `alloc_zone_window` (`jobs.rb:456-461`) is
  a bump allocator: `@nzone += 1`, slot `i * ZONE_STRIDE`, and at `ZONE_SLOTS`
  it raises `JobError` rather than wrapping. `@nzone` returns to 0 only in
  `Jobs#reset` (`jobs.rb:347-352`), called only at the start of
  `render_player_view` (`render.rb:672`). So within a frame no slot is handed
  out twice, and a slot can be reused only by the NEXT frame's render.
* **Whether every job runs before that.** In job modes 1 and 2 the executor runs
  at the end of the same `render_player_view` (`render.rb:688`), after every
  push. In mode 0 there are no jobs. In mode 4 the render only pushes, and
  `bin/doom.rb:325-331` calls `gpu.draw(r.jobs, r.screen)` -- and, if the GPU
  refuses, `r.draw_jobs_cpu` -- before the loop reaches the next
  `render_player_view`. **That is call order in Ruby, not evidence that the
  driver has finished reading the ring memory, and mode 4's ring lifetime is
  UNVERIFIED.** It is not needed for the CPU computation this milestone is
  about, and it is not asserted until synchronous driver evidence or a real
  completion control exists.

So in the original the rule holds by construction. For the port it is a
property to CHECK, not to inherit. The check exists for the original now,
`tests/doom-core/zone-ring.rb`, run by `tick.sh`, over 200 frames of DEMO1. It
watches the CONSUMERS' OWN READS -- `getbyte` on the ring, the WAD data and
`@zonewin` -- against a consumption expected where each window is produced. (An
earlier version compared the ring at the slot a job was pushed with, which an
executor reading the WAD data instead still passed: that showed the bytes were
kept, not that they were read. Mac review of 811ccfa.)

* **queued (job mode 2):** a `RES_ZONE` masked job, when pushed, expects
  `yh-yl+1` reads, all from the ring inside `[slot, slot+128)`, with the ring
  still holding its bytes, while `JobExecutor#exec_masked` runs it: 8229 jobs,
  8038 on a slot other than 0, all consumed, no fault.
* **direct (job mode 0):** a `Wad#zone_window` call inside
  `Renderer#draw_masked_column` expects the next `draw_column` to read only
  `@zonewin` inside `[0, 128)`, holding what was written: 8239 windows, 8229
  consumed and 10 fuzz or empty, no fault.
* **paired:** the two consumers compute which byte of the window each pixel
  reads independently, so their sequences of indices relative to the base must
  be identical, consumption by consumption: 8229 against 8229, none different.
  This is what sees a base shifted INSIDE the window.
* **capacity:** a fresh `Doom::Jobs` hands out its 3072nd slot at 393088 and
  refuses the next by name.

Each control changes one line in a private copy of the library, or misbehaves
through a hook, and is reported by fault and by the first frame/job/slot or
tic/column: a ring rewound early or one slot for every window (stale bytes); an
executor reading the WAD data (wrong store), the next slot (out of window), or
skipping zone jobs (no reads); a direct column reading the WAD data (wrong
store); and a base one byte off in either consumer (the paired sequences
differ).

The port is to be run through the same comparison. Ring overflow already
raises `JobError`; in CORE that is `core_fail(:capacity)`, the existing
CAPACITY status, not a new one.

## The comparison under representation conversion

The original Full reference is fixed and is not adjusted to match. What
changes is the representation on the core side, so the correspondence has to
be stated: for each column and span, the original's chosen buffer and offset
correspond to `(selector, base)`, and two states agree when the selectors
agree, the bases agree, and the pixels the pair produces agree. An agreement
reached by dropping any of the three is not agreement.

## The CORE port, run

`examples/doom/core/src/source.rb` holds the producers and consumers:

* `dc_src_none` (the initial state), `dc_src_texture_column` (sky and wall,
  `RES_ATLAS` at `atlas_base + ((col & widthmask) << 7)`), `dc_src_masked_post`
  (`RES_WAD` at the post while 128 bytes remain in the lump, else `RES_ZONE` at
  the ring slot when queued or 0 when direct) and `dc_src_span` (`RES_FLAT`).
  Each sets both cells on every path; none takes a mode that decides whether to
  write.
* `dc_draw_column` and `dc_draw_span` read the declared resources through the
  selector and base on the direct path; `dc_draw_masked_job` reads the IWAD
  bytes or the RING for a queued masked job. A selector the consumer's context
  cannot read -- `RES_NONE` included -- answers -1 and draws nothing. That is a
  result the caller reports, not a new status.

`tests/doom-core/source-port.rb` runs them INSIDE the original game over DEMO1.
A private copy of the library gets one added producer line at each of the six
sites above (two in `Renderer#initialize`) and a site-marker line at the three
column sites; the tree is not changed. At every consumer, after the original
has drawn, `tests/doom-core/tick.sh` pins:

* **direct (job mode 0), 600 tics:** before the first tick the port holds
  `-1 0 -1 0`, which is the original's choice converted. At 352285 columns
  (133337 masked, 1296 sky from tic 572, 217652 wall) and 94425 spans, the
  port's selector and base equal `Resources::SourceSelect`'s conversion, the
  consumer never answers -1, and it writes the original's pixels.
* **queued (job mode 2), 600 frames:** every one of 222093 wall and sky jobs
  carries `RES_ATLAS` at its offset, 94425 span jobs `RES_FLAT` at theirs, and
  133337 masked jobs (28141 on the ring) exactly their `srcres`/`srcofs`; the
  port's consumer, run on the job when the executor runs it, writes the
  executor's pixels.
* **the masked boundary, as the game reaches it:** in both modes the fewest
  bytes left when a post was read in place is 128 and the most when it was not
  is 127.

Each control removes one producer line and faults, by name, at the site it
removed:

| control | direct | queued |
|---|---|---|
| no sky producer | 1296 producer-disagree, first sky tic 572 x 106 | 1296 job-disagree, first sky frame 572 wall job 335 |
| no wall producer | 80513 producer-disagree; 616 unreadable, the first with RES_NONE | 82353 job-disagree; 80513 unreadable, the first with RES_NONE |
| no masked producer | 37586 producer-disagree | 37586 job-disagree, all unreadable, the first with a stale RES_ATLAS |
| no span producer | 33540 producer-disagree, all unreadable (nothing else writes the span selector, so it stays RES_NONE) | 33540 job-disagree, all unreadable |
| RES_ZONE read from the IWAD bytes | -- (refused: no queued consumer) | 8223 of 8229 zone jobs' pixels differ |

Against "Controls the implementation must carry" above:

* a consumer reached with `RES_NONE` is reported, not drawn: shown (no-wall,
  no-span);
* a deferred `RES_ZONE` job whose ring slot is reused: prerequisite C's
  reset-early and same-slot controls, on the original;
* the direct and Job paths agree pixel for pixel: each is compared with the
  original's own drawing in its mode, and prerequisite C pairs the two masked
  consumers. The port's direct and queued consumers are NOT paired with each
  other;
* the last valid and first invalid index of each resource: done on the
  compiled entries, below;
* two ticks differing only in the selector: NOT run as its own control.

## The port, compiled

`tests/doom-core/fixtures/source/` declares thirty-nine entries over the port --
`dc_sp_col`, `dc_sp_span` and `dc_sp_mjob` for the consumers; `dc_sp_none`,
`dc_sp_tex`, `dc_sp_mask` and `dc_sp_flat` for the selector producers; and
`dc_sp_zone` and `dc_sp_zalloc` for the zone windows, `dc_sp_jreset` for
`Jobs#reset` (`examples/doom/core/src/zone.rb`), `dc_sp_exec` for the job
executor's whole run (`examples/doom/core/src/executor.rb`), and `dc_sp_pwall`,
`dc_sp_pspan`, `dc_sp_pmask`, `dc_sp_ph1` and `dc_sp_ph3` for the pushes and
phase marks (`examples/doom/core/src/jobs.rb`), and `dc_sp_cdis`, `dc_sp_cspan`,
`dc_sp_cmask` and `dc_sp_call` for the interval-table checks
(`examples/doom/core/src/checks.rb`), and `dc_sp_dplanes` for the planes' walk,
with its spans and sky columns (`examples/doom/core/src/planes.rb` and
`planespan.rb`), and
`dc_sp_cplanes` for `clear_planes` (all below; the fixture also packs
`src/fixed.rb`, whose `fixed_div` clear_planes calls), and `dc_sp_sbdraw` and
`dc_sp_hudraw` for the status bar and the HUD's message line
(`examples/doom/core/src/statusbar.rb` and `hud.rb`), and fourteen entries over
seventeen of the renderer's leaves (`examples/doom/core/src/leaves.rb`, from
`dc_sp_pangle` to `dc_sp_addspr`), and `dc_sp_segloop` for the walls' seg loop
(`examples/doom/core/src/segs.rb`) -- each buffer with its own
count, `inout` only where the entry writes. EVERY SCALAR FIELD ARRIVES AS
`state` AND AN INDEX: the selector, the base, the ring's counter and the cells
`Jobs#reset` writes are cells of the one `core_state` buffer, so an entry takes
that buffer once and the index of each cell it touches, never one-element
views of it -- a 0007 adapter caller holds one id for `core_state`, and passing
it twice as a mutable participant is what 0007 refuses. The kernel tool builds each from the units themselves, whose
hashes the fixture manifest pins beside `sources.tsv`'s. Nothing was relaxed
for this: no eligibility rule, no 0007 alias, status or poison contract. The
`spinel-core-build --core` driver, which has no declaration to work from,
still refuses `source.rb`'s definitions (README).

`tests/doom-core/tick.sh` holds, measured:

* **the objects:** each has no undefined symbol and exactly one export, and
  every relocation it carries is a branch to text defined in the same object
  (`tests/doom-core/object-relocs.rb`), so linking them into a shared object
  for the game run leaves nothing for the linker to decide. How many there are
  is the platform's: none on Debian x86_64; on macOS arm64 the column, span and
  masked-job objects each keep one ARM64_RELOC_BRANCH26 from the wrapper to its
  own body (Mac review of b684c22). The rule's controls -- a branch to a
  function of the same object admitted; a call to an undefined function, a
  PC-relative data reference and an unwind record refused -- are compiled and
  run on the host.
* **every buffer face at its edge** (`tests/doom-core/source-edges.rb`,
  `fixtures/source/edges.c`): for the column scr, cmap, atlas, wad, zonewin,
  srcres and srcbase; for the span scr, cmap, flat, srcres and srcbase; for
  the masked job scr, cmap, wad and zonebuf; the selector producers' two cells;
  the zone producer's window, IWAD bytes, lump directory and next-lump chain;
  the allocator's counter and slot count; and for the executor's run scr,
  cmap, atlas, flat, wad, zonebuf and fuzzoffset, each bank through the
  schedule's record index, sc_kind and sc_idx through the schedule's length,
  the length's cell in state, the four frame constants, and the fuzz column's
  read of the row above and below; for each push its bank at the count and one
  past, the bank's and the schedule's capacity, sc_kind and sc_idx at the
  schedule's count, the capacity buffers, both counter indices and a negative
  count; each phase mark's two indices; and for each interval-table check its
  count table past the screen dimension, the dimension buffer, the bank's last
  read cell, each slot table at the second slot, a full column, a job past the
  screen, every counter index and an empty job; and for the plane spans every
  row and column table at the cell the span reads, the spanstart row written,
  the span bank, the schedule, both capacities, every cell index, the cached
  row and a negative light index -- now through the planes' walk, whose own
  faces are its plane arrays, the loop's bound and start, its sentinel columns,
  the empty plane and the light clamp, and for a sky plane its column rows, the
  sky texture's width mask and atlas base, the wall bank and its capacity, the
  sky scale and middle and every column cell index; and for clear_planes the
  clip arrays, the row cache, the prepared constants, every cell index and a
  saturating fixed_div. The case reaching the exact last
  element succeeds, and the same case changed in one field -- checked to be
  one -- reaches one past and is SPINEL_CORE_BOUNDS, as is a resource reached
  one below zero; a full ring, bank or schedule is SPINEL_CORE_CAPACITY, and a
  push refused at the schedule keeps the record and count it stored. Buffers are allocated
  at exactly their count. EVERY expected line CRuby can answer is DERIVED: the
  generator runs the Ruby port on the same case over buffers that refuse an
  index outside their length, so a BOUNDS case's line -- including every
  element stored before the refusal, since 0007's ABI has no rollback -- is
  CRuby's, and a declared answer must agree with it. A two-pixel column whose
  second read is past the atlas keeps its first pixel; a window whose 128th
  store is past its buffer keeps 127 bytes. A selector the consumer cannot
  read answers -1 with status 0 and draws nothing.
* **the arithmetic edges,** in the same lane: the texture producer's sum and
  its shift, the masked producer's `post_ofs + 128`, the column's
  `(yl - centery) * fracstep` (and the executor's wall's, inside the whole run),
  the span's screen offset and the allocator's `i * 128`, each at the last value that fits i64 and one past it, which is
  SPINEL_CORE_ARITHMETIC. This is the one answer CRuby cannot give -- its
  integers do not overflow -- so it is declared, and the lane records what CRuby
  does instead: stores 2**63 as the base, takes the zone branch instead of
  refusing, draws, answers slot 2**63, or raises when the product becomes an
  index; each push's `count * NF`; and the disjoint check's first record past
  `lo * NF` (at `lo` = I64_MAX / 7 the product is I64_MAX, which 7 divides, and
  `+ 1` overflows); map_plane's `planeheight * yslope` inside a plane; and
  clear_planes' `viewangle - ANG90`; and a sky column's `viewangle +
  xtoviewangle`. 505 cases in all: 237 succeed, 14 are ARITHMETIC, 239 BOUNDS, 15 CAPACITY,
  the state buffer's own faces among them: a cell index at the state's last
  element, one past and one below, for every index an entry takes, and the
  reset table's entries the same way.
* **no native access outside a buffer, in those cases:** the same 505 cases
  with the entries and the harness built under AddressSanitizer give the same
  lines and no report. That the entries themselves are instrumented is shown,
  not assumed: a caller declaring 257 atlas bytes over an allocation of 256
  passes the entry's own check -- the count is the caller's claim -- and the
  read is reported as a heap-buffer-overflow from inside the compiled column;
  a caller declaring 4097 flat bytes over 4096, from inside the compiled
  executor; and a wall bank declared two records long over an allocation of
  one is reported as a WRITE from inside the compiled push.
* **the entries in the game** (`SOURCE_PORT_NATIVE`, over DEMO1, in place of
  the Ruby definitions): direct 600 tics and queued 600 frames give exactly the
  Ruby port's comparisons -- the same site counts, zero faults -- with every
  native call returning status 0. The zone windows are the PORT'S: at each
  of the 30904 zone windows the original makes in 600 tics the port's producer
  writes its own window -- the direct window, or the ring at the slot the
  port's allocator hands out -- and each window equals the original's byte for
  byte, each slot the original's slot; the consumers read only the port's
  windows. Without the zone producer 8213 columns in 200 tics draw wrong, and
  a ring producer writing a SECOND ring gets every window right and the
  executor's view wrong on the same 8213. The no-sky and wrong-store controls
  fault as they do in Ruby. The game run is NOT under AddressSanitizer: that
  none of its accesses left a buffer rests on every count being its storage's
  exact length, every status being 0, and the edge cases showing the check at
  every face.
* **a mutant:** a column entry built from `source.rb` with one line changed
  (`k = base + 1 + ...`) changes 13 edge lines and gives 110538 pixel
  mismatches direct and 77342 queued in 200 tics, so the lanes are reading
  the compiled code.
* **over the resident layout:** DEMO1 plays E1M5, so the lane measures E1M5's
  catalog, emits the schema again from its own audit with it -- which must be
  the committed `state.tsv` and `access.tsv` byte for byte -- and generates
  buffers.tsv, slots.tsv and registry.h. `tests/doom-core/fixtures/source/fields.tsv`
  names the resident field each entry parameter is in each context, and for
  each index parameter the slot and whether the entry reads or writes it --
  376 rows, 38 contexts, 204 fields of which 57 are slots -- and
  `tests/doom-core/source-registry.rb` checks every row against the contract,
  the generated layout and registry.h, and `access.tsv`'s doom_core_render
  mode; six one-row changes to the map, and a registry.h with one slot moved,
  are each refused for their own reason. Then `SOURCE_PORT_SESSION` runs the
  entries in the game over a `Doom::Core::Session` that Full opens from
  `Resources.prepared` -- all 558 prepared fields -- with every parameter the
  session's field: `core_state` handed over once, and every cell an entry
  touches its registry slot, the zone producer writing the
  session's `renderer_zonewin` and its ONE ring `jobs_zonebuf`, which is also
  what the executor's view reads (the lane refuses a map that gives the
  producer and the executor different rings). Direct and queued over 600
  tics: the same comparisons, every status 0, and at every column and job the
  selector and base in the slots `core-representations.tsv` names; the slots
  open at the prepared -1 0 -1 0, no other `core_state` slot but the ring's
  counter changes, and no read-only field changes. A map that puts the column
  base in the neighbouring render slot passes the static check and draws the
  same pixels, and the per-call slot check catches it at the first column
  (36389 times in 60 tics) and the first job (37703); the end-of-run checks
  alone did not catch it in direct mode, measured. And over the session, the
  compiled ring producer writing a second ring leaves the executor's view
  stale: 660 pixel faults in 60 frames.

### The zone windows are storage the render entry writes, and the ring is one

The audit used to record no writer for `Renderer@@zonewin` or `Jobs@@zonebuf`:
the stores are `out.setbyte` inside `Wad#zone_window_into`, on its parameter,
and a store was only attributed when its receiver was the ivar itself. So both
were `resource` fields `doom_core_render` could only read, and the ring -- one
object in the original, `JobExecutor#initialize` taking `@zonebuf =
jobs.zonebuf` -- was two allocations, `jobs_zonebuf` and
`job_executor_zonebuf`. Both are fixed, within prerequisite C's settled
representation (a queued job's RES_ZONE is `jobs_zonebuf` at its ring base):

* `tools/doom/audit-core.rb` follows a written parameter back to the argument
  at each resolved call in the closure, to a fixpoint, and attributes the write
  to an instance variable passed there or to the field a generated reader
  names. Anything else -- a local, an expression, a rebound parameter, a call
  with more than one candidate that writes its parameter -- is named in
  `argument-writes.tsv` and fails the run. On DOOM it finds five writes and
  nothing unresolved, and `tests/doom-core/audit.sh` shows a window passed
  through a local and a rebound parameter each named and failing.
  `renderer_zonewin` and `jobs_zonebuf` are now persistent stored fields,
  `inout` for the render entry; the screen and the status bar's backing gain
  writers they already had through other calls, without a role change.
* The hosted executor retains the Jobs owner and calls `Jobs#zone_byte` for
  RES_ZONE reads. Exporting the mutable String at construction snapshots it
  at the updated pin, so the obsolete `JobExecutor@@zonebuf` schema alias is
  removed. `jobs_zonebuf` remains one allocation with the same size and ABI.
  `tick.sh` rejects a copied owner and observes every actual ring read. The
  five array-bank aliases remain in the representation table and schema;
  `Reference.check_aliases` still requires their object identity.

`renderer_zonewin` stays a separate store, the direct path's. The executor's
three banks and two schedule columns were the same case -- `JobExecutor@@wall`,
`@@span`, `@@masked`, `@@sc_kind` and `@@sc_idx` were `resource` fields, prepared
copies with no writer, of the arrays `Jobs` pushes into -- and are now
`alias:jobs_wall` and so on. `jobs_sc_kind` and `jobs_sc_idx` were `output`
(written, never read back) because only the executor reads them; read through
their alias they are `persistent`, and `emit-schema.rb` makes that change only
for a target with an integer allocation fill, refusing any other (no DOOM field
reaches that refusal, so it has no control). Measured consequences on E1M1 at
the time, before `hud_text_ofs` added one field: 686 fields (441 arrays), 557 prepared, 117 stored in the stored lane, all
agreeing with the original, and six aliases each one object in the original.

* **through the 0007 adapter registry:** `spinel-core-adapter` generates each
  of the thirty-nine contracts' adapters -- one registry, the same file every time --
  and the lane links them with the kernel objects. A caller of the adapter
  links with it and fails to link without it, naming the adapter's symbols.
  `SOURCE_PORT_ADAPTER` then runs the game with THE CALLER HOLDING IDS, NOT
  POINTERS (`tests/doom-core/source-adapter.rb`): every resident field the
  mode uses is registry storage allocated at its declared element and count and
  filled through `store`; every call is the generated `invoke` over ids, with
  the result cell poisoned first; every pixel and cell compared is read back
  through `load`. `core_state` is ONE id, handed over once with the indices of
  its cells. Direct and queued over 600 tics: the same comparisons as the native
  lanes, every invoke status 0, the ring written and read through one id, and
  the reset through the registry. A REFUSED STEP ENDS THE SESSION, unlike the
  diagnostic lanes that count and go on: with a reset table missing the ring's
  counter, the first refused invoke -- `zalloc`, CAPACITY by name, at frame 130
  -- stops the game; nothing more is invoked, nothing is read back from the
  poisoned storage, every id is released and the run fails. After a session
  that succeeded, a diagnostic shows what a refusal does: a column naming a
  selector cell past `core_state` is refused (BOUNDS), after which its screen --
  the one participant it writes -- refuses a load and any step, while the state
  and colormap it only reads still load; `core_state` passed as both the
  reset's state and its table is refused (ARGUMENT) before the kernel runs;
  every id the lane allocated -- its own result and word cells included -- is
  released once, and then every id from 1 to the highest the registry handed
  out refuses a second release, so an id allocated and never released is found
  by id whether or not anything tracked it (a control allocates the result cell
  untracked, and that run fails naming id 2). A ring producer
  writing a second ring leaves the executor's view stale through the adapter as
  it does natively.

These are the adapter's C operations, the ones the generated Ruby module binds
with `ffi_func`; the lane reaches them from CRuby, where the game runs, through
Fiddle. A Full program built by the pinned compiler over the generated module
is not run here. Through the adapter a field is read back one call per element,
so the read-only check there compares only the fields of at most 65,536
elements, and says how many it compared.

Not covered: DOOM's own `doom_core_render` entry (task 7) calling these; a
pinned-compiler Full program over the generated modules; `Jobs#check`'s own
per-job checks and every `strict` raise of its interval-table checks; the
renderer's gathering that computes the wall and masked pushes' arguments, the
BSP walk that builds the visplanes, `emit_column`'s fuzz and masked branches and
the view setup around the planes; and job mode 4.

`Jobs#reset` IS PORTED (`dc_jobs_reset`), and which cells it resets is read
off the original rather than listed by hand: every integer field of a fresh
`Jobs` is set to a value reset never writes, the original's reset runs, and
the fields it wrote are the table -- 31 to 0, `fuzz_suffix` to 1. In the game
the port's reset runs after the original's at every frame, over the port's
cells or the session's slots, and each of the 32 cells is checked against
the field the original just wrote; over the session each is also required to
be `inout` for the render entry. A table without the ring's counter is caught
at the first frame that needs it, and the ring's slots go wrong after it.

### The job executor's run, compiled

`examples/doom/core/src/executor.rb` ports `JobExecutor#run` after its
`Jobs#check` call -- the schedule walk -- and `exec_wall`, `exec_span` and
`exec_masked`, fuzz columns included. Every bank, the schedule, the resources
and the ring are borrowed buffers; the schedule's length is `jobs_nsched`, a
`core_state` cell passed by index with the state once; the frame constants are
one-element buffers. The only change of shape is that a masked column keeps its
selector and reads the ring or the IWAD at each texel, where the original binds
one buffer per column. `dc_exec_run` answers how many fuzz columns it drew.

`Jobs#check`, which the original runs first and which raises on a bad bank, is
NOT ported: it stays Full's, and `tools/doom/core-migrated.tsv` has rows for the
four executor definitions and none for it. Neither is `@checked`, the run's
diagnostic counter. This is not `doom_core_render`, and
the tick ledger is not closed by it.

### The pushes and phase marks, compiled

`examples/doom/core/src/jobs.rb` ports `Jobs#push_wall`, `#push_span`,
`#push_masked`, `#mark_phase1` and `#mark_phase3`. A push stores its record in
its bank at the bank's count, counts it, and writes the kind and the record's
index into the schedule at the schedule's count. The counters (`jobs_nwall`,
`jobs_nspan`, `jobs_nmasked`, `jobs_nsched`, and the two phase marks) are
`core_state` cells by index; the banks and the schedule are the session's
`jobs_*` fields; the four capacities are prepared one-element buffers. The
original's `JobError` on a full bank or schedule is CAPACITY, and as with the
raise, a push refused at the schedule has already stored and counted its
record. The schedule step is written out in each push: a helper the three
shared is reached from outside each entry's closure, which the kernel tool
refuses (measured, `unaccounted-ingress`), and that rule is not relaxed. The
push ARGUMENTS are still the original's -- the renderer's gathering is not
ported -- and `Jobs#check` stays Full's.

### The interval-table checks, compiled

`Jobs#check` has two parts, and only one is ported. Its own per-job checks
(#1-#3: a job's coordinates on the screen, its source offset aligned inside the
atlas or flat atlas, its colormap row, its fuzz phase) raise `JobError` on a bad
bank in every job mode, and no 0007 status says "invariant violated" -- porting
them is a status decision, so `Jobs#check` stays Full's. After them it calls four
checks -- `check_disjoint` over the phase-0 walls, `check_span_disjoint`,
`check_masked_k` and `check_wall_all` -- which build per-column (or per-row)
slot tables of the jobs there and keep frame statistics: the most jobs one
column holds, and how many pairs overlap. `examples/doom/core/src/checks.rb`
ports those four on the path job mode 2 takes, where `strict` is false: they
build the tables and count, and a column holding more jobs than its table has
slots is CAPACITY, as the ring overflows are. With `strict` (job mode 1) the
original also raises when a column holds more than its K_MAX or two jobs
overlap; those raises need the same status decision and are not ported. The
statistics are `core_state` cells by index, the tables the session's `jobs_*`
fields, the screen dimensions prepared one-element buffers. Each check is
written out whole: `check_disjoint` and `check_wall_all` differ only in their
range and counters, and a helper they shared would be reached from outside each
entry's closure.

### The plane spans and the planes, compiled

`examples/doom/core/src/planespan.rb` ports `Renderer#make_spans` and
`#map_plane`. For each column of a visplane `make_spans` compares its top and
bottom with the previous column's, emits a span where a run ends and records
the start where one begins; each span is `map_plane`: the row's distance and
x/y steps (computed once per plane height and kept in the row cache), the
length and angle for the span's first column, the source position, the light
row, the packed position and step `#draw_span` would push, and the push itself.
The flat base is `flattranslation[curpicnum] * 4096`, the expression of
`Textures#flat_atlas_base`, which has no row. The push is written out rather
than calling `dc_push_span`. A plane below the view gives a negative distance
and a light index below `zlight`'s start, which CRuby's Array would read from
the end; the entry refuses it (BOUNDS), an edge case records that, and DEMO1's
600 frames never reach it.

`examples/doom/core/src/planes.rb` ports `Renderer#draw_planes` -- the loop
(`dc_draw_planes`, from `pl_from` to the `lastvisplane` cell; the original's
start is 0, and a caller may start later) over a per-plane body
(`dc_draw_plane`) -- `#draw_sky_plane` (`dc_draw_sky_plane`) and
`#clear_planes`. `dc_draw_plane` sets `curpicnum` -- before it tests for the
sky, as the original does -- answers 1 for a sky plane, computes `planeheight`
and `planezlight` from the plane's height, light level, the view height and the
extra light, writes the plane's two sentinel columns and walks every column
through `dc_make_spans`. A sky plane's columns are texture columns: for each
column with a run the sky angle picks the texture column, the column cells are
set, and the job is pushed into the wall bank as `#emit_column`'s phase-0/1
branch pushes it (`push_wall` written out). `dc_clear_planes` resets the clip
arrays, the four plane counters and the row cache, and computes the base scales
through decision 0007's `fixed_div` (src/fixed.rb), which the renderer's own
`#fixed_div` is the same algorithm as. The entries are `dplanes` and `cplanes`;
f3211f6's `mspan` entry and 44a7d4b's `dplane` are gone, because a definition in
one entry's closure may not be called from outside it.

NOT PORTED: `#emit_column`'s fuzz and masked branches, and emit_column as the
walls reach it; `@ds_source` and `@dc_srcbuf`, the buffers only the mode-0 path
reads; the BSP walk and find_plane/check_plane that build the visplane arrays
and lastvisplane; `#render_player_view`'s view; `#extralight=`;
`Textures#animate`. In frame mode the lane loads the visplane arrays as the
original's loop found them, lastvisplane, viewx, viewy, viewz, viewangle,
extralight and flattranslation into the port's storage, and prints their
names; the sky texture's width masks, atlas bases, number, scale and middle are
prepared tables.

### What frame mode compares

`tests/doom-core/source-port.rb`'s `frame` mode runs both. At every one of the
original's pushes the port's push runs with the same arguments into the
port's own banks, schedule and counters, and the record, the schedule entry
and both counters must equal what the original just stored (`push-disagree`);
each phase mark likewise (`phase-disagree`). Plane spans are not pushed by the
lane, and the port takes ONE WALK. The original's draw_planes loop runs
unchanged, and after it one dplanes call walks every plane; then every span and
sky wall job it pushed, the schedule, nspan/nsched/nwall, curpicnum,
planeheight, planezlight, the column cells (when a sky column was pushed), the
sentinel columns, spanstart and the row cache must equal the original's, and so
must the number of sky planes it drew (`plane-disagree`). The lane's own
`push_wall` leaves the sky's columns to that walk: they are the only wall jobs
the original pushes inside draw_sky_plane, and the port pushes them itself. A
sky plane with no column run sets no column cell, so the cells are compared only
where a sky column was pushed: otherwise they hold what the unported wall loop
left. Before
each clear_planes the lane loads the port with what the original's clear_planes
found -- the four plane counters and the two clip arrays as the previous frame
left them, not the port's initial zeros, so that every write shows on every
frame -- and after the port's clear the clip arrays, counters, row cache and base
scales must equal the original's (`clear-disagree`), each mismatching field
counted by name. (At 44a7d4b the comparison was against the initial zeros: in
a run of that revision on macOS arm64 with the official LLVM 23.1.1,
tests/doom-core/tick.sh 224 of 224 with exit 0, deleting the lastvisplane and
lastopening writes left the 600-frame output unchanged. The loaded comparison
here is measured on Debian x86_64.) Each frame the four checks run over
the port's banks in the original's order, and every statistic, every count
table and every filled slot must equal the original's (`check-disagree`) --
`check_disjoint`'s x tables right after it, from a copy the lane takes after the
original's `check_disjoint`, because `check_wall_all` refills them. After each of DEMO1's 600 queued
frames the port's counters must be the original's, and the port's run draws
the PORT'S banks -- nothing is copied from the original's -- onto the port's
own screen, which is never reloaded from the original's; all 64000 bytes of it
must equal the original's screen. The fuzz columns are counted from the
ORIGINAL's banks (masked jobs with a phase and at least one row) and must equal
the port's count. `tests/doom-core/tick.sh` holds, measured:

* in Ruby, compiled (`SOURCE_PORT_NATIVE`), over the session and through adapter
  ids: 600 frames, 222093 wall and 168760 masked pushes; the planes walked by
  the port, its spans, its sky column jobs, its sentinel cells and its 600
  clears -- THE PLANE AND SKY COUNTS ARE NOT MEASURED AT THIS REVISION, because
  the frame lane's declared cases and expectations still describe the per-plane
  port and are regenerated in a later step. SKY COVERAGE IS THIN: every sky
  column DEMO1 reaches is in frames 572-599; before them its sky planes have no
  column run; 1200
  marks each equal, 2400 checks with every statistic equal and 1736382 filled
  slots compared (the statistics reach max_k 8, span_max_kx 7, masked_max_kx
  18, fuzz_max_kx 5, fuzz_n 246, wall_all_max_k 8; no two wall jobs or spans
  overlap in DEMO1, so the three overlap counts stay 0 and only the edge cases
  exercise them), 485278 jobs run, 35246 fuzz columns, 600 screens of 64000
  bytes compared, zero faults, every call or invoke status 0; over the session
  no `core_state` slot but the ones the pushes, marks, allocator and reset write
  changes and no read-only field changes, and through the adapter every id is
  released once;
* twenty controls, each changing one thing on the port's side:
  * on the banks, just before the run: the schedule reversed faults from frame 0
    (583 of 600 frames); every fuzz phase one later from frame 137, the first
    frame whose screen a shifted fuzz column changes (344); the previous frame's
    span bank written over the port's from frame 6, the first whose spans
    differ from the frame before (583). A wall bank read as spans is not the
    wrong-bank control, because a wall record read as a span names a row past
    the screen;
  * at the pushes: every wall push's schedule entry written into buffers nothing
    reads differs from the second push on (221493 pushes) and every screen
    differs; phase 1 marked from the span counter differs at every mark (600)
    and no screen does, since the executor does not read the marks; a wall
    capacity of 100 makes the 101st wall push of frame 0 CAPACITY (162093
    refused pushes, every screen different) -- through the adapter the first
    refusal ends the session and fails the run; and every wall push issued
    through the span push differs from the first push, and the compiled span
    check then refuses the records as BOUNDS at frame 0 (through the adapter,
    ending the session). That control needs the compiled entries: plain Ruby
    would read nil past its arrays, so it is refused there. The wrong phase
    counter also changes the phase-0 table built to it (1200 check faults);
  * at the checks: the phase-0 wall table started at the second job differs at
    every frame from frame 0 (600), and the span table left unbuilt on odd
    frames differs from frame 1 (687 faults). Two controls that looked natural
    did NOT fault over 60 frames and were dropped: the phase-0 table built over
    the whole wall bank, and `check_wall_all` writing a separate x table. The
    likely reason, not measured: until the first sky column (frame 572) there
    is no phase-1 wall job, so both tables hold the same jobs;
  * at the planes (the counts in this bullet and the next are NOT measured at
    this revision; they are regenerated with the frame lane in a later step):
    leaving every plane 1 more than a multiple
    of 3 empty differs in the counters after frame 0's walk (619 plane faults,
    589 screens); drawing the next plane's arrays in its place likewise (627,
    509); every plane's height loaded 1.0 high differs at frame 0's first span
    (600, 589); lastvisplane one lower differs in the counters at frame 0 (604,
    191); leaving the port's clear_planes out on odd frames differs at frame 1,
    first in lastvisplane (300 clear faults), and in the spans from frame 15
    (558, 89 screens); undoing the port's four counter writes differs from frame
    1 (599 clears; lastvisplane 599, lastopening 481, floorplane 585,
    ceilingplane 572 mismatches -- exactly the clears where the loaded value is
    not the cleared one); undoing its clip writes differs from frame 0
    (floorclip 600, ceilingclip 600). A
    version of dc_draw_plane that set curpicnum after the sky test -- the port's
    first -- is caught by the sky plane's curpicnum check: 162 plane faults, the
    first at sky plane 9 of frame 106, every screen still equal;
  * at the sky: a sky flat number no plane has walks the sky planes as flats --
    caught at frame 106, the first sky plane, by the sky-plane count (99 plane
    faults), and on screen from frame 572 (28); the sky texture middle 1.0 high
    and the sky scale 1 high each differ at frame 572's first sky column job and
    on its 28 screens. f3211f6's column-level controls went with its make_spans
    hook: skipping emission at a column is subsumed by plane-skip, the wrong
    height is plane-wrong-height, and the swapped column extents is not kept.
    Controls that did not test what they named were dropped: an x - 1 column,
    which read `distscale[-1]`;
  Ruby and compiled give the same numbers over 600 frames; over the session and
  the adapter the controls run for 200 frames and fault at the same first
  pushes and frames;
* the pushes' and marks' edge cases and the push's AddressSanitizer liar, above.

The game run is not under AddressSanitizer, as for the other entries.
