# GPL inclusion: the facts, and the decision they fed

**Resolved (2026-09-11): the import was approved and has been performed.** The
owner's acceptance of GPL-derived files in `examples/doom/` and `tests/doom/`
predates this page — decision 0006 is accepted for implementation and the
approval was given in the original handover. This document had recorded the
question as outstanding; that was my error, and the record of it is kept rather
than deleted.

Option 1 below is what was done: the sources are imported, GPL-2.0 licence text
is at `examples/doom/LICENSE`, and the notices are in
[`../../examples/doom/NOTICE.md`](../../examples/doom/NOTICE.md) and
[`../../tests/doom/NOTICE.md`](../../tests/doom/NOTICE.md). The facts gathered
below remain accurate and are what those notices are built from, so the page is
kept as the working-out rather than rewritten into a conclusion.

The open question that this page raised and that is **still open** is the last
one: decision 0006's task 3 would import patches against doomgeneric, which are
modifications of GPL C source rather than a reimplementation. Those are not in
this repository, are macOS-owned, and need their own notice when they arrive.

## What would be added, exactly

`tests/doom/manifest.tsv` is the complete list, with each file's byte length and
SHA-256. **46 files**, all Ruby, all from `spinel-llvm` at
`f8ad13c6d9dc990b116ba1c842c7881232f29585`:

| kind | count | what |
|---|---|---|
| entry | 3 | `doom/bin/{doom,sim_demo,record_demo}.rb` |
| lib | 33 | `doom/lib/doom/*.rb` — the port itself |
| test | 5 | the IWAD-independent probes |
| expected | 5 | their recorded combined-stream output |

Nothing else: no WAD, no binary, no experiment archive, no reference C source.

## Provenance of those files

- They are a **Ruby reimplementation**, written against a specification survey
  (the predecessor's R007) of the DOOM source release and of
  [ozkl/doomgeneric](https://github.com/ozkl/doomgeneric) (a Chocolate Doom
  derivative). They are not a translation of a C file, and no C source is
  copied into them.
- The predecessor's `doom/` tree carries **no `LICENSE` and no `COPYING`**. It
  holds `doom/README.md` and `doom/reference/README.md` only. So there is no
  upstream notice to carry over: one would have to be written.
- The behaviour is pinned to a specific reference: doomgeneric at
  `dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`. The predecessor keeps that clone
  and its build outputs **outside** the repository and tracks only patches —
  the same discipline this repository already applies to the IWAD.
- The DOOM source release is GPL-2.0. The plan's own wording treats a
  reimplementation developed against it as GPL-derived, which is why it asks for
  this decision rather than assuming either answer.

Note that Task 3 imports **patches against doomgeneric**, which are
unambiguously derived from GPL C source. That is a separate, and stronger, case
than the Ruby port, and it is macOS-owned. A decision taken here should say
whether it covers that too.

## What the repository's own rules already require

`AGENTS.md` says to record "the source revision, original paths, local changes,
applicable notices, and reproduction instructions for imported components" and
to "preserve required upstream notices and third-party attribution, even when
they use a different language". The first four are already recorded in
[../provenance.md](../provenance.md). **Applicable notices are the open item**,
and they cannot be copied from upstream because upstream has none.

`docs/provenance.md` also records that this project has an "undecided
project-wide licence". A GPL import interacts with that, and this decision is
the first that would.

## The three options, stated plainly

1. **Import under a recorded GPL-2.0 notice.** Add `examples/doom/` and the
   fixtures with a `LICENSE` and a per-file or per-directory notice naming the
   DOOM source release and doomgeneric, and record the owner's acceptance in a
   decision record. The runner needs no change: `stage-sources.sh` prefers
   `DOOM_SRC`, which defaults to `examples/doom`.
2. **Do not import; keep staging.** The checks keep running exactly as they do
   today, from a read-only predecessor checkout named by `DOOM_SRC_GIT`. The
   cost is that `tests/doom/run.sh` is not self-contained — a clean checkout
   needs that second path — and decision 0006's "first code commit has
   executable validation" is satisfied only in the presence of that checkout.
3. **Import a reduced set.** The five probes plus their expectations are 10
   files, and their `require_relative` closure adds 8 library files — `bytes`,
   `errors`, `fixed`, `info`, `palette`, `picture`, `tables`, `wad` — for **18
   of the 46**. The remaining 28 are the playable game and the two other entry
   points, which tasks 3 and 4 need. This would make `tests/doom/` self-contained
   without importing the game, at the cost of splitting the decision in two and
   leaving `examples/doom/` empty for now.

**Option 1 was taken.** All 46 files are imported, the licence text is in
place, and the notices record the origin without asserting authorship. The
manifest now carries the original path, byte length and digest of every file
*and* its local path, byte length and digest, so a file changed on import is
distinguishable by machine from one that was not: 41 are byte-identical, and the
five test programs differ only in their `require_relative` prefixes.

`tools/doom/verify-sources.sh` checks the imported tree against the manifest in
both directions and reads nothing outside this checkout.
`tools/doom/audit-origin.sh` re-derives the original digests from a read-only
predecessor checkout; it is an audit and is never called by the build or the
test suite, so the predecessor is not a build dependency.
