# `tests/doom/oracle/`

The independent oracle for DOOM is the C reference implementation
(doomgeneric), and running it is **macOS-only in this import**: its harness uses
CommonCrypto and a Mac-specific Makefile. Decision 0006 assigns that to the
macOS side, and nothing here claims Debian portability for it.

What lives here is the part that can be built and tested without it.

## `make-fixture.rb` is not an oracle

It re-lays the Ruby port's own output into the reference's column layout. A
comparison against its output is a test **of the comparator**, never of DOOM:
both sides carry the same numbers, so agreement means the comparator can read
the two shapes, and disagreement after a deliberate mutation means it rejects
that mutation.

Using it as evidence that the port matches the reference would be circular. It
exists so that `tests/doom/compare.rb` — which is the thing that will judge the
real oracle's output — can itself be judged on a host with no oracle.

## The reference's two keys

This is the thing the comparator gets right by reading the producer rather than
guessing. `doom/reference/e052_dump_hooks.patch` writes one row per dump call:

```c
fprintf(s_frame, "%ld\t%d\t%016llx\t%016llx\t%s\n",
        s_frameno++, gametic, fh, vh, sha_hex);
```

so the header is `#frame gametic fnv1a64 viewhash sha256`, and:

- **`frame` is the record identity.** `s_frameno++` advances once per call, so
  it is unique and strictly increasing. The same frame number twice is a corrupt
  dump.
- **`gametic` is a grouping key and repeats legitimately.** `D_Display` can run
  more than once for a tic — the title-screen melt wipe parks 41 frames on
  gametic 2, and it is not the only case. Requiring a unique gametic would
  reject correct reference output.

The port renders one frame per tic, so its own `gametic` *is* its record
identity. The comparison rule is the L6 gate's: the port's frame for a tic must
match **one of** the reference frames recorded for that gametic.

The `sha256` column is `-` unless the reference was built with CommonCrypto,
which is one of the reasons the oracle run is macOS-only. The comparator does
not read it.

## What the controls establish

`tests/doom/compare-controls.sh` constructs each defect and requires the
comparator to reject it **with the diagnostic that identifies that defect**, not
merely with a non-zero exit:

| control | what it constructs | must |
|---|---|---|
| 0 | the unmutated fixture | pass — otherwise every control below is vacuous |
| 0b | a mid-run gametic carrying two reference frames, plus the 41-frame wipe | **pass**, and be reported: several frames on one gametic is correct |
| 1 | a stream file that exists but has no rows | fail |
| 2 | a stream file that is not there at all | fail |
| 3 | one gametic removed from the reference | fail |
| 4 | one reference row copied verbatim, so a frame id repeats | fail |
| 5 | one field of one `player.tsv` row altered | fail |
| 6 | one frame hash altered, outside any declared discrepancy | fail |
| 7 | two reference rows transposed | fail |
| 8 | a real difference at a **declared** gametic | **pass** |
| 9 | a declared discrepancy that does not occur | fail |
| 10 | same value and index, different call site | fail |
| 11 | the reference's gametic column going backwards | fail |
| 12 | a candidate frame tic dropped | fail |
| 13 | a candidate state row dropped | fail |

0b, 8 and 9 are the ones that keep the comparator honest in both directions:
legitimate reference shapes and declared differences must be tolerated, and a
declared difference that stops happening must be reported rather than left in
place.

12 and 13 are the ones that stop the comparator passing by checking less.
Dropping a candidate tic once exited 0 here — every remaining tic still found
its reference frame, and the run passed having compared one fewer. Coverage is
now asserted on the candidate as well as the reference, and 12 is the control
that would catch it coming back.

## What these controls do NOT establish

They test the comparator against a synthetic reference in the reference's
*format*. That is not the same as testing it against the reference's *output*.

A fixture built from the candidate's own numbers cannot exercise: the real
distribution of multi-frame gametics, the actual wipe lengths at level
transitions, what the reference emits around demo end, the `sha256` column when
CommonCrypto is present, or any divergence whose shape nobody has predicted.
**Verification against fixed C oracle output on macOS is still required**, and
nothing here should be read as having replaced it.
