# libgrapheme snapshot

- **source**: `https://git.suckless.org/libgrapheme`
- **tag**: `3.0.0`
- **annotated tag object**: `ed6db91cea0117efb5d7f9cf705cafd9d7806236`
- **commit**: `bf20d2f7bce13c7d006a9ca442221399753bce9d`
- **Unicode data**: 17.0.0
- **license**: ISC (`LICENSE`)

E105 puts only `src/util.c`, `src/utf8.c`, `src/character.c` and the
offline-generated `gen/character.h` into the editor TU. The case, word, line
and bidi modules are not included.

## Trimmed in spinel-extended (2026-09-23)

Only the files the editor's translation unit reaches are kept: `src/util.c`,
`src/util.h`, `src/utf8.c`, `src/character.c`, `grapheme.h`, and the generated
`gen/character.h` and `gen/types.h`, with `LICENSE` (ISC), `README` and
`data/LICENSE`. `gen/character.h` is generated from the Unicode Character
Database, so the Unicode License v3 that accompanied that data in the snapshot
(`data/LICENSE`) is kept with it; the data files themselves are not.
