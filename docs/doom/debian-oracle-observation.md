# The C reference built and ran on Debian — an observation, not a plan change

**Date:** 2026-09-11. **Status:** measurement, reported for a decision that is
not mine. Decision 0006 assigns the oracle to macOS, and this does not change
that assignment.

## What the plan says, and what happened

Decision 0006 task 5 says:

> Full C-oracle replay is Mac-only in this import because its reference harness
> uses CommonCrypto; record Debian reference replay and GUI as unverified, not
> successful skips.

On this host the reference **built and ran**:

```
tools/doom/build-reference.sh
  6 patches verified against the manifest
  applied 01…06
  doomgeneric dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284
  built build/doom-reference/doomgeneric/doomgeneric/doomgeneric_headless
```

`cc (Debian 14.2.0-19) 14.2.0`, x86-64 ELF. `strings` finds no `CC_SHA256` in
it, which is the point: the CommonCrypto call is guarded, and without it the
dump hook writes `-` in the `sha256` column. None of the compared streams reads
that column, so its absence costs nothing the comparison needs.

That is the whole of the obstacle as far as this build goes. `Makefile.headless`
compiled without adaptation.

## The measurement

DEMO1 at full length, 5026 tics, reference and port each run once:

| stream | result |
|---|---|
| `rand` | **25013 P_Random calls identical**, call sites checked through SITE_MAP |
| `player` | **5026 rows identical** — every tic's full player state |
| `mobjs` | **1099388 rows identical** — every thinker snapshot |
| `frames` (view) | 5021 / 5024 identical; **3 tics diverge**: 2046, 4480, 4486 |
| `frames200` (full) | 5021 / 5024 identical; the same 3 tics |

The reference wrote 5065 frame rows, which is the row count of the imported
R007 golden `demo1_hashes.tsv` exactly — 41 wipe frames plus 5024 level frames.
That agreement is independent of any patch reading and is worth having.

## Why this is not "Debian verified"

Three reasons, and the third is the one that matters.

1. **It is a different build.** No CommonCrypto, so the `sha256` column is
   unverified here; a Mac build has it. Nothing about the Mac toolchain's
   behaviour is established by a GCC build.
2. **It is one run on one host.** The plan asks for the oracle on the selected
   toolchain, which is not this one.
3. **The divergence count does not match the inherited record.** The
   predecessor records DEMO1 as 5022 of 5024 frames matching — two differing
   tics. This run finds **three**. That is a changed discrepancy, and decision
   0006 is explicit that a changed or new discrepancy requires investigation,
   not a larger allowance. It is **not** being written into an allowance file.

The plan also warns against assuming the old C oracle's undefined behaviour is
stable across toolchains. A frame that differs under Linux/GCC and not under
macOS/Clang is exactly that class of difference, and it is the first hypothesis
to test — before, not after, any of these tics is declared expected.

## What is worth taking from it

- The reference builder works end to end from tracked patches on a second
  platform, which is evidence about the builder rather than about DOOM.
- Game logic agreement is total at full demo length: 25013 random draws with
  their call sites, 5026 player rows, 1099388 thinker rows. Whatever the three
  frames are, they are not a logic divergence — the simulation matches
  exactly and the disagreement is confined to rendering.
- The comparator's structural checks earned their place on real data rather
  than on a mutation. A first run pointed both the R007 harness and the E052
  hook at one `frames.tsv` — they write 4-column and 5-column rows respectively
  — and the width check caught it:

  ```
  MISMATCH frames/reference: row 0 has 6 fields, the header declares 5
  ```

  A comparator that read `min(a, b)` columns would have compared interleaved
  garbage. The two streams are separated by `DG_HASH_OUT` and `DG_E052_DIR`.

## The G0 gate answers part of it: two of the three are the C oracle's own

`tests/doom/gate-r007-golden.rb` compares a freshly built reference's **R007**
output against the recorded golden. It is a separate gate from `compare.rb` and
reads a different hash — the R007 harness's `fnv1a64` with the short basis,
four columns — so the two are never crossed.

Run here, against the golden recorded on macOS:

```
G0: DIVERGES (2 field(s) across 2 frame(s))
    (sha256 not compared: 5065/5065 golden and 0/5065 built rows carry one
     -- a CommonCrypto build difference)
4518	fnv1a64	3128b961d9790b44	0eeaf511f4379017
4524	fnv1a64	d5f0fe9e91c1f34f	b4d0d76f4706ba62
```

5065 frames, identical frame-id sequence, and **two frames differ between two
builds of the same patched source at the same commit**. Their gametics are
**4480 and 4486**.

Those are two of the three gametics where the port diverged from *this* build's
E052 output. So:

- **4480 and 4486: the two C references disagree with each other.** The port's
  disagreement with the Linux build at those tics is not, on its own, evidence
  about the port. Decision 0006 warns not to assume the old C oracle's undefined
  behaviour is stable across toolchains; what is measured here is that it is not
  stable across *hosts*. Which of toolchain, platform or libc is responsible is
  **not** established.
- **2046: the two references agree.** The port's divergence there is a
  port-side difference that no toolchain argument explains away.

What this does **not** establish: that the port matches the macOS reference at
4480 and 4486. The G0 comparison is reference-against-reference in the R007
hash; the port comparison is in the E052 hash. They are different functions, so
the agreement cannot be carried across. Only a macOS E052 run can say what the
port does against the selected toolchain.

The `sha256` column is reported as not compared rather than silently ignored:
the golden has it for all 5065 rows and this build has it for none.

## The macOS measurements came back, and the prediction was half wrong

Recorded from the macOS side's reports (exec `18238` and `61260` there), kept
separate from what this host measured.

**macOS, E052, port against reference** — reference built with
`.../llvm-23.1.1/bin/clang`, port on pin `cad0ad14` with the same `--cc`:

| demo | tics | rand | player | mobjs | frames diverge at |
|---|---|---|---|---|---|
| DEMO1 | 5026 | 25013 ✓ | 5026 ✓ | 1099388 ✓ | **2046, 4486** (4480 agrees) |
| DEMO2 | 3836 | 15691 ✓ | 3836 ✓ | 1172703 ✓ | **631, 2325, 2925** |
| DEMO3 | 2134 | 22991 ✓ | 2134 ✓ | 589204 ✓ | none |

**macOS, G0, rebuilt reference against the golden**, with all `DG_*` removed
except `DG_HASH_OUT` and the E052 hooks disabled: **byte-identical to the
tracked golden, all 463,676 bytes including the SHA column.**

### What I predicted, and what happened

I predicted the port would diverge at 2046 and agree at 4480 **and 4486**. The
first two held; **4486 did not**. The port diverges at 4486 on macOS too, so
4486 is not explained by the reference build differing there — both things are
true at that tic, and I had folded them into one.

| gametic | Debian port-vs-ref | macOS port-vs-ref | Debian ref-vs-golden | reading |
|---|---|---|---|---|
| 2046 | diverges | **diverges** | agrees | a port-side difference, on both platforms |
| 4480 | diverges | **agrees** | diverges | the Debian reference differs here; macOS does not see it, and why is unidentified |
| 4486 | diverges | **diverges** | diverges | **both**: a port-side difference *and* a Debian reference difference |

So DEMO1 has **two** port-side divergences, 2046 and 4486 — which is what the
inherited record's 5022 of 5024 says. The third was mine, not the port's.

### What the Clang rebuild actually showed

The macOS side asked for 4480 to be re-checked with the selected Clang. Done:
the reference was rebuilt on this host with `/opt/llvm-23.1.1/bin/clang`
(clang 23.1.1, the same release macOS used) and re-run at full length.

**Both Debian builds produce byte-identical output.** `cmp` on the R007
`frames.tsv` and on the E052 `frames.tsv` between the GCC 14.2.0 build and the
Clang 23.1.1 build: identical. G0 reports the same two frames, 4518 and 4524,
with the same hash values; the E052 comparison reports the same three tics.

**The scope of that result, stated exactly.** What was measured is that *on this
host*, GCC 14.2.0 and Clang 23.1.1 agree with each other. That is one pair of
compilers on one platform. It does **not** rule out the compiler as a cause in
general, and an earlier version of this page said "the compiler is ruled out",
which overstated it. Two compilers agreeing is evidence that the difference is
not sensitive to *those two*; it says nothing about the macOS Clang's own
behaviour on macOS, where the libc, the headers and the target differ as well.

The honest statement is that the cause is **unidentified**. Platform, libc,
target, and compiler-on-that-platform all remain open, and naming one would be
the same overreach in a new place.

### Exit 255: I had this wrong

I wrote that the reference exits 255 because the dump hook stops at
`DG_E052_MAX_TIC`. The macOS side traced it instead to
`g_game.c:G_CheckDemoStatus`, which calls `I_Error` at demo end, with
`i_system.c` doing `exit(-1)`. So 255 means end-of-demo — and **a 255 must not
be read as success in general**, because `I_Error` is also how the reference
reports a real failure. The evidence a run completed is the stderr line `timed N
gametics` with N matching the demo length. This host's Clang run:
`timed 5026 gametics in 4965 realtics (35.430012 fps)`.

The handover page is corrected.

### Coverage, checked independently

The macOS side checked the ranges directly: candidate tics `0..5025` / `0..3835`
/ `0..2133` exactly contiguous, reference frame ids `0..5064` / `0..3874` /
`0..2172` exactly contiguous, and candidate stderr carrying only `sim_demo`'s
own summary line. That is the property the comparator's request-derived coverage
rule now enforces rather than infers, after the truncation defect they found.

### Historical records are not conclusions

The macOS side also read the predecessor's `E053 zone_nondeterminism.txt` and
`E054 zone_attribution.txt` at `f8ad13c6` and reports that the divergent tics
line up with positions recorded there. That is a **correspondence between a past
record and a present observation**, and it is recorded as that. No cause is
re-attributed here, and the historical attribution is not adopted as an
explanation of what was measured today.

## All three demos, both hosts

This host then ran DEMO2 and DEMO3 against the Clang-built reference, so the
same table exists on both sides.

| demo | tics | game logic | macOS frames diverge | Debian frames diverge | Debian-only |
|---|---|---|---|---|---|
| DEMO1 | 5026 | rand 25013, player 5026, mobjs 1099388 — identical on both | 2046, 4486 | 2046, 4480, 4486 | **4480** |
| DEMO2 | 3836 | rand 15691, player 3836, mobjs 1172703 — identical on both | 631, 2325, 2925 | 631, 2325, 2925, 3604 | **3604** |
| DEMO3 | 2134 | rand 22991, player 2134, mobjs 589204 — identical on both | none | none | — |

Every game-logic count matches the macOS side's exactly, and so do the reference
frame id ranges: `0..5064`, `0..3874`, `0..2172`, contiguous with no gaps, on
both hosts.

The pattern is consistent rather than scattered: **this host sees exactly the
macOS divergences plus one extra per demo**, and none at all where macOS sees
none. Both hosts used Clang 23.1.1, so the extra tics are not explained by
"a different compiler was selected"; they are rare, reproducible, and absent
from DEMO3 entirely. That is a description of the shape. The cause is not
identified, and the difference between the two hosts is more than the compiler
— platform, libc and target all differ too.

## Where this leaves the allowance list

Still empty, and still written only from the selected toolchain's result. What
is now known is enough to separate two different things, which an earlier
version of this page ran together.

- **Candidates for the allowance list: the tics macOS sees** — 2046 and 4486 in
  DEMO1, 631, 2325 and 2925 in DEMO2. macOS is the selected toolchain, and the
  acceptance criterion is its result.
- **The Debian-only tics, 4480 and 3604: out of scope for that criterion, and
  unresolved here.** This page previously said they were "not candidates,
  because the selected toolchain does not see them". That was wrong on its own
  terms: **both hosts used the selected Clang 23.1.1**, and this one does see
  them. They are excluded because the criterion is defined on macOS, not because
  the toolchain is innocent — and on Debian they remain an open difference with
  no cause identified.

Writing anything into the list needs the cause, not the coincidence.
