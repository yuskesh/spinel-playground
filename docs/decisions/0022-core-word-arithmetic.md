# 0022: Explicit 32-bit word arithmetic in CORE, and DOOM at 32 bits

- Date: 2026-10-21
- Status: Accepted (owner, 2026-10-21). The owner chose the direction the same
  day: add explicit operations, option (a) below.
- Scope:
  - a small set of CORE intrinsics that compute on 32-bit words: wrapping
    `+ - *` and negation, unsigned comparison, logical right shift, and the
    two fixed-point operations `FixedMul` and `FixedDiv`;
  - how DOOM's CORE sources move from `# spinel: int64`
    ([decision 0019](0019-target-integer-width.md)) to the target's 32 bits;
  - a lowering change for the entry wrapper's descriptor checks on 32-bit
    targets. The check stays the same; only the width it is computed in
    changes.

  Ordinary Integer arithmetic in a CORE closure behind the status boundary
  (decision 0007) stays checked: overflow is `ARITHMETIC`. The buffer
  boundary's ABI and the set of descriptors it accepts (0007, 0010) do not
  change.

## Context

**DOOM runs on the FRDM-IMXRT1186 at 64 bits.**
[Decision 0021](0021-doom-core-on-frdm-imxrt1186.md) accepted DOOM's three
CORE entries on the board. The sources declare `int64`, so the Cortex-M33
computes every Integer in two registers.

The board profile of 2026-10-21 (DEMO1, every tenth tic, 503 samples, median)
measured:

| stage | median |
|---|---|
| render | 84.3 ms |
| step | 56.0 ms |
| sha256 | 16.7 ms |
| FNV | 4.9 ms |
| one tic | 164.6 ms |

**Where the 64-bit work is.** This is a static inventory of 1bcde53's thumb
objects and sources. Instruction counts are static, not executed counts.

- **Objects:**

  | object | 64-bit multiplies | `sbc` | `__aeabi_*ldivmod` call sites |
  |---|---|---|---|
  | step | 262 | 42,970 | 19 |
  | render | 208 | 33,748 | 12 |

  - 99.6% of the `sbc` are 64-bit comparisons.
  - Most of them are in the entry wrappers' descriptor checks, which compute
    in i64 (`Kernel.cpp`, the `konst`/`address` helpers and the count, size
    and limit checks).
- **Sources:** the sites that need more than 32 bits, or wrap at 32.

  | entry | `FixedMul`-like products | divisions | BAM angle wraps | `fixed_to_i32` truncations | literals past 2^31 |
  |---|---|---|---|---|---|
  | step | 65 | 29 | 41 | 226 | 58 |
  | render | 39 | 11 | 95 | 125 | 47 |
  | input | – | – | – | – | 1 |

- **Angles:**
  - Angles are held as non-negative Integers up to 2^32−1.
  - 51 lines change meaning if an angle becomes a signed i32: 25 comparisons
    and 26 right shifts into table indices (`>> ANGLETOFINESHIFT`, `>> 29`).
- **Tables:** some tables pack values 56 or 64 bits to an Integer:
  `ST_RND_*`, `KN_WALK` and `SS_USE`.

**Why CORE cannot express this today.**

- At 32 bits, an ordinary `+ - *` that leaves the i32 range is `ARITHMETIC`
  (0015, 0019).
- A literal past 2^31 has no CORE form.
- The width is one per packed entry unit (`tools/doom/pack-core.rb`).
- DOOM depends on three things in particular:
  - **BAM wraps:** modular arithmetic on 32-bit words, as the C original does.
  - **Fixed-point products:** `FixedMul` needs the exact 64-bit product
    before its shift.
  - **Wide numerators:** `FixedDiv` needs `a << 16` as a wide numerator.

## Options

- **(a) Explicit word operations** (chosen).
  - Ordinary arithmetic stays checked.
  - The few places that mean modular or wide arithmetic say so by name.
- **(b) Plain 32-bit CORE as it is.**
  - Every wrap and product would be written as 16-bit halves with carries.
  - The 136 BAM wraps and 104 products make this slow and error-prone. It
    would cost much of what the move to 32 bits gains.
- **(c) A per-function width.**
  - This keeps `fixed_mul`/`fixed_div` at 64 bits but leaves the BAM wraps
    unsolved.
  - It needs per-definition literal classification and width conversion
    across calls. `spinel-typedump`'s width is process-global
    (`slc_set_target_int_bits`), and the packer raises the whole unit to
    `int64` when any part declares it.
- **(d) A source-wide `wrap` declaration**, upstream's
  `--int-overflow=wrap` applied to a CORE unit.
  - Index, counter and coordinate arithmetic share the closure with the
    angles, so their overflow would also become a value.
  - Upstream's wrap also defines `MIN / -1`, `abs(MIN)` and every shift count,
    which CORE refuses today.
  - The emitter's `OverflowMode` treats status and wrap as exclusive
    (`MlirGen.cpp`), so failure delivery and the arithmetic policy would have
    to be separated first.
  - It may be worth a later decision of its own. It is not the way to move
    DOOM.

## Decision

### 1. Word intrinsics

These names are CORE intrinsics in a checked CORE closure behind the status
boundary (`spinel-core-contract`, decision 0007). This slice does not
recognise them in the native `--core` slice (0015) or in freestanding
kernels; those deliver failure differently and would each need their own
rule.

**Types.**

- Every operand must be an Integer in the i32 range, on every target. An
  operand outside it is `ARITHMETIC`, checked before the operation and taking
  precedence over any other outcome, including `core_fixed_div`'s early
  saturation.
- The comparisons answer a Boolean.
- Every other intrinsic answers a signed i32: the low 32 bits of its result,
  read as two's complement. A 64-bit host computes the same answers as the
  board.

**Recognition.**

- Only a call with no receiver, exactly the listed number of positional
  arguments and no block, keyword or splat is the intrinsic.
- These are refused in this slice:
  - `self.core_*` and `Obj.core_*`;
  - `send`;
  - `alias`;
  - a wrong arity;
  - a block, keyword or splat argument.
- When the selected closure calls one, and the captured packed unit also has
  a top-level definition of that name, the build is refused
  (`conflicting-intrinsic`). The name is not reserved otherwise. A call is
  never substituted silently.
- The Ruby prelude that gives the CRuby route the same results is never part
  of the source handed to CORE.

**Lowering.** After the operand checks, each intrinsic's normal path lowers
to straight-line code with no call. The only exception is `core_fixed_div`,
below. The checks themselves branch to the status return.

| intrinsic | result |
|---|---|
| `core_w32_add(a, b)`, `core_w32_sub(a, b)`, `core_w32_mul(a, b)` | the low 32 bits of the exact result |
| `core_w32_neg(a)` | `core_w32_sub(0, a)`; `core_w32_neg(-2**31)` is `-2**31` |
| `core_u32_lt(a, b)`, `core_u32_le(a, b)`, `core_u32_gt(a, b)`, `core_u32_ge(a, b)` | the comparison of the two operands' bit patterns as unsigned 32-bit words |
| `core_u32_shr(a, n)` | the logical right shift of `a`'s bit pattern by `n`, read back as signed. `n` must be in 0..31, otherwise `ARITHMETIC`. `core_u32_shr(a, 0)` is `a`, so `core_u32_shr(-1, 0)` is `-1` |
| `core_fixed_mul(a, b)` | `low32(asr(p, 16))` where `p` is the exact signed 64-bit product (`-2**31 * -2**31 = 2**62` fits): `DG/m_fixed.c`'s `FixedMul` |
| `core_fixed_div(a, b)` | exactly today's `fixed_div` in `examples/doom/core/src/fixed.rb:53`, for every pair of i32 inputs |

`core_fixed_div` in detail:

- **Saturation.** It saturates when `(|a| >> 14) >= |b|`, with mathematical
  absolute values.
  - The result is `I32_MIN` when `(a ^ b) < 0`, and `I32_MAX` otherwise.
  - So `(0, 0)` and `(1, 0)` give `I32_MAX`, and `(-1, 0)` gives `I32_MIN`.
  - `b == 0` therefore saturates and never divides.
  - The guard is not "clamp the quotient to i32": `(16384, 1)` saturates to
    `I32_MAX` although its quotient, 1073741824, is an i32.
- **Otherwise.** The result is the quotient of `a * 65536` by `b`, truncated
  toward zero and computed exactly.
  - The guard bounds its absolute value below 2^30.
  - The low-32 step of today's definition is kept, as part of the equivalent
    statement.
- **Lowering.** It may use the target's 64-bit division helper. The helper is
  recorded as 0021 records helpers.

### 2. DOOM's sources at 32 bits

1. **Width.** The CORE sources drop `# spinel: int64` and compute at the
   target's width. On the hosts, this is 64 bits.
2. **Explicit wraps.**
   - Every BAM wrap becomes a `core_w32_*` call.
   - Every `FixedMul` and `FixedDiv` becomes `core_fixed_mul` or
     `core_fixed_div`.
   - Every `fixed_to_i32` that stands for a C truncation of a wrapping
     result becomes the wrapping operation itself.
   - A truncation that cannot wrap is removed after the inventory shows why.
3. **Angles as signed i32 bit patterns.**
   - `ANG180` is written `-2147483648`.
   - The 25 comparisons use `core_u32_*`.
   - The 26 index shifts use `core_u32_shr`.
4. **Angle cells.**
   - Buffers that hold angles change their element from `u32` to `i32`
     (decision 0018's width table).
   - The element then stores the bit pattern, and no bit-level load or store
     contract is needed.
   - The angle slots of `core_state` that the port writes through
     `core_w32_*` hold the same signed pattern in their i64 cells
     (`examples/doom/core/state-repr.tsv`; the coordinator's correction, 2026-10-22).
   - The schema, the session image, the Full/adapter side and the recorded
     cells move together.
5. **Tables.** Tables packed past 32 bits are repacked into 32-bit words. The
   source digests and manifests are updated with them.
6. **Order.** The entries move one at a time:
   1. input;
   2. render, the largest stage;
   3. step.

   Today the three entries share one packed file (`stage/src/packed.rb`). The
   packer raises the whole file to `int64` when any unit declares it. So the
   first step gives each entry its own packed file and its own width line in
   the manifest. An entry that has not moved keeps `int64`. Removing one
   unit's declaration never moves an entry that is not ready.

### 3. The entry wrapper on 32-bit targets

The descriptor checks keep their meaning and their `ARGUMENT` results. These
are the checks:

- count domain;
- `count * size` and `base + size` within the address width;
- null base;
- alignment;
- overlap, including against the result pointer;
- a read count's value within the effective Integer range (decision 0019):
  `INT32_MAX` for a 32-bit body, `INT64_MAX` for one declared `int64`.

On a target with 32-bit pointers, the wrapper may compute the address, range
and overlap comparisons in 32 bits, but only in this order:

1. It refuses a count whose upper word is not zero.
2. It computes `count * size` in a width that cannot overflow, and checks
   `count * size <= UINTPTR_MAX - base`.
3. Only then does it narrow a value to 32 bits.

A range is compared in 32 bits only when each of its endpoints has been shown
to be representable there.

- **Buffers.** The exclusive end of a buffer is at most `UINTPTR_MAX`, so
  after step 2 buffer-against-buffer comparisons can be done in 32 bits.
- **The result pointer.** Its end (`r + 4` or `r + 8`) may be `2**32`. For
  example, with `r = 0xfffffffc` and a u8 buffer at `0xfffffff8` with
  `count = 7`, today's wrapper refuses the overlap. A 32-bit `rEnd` would be
  0, and the overlap would be missed.
- **Keeping that refusal.** The result comparisons therefore do one of these:
  - keep a carry or end sentinel;
  - use an equivalent overlap test that adds no endpoint;
  - stay in i64.

  None of them may be replaced by a new refusal of high result pointers,
  since that would narrow the accepted set.

The other rules stay as they are:

- the ABI's u64 count;
- the exclusive-end rule;
- zero length.

No check is computed in a wrapped value. This item stands on its own and is
measured on its own, so that its effect is not confused with item 2's.

## Acceptance

- **Intrinsics.** These hand-computed values are observed by running them on
  both hosts and on the board, not only read from the disassembly. Here MIN is
  `-2**31` and MAX is `2**31 - 1`.

  | intrinsic | cases |
  |---|---|
  | `core_w32_add` | `(MAX, 1) = MIN`, in the same body as an ordinary `MAX + 1` that is `ARITHMETIC` |
  | `core_w32_sub` | `(MIN, 1) = MAX` |
  | `core_w32_neg` | `(MIN) = MIN` |
  | `core_w32_mul` | `(MIN, MIN) = 0` |
  | `core_u32_lt` | `(0, MIN) = true`, `(MIN, 0) = false` |
  | `core_u32_le` | `(MIN, MIN) = true` |
  | comparison results | used in a real branch |
  | `core_u32_shr` | `(-1, 0) = -1`, `(-1, 31) = 1`; counts −1 and 32 are `ARITHMETIC` |
  | `core_fixed_mul` | `(-1, 1) = -1` (rounding toward zero is refused), `(MIN, MIN) = 0` |
  | `core_fixed_div` | `(±16383, 1) = ±1073676288`; `(16384, 1) = MAX`; `(-16384, 1) = MIN`; `(MIN, MIN) = 65536`; `(-1, 3) = -21845`; `(0, 0) = MAX`; `(1, 0) = MAX`; `(-1, 0) = MIN` |

- **Controls:**
  - **Operand range.** An out-of-i32 operand is `ARITHMETIC`.
    - It is passed at run time to a 64-bit or `int64` body. A 32-bit
      literal's parse-time refusal is not evidence for the run-time guard.
    - `core_fixed_div(2147483648, 0)` is `ARITHMETIC`, not saturation.
  - **Conflicting names.** A `def core_w32_add` in the packed unit that the
    closure calls is refused, as are each refused call shape, a wrong arity
    and a wrong type.
  - **Inlining.** One fixture shows the intrinsic means the same after its
    callers are inlined.
- **Lowering.**
  - **Thumb.** The board's objects show `core_fixed_mul` as one long multiply
    and shifts, with no call, and the wrapper's 32-bit comparisons.
  - **Hosts.** The code the wrapper lowering does not touch is unchanged on
    the hosts.
- **Wrapper.** Positive and negative fixtures, so that a narrowed accepted set
  cannot pass on negatives alone.
  - **Descriptors:**
    - zero-length NULL accepted;
    - misaligned non-NULL with a nonzero count refused;
    - misaligned non-NULL with a zero count accepted;
    - malicious u64 counts and aliases refused.
  - **Ranges:**
    - read-only overlap accepted;
    - adjacent ranges accepted;
    - `end == UINTPTR_MAX` accepted.
  - **Counts:**
    - read and unread counts at both effective widths;
    - an `int64` body with 32-bit pointers.
  - **The result pointer:** the result-end carry case above refused.

  The fixtures touch no memory beyond what the guards admit.
- **DOOM.** The board lane with `DEMOS=DEMO1 TICS=500` matches the recorded
  frames during the work.
  - The checks for a change are the ones `tools/test/affected.rb` selects
    (owner, 2026-10-21).
  - The CRuby comparisons wait until the 32-bit entries run on the board.
  - Before main takes the work, the end-of-development checks run once:
    DEMO1 to DEMO3 on the board and the lanes the preprocessor names.
- **Measurement.** The board profile is re-measured with the same method, for
  each item separately where it can be.

## Consequences

- The number contract changes in one named place. Ordinary Integer arithmetic
  stays checked, and only these intrinsics wrap.
- CORE's claims about allocation and the runtime do not change.
- DOOM's sources stop meaning the same as their 64-bit Ruby original line for
  line. Each changed site says what C meant.
- A source-wide wrap mode (d) remains open for a later decision.

## Owner's decision, 2026-10-21: the entries' boundary types

A 32-bit body refuses an `i64` result, `i64` scalar parameters and `i64`
extern values (0019; `Boundary.cpp`). DOOM's three entry contracts declare
their result and their non-count scalars `i64`. The buffers' `u64` counts are
descriptor counts (0007), not general scalars, and are not refused.

The owner chose to change the entry contracts, not 0019's rule:

- **Types.** Each entry's result and its non-count scalars become `i32` as the
  entry moves to 32 bits. These are `scripted`, `tic` and `recording`
  (input), `predraws` (step), and `first`, `health`, `armorpoints`,
  `ammokind`, `viewx`, `viewy`, `viewz` and `viewangle` (render).
- **Ranges.** Every value fits i32 by type and by the ranges observed over
  DEMO1 to DEMO3, except `viewangle`. That angle is passed as its signed i32
  bit pattern, as section 2.3 holds angles.
- **What changes.** The contract generator (`tools/doom/core-entries.rb`)
  changes, along with the native preparation's FFI (`core-native-prep.rb` and
  the generated `nativeprep.rb`), the session wrapper's result type
  (`tools/app/lib/core_app/session.rb`) and the callers that pass
  `viewangle`. The adapter follows from the contracts.
- **What does not change.** 0019's rule, the u64 descriptor counts and an
  entry that has not moved.

## Owner's decision, 2026-10-21: a 32-bit cycle count

The `Clock` adapter (decision 0014) answers `cycles()` and `uptime_us()` as
`i64`, from Zephyr's `k_cycle_get_64()` and `k_uptime_ticks()`. A 32-bit body
refuses an `i64` extern value (0019), and DOOM's board application reads
`Clock.cycles` twice per tic.

The owner chose to add `fn cycles32() -> i32` to `Clock`:

- **What it answers.** `k_cycle_get_32()`, read as a signed i32 bit pattern.
- **How the board uses it.** The board application takes a difference with
  `core_w32_sub`.
- **Range.** At 240 MHz the count wraps every 17.9 s, far longer than a tic.
- **What does not change.** `cycles()` and `uptime_us()` stay as they are.
