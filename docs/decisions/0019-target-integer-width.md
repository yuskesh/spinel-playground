# 0019: The integer width of freestanding and CORE code follows the target

- Date: 2026-10-19
- Status: Accepted (owner, 2026-10-19). Implemented; Debian and macOS validation are recorded below.
- Scope:
  - the internal integer width of freestanding kernels (`tests/freestanding`,
    `spinel-fs-emit`);
  - the internal integer width of CORE applications on Zephyr
    ([decision 0014](0014-core-applications-on-zephyr.md));
  - how a source keeps the 64-bit width.

  Native hosts (Debian x86_64, macOS arm64) are 64-bit targets, so their
  `--core` slice ([decision 0015](0015-core-scalar-arithmetic.md)) does not
  change. Buffer element widths ([decision 0018](0018-narrow-buffer-elements.md))
  are a separate axis.

## Context

**Two earlier decisions fixed the width at 64 bits.**

- The freestanding design's D-1 (spinel-llvm P003, enforced by
  `ProfileReader.cpp`: `abi.int_width must be i64-internal`) did this because
  Spinel's inference ran at the host's width and had no parameter for another.
- [Decision 0014](0014-core-applications-on-zephyr.md)'s D3 deferred a 32-bit
  mode for CORE applications on 2026-09-22.

**Upstream now defines the width by the target.** At the pin (`ad4bb8c42`,
upstream `e1d92f1e1`), `docs/int-overflow.md` says that `sp_int` is
`intptr_t`.

- The Integer is therefore 32 bits on i386 and wasm32.
- Literals, `Integer#size` and the overflow boundary follow that width.
- `spinel` learns the width from the C compiler it targets.
- `docs/wasm.md` states that `Integer` is 32-bit on wasm32.
- A test that assumes 64 bits says `# spinel: int64` on its first line.

**This matters for `--core`.** 0015 takes Spinel's own integer contract as
the reference for what a `--core` build means. On a 32-bit target, a 64-bit
CORE body therefore disagrees with what the same program means under Spinel
for that target.

**The 64-bit body also costs time on Cortex-M33.** 0014's Task 11 measured
about 101 instructions for one 64-bit division (`__aeabi_ldivmod`), half the
cost of the invocation that made it.

**DOOM's Ruby source assumes a 64-bit Integer.** The original game is 32-bit
code, with 64-bit intermediates in `FixedMul`/`FixedDiv`. The Ruby port does
two things that need more than 32 bits:

- it stores the unsigned 32-bit BAM angles as non-negative Integers (observed
  up to 4,278,190,080);
- it forms 64-bit products in `fixed_mul` before truncating them.

Under a 32-bit Integer both fail with `ARITHMETIC`. A 32-bit DOOM is a later
rewrite, which the owner has said will follow.

## Decision

1. **The default width is the target's pointer width,** as upstream defines it:
   32 bits on Cortex-M33, RV32 and wasm32, and 64 bits on 64-bit targets.
   - The profile states it.
   - `int_width` accepts `i32-internal` as well as `i64-internal`.
   - A profile whose `int_width` disagrees with its triple's pointer width is
     refused unless the source declares 64 bits (item 3).
2. **Analysis runs at that width.**
   - The contract reader's typedump must classify literals and widths as
     upstream does for that target, by selecting upstream's 32-bit
     configuration for the in-process analysis.
   - If the pinned compiler cannot do this in process, the 32-bit width is
     refused, not approximated. This is the first thing the implementation
     establishes.
3. **A source keeps 64 bits by declaring it.**
   - Upstream's spelling, `# spinel: int64` on the first line, applies to a
     freestanding kernel file or a CORE application.
   - Upstream uses this spelling as a 32-bit test-corpus exclusion marker;
     Extended reads it as the width declaration defined here.
   - The body then computes in 64 bits on any target, as now, and the 64-bit
     helpers (`__aeabi_ldivmod` and the like) remain admitted by name.
4. **Overflow keeps its rules at the new boundary.**
   - The `trap`/`wrap` policies of freestanding declarations apply.
   - CORE applications keep `ARITHMETIC` on overflow and narrowing.
   - Boundary widths (`params:`/`returns:`) are unchanged.
   - An `:i64` boundary on a 32-bit body is refused unless the source declares
     64 bits.
5. **Existing sources that need 64 bits declare it:**
   - DOOM's CORE sources;
   - the freestanding kernels whose cases depend on a 64-bit body
     (e040's `bigmul` and `mulwide`, among others).

   The implementation lists them by running every lane at the target width
   first, and records which ones are declared.

## Acceptance

- Every freestanding lane and CORE application suite passes on both hosts:
  - each declared-64-bit source is unchanged;
  - every other source passes at 32 bits.
- New controls:
  - a 32-bit kernel traps at `2**31`;
  - a declared-64-bit kernel does not trap there;
  - a profile/triple width disagreement is refused;
  - a literal past `2**31` in a 32-bit source is refused, since a Bignum has
    no CORE form.
- The 0014 Task 11 instruction counts are re-measured at 32 bits, beside the
  64-bit figures.

## Owner's decisions, 2026-10-19

- The proposal is accepted as written.
- CORE applications on Zephyr take the default too: 32 bits on a 32-bit board,
  unless the application declares `int64`.
- A declared `int64` needs no recorded reason; it is the source's free choice.

## Implementation and Debian evidence, 2026-10-19

`spinel-typedump --int-width=32|64` selects the pin's `sp_target_int_bits`
before parsing and analysis in the same process. Its default remains the host
width. `slc_set_target_int_bits` is the narrow contract entry point; no vendor
change or 32-bit host executable is needed.

The freestanding emitter and the CORE application kernel resolve the target
pointer width, the profile claim and the source's first line before requesting
analysis. Unknown widths and mismatched claims are refused. The source marker
selects a 64-bit body; it does not change the target's pointer or boundary ABI.
Integer constants, helpers, comparisons and checked arithmetic follow the body
width. Descriptor counts and failure-hook operands retain their physical u64
and i64 carriers, respectively. Scalar i64 boundaries require a declared wide
body on a 32-bit target; buffer element widths remain independent.

The first 32-bit pass identified these sources whose existing behavior is
preserved by an explicit declaration:

| Sources | Existing wide requirement |
| --- | --- |
| `tests/freestanding/e040/e040_kern.rb` | `bigmul` and `mulwide` i64 results; shared by e040, bm040, bm040-frdm and e063 |
| `tests/freestanding/e077/e077_kern.rb` | `recsum` i64 result |
| `tests/freestanding/e081/e081_kern.rb` | `pin_probe` i64 result |
| `tests/freestanding/e079/e079_kern.rb`, `e083/e083_kern.rb`, `e084/e084_kern.rb` | PRNG modulus literal 2147483648 |
| e040's generated `d04_i64`, e077's generated `e14_stride`, e081's `reject/c1_ok.rb` and `reject/c3_wrap_narrow.rb` | Preserve existing i64 boundary and narrowing controls |
| `examples/doom/core/src/*.rb`, `examples/doom/core/knot/*.rb` | DOOM's existing wide Integer contract; generators and packed sources preserve the declaration |
| `tests/core-stack/fixtures/stack.rb`, `tests/app/fixtures/cross/{zero,probe}.rb` | Existing i64 scalar contracts and division-helper evidence |
| `tests/app/fixtures/lowering/body.rb` | Intentional i64 division-helper control; the packed fixture keeps the declaration before byte helpers |
| `tests/app/fixtures/build/divides/app.rb` | Existing i64 division and release-5 failure lifecycle |
| `tests/app/stress/app.rb` | Checksum multiplier literal 2654435761 |
| `tests/app/fixtures/channel/app.rb` | Decimal-output literal 4294967296; its oracle suite is held, not a validation claim here |

The new non-oracle controls are
[`tests/contract/int-width.rb`](../../tests/contract/int-width.rb) (10 pass),
[`tests/freestanding/int-width/run.rb`](../../tests/freestanding/int-width/run.rb)
(4 pass) and [`tests/app/int-width.sh`](../../tests/app/int-width.sh) (3 pass).
They observe target literal classification, intermediate overflow at 2**31,
the wide declaration, profile disagreement, and a status-returning helper with
a borrowed buffer and literal byte access. The application lowering suite also checks literal-buffer
borrowing: its hidden descriptor count remains u64 when Integer is i32.

After incorporating main's narrow buffer elements, the freestanding runner
passed every available lane in 182 seconds: e040 84, bm040 46, bm040-frdm image
9, e063 48, e077 127, e081 57, e079 52, e083 80 and e084 104 checks, all with
zero failures. The profile reader passed 5 tests / 27 assertions. The e040 and
bm040 FRDM hardware executions were not run because no board destination was
configured. Native core acceptance passed 33 checks, DOOM entries 31 and
object relocation controls 7. The three DOOM entry objects and nine source-entry objects (`col`, `span`, `mjob`, `none`, `tex`, `mask`, `flat`, `zone`, `zalloc`) matched the SHA-256 digests generated before this change at main 9a92698 (12 match, zero differences). Source manifests were refreshed for the added declaration; executable object bytes did not change. Application cross and lowering each passed 45,
and production stress passed 12. The application build suite's fresh repeat
passed 40 checks. Its first run had one console-tail framing failure
(`system-ar` after the last decoded frame); the unchanged main build suite
passed twice, and direct console checks of main and i32 firmware each passed
10 times. The initial failure was not reproduced and is not classified as an
existing issue or as a width regression.

The aggregate application runner includes oracle checks indirectly:
`channel.sh` runs a CRuby byte table, and `verify.sh` invokes CRuby trace replay.
Their results are excluded from the non-oracle acceptance evidence above.
The wide channel `fill` fixture was separately packaged and compiled for
Cortex-M33 without running that suite. The verification replay's own Integer
model remains a separate limitation for undeclared i32 overflow; Task 11's
measurements below bypass replay entirely.

### Task 11 instruction counts without replay

The measurement builds verification firmware with `spinel-core-app build
--verify --app SOURCE --board mps2_an521 --stimulus STIMULUS --out OUTDIR`.
The sample additionally uses its committed `mps2_an521.overlay`. The source
is copied unchanged for 32 bits and with a first-line `# spinel: int64` for the
64-bit control. Run the published `zephyr.elf` directly with the QEMU recorded
in `firmware/build.json`, using the mps2/an521 flags from Task 11 and
`-icount shift=5,align=off,sleep=off -rtc clock=vm`. Stop after `SPC_END` and
read the `SPC_CYCLES` lines with `CoreApp::Console`; do not invoke the `verify`
command or its CRuby replay for this measurement.

At 25 MHz and icount shift 5, instructions = cycles × 5/4. Totals and counts
per invocation are rounded as in Task 11. These include verification overhead
and do not measure production performance.

| Body | Entry | Invocations | Cycles | Instructions/invocation | ldivmod calls | Instructions inside ldivmod |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| i32 | sample | 49 | 50154 | 1279 | 0 | 0 |
| i64 | sample | 49 | 50154 | 1279 | 0 | 0 |
| i32 | report | 9 | 27912 | 3877 | 0 | 0 |
| i64 | report | 9 | 27883 | 3873 | 0 | 0 |
| i32 | command_poll | 4 | 3698 | 1156 | 0 | 0 |
| i64 | command_poll | 4 | 3697 | 1155 | 0 | 0 |
| i32 | divides/step | 3 | 166 | 69 | 0 | 0 |
| i64 | divides/step | 5 | 800 | 200 | 4 | 405 |

The divides rows have different failure endpoints and are not a speed
comparison. After the first two invocations, acc is 2 and then 500003. The
third multiplication is 500003 × 1000003 = 500004500009, outside i32, so the
32-bit run reports ARITHMETIC at release 3. The declared-wide fixture keeps
its release-5 endpoint and its four 64-bit divisions. Task 11's historical
64-bit sample figures (1279 / 4461 / 1155) remain historical evidence; the
table above contains the fresh runs at this revision.

## macOS evidence, 2026-10-19

On macOS arm64 with LLVM 23.1.1, a clean build of `642fda4` passed:

- `tests/contract/int-width.rb`: 10/0.
- `tests/freestanding/int-width/run.rb`: 4/0.
- `tests/app/int-width.sh`: 3/0.
- `tests/freestanding/run.sh`: every lane passed. The FRDM-MCXN947 lanes were
  NOT RUN without `FRDM_HOST`.
- `tests/doom-core/entries.sh`: 31/0.
- `tests/doom-core/object-relocs.sh`: 7/0.
- The individual application suites:
  - contract 66/0, effects 20/0, reserves 33/0, cross 45/0, lowering 45/0;
  - build 40/0, host 56/0, board 82/0, stress 12/0;
  - platform-facts, with no failure among its required facts.

`tests/core/run.sh` passed 21 and failed 12. A clean build of main `9a92698`,
run the same way, fails the same 12 checks by name. They are the known macOS
failures, not a regression.

The CRuby comparisons were not run on either host. They are
`tests/app/channel.sh`, `tests/app/verify.sh` and the `verify` command, and
`tests/app/doom-admission.sh`.

## Revision, 2026-10-21: no 64-bit Integer on a 32-bit target

The owner revised item 3 and the 2026-10-19 decision that "a declared `int64`
needs no recorded reason". On a target whose pointers are 32 bits, a source
can no longer keep 64 bits:

- **The width declaration.** `# spinel: int64` on a freestanding kernel, a
  CORE application or a CORE entry unit is refused when the target's pointers
  are 32 bits, unless the source is listed in `tools/core/int64-allow.tsv`.
  - Each row of that table names one source and why its 64-bit Integer is
    not performance-critical (owner, 2026-10-21): typically a test whose
    subject is 64-bit arithmetic or a 64-bit platform value.
  - A listed source builds at 64 bits as before.
  - An unlisted one computes at 32 bits or does not build, and the
    diagnostic names the table.
  - DOOM's CORE entries and its board application are not listed. Code that
    runs on the board for real stays at 32 bits.
- **The boundary.** An `i64` result, `i64` scalar parameters and `i64` extern
  values stay refused there, as item 4 already says.
- **Unchanged:**
  - the u64 descriptor counts of decision 0007, which are not general
    scalars;
  - buffers whose elements are `i64`;
  - the 64-bit division helper inside decision 0022's `core_fixed_div`;
  - 64-bit targets, where `# spinel: int64` changes nothing.
- **When.** The refusal applies at once (owner, 2026-10-21). The sources that
  declare `int64` and build for a 32-bit target move to 32 bits, or their
  32-bit builds stop:
  - DOOM's step and render entries, and the board application, migrate under
    decision 0022. Until they do, the FRDM-IMXRT1186 lane does not build them.
  - Freestanding cases whose subject is 64-bit arithmetic run on 64-bit hosts
    only.
  - Application fixtures that declare `int64` move to 32 bits or to a 64-bit
    target.

## Implementation of the revision, Debian evidence, 2026-10-21

**The refusal.** The kernel (`Core/Boundary.cpp`, so `spinel-core-app` too),
`spinel-fs-emit` and `spinel-fs-grad` read the source's first line before
analysis. On a 32-bit target a declared source must be listed in
`tools/core/int64-allow.tsv`; otherwise the build stops with
`<file>:1: int-width-int64-refused`, and the message names the table.

- A source is listed when its bytes are a listed file's current bytes. The
  lanes compile copies, so the path a tool is given is not used.
- Every read checks the whole table. A malformed row, a path listed twice, a
  path that does not exist, or a listed file without the declaration refuses
  every source (`int64-allow-table`, naming the row).
- `--int64-allow FILE` reads another table. Its paths are relative to the
  directory two levels above it.
- A listed source builds at 64 bits as before.
- The i64-boundary diagnostics of an unlisted source now say to use i32.

**The table** lists e081's kernel and its two accepted reject fixtures, as
the owner ruled for e081's 64-bit Zephyr platform values.

**The sources, per the coordinator's rulings:**

- **e079, e083, e084.** `gen_row`'s LCG keeps its rows under
  `overflow: :wrap`, written as `% (m + m)` with `m = 2**30` plus a fix-up.
  The freestanding lane admits no `&`.
  - The rewrite was compared with the declared generator of the base, on the
    x86_64 host and on wasm32, for k = 0..65535. The rows are identical.
  - A perturbed generator differs on all 64 fixture rows.
- **e040.**
  - `mulwide` and `bigmul` moved to `e040_wide.rb`. `run_wide.sh` builds it
    for the 64-bit host only, against values worked by hand.
  - In a 32-bit body, `add(2147483647,1)`, `mulnarrow(46341,46341)` and
    `abi4(-2147483648,1,0,0)` trap with code 1, in the body, not code 3.
- **The gates that named a 64-bit helper of the kernel.**
  - e040's `e03_nortdeny` and e063's `g1`/`g2` gate a planted C object, each
    with an allowing control.
  - The 32-bit kernels import only `spinel_trap`.
- **e077.** `recsum` and the sums return `:i32`.
- **cross.sh's D1 probe and lowering.sh's final probe** take
  `core_fixed_div`, now the only `__aeabi_ldivmod` caller.
- **wrapper32.rb.** The int64-body rows became refusals.
- **stress.** It uses `core_w32_mul(s, -1640531535)`, so the wire frames are
  unchanged.
- **Unlisted and recorded in `tools/test/known.tsv`.** `divides` and
  `channel/app.rb` are used only by the held oracle suites.
  - Later, 2026-10-22: the owner kept `divides`, and the table lists it as
    decision 0014's D3 64-bit division control. `tests/app/build.sh`'s
    unlisted-int64 controls now plant an edited copy of it, which is not
    listed. `channel/app.rb` stays unlisted.
- **DOOM's entries and the board application** are unchanged, under 0022.

**Runs.** These are the non-oracle tests `tools/test/affected.rb` selected,
on Debian, without `ALLOW_ORACLE`:

| test | result |
| --- | --- |
| `tests/freestanding/run.sh` | every lane passed, 158 s |
| `tests/app/int-width.sh` | 6/0 |
| `tests/app/cross.sh` | 47/0 |
| `tests/app/lowering.sh` | 45/0 |
| `tests/app/build.sh` | 43/0 |
| `tests/app/stress.sh` | 12/0 |
| `tests/core/run.sh` | 33/0 |
| `tests/core-report/run.sh` | 636/0, 1 skipped |
| `tests/core-stack/run.sh` | 31/0, 1 skipped |
| `tests/core-boundary/intrinsics.sh` | 50/0 |
| `borrowed-calls` | 47/0 |
| `control-flow` | 55/0 |

In `tests/freestanding/run.sh`, the FRDM lanes were NOT RUN without a board.

**Known failures.**

- `tests/core-boundary/run.sh`: 8 of 11 lanes. `schema`, `framebuffer` and
  `closure` fail, as `known.tsv` records.
- `tests/affected/run.sh`: 35/38. The same three checks fail at the base
  61b5ee9.

**Not run:**

- the board checks;
- `loop-reports.sh`, which takes hours;
- the oracle suites.
