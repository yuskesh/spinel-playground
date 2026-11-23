# spinel-vi — a small vi in Spinel

The editing core and the modal state machine are Ruby compiled by Spinel. The
terminal, grapheme clusters and POSIX regular expressions come through small C
seams: `shim/spinel_vi_term.{h,c}` over termbox2, `shim/spinel_vi_grapheme.c`
over libgrapheme, and libc's `regcomp`/`regexec`. The buffer is a piece table
(`lib/editor_core.rb`). Ported from spinel-llvm `463d49dd` (its P009,
experiments E097 and E101–E106); see [provenance](../../docs/provenance.md).

## Run

```sh
examples/spinel-vi/build.sh                 # -> build/spinel-vi, offline
examples/spinel-vi/run.sh path/to/file      # the real terminal (termbox2)
SPINEL_VI_BACKEND=fake examples/spinel-vi/run.sh path/to/file   # a normalised draw log
```

The build needs only `vendor/spinel/bin/spinel`. It uses the vendored termbox2
and libgrapheme sources, never a system package or the network.

Implemented: Normal, Insert and Command-line modes; `h j k l`, `i a o`, `Esc`,
`x`, `dd` / `yy` / `p`, `u` / Ctrl-R, `:w` `:q` `:wq` `:q!`, and `/pattern`
with `n` (POSIX BRE; no substitution yet). Buffer offsets and regex matches are
in bytes; the cursor, deletion and drawing move by extended grapheme cluster,
so combining marks, skin tones, ZWJ sequences and flags are one unit. Keyboard
input is ASCII. Files must be UTF-8 with LF line ends; CRLF, NUL, invalid UTF-8
and symlinks are refused on load. `:w` writes a same-directory temporary file,
fsyncs it and renames it over the original.

## The terminal seam

`shim/spinel_vi_term.h` is the only terminal ABI Ruby sees. termbox2's
`tb_event`, enums and macros stay in C; Ruby's `ViTerm::Event` reads fields
through accessors the C compiler generates, and no pointer to a Ruby string or
array is kept on the C side. The fake backend (`SPINEL_VI_BACKEND=fake`, or any
value but `termbox2`) records events and draws as a normalised log, which is
what the tests compare, so no terminal emulator's behaviour reaches a golden.

`app.rb` and the probes are the Phase 0 ABI probe, kept with their own gate.

## Vendored C

| | termbox2 | libgrapheme |
|---|---|---|
| upstream | https://github.com/termbox/termbox2 | https://git.suckless.org/libgrapheme |
| revision | commit `385fec64778591f344aeaa5691c757025606f274` | tag `3.0.0` (object `ed6db91cea0117efb5d7f9cf705cafd9d7806236`), commit `bf20d2f7bce13c7d006a9ca442221399753bce9d`, Unicode 17.0.0 |
| licence | MIT, `vendor/termbox2/LICENSE` | ISC, `vendor/libgrapheme/LICENSE`; the Unicode License v3 for the generated tables, `vendor/libgrapheme/data/LICENSE` |
| kept | `termbox2.h` (single header, `TB_IMPL` in one TU) | `src/{util,utf8,character}.c`, `src/util.h`, `grapheme.h`, `gen/{character,types}.h` ([SNAPSHOT.md](vendor/libgrapheme/SNAPSHOT.md)) |

Both are trimmed to what the editor compiles, with their notices.

## Checks

`bash tests/spinel-vi/run.sh` builds everything and runs the example's own
gates (`test/run-gates.sh`, `test/run-editor-gates.sh`,
`test/run-e103-gates.sh`, which include real-PTY runs through `script` and a
perl watchdog) and the Spinel legs of the piece-table, search and Unicode
checks. The same fixtures under CRuby (`test/core_oracle.rb`,
`test/core_flat_oracle.rb`) are oracles and are not run.

## Limits

- Terminal restore is verified on the normal path only; not through a Ruby
  exception or a signal. Mouse input and real user-driven resize ordering are
  unverified.
- Emoji width, bidi and font shaping in a real terminal are unverified; a
  keycap sequence is refused rather than guessed.
- No visual mode, registers beyond one, marks, windows or substitution.
