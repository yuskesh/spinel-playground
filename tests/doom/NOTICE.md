# Notices for `tests/doom/cases/`

The five test programs and their five recorded expectations in `cases/` are
GPL-derived, from the same source and revision as `examples/doom/`. The full
notice, the licence text and the statements the sources make about their own
origin are in [`../../examples/doom/NOTICE.md`](../../examples/doom/NOTICE.md)
and [`../../examples/doom/LICENSE`](../../examples/doom/LICENSE).

The two input scripts in `fixtures/scripts/` come from the same source:
`script1.txt` and `script2.txt`, originally `doom/test/`. Their comment lines
were translated into English (2026-11-23); their input lines are unchanged. They
drive `tests/doom/interactive.sh`, which replaces a human at the keyboard for
the frame comparison and replaces nothing about whether a real keyboard reaches
the game.

## Local changes on import

Four of the five `.expected` files are byte-identical to their originals.
`wad_and_picture.expected` has two lines whose trailing remark was translated
into English, with the matching `puts` in `wad_and_picture.rb` (2026-11-23).

Each of the five `.rb` files has exactly one kind of change: the
`require_relative` prefix, rewritten from `../lib/doom/…` to
`../../../examples/doom/lib/doom/…` because the library and the tests live in
different directories here and did not in the source tree. Seven lines in total
are affected — one in `bytes_le`, `info_and_span` and `palette_colormap`, two in
`fixed_and_bsp` and `wad_and_picture`. On 2026-11-23 their Japanese comments
(and the two printed remarks above) were also translated into English; the code
is otherwise unchanged.

`manifest.tsv` records the original digest and the local digest of every file
separately, so this distinction is machine-checkable rather than a claim in
prose: for these five files the two differ, and for every other imported file
they are equal.
