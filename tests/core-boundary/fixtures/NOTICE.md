# Notices for the extracted DOOM fixtures

Three directories beside this file hold Ruby that was **copied and adapted from
`examples/doom/`**, which is GPL-derived. They are therefore GPL-derived too,
and are redistributed under the GNU General Public License, version 2, whose
text is in [`../../../examples/doom/LICENSE`](../../../examples/doom/LICENSE).

| directory | what was extracted |
|---|---|
| `capabilities/src` | the fixed-point helpers and the angle normalisation |
| `framebuffer/src` | the wall column, the plane span and the fuzz column |
| `slots/src` | the thinker list and the mobj slot allocator |

Nothing else under `fixtures/` is derived from DOOM. `schema/`, `arithmetic/`,
`buffers/` and `adapter/` were written for this project, and `closure/` reads
the Full tree to count what is in it without copying any of it.

## Where each extracted file came from

Each directory carries a `provenance.tsv` naming, per file, the original it was
taken from and the upstream C function behind that. Each extracted source also
names its own origin in its own header — a record kept only in a side table is
one a reader of the source never sees — and `capabilities.sh`,
`framebuffer.sh` and `slots.sh` each check both, so a file that lost its
attribution fails a lane rather than going unnoticed.

The originals are all in `examples/doom/lib/doom/`, whose own import is
recorded in [`../../../examples/doom/NOTICE.md`](../../../examples/doom/NOTICE.md)
with the source repository, the source revision and the per-file digests.

## What was changed, and what that means here

These are adaptations, not copies: each source lists every change it makes to
the original, in the source, and each is held to the original's own answers by
a lane that runs both. The adaptations are spelling changes within the checked
subset — parameters for instance variables, `[]` for `getbyte`, an if/else for
an `unless` — with one exception that is marked as such in
`slots/src/thinker_collect.rb`, where the sweep is given a step bound the
original does not have.

**No authorship, copyright holder or licence beyond what the sources state is
asserted or inferred here.** The upstream attributions the extracted files
carry — `DG/r_draw.c`, `DG/p_tick.c`, `DG/m_fixed.c`, `DG/p_mobj.c` — are
recorded as the Full sources state them, and are not an independent claim about
what those files contain.
