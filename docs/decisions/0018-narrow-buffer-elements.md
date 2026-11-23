# 0018: Narrow buffer elements for DOOM's CORE storage

- Date: 2026-10-19
- Status: Accepted (owner, 2026-10-19). Implemented: the element types at the
  CORE boundary (see [the buffer boundary](../core/buffer-boundary.md)), and
  DOOM's widths from the tracked table `examples/doom/core/widths.tsv`.
- Scope:
  - the buffer element types of the CORE boundary of
    [decision 0007](0007-doom-core-preparation.md);
  - the element type of each resident buffer that DOOM's three CORE entries
    take, and the evidence that chooses it.

  CORE scalars, entry arguments and results, and the hosted program are
  unchanged.

## Context

The three entries of [decision 0008](0008-doom-core-migration.md) take 394
resident buffers. At main `19e0153`, for E1M1 at 320x200, they hold
22,288.2 KB (1 KB = 1,024 B). Of the writable part (persistent, output and
scratch roles), 7,578.1 KB, the `i64` buffers hold 6,965.2 KB.

Their values are much narrower than 64 bits. Two measurements show this:

- **Observed.** DEMO1 (E1M5), DEMO2 (E1M3) and DEMO3 (E1M7) were played to
  their ends through the route of `tests/doom-core/route-demo.rb`. The minimum
  and maximum of every element of the 379 `i64` buffers were read after each
  tic. 374 of the buffers stayed within `i32`, and four of the other five
  within `u32`. With each buffer at the smallest type its range fits, the
  `i64` buffers would hold 1,972.8 KB instead of 7,800.9 KB.
- **Static.** Every store into 57 of the fields goes through a 32-bit
  truncation (`fixed_to_i32`, `fixed_bam`, `& 0xffffffff`) or is a constant.
  For the others, the source alone gives no bound.

0007 admits `u8`, `i32`, `u32` and `i64` as buffer elements. It already
defines a narrowing store: "Narrowing of computed values at a store or
return is ARITHMETIC".

A smaller footprint is the precondition for running DOOM's CORE on a
microcontroller board with external RAM. That use is
[proposed](../roadmap.md), not decided here.

## Decision

**Element types.** The CORE buffer elements are `u8`, `i8`, `u16`, `i16`,
`i32`, `u32` and `i64`.

- Bodies still compute in signed 64 bits.
- A load widens: signed elements sign-extend and unsigned elements
  zero-extend.
- A store narrows under 0007's existing rule: a value outside the element's
  range fails the entry with `ARITHMETIC` and stores nothing.
- Nothing is truncated or wrapped silently.
- Entry validation, alignment and count-times-size overflow checks apply to
  the new elements as they do to the existing ones.

**DOOM's widths.** Each resident buffer of the three entries is given the
smallest element type that holds its evidenced range.

- A static bound comes from the source, with the line that establishes it.
- Otherwise, the evidence is the union of the observed ranges over the three
  demos and the state before the first tic. An observed range covers every
  value the three entries store, not only the values left after each tic
  (owner, 2026-10-19): `renderer_ss_last` reads 0..2147483647 between tics,
  but `dc_rv_clear_clip_segs` stores the sentinel -1 into it during a call,
  and the first render failed with `ARITHMETIC` at that store.
- The `core_state` scalar slots stay `i64`: 246 slots, 1,968 B.

**A tracked table.** The chosen type and its evidence are recorded per field
in a tracked table, from which the generated state schema takes the element
type. Each row holds:

- the field;
- the element type;
- the minimum and maximum;
- the kind of evidence: `static`, with the file and line, or `observed`, with
  the demos;
- the commit the evidence was measured at.

**Re-measured.** A check replays the demos and fails when an observed value
falls outside its row's type. The evidence is therefore re-established
whenever the source or the pin changes.

- A failing check is not adjusted by hand: the table is regenerated from a new
  measurement.
- A store outside the type in any other run fails with `ARITHMETIC`.

## Why not the alternatives

- **Truncating or wrapping stores** would let an unobserved value change the
  game silently. 0007 already forbids that.
- **Narrowing only the statically bounded fields** keeps the proof, but saves
  much less.
- **A margin of one type size on observed ranges** loses most of the saving,
  and is still not a proof.

## Consequences

- The observed bounds are evidence, not proof. Their protection is the
  `ARITHMETIC` failure at the store.
- The CORE boundary's element vocabulary grows, along with its adapters and
  their element conversions. The boundary suites gain cases for the new
  elements, including an out-of-range store and sign extension.
- A store outside its type fails with `ARITHMETIC`, as it already does for
  `u8`, `i32` and `u32` buffers. Before this record, such a value was stored
  in an `i64` buffer; that is the only behaviour this record changes.
- DOOM's CORE lanes must pass unchanged on both hosts, and the resident
  footprint is re-measured and recorded.

## Implementation and validation

- **The table.** `examples/doom/core/widths.tsv`, generated by
  `tools/doom/core-widths.rb`, has 394 rows: 155 `u8`, 14 `i8`, 86 `u16`,
  36 `i16`, 51 `u32`, 51 `i32` and one `i64`. 14 rows are `static`, 380
  `observed`. The observed ranges come from DEMO1 to DEMO3 after each tic and
  from 27 runs that record every store: input, three steps, four renders
  (one at scale 2) and 19 scenarios.
- **The re-measuring lane.** `tests/doom-core/widths.sh`, run from
  `verify.sh`, checks the 394 rows against those runs.
- **The footprint.** For E1M1 at 320x200, over the 394 buffers and without
  `core_state` and derived buffers, calculated from the catalog's counts
  times the element widths (no allocation or RSS was measured):

  | part | all `i64` (`3299845`) | narrowed (`fe94c61`) |
  |---|---|---|
  | writable (persistent, output, scratch; 191 buffers) | 7,578.1 KB | 2,586.8 KB |
  | read-only (resources; 203 buffers) | 14,710.1 KB | 14,154.0 KB |
  | total | 22,288.2 KB | 16,740.7 KB |

  At 640x400 the total is 26,920.9 KB before and 18,008.8 KB after; for
  E1M5, 22,430.5 KB and 16,785.8 KB.
- **Validation** at `b283065` (`dd1e9fa` adds only the audit's call-site
  count, 19637, and its documentation row):
  - Debian x86_64: `verify.sh` 97/97 (`native` 21/21,
    `native-scenario-diff` 22/22, `widths` 9/9), `state.sh` 270/270,
    `screens.sh` 23/23, `entries.sh` 33/33, `tick.sh` 118/118 and
    `loop-reports.sh` 102/0 (at `47b0cbb`). The owner-approved oracle lanes,
    once each with `ALLOW_ORACLE=1`: `audit` (268/269, the call-site count
    since fixed statically), `borrowed-calls` 49/49, `control-flow` 59/59,
    `source-pack` 81/81, `abort-controls` 6/6 and `tests/doom/run.sh` 5/5.
  - macOS arm64 with LLVM 23.1.1: `entries.sh` 33/33, `state.sh` 270/270,
    `tick.sh` 118/118 and `verify.sh` 97/97, the same counts as on Debian.
