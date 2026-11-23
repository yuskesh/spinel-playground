# Task 1: inventory and the pinned compatibility checkpoint

Decision [0006](../decisions/0006-doom-hosted-import.md), plan task 1.

**Status (2026-09-11): passed.** The ledger is complete, the IWAD is fetched
with a checked digest, DEMO1 replays in full with the renderer, and both stress
segfaults have an identified cause with a reproducer and a control. Two minimum
diffs are proposed and neither is applied; the pin is not moved.

Sections below are cumulative and some record **earlier observations of the same
run**. Where an earlier reading was superseded it is labelled with its date and
kept, rather than rewritten, so the order of discovery stays legible. The
authority for current state is this block and the `Task 1 gate` section at the
end; they agree.

A verdict of "not reproduced" below means exactly that: the reproducer ran
clean **here, on this pin, under the conditions stated**. It is not a claim that
a fix is present upstream. Where the presence or absence of a fix was actually
read in the pinned source, that is said explicitly.

Debian x86_64, LLVM/Clang 23.1.1, Extended `0655b4e` with pin `cad0ad14`.
Source read from `spinel-llvm` Git objects at
`f8ad13c6d9dc990b116ba1c842c7881232f29585`; that checkout was not modified
and nothing here depends on an untracked file in it.

## Dependency closure, computed rather than assumed

Each entry's `require_relative` graph was walked through Git objects.

| entry | files in closure |
|---|---|
| `doom/bin/doom.rb` | 32 |
| `doom/bin/sim_demo.rb` | 28 |
| `doom/bin/record_demo.rb` | 29 |
| union | 34 |

All references resolved; none dangling.

The plan's three specific claims were checked, not taken on trust:

- `jobs.rb` and `executor.rb` enter through `render.rb` — confirmed:
  `render.rb` requires `executor`, and `executor.rb` requires `jobs`.
- `hires.rb` enters through both `doom.rb` and `sim_demo.rb` — confirmed,
  and it is required by those **entries** directly, not by any library file.
- `render_gpu.rb` is in the interactive closure only — confirmed. The files
  unique to the interactive entry are `doom.rb`, `input.rb`, `record.rb`,
  `render_gpu.rb` and `video.rb`.

## The five IWAD-independent probes

Assembled in disposable scratch from Git objects, compiled with the pinned
Extended compiler and `--cc=/opt/llvm-23.1.1/bin/clang`, then run. Exit
status was captured **before** any comparison.

| probe | compiled | CRuby | compiled vs `.expected` | CRuby vs `.expected` | stderr empty |
|---|---|---|---|---|---|
| `bytes_le` | exit 0 | exit 0 | match | match | yes |
| `fixed_and_bsp` | exit 0 | exit 0 | match | match | yes |
| `info_and_span` | exit 0 | exit 0 | match | match | yes |
| `palette_colormap` | exit 0 | exit 0 | match | match | yes |
| `wad_and_picture` | exit 0 | exit 0 | match | match | yes |

The `.expected` files record a **combined** stdout+stderr stream, so the
comparison is against that concatenation, and empty stderr is asserted
separately rather than inferred from the match.

This reproduces the macOS side's result on a second host and toolchain.
It does **not** establish compatibility: these five probes were never
claimed to cover the eleven compiler batches, and the ledger below is what
the checkpoint turns on.

## Probe closure, with source hashes

| source path at `f8ad13c6` | blob |
|---|---|
| `doom/lib/doom/bytes.rb` | `7034de6e3136` |
| `doom/lib/doom/errors.rb` | `9752999aaa5d` |
| `doom/lib/doom/fixed.rb` | `beaf59d2e016` |
| `doom/lib/doom/info.rb` | `baf392df2159` |
| `doom/lib/doom/palette.rb` | `8e9d65980757` |
| `doom/lib/doom/picture.rb` | `2e49db6857c0` |
| `doom/lib/doom/tables.rb` | `ef9f42d6b20c` |
| `doom/lib/doom/wad.rb` | `ec090209aab2` |
| `doom/test/bytes_le.rb` | `2e9c15458000` |
| `doom/test/fixed_and_bsp.rb` | `964144e788a0` |
| `doom/test/info_and_span.rb` | `417906e377d9` |
| `doom/test/palette_colormap.rb` | `ab8a9f551a24` |
| `doom/test/wad_and_picture.rb` | `097339bb5bb0` |

## The 11-batch compatibility ledger

Every reproducer was located in the fork commit that carries its batch, or in
the source experiment record where the batch shipped no test, and executed here
on the Extended pin with `--cc=/opt/llvm-23.1.1/bin/clang`. Exit status was
captured before comparison. Nothing below is inferred from Git ancestry.

| # | fork commit | reproducer | on the pin | verdict |
|---|---|---|---|---|
| 1 · B1 | `99a5fc49` | `ctor_yield_inline_self_rooted` | matches; 0 anomalies in 10 stressed runs | not reproduced here |
| 1 · B2 | `99a5fc49` | `hash_merge_chain_rooted` | wrong answer (line 3 `false` → `true`); **SIGSEGV under stress** | reproduced defect; cause identified below as two unrooted merge promotions |
| 1 · B2 | `99a5fc49` | `hash_ctor_merge_clone_transform` (the commit's second B2 case) | matches; 0 anomalies in 10 stressed runs | not reproduced here |
| 1 · B3 | `99a5fc49` | `literal_string_markers` (named by the commit as B3's case) | matches normally; **SIGSEGV under stress, at some invocation paths** | reproduced defect; cause identified below as `sp_program_name` never marked |
| 1 · B4/B5 | `99a5fc49` | `bignum_rational_basic` (E021 C1/C2, `sp_box_brat` / `sp_brat_to_s`) | matches; 0 anomalies in 10 stressed runs | not reproduced here |
| 1 · B6 | `99a5fc49` | `regex_value_as_match_arg` (E021 D1, `sp_MatchData_inspect`, a SIGABRT fix) | matches; 0 non-zero exits in 10 stressed runs, and none at any argv[0] length from 6 to 80 | **not reproduced here, and the fix is verifiably absent** — see below |
| 2 | `61ffe24e` | `loop_source_rooted` | matches; 0 anomalies in 10 stressed runs | not reproduced here |
| 3 | `8154ec0c` | `nil_ivar_attr_writer_guard` | matches | not reproduced here |
| 3 | `8154ec0c` | `rescue_var_shadow_specialized` | matches | not reproduced here |
| 4 | `c02ca2cf` | `poly_exc_attr_builtin_fallback` | exit 1, output truncated after line 2 | reproduced defect |
| 5 | `7d8a6408` | `poly_builtin_arm_type_confusion` | **C compile error**: `sp_int` passed where `sp_RbVal` expected | reproduced defect |
| 6 | `da2d009d` | same fixture, extended by that commit | same compile error | reproduced defect |
| 7 | `8648d478` | `io_write_poly_binary` | `IO#<<` writes 2 bytes where 6 are expected; `write`/`syswrite` correct | reproduced defect |
| 8 | `cec1ec4d` | `io_print_puts_binary` | binary output differs (truncation at NUL) | reproduced defect |
| 9 | `883957dd` | `module_ivar_from_includer` | matches | not reproduced here |
| 9 | `bd2d276a` | `return_type_renarrow` | matches | not reproduced here |
| 10 | `f8512260` | `r028_repros/flt_pop.rb` | matches CRuby | not reproduced here |
| 11 | `ecbd0f2a` | `E146/array_paths.rb`, `more_paths.rb` | a nil Float prints `NaN`; CRuby prints empty | reproduced defect |
| 11 | `ecbd0f2a` | `E146/real_nan.rb` | matches CRuby | control: a genuine NaN is correct |

Batch 1 is **six** defects, not one, and the commit names a verification case
for each; they are listed individually above rather than folded into the two
tests the commit added.

Counting per reproducer: eleven do not reproduce here, eight reproduce, and one
— `literal_string_markers` — passes normally and fails under stress depending on
how the binary is invoked.

### "Not reproduced here" is not "fixed upstream": the B6 counter-example

`regex_value_as_match_arg` ran clean here in every condition tried — 10 stressed
runs, and a sweep of argv[0] lengths from 6 to 80 after that lever was
discovered. The macOS side reports a **SIGABRT** for it under stress.

Reading the pinned source settles which reading is safe. The fix that batch 1
B6 describes is a root on the builder in `sp_MatchData_inspect`. At `cad0ad14`
(`lib/sp_re.c:195`) the function is:

```c
const char *sp_MatchData_inspect(sp_MatchData *m) {SP_GC_ROOT(m);
  if (!m) return SPL("nil");
  sp_String *b = sp_String_new("#<MatchData ");
  sp_String_append(b, sp_str_inspect(sp_str_substr(...)));
  for (int g = 1; g < m->ncap; g++) { … sp_String_append(b, …); }
```

Only `m` is rooted. The builder `b` is not, and every `sp_String_append`,
`sp_str_inspect` and `sp_str_substr` in that loop allocates. **The fix is not
present at this pin**, so a clean Debian run cannot be evidence that it is. The
reproducer does exercise the function — its generated C carries 11 references to
`sp_MatchData_inspect` / `SP_BUILTIN_MATCHDATA`.

Recorded verdict: **not reproduced on Debian under the conditions tried; the
precondition for the defect is present in the pinned source; macOS reproduces
it.** Whether the macOS SIGABRT has the same underlying cause as the Debian `$0`
segfault is a **hypothesis, not a finding** — different fixture, different
helper, a different signal, and no macOS control was measured here. Chasing it
is not in this task, and no compiler fix is proposed for it.

The same discipline applies to every other "not reproduced here" row, including
B1, the second B2 case and B4/B5: those rows record a clean run under stated
conditions. The presence of a fix was **not** read in the pinned source for
them, and none of them should be cited as "resolved upstream".

### Relevance to this DOOM path: a preliminary screen, not a proof

*(2026-09-11, superseded for the four defects it could not settle. The screen
below is kept because it is what narrowed the search; see "Reaching the real
call sites" and "The binary-IO defects, at the call sites" for the
generated-code evidence that replaced it. Its own caveat — that a word count
cannot answer a dispatch or typing question — is exactly what those sections
answer, including the `File#write` case it leaves open.)*

Each reproduced defect was screened against the 34-file CPU closure. **This is a
text search, and a text search is not an absence proof for a question about
Ruby dispatch or types.** A method can be reached through a receiver whose type
is not written at the call site, through `send`, or through a builtin arm the
source never names. The counts below narrow where to look; they do not settle
it, and they are recorded as a screen.

The counts are over code with comment-only lines excluded.

| defect | construct it needs | occurrences in the closure |
|---|---|---|
| `hash_merge_chain_rooted` | `Hash#merge` | **0** |
| `poly_exc_attr_builtin_fallback` | a `rescue` of a builtin exception attribute | **0 `rescue` sites at all** |
| `poly_builtin_arm_type_confusion` | poly builtin arms under `rescue` | same: 0 `rescue` sites |
| `io_write_poly_binary` | `IO#<<` | **0** occurrences. The two binary writes are `File#write` on a `"wb"` file. The same fixture shows `write`/`syswrite` answering correctly *for its own receiver types* — which is not the same as showing that DOOM's two call sites take the same path, and that has not been checked |
| `io_print_puts_binary` | binary through `print`/`puts` | **0** — no `print`/`puts` site carries packed or binary data |
| E146 nil-float rendering | any `Float` | **0** `to_f`, `Float`, `FloatArray` or `.nan?`; the renderer is fixed-point (`FRACBITS = 16`) |

For the two build-level defects there is evidence that does not rest on the
screen at all:
**`doom/bin/sim_demo.rb` and `doom/bin/record_demo.rb` both compile on this pin**
(1,521,568 and 1,441,040 bytes). A C compile error cannot be latent.

### What `SPINEL_GC_STRESS=1` actually does

Checked in the pinned source rather than inferred from the name. It sets the
collection **threshold** to 2048 bytes and pins it — `sp_alloc.c:564` and `:578`
for the object heap, `sp_alloc.h:268` and `:298` for the string heap — and the
trigger that consults it is `sp_gc_bytes > sp_gc_threshold` (`sp_alloc.c:389`).
The header's own words are "shrink the collection threshold to a few KB so a
cycle runs at almost every allocation".

So it is **threshold-driven, not per-allocation**. An earlier draft of this
document called it "a forced collection at every allocation"; that was wrong.
`sp_gc_alloc_nogc` is a second allocator that does not consult the threshold at
all, and it is used in `sp_bigint.c`, `sp_cold.c` and `sp_gc.c`, so an
allocation on those paths does not create a collection point under stress
either.

What this means for the evidence below: stress makes a rooting hole *likely* to
be hit, not certain. A clean stressed run is weaker evidence than "every
allocation collected" would have been.

### The GC-soundness finding as first recorded (2026-09-11, superseded)

*This section is the reading taken before the causes were identified. It is kept
as written; the paragraph after it says which parts no longer hold.*

`literal_string_markers` **segfaults 10 times out of 10** under
`SPINEL_GC_STRESS=1` here, while passing normally. On macOS it segfaulted once
and passed on re-run; on Debian it is deterministic.

That fixture is **batch 1's B3 verification case**, not a test outside the
batches — the batch 1 commit says B3 "also clears literal_string_markers". An
earlier draft of this document listed it as unrelated, which confused "not a
test the commit added" with "not a test the commit is about". It is the latter's
opposite: the commit names it.

**The cause has not been established.** B3 was `sp_program_name` not being marked
in `sp_re_mark_globals`, and E021 records that `sp_program_name` affected 0 of
its 44 stress failures. A segfault at this fixture on this pin is not thereby
B3's defect, and it is not recorded as one. What is recorded is that a segfault
reproduces, deterministically, under stress.

`hash_merge_chain_rooted` (B2) segfaults under stress as well, on top of its
wrong answer in normal mode.

Because this class is not gated by an absent language construct, it was tested
directly rather than argued about: **the five IWAD-independent DOOM probes run
clean under `SPINEL_GC_STRESS=1`, three runs each — fifteen stressed runs, no
non-zero exit, no output difference.** Given what the flag actually does, that
is evidence that those probes do not hit a rooting hole at a 2 KB threshold. It
is not proof that the game does not, and the renderer and game loop cannot run
here without an IWAD.

**What of the above no longer holds.** Two claims were superseded later the same
day. "On Debian it is deterministic" was true of the invocation used and false as
stated: the fault depends on argv[0] length, and the same bytes are clean at
other paths — so the macOS "once, then clean" and the Debian "10/10" are the same
defect at different invocation paths. And "the cause has not been established" is
no longer the case: it is `sp_program_name`, allocated on the string heap by
`src/codegen.c:10459` and never marked by `sp_re_mark_globals`, which is B3's
named case after all. The section below carries the evidence. The fifteen clean
stressed probe runs stand as recorded, and the renderer and game loop have since
been run.

### Tests outside the eleven batches

Run for completeness because the macOS side reported them:

| reproducer | normal | GC stress |
|---|---|---|
| `bignum_rational_arith` | matches | not run |
| `rational_bigint_and_complex_zero` | matches | not run |
| `regex_value_as_match_arg` | matches | 10/10 clean here — **but the fix is absent from the pin and macOS reproduces a SIGABRT**; see the B6 note above |
| `literal_string_markers` | matches | **0/10 clean at the invocation path used** — clean at other argv[0] lengths; cause identified below |

`word_typed_user_return` is not in the old vendor's test directory at
`ecbd0f2a`; the macOS report names it as an E065 addition. Not run here, and
recorded as not run rather than as passing.

### Two cautions carried from the macOS report, respected here

- `poly_builtin_arm_type_confusion`'s own recorded expectation disagrees with
  CRuby on its last hash line, and CRuby hash ordering is randomised. It was
  compared against both here, and it fails to build in any case, so the
  expectation's status does not change the verdict.
- `literal_string_markers`' single macOS segfault was **not** assigned the
  historical cause when this was written. It has since been identified on Debian
  as `sp_program_name` never being marked, and the apparent intermittency is
  invocation-path dependence rather than randomness. That the macOS occurrence
  has the **same** cause is a reasonable hypothesis and is **not** established
  here: no macOS control was measured, and this document does not claim it.

## The IWAD, acquired with the digest checked before publication

`tools/doom/fetch-iwad.sh` fetches the Doom shareware 1.9 IWAD into an untracked
directory (`build/doom-wad` by default; `/build/` is already in `.gitignore`, and
`git check-ignore -v build/doom-wad/doom1.wad` confirms it against
`.gitignore:16`). **The IWAD is not committed and must not be.**

It is adapted from the predecessor's read-only `doom/tools/fetch_wad.sh`
(`f8ad13c6d9dc990b116ba1c842c7881232f29585`) with three changes:

- POSIX `sh` with `sha256sum`. `shasum` is not guaranteed on Debian.
- The temporary file is **owned** — `mktemp` in the destination, removed by a
  trap — instead of a fixed `.part` name two concurrent runs would share.
- The **length is checked before the digest**, so an error page or a truncated
  body is diagnosed as the wrong length rather than only as a digest mismatch.

The mirror list is the predecessor's, kept plural for the reason recorded there:
with a single URL, "the gate failed" and "the gate could not be run" become
indistinguishable when the host 404s. Verification runs for every mirror, and
again unconditionally at the end — including when the file was already present,
which covers a hand-placed or since-truncated copy.

Result on this host:

```
build/doom-wad/doom1.wad  sha256=1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771  bytes=4196020  (Doom shareware 1.9)
```

### Negative controls for the verification itself

A digest check that has only ever seen the right bytes has not been shown to
reject anything. Four controls, all run:

| control | construction | result |
|---|---|---|
| A — wrong length, already present | first 100 bytes of the real IWAD placed at the destination | refused: `is 100 bytes, want 4196020`, exit 1 |
| B — right length, wrong bytes | the real IWAD with one byte at offset 2097152 set to `0xFF` | refused: `has sha256 79f37433…`, exit 1 |
| C — no mirror reachable | every URL rewritten to a non-resolving host | refused, exit 1, and the destination is left **empty** — no partial file published |
| D — a mirror that 200s with the wrong bytes | a real 200-serving URL (git's `README.md`, 3808 bytes) prepended to the list | that mirror rejected by length, the next mirror used, correct IWAD published, exit 0 |

D is the one that matters most: it shows the fall-through is driven by
verification and not by transport failure, and that a 200 response is not
trusted.

## Scratch compatibility probe: the game actually runs

This is a **scratch compatibility probe**, in the sense fixed at the end of this
document: not Task 2, not an import, not product acceptance. Nothing here was
committed beyond this record and the fetch script.

### Which compiler, and a first run made with the wrong one

`spinel --version` reports the C compiler **Spinel will invoke on the generated
C** — `src/main.c:407` runs `"<cc_cmd> --version"` through `popen` and prints its
first line, where `cc_cmd` is whatever `--cc=` selected if that flag came first,
and `cc` otherwise. It says nothing about the compiler that built Spinel itself.
Both are in fact GCC here (`readelf -p .comment vendor/spinel/bin/spinel` →
`GCC: (Debian 14.2.0-19) 14.2.0`), which is why the distinction was easy to miss.

The first pass of this probe was run with the **default `cc`**, so the generated
DOOM C was compiled by GCC 14.2.0. Decision 0006 §"Compiler configuration" says
the selected Clang is to be passed explicitly, and that LLVM 23.1.1 Clang is the
selected C toolchain on both test hosts. So that pass used the wrong toolchain.

```
$ spinel --cc=/opt/llvm-23.1.1/bin/clang --version
spinel cad0ad148af0 (unreleased) [clang version 23.1.1 (… 6dfe1677ab8dffbc…)]
$ spinel --version
spinel cad0ad148af0 (unreleased) [cc (Debian 14.2.0-19) 14.2.0]
```

Everything below was re-run on **Clang 23.1.1**. The GCC results are kept rather
than discarded, and the two toolchains are compared directly, because a
cross-toolchain agreement is worth more than either run alone.

Compiler: `spinel cad0ad148af0`, `--cc=/opt/llvm-23.1.1/bin/clang`. The Spinel
binary at `vendor/spinel/bin/spinel` reports the pin, the submodule tree is
clean, and no source file is newer than the binary.

Sources: the predecessor's `doom/lib` and `doom/bin` at `f8ad13c6`, extracted
read-only into a scratch directory. No predecessor file was modified.

### DEMO1 is 5026 tics

The earlier runs at 2200 tics were **not** the demo's full length, and this
document previously called them that. DEMO1's true length is **5026 tics**,
established two independent ways:

- `sim_demo.rb:152` clamps with `n = ntics < demo.numtics ? ntics : demo.numtics`,
  so asking for 100000 tics reports what the demo actually has: `5026 tics`.
- Reading the WAD directory directly: the `DEMO1` lump is 20118 bytes; the
  vanilla layout of a 13-byte header plus 4 bytes per tic puts the `DEMOMARKER`
  (`0x80`) at offset 20117, giving 13 + 5026×4 = 20117. (`DEMO2` = 3836 tics,
  `DEMO3` = 2134 tics, by the same reading.)

2200 tics was 44% of DEMO1. The runs below are at 5026 — the whole demo, with
the terminator reached.

### What was run

| run | entry point | arguments | result |
|---|---|---|---|
| single frame, E1M1 | `bin/render_frame.rb` | `doom1.wad E1M1 1 <out>` | exit 0, 33 subsectors / 34 walls / 791 columns, `frame.bin` 64000 bytes = 320×200, `frame.ppm` |
| whole demo | `bin/sim_demo.rb` | `doom1.wad DEMO1 5026 <out> rand,player,mobj,frame` | exit 0, 8.1 s, **5026 frames rendered**, `prndindex=181`, `P_Random calls=25013` |

`render_frame`'s `frame.ppm` was inspected visually: it is the E1M1 opening
view — hexagonal floor, the flanking pillars, the nukage pool with the armour
bonus on it. Not a proof of correctness against the C oracle, which Debian does
not have; it is evidence that a frame is a frame and not noise.

The demo is genuinely being **replayed**, not merely ticked: `player.tsv`'s
`fwd` / `side` / `aturn` columns carry per-tic input from the demo lump, and
2195 of the first 2200 view hashes are distinct.

### Determinism, across two toolchains and two GC modes

Six runs of the whole demo with the renderer on. Every one produced the same
`rand.tsv`, `player.tsv`, `mobjs.tsv`, `frames.tsv` and stdout, compared with
`cmp` against the Clang normal run:

| run | exit | wall | collections | outputs |
|---|---|---|---|---|
| Clang, normal | 0 | 8.1 s | 70 (7 full) | reference |
| Clang, `SPINEL_GC_STRESS=1` ×3 | 0 | 23.0 / 23.3 / 23.1 s | 1497093 (11704 full), all three | byte-identical |
| GCC 14.2.0, normal | 0 | 8.5 s | 70 (7 full) | byte-identical |
| GCC 14.2.0, `SPINEL_GC_STRESS=1` | 0 | 24.2 s | 1497093 (11704 full) | byte-identical |

`render_frame` was also built and run under both toolchains: all nine outputs,
including `frame.bin` and `frame.ppm`, are byte-identical.

### The collector really ran, counted rather than inferred

A 2.9× slowdown is not evidence that the collector ran; it is evidence that
*something* got slower. The count is available from an existing diagnostic and
needed no new measurement code and no runtime change: `SPINEL_GC_STATS=1`
(`lib/sp_alloc.c:199–226`) prints a `[gc]` line on stderr, at most once a second
and again from an `atexit` handler.

```
[gc] 70 collections (7 full) in 0.29s of 8.1s wall (3.6%) …          # normal
[gc] 1497093 collections (11704 full) in … of 23.0s wall (69.6%) …   # GC stress
```

So the stress lane runs **1,497,093** collections against the normal lane's 70,
and spends 69.6% of wall time inside the collector. The stress figure is
*identical* in all four stress runs, across both toolchains — the collector runs
a deterministic number of times on this workload, which is a stronger statement
than the timing was.

### Reproducibility of the build, stated only for what was compared

Two Clang 23.1.1 builds of `bin/sim_demo.rb`, both 1,521,568 bytes.

Method: `cmp -l`, which compares **every byte of both files**; then each
differing offset mapped against `readelf -S -W` (sections) and `readelf -l -W`
(program headers) of the first binary.

Result: **exactly one** differing byte, at file offset 1485786 (`0x16abda`). It
falls in `.strtab` and **inside no `PT_LOAD` segment** — the four `PT_LOAD` file
ranges are `0x0–0x9420`, `0xa000–0x117df9`, `0x118000–0x13a438`,
`0x13b418–0x15fa00`. The byte is one digit of the PID in the temporary
translation-unit name `spinel_out_<PID>_0.c`, which the symbol table records.

**The claim is limited to these two builds, on this host, with this toolchain:**
every byte the loader maps was identical between them. This is not a statement
about Spinel builds in general, and it is not evidence for decision 0005's
reproducibility requirement, which covers a different artifact and a different
procedure. No reproducibility work is proposed here.

### Correcting the earlier size discrepancy

This document previously recorded `sim_demo` at 1,521,568 bytes, and the first
pass of this probe then reported 1,565,736 and called the earlier figure
unreproducible. Both figures are correct and the discrepancy is fully explained:
**1,521,568 is the Clang 23.1.1 build and 1,565,736 is the GCC 14.2.0 build.**
The earlier Task 1 compile used the selected toolchain; the first pass of this
probe did not. The "not reproducible" note is withdrawn.

## The two stress segfaults, identified

Both were open with "cause unidentified". Both now have a cause, a minimal
reproducer, and a control that removes the cause and the fault together. Neither
is fixed here: a compiler change is not pre-approved, so each is written up as a
proposed minimum diff for a separate decision.

### Why they looked intermittent, and were not

`literal_string_markers` segfaulted 10/10 through `make` and 0/10 when the same
source was compiled and run by hand. The binaries were not the difference — a
binary built by hand at the harness's own path is **byte-identical** to the one
`make` builds (`cmp` clean). The difference is **how the program is invoked**:

| argv[0] length | result (10 runs, same bytes) |
|---|---|
| 6 | segfault 10/10 |
| 7 | clean |
| 15 | clean |
| 32 (the harness's `/tmp/spinel-test.XXXXXX/test_bin`) | segfault 10/10 |
| 35 | segfault 10/10 |
| 69, 117, 118 | clean |

So the earlier "10/10 deterministic under stress" and the macOS report's "single
segfault" are the same defect seen at different invocation paths. It is
deterministic per path, with occasional ASLR-dependent survival (one run in five
at one padding size).

### `literal_string_markers`: `$0` is allocated on the string heap and never marked

`src/codegen.c:10459` emits, when the program reads `$0` or `$PROGRAM_NAME`:

```c
sp_program_name = argc > 0 ? sp_str_dup_external(argv[0]) : sp_str_empty;
```

`sp_str_dup_external` copies into the **GC string heap** with mark byte `0xfe`.
`sp_re_mark_globals` (`lib/spinel_rt.h:1307–1336`) is the root-marking hook, and
it marks the regex registers, `sp_argv.data[i]` for every ARGV entry, the ARGV
array cache, in-flight exceptions, proc homes, break values, at-exit hooks and
fiber storage — **and never `sp_program_name`**. `grep -n sp_program_name
lib/spinel_rt.h` returns exactly one line, the declaration at 1265.

So on the first `sp_str_sweep` after `$0` is materialised, the string is reaped
and the global dangles. This is the same defect the file's own ARGV comment
describes, in the same file, a few lines above: *"Without explicit marking they
get reaped on the first sp_str_sweep, leaving sp_argv.data[i] as a dangling
pointer… The exact length boundary triggering the segfault depends on malloc's
reuse pattern (so the bug surfaces non-deterministically by string length), but
the underlying issue is unconditional."* ARGV received the marking loop;
`sp_program_name` received the same `sp_str_dup_external` treatment and was not
added to it. The comment's own prediction — non-determinism by string length —
is what the table above measures.

Minimal reproducer (12 lines, no `require`, no exceptions, no `inspect`):

```ruby
def churn
  a = []
  200.times { |i| a.push("filler #{i}") }
  a.length
end

def through_gc(s)
  churn
  GC.start
  s
end

p through_gc("plain heap string").length
p through_gc($0).class.to_s
```

Both ingredients are necessary and neither is sufficient: with the `$0` line
removed it is clean 10/10, and with *only* the `$0` lines (no other heap string
held across the collection) it is also clean 10/10 — the swept slot has to be
reused before the dangling read lands on changed bytes.

**Proposed minimum diff** (one line, `lib/spinel_rt.h`, in `sp_re_mark_globals`
beside the ARGV loop):

```c
  SP_GLB_PHASE("globals:argv");
+ sp_mark_string(sp_program_name);
  for (sp_int i = 0; i < sp_argv.len; i++) sp_mark_string(sp_argv.data[i]);
```

Tested in a **scratch copy** of `lib/` reached through `-I`; `vendor/spinel` was
not modified and `git status` there is clean. With the line: the minimal
reproducer and the full fixture go to 0/10 at both `-O2` and `-O3`, with
`-Werror` on. The `-O3` check matters because the comment at `lib/spinel_rt.h:1238`
records that a rodata `""` default made GCC prove an out-of-bounds `s[-1]` write
in this exact inlined call — `sp_program_name` is reassigned in `main`, so that
proof does not apply here, but it had to be checked rather than assumed.

### `hash_merge_chain_rooted`: both promoted merge operands are unrooted temporaries

Reproduced at the pin: wrong answer normally (line 3 `true`, expected `false`)
and SIGSEGV under stress. Bisecting the fixture's four shapes isolates it to
exactly one — the **cross-variant** case, `{"x" => 1}.merge({"y" => "s"})`:

| shape | normal | stress |
|---|---|---|
| `h1.merge({b: 2}).merge({c: 3})` | correct | clean 0/3 |
| `h1.merge({b: 2}, {c: 3})` | correct | clean 0/3 |
| `g1.merge({"y" => "s"})` (cross-variant) | **wrong** | **segfault 3/3** |
| `mk(1).merge(mk(2))` | correct | clean 0/3 |

The generated C says why:

```c
sp_StrPolyHash_length(
  sp_StrPolyHash_merge(sp_StrPolyHash_from_str_int_hash(lv_g1),
                       sp_StrPolyHash_from_str_str_hash(_t3)))
```

A `{"x" => 1}` receiver is a `StrIntHash` and a `{"y" => "s"}` argument is a
`StrStrHash`, so **both** operands are promoted to `StrPolyHash` by a fresh
allocation, and **neither promoted result is rooted**. C does not fix the
evaluation order of the two arguments, so whichever runs first sits in an
unrooted C temporary while the other `from_*` allocates. A collection in that
window reclaims it and the allocator hands the block back zeroed — the merge
then reads a recycled block. `sp_StrPolyHash_merge` does open with
`SP_GC_ROOT(a); SP_GC_ROOT(b);`, but that is too late: both arguments have
already been evaluated by then.

Control, which changes only whether a promotion is needed:

| receiver | generated call | normal | stress |
|---|---|---|---|
| `{"x" => 1}` | `sp_StrPolyHash_merge(sp_StrPolyHash_from_str_int_hash(…), …)` | wrong | segfault 3/3 |
| `{"x" => 1, "w" => "t"}` | `sp_StrPolyHash_merge(lv_g1, …)` | correct | clean 0/3 |

**Proposed minimum diff**: at the codegen call site, hoist each promoted operand
into a rooted temporary before the merge call, rather than passing the `from_*`
calls as arguments —

```c
sp_StrPolyHash *_p0 = sp_StrPolyHash_from_str_int_hash(lv_g1); SP_GC_ROOT(_p0);
sp_StrPolyHash *_p1 = sp_StrPolyHash_from_str_str_hash(_t3);   SP_GC_ROOT(_p1);
… sp_StrPolyHash_merge(_p0, _p1) …
```

This is a codegen change, is not pre-approved, and has not been written. It is
recorded here as the shape a fix would take, with the reproducer and the control
that any fix must satisfy.

### Reaching the real call sites: what the generated C actually contains

This replaces the text screen recorded earlier. Each defect is gated on a
construct the codegen either emits or does not, and the generated C for the DOOM
entry points can be read directly. An absent symbol in the translation unit is a
different order of evidence from an absent word in the Ruby source: the dispatch
and typing decisions have already been made by the time the C exists.

**Entry points and flags.** All four DOOM entry points were generated, not just
the one that was run:

```
vendor/spinel/bin/spinel <entry>.rb -c --no-line-map -o <out>.c
```

at pin `cad0ad14`, from the predecessor sources at `f8ad13c6` extracted
read-only. `--cc` does not enter C generation and was omitted here; the default
overflow mode (`raise`, `src/main.c:310`) was used, which is decision 0006's
configuration. The counts are of the generated C, not the Ruby.

| entry point | C lines | `sp_program_name` | `_merge` (any) |
|---|---|---|---|
| `bin/doom.rb` (the interactive game) | 27660 | **0** | **0** |
| `bin/record_demo.rb` | 26756 | **0** | **0** |
| `bin/sim_demo.rb` | 27286 | **0** | **0** |
| `bin/render_frame.rb` | 12120 | **0** | **0** |

Controls: the `literal_string_markers` C carries the `sp_program_name`
assignment at line 464 plus two reads, and the `hash_merge_chain_rooted` C
carries `sp_StrPolyHash_merge` and `sp_SymPolyHash_merge`. So the two identified
defects cannot reach any of the four entry points, the interactive game
included.

### The binary-IO defects, at the call sites rather than by word count

The earlier screen left `File#write` unresolved: it counted `IO#<<` occurrences
and noted that the two binary writes are `File#write` on a `"wb"` file, without
checking which arm those calls take. That is settled here.

What the two defects actually are:

- `io_write_poly_binary` — a binary String whose **inferred type is `TY_POLY`**
  (`String | nil`) reaching `IO#write` was sized with `strlen` and truncated at
  its first NUL. The fixture's own comment records that the `TY_STRING` arm was
  already binary-safe.
- `io_print_puts_binary` — `print` / `puts` sized a binary String with `strlen`
  **regardless of the inferred type**, and `puts` read the byte before the first
  NUL for its trailing-newline check.

Which helper each entry point emits:

| entry point | `sp_File_write_bin` | `sp_File_write_poly` | `sp_File_write` | `sp_File_puts` | `sp_File_puts_val` | `sp_File_print` |
|---|---|---|---|---|---|---|
| `bin/doom.rb` | 1 | **0** | **0** | 14 | **0** | **0** |
| `bin/record_demo.rb` | 1 | **0** | **0** | 6 | **0** | **0** |
| `bin/sim_demo.rb` | 1 | **0** | **0** | 15 | **0** | **0** |
| `bin/render_frame.rb` | 37 | **0** | **0** | 1 | **0** | **0** |
| *control:* `io_write_poly_binary` | present | **present** | present | – | – | – |
| *control:* `io_print_puts_binary` | – | – | present | present | **present** | – |

The poly arms — `sp_File_write_poly` and `sp_File_puts_val` — are emitted by the
fixtures and by **no** DOOM entry point. Every DOOM binary write lowers to
`sp_File_write_bin`, with the argument visible in the C:

```c
sp_File_write_bin(lv_q, (lv_r)->iv_screen)                       /* sim_demo */
sp_File_write_bin(lv_f, sp_str_byteslice(self->iv_buf, 0, …))    /* doom, record_demo */
```

`sp_File_write_bin` (`lib/sp_io.c:271`) sizes with `sp_str_byte_len(s)`, not
`strlen`, and hands that length to `sp_File_write_len`. That is the arm the
defect does not affect.

**Positive control, from the bytes rather than the symbol name.** The rendered
outputs are written through this path and are full of NULs:

| file | size | NUL bytes | first NUL at | size a strlen-sized write would give |
|---|---|---|---|---|
| `frame.bin` | 64000 | 10350 | 19922 | 19922 |
| `frame.ppm` | 192015 | 34740 | 59781 | 59781 |

`frame.bin` is exactly 320×200 and `frame.ppm` exactly 15 + 320×200×3. Had the
write path been `strlen`-sized, both would have stopped at their first
palette-index-0 pixel. They do not. The binary write path is NUL-safe in this
build, measured.

**An honest boundary on `print` / `puts`.** `sp_File_puts` (`lib/sp_io.c:1010`)
**is still `strlen`-based at this pin** — `size_t n = strlen(s); fputs(s, f->fp);`
plus an `s[n-1] != '\n'` check. The defect is live in the helper DOOM uses. What
makes it harmless here is the data, not the structure: all 36 `sp_File_puts`
sites across the four entry points write TSV rows and stderr diagnostics, and
none of the TSVs produced by the full runs contains a single NUL byte. This is a
property of what DOOM currently sends to `puts`, so it is a **hazard to watch
during Task 2**, not a closed structural argument: routing packed or binary data
through `print`/`puts` would truncate it silently. `sp_File_print` is emitted by
no entry point at all.

## Task 1 gate

**Passed (2026-09-11).** This agrees with the status block at the top of the
document; anything between them that reads differently is an earlier observation
of the same run and is labelled as such.

1. **Closed.** Both stress segfaults have an identified cause, a minimal
   reproducer, and a control: `$0` is allocated on the string heap by
   `src/codegen.c:10459` and never marked by `sp_re_mark_globals`; and the
   cross-variant `Hash#merge` passes two freshly allocated, unrooted promotions
   as arguments. Neither was intermittent — the first depends on argv[0] length.
   The first was verified fixed by a one-line diff in a **scratch copy** of
   `lib/`; the second has a proposed shape and a control any fix must satisfy.
   `vendor/spinel` is unmodified.
2. **Closed.** The relevance argument no longer rests on a text search. All four
   entry points — including the interactive `bin/doom.rb` — emit zero
   `sp_program_name` and zero `_merge`, against fixtures that emit both. The
   binary-IO question is settled at the call sites: every DOOM write lowers to
   `sp_File_write_bin`, which sizes with `sp_str_byte_len`; no entry point emits
   `sp_File_write_poly`, `sp_File_puts_val` or `sp_File_print`; and a rendered
   `frame.bin` of exactly 64000 bytes with its first NUL at offset 19922 proves
   the write path NUL-safe from the bytes. One boundary is carried forward
   rather than closed: `sp_File_puts` is still `strlen`-based at this pin, and
   DOOM is safe from it only because nothing it sends to `puts` contains a NUL.
3. **Closed.** A frame has been rendered (320×200, E1M1, visually checked) and
   DEMO1 has been replayed in full — all 5026 tics with the renderer, on the
   selected Clang 23.1.1, byte-identical across two toolchains and under
   1,497,093 collections.

What is **not** claimed: that any "not reproduced here" row is fixed upstream —
the B6 note shows why that inference is unsafe, since its fix is verifiably
absent from the pin while macOS reproduces a SIGABRT. And that the macOS
`literal_string_markers` occurrence shares the Debian cause; that is a
hypothesis with no macOS control behind it.

Unchanged: the pin is not moved and no compiler change is made here. Two minimum
diffs are proposed, each with a reproducer and a control, for a separate
decision.

Carried into Task 2: `sp_File_puts` is `strlen`-sized, so any new DOOM path that
sends packed bytes through `print`/`puts` will truncate silently.

Anything run before Task 2 begins is a **scratch compatibility probe**. It is
not Task 2, not an import, and not product acceptance.
