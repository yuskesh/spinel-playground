# 0036: A per-slot record of the collector, for watching it work

- Date: 2026-11-12
- Status: Accepted by the owner on 2026-11-12 (the proposal: a fork patch,
  the pin move with the fork push, this record, `tools/gcviz`, `tests/gcviz`
  and an animation).
- Scope: the hosted native runtime's collector (`vendor/spinel/lib/sp_gc.c`,
  `lib/sp_slab.c`), in an opt-in archive only. Single-threaded programs.

## Context

The owner asked for an animation of a real program's memory: the stack's
roots, young and old objects, strings and payloads, with promotion from young
to old and sweeps freeing what is no longer used. `GC.stat` gives totals per
collection, not the life of each object, so an animation drawn from it would
have to invent where each object is and when it dies.

The runtime already notes each slab slot's allocation, survival and sweep for
its verifier (`sp_slab_note`, under `sp_slab_verify_on`). Those sites are the
events an animation needs; nothing records them.

## Options

1. **Totals per collection.** `GC.stat` after each step: no vendor change, but
   the animation would have to invent each object's place and death.
2. **One record per slot.** A vendor patch on the verifier's note sites: each
   object's real allocation, promotion and sweep. The owner chose this, with
   a small example program written here.

## Decision

1. **A fork patch, opt-in at build time.** Commits `8e1ac9e2c`,
   `edb7761b7` and `c23d82a7c` on the fork's `gc-events` branch add
   `SP_GC_EVENTS`. `make events-runtime` builds `lib/libspinel_events_rt.a`
   with it, and `gcviz-build` compiles the program with it (the object pools
   are in the runtime headers); `libspinel_rt.a` is not rebuilt and
   its sources read the same tokens as before (`SP_SLAB_NOTING` expands to
   `sp_slab_verify_on` without the switch).
2. **Opt-in at run time.** In the events archive, `SPINEL_GC_EVENTS=FILE`
   records: each slot's allocation (an object's scan function names its
   class), survival with whether it was promoted, explicit free and sweep;
   each collection's start with its root stack, frames expanded; the slots
   still allocated at exit (a census); marks the program places; and, after
   each allocation and each collection's start, the return addresses of the
   stack behind it, read from the unwind tables. Blocks malloc'd outside the
   slab (the slab off, past `SP_SLAB_MAX`, or the slab full) are recorded
   too: allocation, reuse from a pool, explicit free, sweep from a list and
   survival, so a run with `SPINEL_GC_SLAB=0` can be set beside one with the
   slab (the owner's request, 2026-11-12). Records
   go into storage mapped at start-up, so recording allocates nothing on the
   heap it watches, and the file is written at exit. `SPINEL_GC_EVENTS_MAX`
   caps the count (default 2^20) and the header counts what was dropped.
3. **Named apart from spinel-llvm's L8.** That unapproved predecessor patch
   used `SPINEL_GC_TRACE`; this one does not take the name.
4. **Tools here.** `tools/gcviz/gcviz-build` compiles a program with the pinned
   Spinel and links the events archive (binding `gcviz_mark(id)` through
   Patch 1's `SPINEL_EXTERN_METHODS`); `tools/gcviz/gcviz-events.rb` reads,
   checks and converts a record; `tools/gcviz/example.rb` is the animated
   program.
5. **Source lines from the program's own debug information.** Spinel writes
   `#line` directives naming the Ruby file, so with `-g` (which
   `gcviz-build` passes) `llvm-symbolizer` resolves a compiled Ruby frame to
   its `.rb` line. The owner asked (2026-11-12) for the replay to follow the
   source; this is the precise way, chosen over marks placed on every line.
6. **Checked by replay, not by comparison.** `tests/gcviz/run.sh` replays a
   record: nothing dropped, every sweep and survival names a live slot, and
   the census names every slot the replay left live, every allocation has
   its stack, and the example's allocations resolve to the lines that make
   them. Planted defects fail it.
   No other implementation is consulted, and the default build is not compared
   with the previous pin's: the source shows the switch's absence leaves it as
   it was.

## Limits

- The census at exit walks the slab, so it names slab slots only; a run with
  the slab off has none. Malloc'd blocks are checked by replay alone.
- A malloc'd block's size is what the C library reports as usable (glibc,
  macOS), not what was asked for; elsewhere it is 0.
- References between objects are not recorded; the roots are.
- The allocation fast paths step aside while recording, so a recorded run is
  slower and its pacing is not a measurement.
- With threads the record is not safe: the buffer has no lock. A collection
  that would run helper threads stops the record with a message.
- At most 12 frames are kept per stack; a deeper program's outer frames are
  lost. A frame is a return address, so an inlined call resolves to the
  lines of the whole inlined chain, which the tool reads innermost first.
- Promotion happens in place (a bit in the chunk's old bitmap). An animation
  that draws young and old as separate places is drawing generations, not
  addresses.
