# `tests/doom/fixtures/allowances/`

Declared frame divergences between the Ruby port and the C reference, in
`tests/doom/compare.rb`'s format:

```
stream	gametic	field	reference-value	candidate-value	reason
```

One file per demo, passed with `--allowances`. **There is no file here yet**, and
that is a state rather than an oversight — see
[the baseline](../../../../docs/doom/frame-divergence-baseline.md) for what goes
in them, what is still needed, and why this host cannot supply it.

## The rules these files are written under

- **A tic is never declared. A value is.** The observed difference set must
  equal the declared set exactly, so a different hash at a listed gametic is a
  new defect and fails. Controls 8b and 8c in
  `tests/doom/compare-controls.sh` are what hold that.
- **The values come from the selected toolchain**, which decision 0006 makes
  macOS. This host's reference disagrees with it at one of the tics, so this
  host's hashes are not the ones the criterion is defined on.
- **The reason cites the historical record, it does not copy numbers from it.**
  The predecessor's E053 and E054 recorded the cause — the reference reading its
  own zone allocator's pointers and allocation history, which the port zeroes —
  and that is what the reason names. The values are measured in 2026-09.
- **An entry that stops firing fails the run.** A declared difference that
  disappeared is a change, and changes are investigated rather than tidied away.
- **Nothing generates these files.** `--report-all` prints candidate lines for a
  human to read; it writes nothing and does not change the exit status. A file
  regenerated from a failing run is how a regression becomes expected.

## What is deliberately absent

The extra divergences a Debian-built reference produces — DEMO1 gametic 4480,
DEMO2 gametic 3604 — are **not** here. They have no identified cause and are
absent from the historical record. They are **not observed under the macOS
criterion**, and they are **unresolved on Debian** — two separate statements.
Both hosts used the selected Clang 23.1.1, so "the selected toolchain does not
see them" would be false: the toolchain is not what distinguishes the hosts.
Writing them down would turn an unexplained difference into a tolerated one.

## Validated

macOS, 2026-09-11 (their exec `30474`): applied to the saved outputs, DEMO1,
DEMO2 and DEMO3 all exit 0, with every declaration firing and nothing else
differing.

## These files apply to the macOS reference, and only to it

Measured 2026-09-11: applying them to a Debian-built reference fails, and
should. `demo1.tsv`'s 2046 entry fires — both references agree there — while its
4486 entry does not, and **all six** of `demo2.tsv`'s do not. The values are
pointer bytes and allocation history, which the historical records say are not a
function of the WAD; they are therefore properties of one build, and two builds
disagree on them.

The gate reports that as `declared discrepancy(ies) did not occur`, which is the
stale-allowance rule doing its job. A run that is not against the macOS
reference should not pass with these files, and does not.
