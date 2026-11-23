# 0028: A doorbell over the MU for the channels between the FRDM-IMXRT1186's cores

- Date: 2026-10-26
- Status: Accepted by the owner on 2026-10-27. The owner had decided on
  2026-10-26 that the doorbell follows stage 2 of decision 0027 as its
  second part, under its own decision, and on 2026-10-27 approved the six
  points under The owner's decisions as recommended: Q1 MU1, channel 0 from
  the M7 to the M33 and channel 1 back, MU2 free, as a board fact; Q2 the
  put writes one GIRn bit of its own side's GCR; Q3 a 10 ms time-out for the
  console relay; Q4 the `wake:` keyword; Q5 the drift's estimate in a new
  line per channel; Q6 ABI version 4. Nothing here is implemented yet.
- Scope: a channel of 0027 whose consumer is woken by the other core's
  Messaging Unit (MU) when a message is put. The consumer then no longer has
  to poll. The wait from put to get is measured as 0027's stage 2 measured
  it, and compared with stage 2's baseline.

## Context

What exists on main at `f20f512`. Zephyr paths are of the pinned tree,
v4.4.2 at `dccb09599635bdff17633fa7e9dab014b91dce90`. RM is IMXRT1180RM
Rev. 9.

### What stage 2 left for this record

- **The channel polls.** The consumer of 0027's `console` channel, the
  companion's relay, takes up to 4 messages every millisecond
  (`every_ms 1`). The producer, `pair.rb` on the M7, puts one line a tic.
- **ABI version 3 already leaves room** (0027, `tools/app/ring/ring_abi.h`):
  - the descriptor's `flags` carry a `notify` byte (bits 24-31), 0 for
    polling;
  - each channel has a `rung` word in its producer line P and a `waiting`
    word in its consumer line C;
  - both stay 0 in stage 2, and the start-up checks refuse a channel where
    either is not 0.
- **The baseline**, from 0027-results.md: DEMO1 and DEMO3 at `3b2a7cd`, as
  the lane printed them.

  ```
  pair-counts: wait console: n=5027 min=11.75 mean=491.03 max=1039.342 us p50<=546.129 p99<=1092.263 us poll_max=1182.971 us sync_err=+-0.754 us drift=0.0 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
  pair-counts: wait console: n=2135 min=11.663 mean=497.799 max=1017.146 us p50<=546.129 p99<=1092.263 us poll_max=1221.779 us sync_err=+-0.721 us drift=0.0 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
  ```

  - The waits spread over the 1 ms poll: a mean near 0.5 ms, p99 at most
    1.09 ms.
  - The drift in these lines is a lower bound (0027-results.md).
  - The get's reference is extrapolated at the nominal 33/10, so late waits
    in a run may carry a bias of some ten microseconds, which the void rule
    catches.
- **Open items carried here** (0027, Out of scope / later):
  - **(b), the drift's estimate.** Keeping each drift round's trip in the
    header would turn the drift from a lower bound into an estimate. It adds
    ABI words.
  - **The clock ratio.** It may differ from the nominal 33/10 by some
    0.1 ppm. Not confirmed.

### The MU (RM §37; 0027's facts)

- **The instances.** Two core-to-core MUs, MU1 and MU2, each with an A side
  for the M33 and a B side for the M7 (§4.2 Table 11; §3.4, §3.5). Their
  interrupts are IRQ 21 and 22.
  - MU1_A is at `0x4422_0000` (secure `0x5422_0000`), MU1_B at
    `0x4423_0000`.
  - Zephyr labels them `mbox1_a` and `mbox1_b`, `mbox2_a` and `mbox2_b`.
- **The general-purpose interrupt** (§37.3, the interrupts, and §37.7, the
  register map). Each side has four.
  - The sender sets a bit GIRn of its General-Purpose Control register
    (GCR, offset `0x114`).
  - The MU sets GIPn in the receiving side's General-purpose Status
    register (GSR, `0x118`). The receiver is interrupted when GIEn is set in
    its General-Purpose Interrupt Enable register (GIER, `0x110`).
  - The receiver clears GIPn by writing 1 to it. That clears the sender's
    GIRn.
  - The RM: "Before writing 1 to GCR[GIRn], verify that the field is 0 ...
    Generally, MU ignores writing 1 to this field while the field is already
    1, but in some cases it may issue a second interrupt."
- **Zephyr's driver.** `drivers/mbox/mbox_nxp_imx_mu.c`:
  - signalling mode is `mbox_send` with no message. It calls
    `MU_TriggerInterrupts` (`modules/hal/nxp/.../fsl_mu.c:314-333`), which
    sets the bit only when the previous request was taken, and otherwise
    returns a failure the driver ignores (`:62-79`);
  - its interrupt handler, `mu_isr`, clears the pending flag, then calls the
    callback the channel registered (`:180-202`).

### Two constraints from stage 2

- **A channel's put and get call nothing outside their unit.** That is what
  makes their stack evidence their own frame (0027, the owner's choice of
  DWT CYCCNT for the same reason). `mbox_send` is a call into the driver,
  and through it the HAL.
- **An entry runs only when its trigger releases it.** The scheduler thread
  sleeps until the next release time of its thread entries (`main.c.erb`,
  `spc_scheduler_thread`). Nothing releases an entry early today.

## Proposal

### The protocol, in the words version 3 reserved

The words version 3 reserved, each in its place. Version 4 (Q6) only adds
the drift line of Q5.

- **The consumer**, finding the ring empty, stores `waiting = 1`, issues a
  barrier, and reads `head` again. If a message arrived meanwhile, it takes
  it. Otherwise it returns. On taking a message it stores `waiting = 0`.
- **The producer**, after publishing `head`, issues a barrier and reads
  `waiting`. When it is 1, the producer rings and counts `rung`.
- **No wake-up is lost.** A put that misses `waiting = 1` happened before the
  consumer's second read of `head`, which then sees it.
- **The descriptor's `notify` names the doorbell:** the MU instance and its
  channel (for example bits 24-25 the instance, bits 26-27 the channel).
  Both images check it at start against their compiled value, as every other
  descriptor word is checked.

### Ringing: one register write in the put

- **The put rings by writing the sender's GCR directly**, after reading that
  GIRn is 0, as the RM asks. It is a load and a store at a fixed address in
  the unit, like DWT CYCCNT's load, so the put still calls nothing.
- **The address is the producer core's view of its own MU side**: MU1_B for
  the M7, MU1_A for the M33.
- **A ring that finds GIRn still 1 is not repeated**: the consumer has not
  taken the last one yet, and will see every message when it does.

### Waking: the MU interrupt brings the consumer's release forward

- **The interrupt is Zephyr's MU driver's.** The glue registers a callback on
  the channel and enables it (`mbox_register_callback`, `mbox_set_enabled`).
  The callback runs in the interrupt.
- **The callback marks the consumer's entry due and wakes the scheduler
  thread** (`k_wakeup`). That thread runs the entry, as it runs any due
  entry.
- **The entry's own period stays, as the time-out.**
  - A doorbell that never comes (lost, or the producer stopped) leaves the
    consumer polling at its period, as in stage 2.
  - That period can then be longer than stage 2's 1 ms: 10 ms for the
    console relay (Q3).
- **The MU interrupt is a new interrupt source.** The build's inventory names
  each source and its reserve (decision 0014, `reserves.tsv`), so the MU
  handler needs a traced reserve row on the consumer's board. Without one,
  step 10 refuses the image, as it refuses any unlisted handler.

### The measurement

- **The same lane as stage 2:** `RT1186_PAIR=1 tests/doom-core/rt1186.sh`,
  `pair.rb` with `companion.rb`. Two counts join the report: `rung` on the
  producer's line, and the doorbell wake-ups on the consumer's.
- **Compared with the baseline under its conditions:** DEMO1 and DEMO3, the
  relay's 4 gets a release, `vcom` depth 32, both clock rates. Only
  `notify` and the consumer's period change.
- **The expectation, not a measurement.** The wait should fall from about
  0.5 ms to the interrupt's latency plus the scheduler's dispatch. A wait
  near the period would mean the doorbell is not waking.

### Failures and controls

Each control is planted by the build and checked by name on the board:

- **A put that never rings.** The relay still runs, at its period, and its
  waits spread over that period. `rung` stays 0.
- **A consumer that never enables the interrupt.** The same outcome. The
  doorbell is only a wake-up, never the data path.
- **A descriptor whose `notify` differs between the images.** The start-up
  check refuses the channel and names the word, as for any descriptor word.
- **The counts still close** after a drained run, by the four equations of
  0027, and the wait is reported as in stage 2.

## The owner's decisions (2026-10-27)

Each is an ABI choice, a platform write, or new vocabulary. The owner
approved all six as recommended.

- **Q1. Which MU and which channels. Decided: MU1, as a board fact.**
  - MU1 carries the pair's channels, one general-purpose interrupt per
    direction: channel 0 for the M7 to the M33, channel 1 for the M33 to the
    M7, as Zephyr's `samples/drivers/mbox` pairs `mbox1_a` and `mbox1_b`.
  - MU2 stays free.
  - The allocation is a board-table fact (like `core`), not a field of the
    `.channel` contract.
- **Q2. Writing the MU's GCR from the put. Decided: the direct write.** A
  platform write, as DWT's was.
  - The put reads and sets one GIRn bit of the producer's own side's GCR,
    and writes nothing else. The receiving side is left to Zephyr's driver.
  - The alternative was Zephyr's `mbox_send`, a call outside the unit, whose
    frames the stack evidence would then have had to carry (the HAL's and
    the driver's).
- **Q3. The time-out: the consumer's period with the doorbell. Decided:
  10 ms for the console relay.**
  - A lost doorbell costs at most one period. The wait's report names the
    period it ran with.
- **Q4. How the application says that a doorbell wakes an entry. Decided:
  the `wake:` keyword.** Today a trigger is a period only. This is new
  vocabulary for 0014's scheduling.
  - A keyword on the trigger names the channel, for example
    `every_ms 10, :relay, wake: :console`. It is accepted only when the
    channel is a contract channel this core consumes, and refused otherwise.
  - It also changes what a release is: an entry may run before its period
    is due. The verification build (0014 Task 11) refuses `wake:` for now,
    rather than recording such releases.
- **Q5. The drift's estimate (0027's open item (b)). Decided: a new line
  per channel.**
  - Each drift round's round trip, and the departure of the shortest one,
    are kept in the header, so that the drift is an estimate rather than a
    lower bound.
  - Line M is full, so the words go in a new line per channel.
- **Q6. The ABI's version. Decided: 4.**
  - Q1 to Q4 alone would have kept version 3: `notify`, `rung` and
    `waiting` exist already, and only their values change.
  - Q5 adds a line per channel, so the version moves to 4.
  - Both images come from one build, so no compatibility with version 3 is
    kept (decision 0025's precedent).

## Acceptance

On the board, through `tests/doom-core/rt1186.sh` with `RT1186_PAIR=1`:
during the work at `DEMOS=DEMO1 TICS=500`, and DEMO1 to DEMO3 once at the
end, as stage 2.

- **The frames are the recorded ones,** relayed through the M33.
- **The counts close after the drain.** `rung` and the wake-ups are reported
  beside them.
- **The wait is reported with the doorbell**, under the baseline's
  conditions and the new period, and compared with DEMO1 and DEMO3 at
  `3b2a7cd`.
- **The controls above are refused or fall back by name.**

No oracle is involved: every check compares the board run with its own
build's records, the recorded frames, or the baseline of the same lane.

## Out of scope / later

- **The other direction's first user.** No channel goes from the M33 to the
  M7 yet. Q1 reserves its interrupt.
- **A doorbell for the `udp:` rings of 0024 and 0025.** The network firmware
  polls them and is not a Spinel application.
- **Interrupt-context consumers.** An entry in interrupt context woken by the
  MU would run inside the MU handler. Not proposed.

## Clarification (2026-10-27): what the implementation settled

Within the accepted points, without changing them:

- **The wake is a semaphore, not `k_wakeup`.** The callback gives
  `spc_wake_sem` (count limit 1), and the scheduler thread takes it with its
  next release as the time-out, in place of `k_sleep`. `k_wakeup` on a
  thread that has not yet gone to sleep does nothing, so a doorbell taken
  between the thread's last look at the entries and its sleep would have
  been lost until the period; the semaphore keeps it.
- **A woken entry runs once, early.** A doorbell marks the entry due; the
  scheduler runs it at once and leaves its `last_run` at the last periodic
  release, so the periodic releases are unchanged and stay the time-out.
- **`notify` is 0x01** for the console channel: bits 24-25 the MU (1 is
  MU1), bits 26-27 the general-purpose interrupt (0). Both images check it
  in the descriptor's flags word.
- **The consumer's count of wake-ups is `woken`,** word 5 of line C, in
  ABI version 4. The producer's count is `rung`, word 5 of line P, as
  version 3 reserved it.
- **Line E (Q5)** holds, of the drift rounds: their number, the shortest
  trip with its departure and its round, the last round's trip, departure
  and round, and the longest trip. `pair-counts.rb` prints each departure
  with its half trip as the error, beside the lower bound.
- **The MU's facts** are each board table's `doorbell` row (the side's
  label and base, the interrupts it sends and receives on) and the
  companion's `doorbell_free` (MU2's label, disabled in the consumer's
  devicetree). MU1_B's clock gate, LPCG28, is on from reset (RM Table 136,
  LPCG28_DIRECT reset value 0000_0001h), so the M7 enables nothing.
- **The MU's reserve** is `isr_mbox_nxp_imx_mu` on `frdm_imxrt1186`, the
  companion's reserves board: `_isr_wrapper`, `mu_isr`,
  `z_impl_k_sem_give`, `z_ready_thread`, `ready_thread`, `z_arm_exc_exit`,
  112 bytes from a harness built with `CONFIG_MBOX=y`. Step 10 adds the
  callback's own measured frame.
- **The controls** are `--mutate-doorbell-unrung CHANNEL` (a put that never
  rings), `--mutate-doorbell-unenabled` (a consumer that never enables the
  interrupt) and `--mutate-doorbell-notify CORE` (that core's check wants
  another notify), run on the board by
  `tests/doom-core/rt1186-pair-controls.sh`.

## Amendment (owner, 2026-10-29): the open items, ring ABI version 5

The owner approved both open items of [the results](0028-results.md#open-items),
with the ABI changes they need. The coordinator checked the plan.

- **The longest wait's message.** Line C's word 6, `lat_max_at`, is the number
  of the message whose wait is `lat_max`, in `tail`'s running count: the value
  of `tail` when that message was taken, since each get takes one message.
  `pair-counts.rb` prints it less `init_index`, so 0 is the first put.
- **The drift's rounds, from t1.**
  - The M7 answers from `main` at `K_PRIO_PREEMPT(0)`, above the scheduler's
    1, in place of the lowest priority. The companion's 5 ms time-out is
    unchanged.
  - The M7 stores its stamp, a barrier, then `s7_seq`, with its interrupts
    locked.
  - The companion loads `s7_seq`, a barrier (DMB, ISB), then reads t1. So the
    stamp lies before t1.
  - g is t1 less the previous pass's t1. The previous pass's load did not see
    `s7_seq`, so the stamp lies within g before t1, and the departure measured
    from t1 is in [dev - trip/2, dev - trip/2 + g]: a one-sided bound.
- **Line F**, a sixth line per channel, which the M33 alone writes:
  `timeouts` (the drift rounds no answer came to within 5 ms), g at the
  shortest trip's round, g at the last round, and the largest g. Words 4 to 7
  are 0, and `pair-counts.rb` refuses a header where they are not.
- **The version** is 5. A channel takes six lines, so one channel's header
  is 704 bytes, from 672. No other word moves. `pair-counts.rb` reads version 5
  only and refuses another, named.
- **The stop condition** for the final board run: a missed deadline or a
  fault with the M7 answering at priority 0, or a round that timed out.
  Fewer rounds than due is not one; a slower tic is reported as information.
