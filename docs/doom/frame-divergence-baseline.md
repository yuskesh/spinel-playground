# The frame divergences: what was recorded before, and what was measured now

Decision [0006](../decisions/0006-doom-hosted-import.md), task 3. This is the
baseline the allowance files are written from. It keeps two things apart on
purpose: **what the predecessor recorded as the cause**, and **what was measured
here and on macOS in 2026-09**. The first is history and is quoted; the second is
observation and is dated. Where they line up, that is stated as a
correspondence — not as the old record being re-confirmed, which no one has done.

## The historical record

Two files in the predecessor at `f8ad13c6`, read from Git objects:
`docs/experiments/results/E053/zone_nondeterminism.txt` and
`docs/experiments/results/E054/zone_attribution.txt`. Taken on
`doomgeneric dcb7a8db (-Os) / arm64` — the same doomgeneric commit this import
pins.

Their method was finer than a frame hash: the E053 hook dumps, for every
`R_DrawColumn` call, the drawing parameters **and the 128-byte window visible
through `dc_source`**, and the port's window was taken through a CRuby probe and
compared byte by byte.

What they found, in both cases, is that the reference reads bytes that belong to
**its own zone allocator's bookkeeping** rather than to the WAD:

| demo | gametic | pixel | ref | port | index | field read |
|---|---|---|---|---|---|---|
| DEMO1 | 2046 | (288, 110) | 8 | 0 | — | low byte of the `size` of the free block just after `texturecomposite` (`size = 264`) |
| DEMO1 | 4486 | (149, 108) | 104 | 0 | — | low byte of `next` in the header after lump `TROOM0` |
| DEMO2 | 631 | (135, 98) | 78 | 0 | 127 | `next` (pointer) |
| DEMO2 | 2325 | (164, 118) | 142 | 0 | 127 | `next` (pointer) |
| DEMO2 | 2325 | (165, 118) | 188 | 0 | 127 | `prev` (pointer) |
| DEMO2 | 2925 | (271, 142) | 83 | 0 | 127 | `next` (pointer) |
| DEMO2 | 2925 | (272, 142) | 83 | 0 | 127 | `next` (pointer) |

Their totals: **DEMO1 2 tics / 2 pixels, DEMO2 3 tics / 5 pixels**, and no entry
for DEMO3.

Two points from those records worth carrying, because they bound what any fix
could look like:

- The drawing parameters agree everywhere. Across DEMO2's 2072 columns at those
  three tics, `(x, yl, yh, cmap, iscale, texturemid)` had **no** disagreement,
  and the 128-byte windows matched at every byte except the ones above. The
  divergence is a handful of source *bytes*, not a rendering difference.
- The bytes are not a function of the WAD. `next` and `prev` are pointers; the
  `size` cases depend on what `Z_Malloc` allocated before. The port's
  `Wad#zone_window` zeroes those fields, so it reads 0 where the reference reads
  whatever its process happened to hold. E053 also records that running the
  reference **twice** changes 141 of 1441 windows at DEMO1's two tics, and 206
  columns at DEMO2's three — always in `user` / `next` / `prev`.

## What was measured in 2026-09

macOS, the selected toolchain, reference built with Clang 23.1.1 at the pinned
doomgeneric commit; the port on pin `cad0ad14` with the same `--cc`:

| demo | tics | game logic | frames diverge at |
|---|---|---|---|
| DEMO1 | 5026 | rand 25013, player 5026, mobjs 1099388 — identical | **2046, 4486** |
| DEMO2 | 3836 | rand 15691, player 3836, mobjs 1172703 — identical | **631, 2325, 2925** |
| DEMO3 | 2134 | rand 22991, player 2134, mobjs 589204 — identical | **none** |

## The correspondence

The tics macOS measures are **exactly** the tics the historical records list,
demo for demo, including DEMO3 having none. The counts match too: 2 and 3 and 0.

That is a strong correspondence and it is not a re-derivation. Nobody has
re-run the byte-window instrument in 2026-09; what was re-run is the frame hash,
which cannot see *which* byte differed. The right reading is: **the historical
cause is the standing explanation, the present measurement is consistent with
it, and no one has re-confirmed the mechanism.** If a fix were ever proposed for
these tics, the byte-window instrument would have to be re-run first.

## What does not correspond, and is therefore held

This host measures **one extra divergent tic per demo**: DEMO1 4480 and DEMO2
3604. Neither appears in the historical records.

They are **not accepted and not written into any allowance file.** What is known
about them:

- They are **not observed under the macOS criterion**: macOS agrees with the
  port at 4480. That is not the same as saying the selected toolchain does not
  see them — **both hosts used the selected Clang 23.1.1**, so the toolchain is
  not what separates the two results. Out of scope for the criterion, and
  unresolved here, are two different statements and both are true.
- At DEMO1 4480 the two *reference builds* also disagree with each other — the
  G0 gate shows this host's reference differing from the recorded golden at
  frames 4518 and 4524, which are gametics 4480 and 4486.
- On this host, GCC 14.2.0 and Clang 23.1.1 produce byte-identical output, so
  the difference is not those two compilers disagreeing. What it *is* — platform,
  libc, target, or that compiler on that platform — is **unidentified**.

Recording them as expected would convert an unexplained difference into a
tolerated one, which is the outcome the allowance mechanism exists to prevent.
See [debian-oracle-observation.md](debian-oracle-observation.md).

## What the allowance files will contain

`tests/doom/fixtures/allowances/`, one file per demo, in `compare.rb`'s format:

```
stream	gametic	field	reference-value	candidate-value	reason
```

The rules that make this a baseline rather than an exemption:

- **Values are pinned, not tics.** A different hash at a listed gametic is a new
  defect and is rejected; the observed difference set must equal the declared
  set exactly.
- **Values come from the selected toolchain.** macOS's measurement is the
  criterion, so its reference and candidate hashes are what get written — not
  this host's, which differ at 4486 because its reference differs there.
- **The reason cites the historical record; it does not transcribe it.** The
  reason field names E053/E054 and the field read; the *values* are the ones
  measured in 2026-09.
- **A listed discrepancy that stops occurring is a failure.** Stale entries are
  reported, not left in place.

### Written, from the macOS measurement

`tests/doom/fixtures/allowances/demo1.tsv` (4 entries) and `demo2.tsv` (6), one
file per demo because a gametic is not unique across demos. The values are the
macOS side's `--report-all` output, extracted from their saved logs
(`build/mac-review-361721b/DEMO1.log` and `DEMO2.log`, their exec `31602`) rather
than regenerated from any run here. The reasons cite E053 and E054 and name the
field read; they copy no values from those records.

### Validated on the selected toolchain

macOS applied both files to its saved outputs (their exec `30474`) and all three
demos exit 0: **every declaration fires and nothing else differs**. DEMO1 two
tics per stream, DEMO2 three per stream, DEMO3 no file and no divergence.
Coverage 5024 / 3834 / 2132 frames, with the random, player and thinker counts
as previously reported. That closes decision 0006's "reproduce each inherited
reference discrepancy … preserve concrete expected differences and provenance".

### They belong to one reference build, and that is measurable

Applying them to a **Debian**-built reference fails, and that is the correct
outcome. Measured here on 2026-09-11:

| | |
|---|---|
| DEMO1 | the 2046 entries fire — both references agree there — and the 4486 entries **do not**; 4480 is undeclared and diverges |
| DEMO2 | **all six** entries do not fire |
| DEMO3 | no file, no divergence, passes |

So on this host only DEMO1 2046 matches macOS's reference value. The rest are
properties of one build: the bytes involved are pointers and allocation history,
which the historical records say are not a function of the WAD, and two builds
duly disagree about them. The gate reports `declared discrepancy(ies) did not
occur`, which is the stale-allowance rule working — a run against a different
reference should not pass with these files, and does not.

That is a limitation to state, not to engineer around. Pinning a value that is
not a function of the input means the entry is pinned to one build of the
reference. If one stops matching, the first thing to check is whether the
reference build changed.
