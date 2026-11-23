# The two source aliases, and what is NOT settled about them

`tools/doom/core-acquired.tsv` answers "how long is this field" for every
field the tree never allocates. Two fields in `Doom::Renderer` have no answer
in it, and the audit names them and refuses:

    Renderer@@ds_source   (stored, typed string, allocated nowhere)
    Renderer@@dc_srcbuf   (stored, typed string, allocated nowhere)

Both begin as `""` and are rebound during rendering to bytes that belong to
another field:

| where | bound to |
|---|---|
| `examples/doom/lib/doom/render.rb:302` | `@ds_source = ""` |
| `examples/doom/lib/doom/render.rb:424` | `@dc_srcbuf = ""` |
| `examples/doom/lib/doom/render.rb:1328` | `@textures.flatdata(@pl_picnum[pl])` |
| `examples/doom/lib/doom/render.rb:1370` | a sky column buffer |
| `examples/doom/lib/doom/render.rb:1919` | `@textures.texdata(tex)` |
| `examples/doom/lib/doom/render.rb:2350` | `@wad_data` |
| `examples/doom/lib/doom/render.rb:2364` | `@zonewin` |

So they are not storage with a length. They are a CHOICE OF REFERENT, made
per column, and the byte they are read at is `@dc_srcofs` beside them.

## What this file does not do

It does not give them a count. Writing one would be a fabrication in a new
place: the length of the largest thing they can point at is not their length,
and copying those bytes into the snapshot would duplicate bytes the atlas and
the WAD fields already carry.

It also does not carry a marker meaning "alias, excluded from the schema".
That was proposed and REFUSED on review: decision 0008's plan for task 5 asks
for an accounting of every reachable field AND every source alias, and
excluding the field does not account for the choice of referent — it deletes
the question. Which buffer was selected is part of the state a tick reaches.

## Status

THE REPRESENTATION IS DECIDED. `docs/core/doom-source-alias.md` records it:
`RES_NONE = -1` with `RES_ATLAS`..`RES_FLAT` unchanged, one base per column in
the existing `dc_srcbase`, `ds_srcres`/`ds_srcbase` for the span, and the
per-producer pairs. What remains is IMPLEMENTATION, and it is sequenced behind
the initial-value work and condition (B) in that document -- not behind a
decision. The audit stays red on these two until the implementation lands,
naming them rather than inventing a count.

Everything else in the acquisition table is complete: 68 rows declared, 68
used, no dead rows, and no array or buffer left at an invented `fixed:1`.

WHAT IS BLOCKED ON THAT DECISION IS ONLY THIS. The reference's remaining 18
shape refusals, the DOOM session's connection to the real registry, and task 6
onward do not depend on it and are not waiting for it.

# What the prepared comparison is evidence of

`tests/doom-core/state.sh`'s prepared lane builds its session by slicing each
field's bytes out of the reference snapshot, so its 220-of-226 agreement is
evidence that the bytes survive the route — schema order, offsets, lengths,
the comparator. **It is transport evidence.** It says nothing about whether
the prepared state matches what Full's own preparation produces, because
Full's preparation is not in that path.

`Doom::Core::Resources.prepared` produces prepared bytes for 146 of the 226
fields, and `tests/doom-core/build-prepared.rb` compares those against the
original both directly and through a real `Session`. The remaining 80 are
named in `<layout>.unsupported` with their origin and reason.

**The 146 are not one kind of evidence.** 40 come from packed constants in
`Doom::Info` and `Doom::Tables`, where Full building the table is a second
read of the same literal. 106 are read off objects Full constructs — the
level, the game, the sprites, the renderer — which is the construction the
reference performs too, so what agreement shows there is the schema and
session route: layout, offsets, lengths, and the binding of a prepared name
to one field. The run reports the two counts separately and writes the
per-field split to `<layout>.kinds`.

**The configuration is one configuration.** E1M1, episode 1, skill 2,
setblocks 10, resscale 1, trace false — the same one `build-reference.rb`
builds. `SKILL`, `SETBLOCKS` and `RESSCALE` are optional arguments with those
defaults; `trace` is not an argument and is fixed false. No other
configuration has been compared.

The stored subset is a different comparison, and the difference matters: it
compares the original against a session built from **the current schema's
initial values**. Its two sides have different origins, which is why it can
differ and does — but it is not the verification of every defined initial
cell, because 364 of the schema's initials are the assumed zero rather than a
derived one. (364 is the emitter's count, which is what the schema holds; 375
is the audit inventory's `UNDERIVED` count, a different measurement of a
different file. They are not interchangeable and I had been using the larger
one for both.)

Deriving every initial statically is **not** the requirement — Full may
initialise correctly and carry the value. The requirement is that every
defined initial cell agrees for the same WAD and configuration, and that is
not yet shown.

# Why the session connection waits on the producers

`Doom::Core::Session.open` refuses a prepared name it was given no bytes for:
`"… wants prepared:NAME, which Full did not prepare"`. That refusal is
deliberate — it is what stopped prepared fields becoming substitute zeros —
and it means **a session cannot be opened with 40 of the 226**. So putting
Full's produced bytes through a real session is not a step that can be taken
before the producers cover all 226; the order is forced by the session's own
contract, not chosen.

Of the 186 not yet produced, 158 have no row in this table at all, because it
records fields with NO allocation site and those 158 have one. Recording how
Full obtains a field that it allocates is a different question from recording
where an unallocated field comes from.

## What "produced by Full" can and cannot mean for those fields

For `Doom::Info` and `Doom::Tables` the producer is a packed constant, and Full
building it is genuinely a second path to the same bytes.

For a field like `Level@sector_floorheight` there is no second path: Full
obtains it by loading the level, which is what the reference does too. For
those fields the comparison's content is **the schema and session route** —
layout, offsets, lengths, slot indices, the binding of a prepared name to one
field — and not a second independent measurement of the value. That is worth
checking and it is a smaller claim, so it should be counted and named
separately rather than folded in with the table fields.
