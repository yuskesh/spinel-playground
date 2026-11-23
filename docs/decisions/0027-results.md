# 0027: results of the board runs (2026-10-26)

The record decision 0027 keeps beside it: what the final board runs of stages 1 and 2 showed.
- The figures are the commands' own output, pasted as printed.
- The wait from put to get is a measurement, not a verdict.
- It is the baseline the doorbell's decision compares with (0027, Out of scope / later).

## Conditions

- **Tips.** DEMO1 to DEMO3 ran at `3b2a7cd`. DEMO1 ran once more at the final tip, `31792e2`: the same firmware, the lane's tools fixed (below).
- **The lane.**
  - `RT1186_PAIR=1 tests/doom-core/rt1186.sh`, without `TICS`, so each demo runs to its end and its counts are read after the drain.
  - `examples/doom/core/board/pair.rb` on the M7, `companion.rb` on the M33.
- **The channel.**
  - `channels/console.channel`: `tic u32`, `len u8`, `text u8 x 119`, depth 16, slots of 160 bytes.
  - The companion relays it every millisecond, up to 4 gets a release, onto its `vcom` uart channel of depth 32.
  - `notify` is 0: the consumer polls, with no doorbell.
- **The clocks.**
  - Each core's DWT CYCCNT: the M7 at 792 MHz, the M33 at 240 MHz, a ratio of 33/10 by the builds' `CYCLES_PER_SECOND`.
  - Both counters run from the 24 MHz RC oscillator, RC24M. The ratio is fixed; the absolute rate carries RC24M's error.
  - The system counter is stopped (CNTCR 0), so it is not used.

## The four equations, after the drain

At `3b2a7cd`, from each demo's `pair-counts-<demo>.out`:

```
-- DEMO1
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 5027 + 0 = 5027, 5027
pair-counts: accepted = head - init_index: 5027 = 5027, 5027
pair-counts: taken = accepted: 5027 = 5027, 5027
pair-counts: taken = written + malformed + held: 5027 + 0 + 0 = 5027, 5027
pair-counts: consumer: state 1, fault 0, tail 5027
-- DEMO2
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 3837 + 0 = 3837, 3837
pair-counts: accepted = head - init_index: 3837 = 3837, 3837
pair-counts: taken = accepted: 3837 = 3837, 3837
pair-counts: taken = written + malformed + held: 3837 + 0 + 0 = 3837, 3837
pair-counts: consumer: state 1, fault 0, tail 3837
-- DEMO3
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 2135 + 0 = 2135, 2135
pair-counts: accepted = head - init_index: 2135 = 2135, 2135
pair-counts: taken = accepted: 2135 = 2135, 2135
pair-counts: taken = written + malformed + held: 2135 + 0 + 0 = 2135, 2135
pair-counts: consumer: state 1, fault 0, tail 2135
```

The fourth equation, the frames on the console against `written`:
- **What happened.** The lane's tool counted the console from the lane's reset. That span also held the end of the run the write itself had started, 89 frames before DEMO1's banner, so it printed `5116 != 5027` and its like. The frames themselves were all judged by `board-frames.rb`, which starts at the banner.
- **The fix.** The tool now counts from the banner (`477dea7`).
- **What was re-computed, and from what.**
  - For each demo, the frames were re-counted from that run's saved console log, against `written` from the lane's output.
  - DEMO3 was judged whole from its saved reads.
  - DEMO1's and DEMO2's reads had been overwritten, a harness defect since fixed (`0c36dd7`). Their first three equations are as the lane printed them, above.

```
== DEMO3, whole, from the saved reads
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 2135 + 0 = 2135, 2135
pair-counts: accepted = head - init_index: 2135 = 2135, 2135
pair-counts: taken = accepted: 2135 = 2135, 2135
pair-counts: taken = written + malformed + held: 2135 + 0 + 0 = 2135, 2135
pair-counts: frames on the console = written: 2135 = 2135, 2135
pair-counts: consumer: state 1, fault 0, tail 2135
pair-counts: wait console: n=2135 min=11.663 mean=497.799 max=1017.146 us p50<=546.129 p99<=1092.263 us poll_max=1221.779 us sync_err=+-0.721 us drift=0.0 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
rc=0
== frames from the banner against written (pair-counts-<demo>.out)
DEMO1: frames from the banner 5027, written 5027: closes
DEMO2: frames from the banner 3837, written 3837: closes
DEMO3: frames from the banner 2135, written 2135: closes
```

At the final tip `31792e2`, DEMO1, the whole judgement as the lane printed it:

```
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 5027 + 0 = 5027, 5027
pair-counts: accepted = head - init_index: 5027 = 5027, 5027
pair-counts: taken = accepted: 5027 = 5027, 5027
pair-counts: taken = written + malformed + held: 5027 + 0 + 0 = 5027, 5027
pair-counts: frames on the console = written: 5027 = 5027, 5027
pair-counts: consumer: state 1, fault 0, tail 5027
pass DEMO1: the console channel's counts close after the drain (tools/doom/pair-counts.rb)
```

The frames, as `board-frames.rb` printed them (`3b2a7cd` DEMO1, DEMO2, DEMO3, then `31792e2` DEMO1):

```
board-frames: build a2aff48316203393, 5026 frame(s), every one the recorded frame; ended after 5026 tics; per tic min 9.2 ms, median 18.3 ms, max 34.5 ms (information, not a bound)
board-frames: build 0d96542478111f01, 5026 frame(s), every one the recorded frame; ended after 5026 tics; per tic min 9.1 ms, median 18.3 ms, max 34.6 ms (information, not a bound)
board-frames: build 9c029274ce289cda, 3836 frame(s), every one the recorded frame; ended after 3836 tics; per tic min 7.7 ms, median 16.8 ms, max 32.5 ms (information, not a bound)
board-frames: build 5d45879b8da9eba0, 2134 frame(s), every one the recorded frame; ended after 2134 tics; per tic min 8.3 ms, median 20.7 ms, max 35.7 ms (information, not a bound)
```

## The wait from put to get

As printed at each run's time:

```
-- 3b2a7cd DEMO1
pair-counts: wait console: n=5027 min=11.75 mean=491.03 max=1039.342 us p50<=546.129 p99<=1092.263 us poll_max=1182.971 us sync_err=+-0.754 us drift=0.0 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
-- 3b2a7cd DEMO2
pair-counts: wait console: n=3837 min=13.138 mean=474.232 max=1051.246 us p50<=546.129 p99<=1092.263 us poll_max=1190.825 us sync_err=+-0.721 us drift=4.217 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz; VOID: the drift is above the alignment's error
-- 3b2a7cd DEMO3
pair-counts: wait console: n=2135 min=11.663 mean=497.799 max=1017.146 us p50<=546.129 p99<=1092.263 us poll_max=1221.779 us sync_err=+-0.721 us drift=0.0 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
-- 31792e2 DEMO1
pair-counts: wait console: n=5027 min=11.65 mean=497.608 max=1056.517 us p50<=546.129 p99<=1092.263 us poll_max=1181.85 us sync_err=+-0.725 us drift=13.688 us; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz; VOID: the drift is above the alignment's error
```

How to read these figures:
- **The drift is a lower bound in all four runs.**
  - The values are 0.0, 4.217, 0.0 and 13.688 us.
  - The companion counts a once-a-second drift round only past that round's own half round trip, and the M7 answers those rounds at its lowest priority.
  - A long round therefore hides a small drift. 0.0 was a run whose rounds were all answered (DEMO3: `s33_seq` and `s7_seq` both `0x14b`) and showed none above their own error.
  - The tool now says so (`abc0276`): `drift >= X us`, or `drift: none seen above the rounds' own error`. The same saved reads give the same numbers in those words (DEMO3 and the final DEMO1).
- **The bias.** The get's reference is extrapolated from the start's alignment at the nominal 33/10. If the real ratio differs, the late waits of a run carry up to the drift, some ten microseconds, a few percent of the mean.
- **VOID.** The figures are void when the drift is above the alignment's error, and the rule is unchanged. It caught exactly that bias in DEMO2 and the final DEMO1.
- **The baseline for the doorbell** is DEMO1 and DEMO3 at `3b2a7cd`.

## Open items

- **The drift's cause.** Possibly the nominal 33/10 differs from the real clock ratio by some 0.1 ppm. Not confirmed.
- **An estimate of the drift.** Keeping each drift round's trip in the header would turn the drift from a lower bound into an estimate. That adds ABI words, so it is left to the doorbell's decision (0027, Out of scope / later).

## The board controls 4 to 6

`tests/doom-core/rt1186-pair-controls.sh` at `3b2a7cd`: 17 checked, 17 pass. The consoles' own lines:

```
pair-id: SPC_CHANNEL_REFUSED cm7 3 90
cacheable-cm7: SPC_CHANNEL_REFUSED cm7 1 720896
cacheable-cm33: SPC_CHANNEL_REFUSED mpu cm33 attr ff regions 1
consumer: P head 16 attempted 15475 accepted 16 refused 15459; C tail 0 state 0 taken 0
```

## The other final runs

- **The `app.rb` lane, DEMO1 to DEMO3, at `3b2a7cd`.** 79 of 79: the network firmware over ring ABI version 3, every frame recorded, the ring drained.
  - DEMO2's network counts in that run were DEMO1's to the digit, DEMO1's boot id included, while DEMO2's console named boot `602d1eb8`.
  - Most likely a stale read: `rt_gdb_read` let an earlier demo's file pass, since fixed in `5855eaa`.
  - Those counts are not a figure this record claims. DEMO2's frames, 3836 of 3836 for boot `602d1eb8`, stand.
- **The `app.rb` lane, DEMO1, at `31792e2`.** 59 of 59. Its network counts' boot, `602d4923`, matches its console's.
- **`tests/doom-core/audit.sh`.** 263 of 263, at `3b2a7cd`, and again at `c4cef48`.
- **`tests/doom-core/rt1186-profile.sh`.** rc 0, at `3b2a7cd`.
- **`tests/doom-core/rt1186-play.sh`.** 9 of 9, at `31792e2`. At `3b2a7cd` it stopped before the board, on `tests/app/play.sh`'s version 2 figures (fixed in `c4cef48`).
