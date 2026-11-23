# Notices for `tests/doom/reference/`

The patches in `patches/` modify C source from [ozkl/doomgeneric](https://github.com/ozkl/doomgeneric),
a Chocolate Doom derivative of id Software's DOOM source release. They are
GPL-derived and are redistributed here under the GNU General Public License,
version 2, whose text is in [LICENSE](LICENSE) beside this file.

**This is a different provenance from `examples/doom/`.** That directory holds a
Ruby reimplementation written against a specification survey; these are
modifications of the GPL C source itself. The two are covered by separate
notices on purpose.

Everything below is recorded from the sources or from this repository's own
records. **No authorship, copyright holder or licence beyond what the sources
state is asserted or inferred here.**

## Where these files came from

| | |
|---|---|
| source repository | `spinel-llvm`, the predecessor project |
| source revision | `f8ad13c6d9dc990b116ba1c842c7881232f29585` |
| how obtained | read from Git objects with `git show`; that checkout was not modified |

Original paths, byte lengths and SHA-256 digests, beside the local ones, are in
[`manifest.tsv`](manifest.tsv). **Every file is byte-identical to its original**,
except `04-e051-dump-hooks.patch` and `05-e052-dump-hooks.patch`: the Japanese
comments in their added lines were translated into English on 2026-11-23, with
the same line counts, so every hunk applies as before.
The only thing the local names add is the application order, which
`doom/reference/build_reference.sh` fixes:

| local name | original path |
|---|---|
| `patches/01-r007-headless.patch` | `docs/researches/r007_probes/reference/doomgeneric_headless.patch` |
| `patches/02-e044-dump-hooks.patch` | `doom/reference/e044_dump_hooks.patch` |
| `patches/03-e047-dump-hooks.patch` | `doom/reference/e047_dump_hooks.patch` |
| `patches/04-e051-dump-hooks.patch` | `doom/reference/e051_dump_hooks.patch` |
| `patches/05-e052-dump-hooks.patch` | `doom/reference/e052_dump_hooks.patch` |
| `patches/06-e053-dump-hooks.patch` | `doom/reference/e053_dump_hooks.patch` |

## What they apply to

doomgeneric at `dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`. That clone and every
build output stay **outside** this repository — only the patches are tracked,
which is the discipline the predecessor used and the same one this repository
applies to the IWAD.

The first patch makes the build headless and adds the frame hash; the rest add
dump hooks and delete almost nothing (the predecessor records E044 and E047 as
addition-only, and E051/E052/E053 as removing one line each). No doomgeneric
source file is tracked here.

## The FNV basis: two hash functions, not one

`1469598103934665603` appears in three of the patches, but only one of them
*uses* it, and the distinction decides whether two files may be compared.

- **`patches/01-r007-headless.patch` uses it.** Its `fnv1a64` starts from
  `1469598103934665603ULL`, which is one digit short of the real FNV-1a 64-bit
  offset basis `14695981039346656037`. Every hash that harness wrote —
  including the whole of `demo1_hashes.tsv` — is computed with it.
- **`patches/02-e044-dump-hooks.patch` and `patches/05-e052-dump-hooks.patch`
  use the correct basis** and only *mention* the short one, in comments that
  exist to warn about exactly this. E044's says it plainly: the R007 golden "is
  self-consistent and still a perfectly good hash, but a Ruby side written from
  the *documentation* will not reproduce that column."

So the reference produces **two different hash functions under the same name**:
the R007 harness's `fnv1a64` and the E052 hook's `fnv1a64`. Their outputs are
not comparable, and a column named `fnv1a64` does not by itself say which one
produced it. The distinguishing evidence is the file's header shape — see the
next section.

The constant is preserved verbatim and must stay that way. Changing it would
invalidate [`../fixtures/reference/demo1_hashes.tsv`](../fixtures/reference/demo1_hashes.tsv)
without any comparison failing: the numbers would still line up in shape and
mean something else.

## The golden

[`../fixtures/reference/demo1_hashes.tsv`](../fixtures/reference/demo1_hashes.tsv)
is imported byte for byte, 463,676 bytes, 5065 data rows. Its header is

```
#frame	gametic	fnv1a64	sha256
```

— four columns, the **R007 layout**, which predates the `viewhash` column the
E052 hook adds. Two consequences, and both matter:

- The column a golden gate reads for a full-frame hash here is `fnv1a64`, index
  2, and there is **no view-only hash in this file at all**. A comparator
  written for the E052 five-column layout must not assume this file has the same
  shape.
- Its hashes come from the R007 `fnv1a64` with the short basis, so they are
  **not comparable with the E052 `frames.tsv`** even though both columns are
  called `fnv1a64` and both sit at index 2. `tests/doom/compare.rb` reads the
  E052 layout and does not read this file; the R007 golden is the input to its
  own gate, and keeping the two apart is deliberate.

Its first rows also show, independently of any patch, that the reference keys
frames by a monotonic `frame` number while `gametic` repeats: rows 0 and 1 are
both gametic 2, part of the 41-frame melt wipe. 41 wipe frames plus 5024 level
frames is the 5065 rows here.

This golden is **not regenerated during import**, and nothing in this repository
regenerates it.

## Scope

This notice covers `tests/doom/reference/` and the golden in
`tests/doom/fixtures/reference/`. The Ruby port has its own:
[`../../examples/doom/NOTICE.md`](../../../examples/doom/NOTICE.md).
