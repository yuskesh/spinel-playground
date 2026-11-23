# 0028: results of the board runs (2026-10-27)

The record decision 0028 keeps beside it: what the final board runs of the doorbell showed.
- The figures are the commands' own output, pasted as printed.
- The wait from put to get is a measurement, not a verdict.
- It is compared with 0027's baseline, DEMO1 and DEMO3 at `3b2a7cd` (0027-results.md).

## Conditions

- **Tips.**
  - DEMO1 to DEMO3 of the pair ran at `1abd974`, and DEMO1's first 500 tics before them, at the same tip.
  - The board controls ran at `cebc350`, which changed only `tests/doom-core/rt1186-pair-controls.sh` (below).
  - The `app.rb` lane, `rt1186-play.sh`, `rt1186-profile.sh` and `audit.sh` ran at `e30462c`, a comment of that script's apart.
  - No firmware, tool or template changed between `1abd974` and `e30462c`.
- **The tools.**
  - The kernel, the reader, the adapter and the pinned compiler are 0027's builds, copied with their sha256 (the kernel `f479debc…`, the reader `bb6d68f6…`): 0028 changes none of their sources.
  - The lane checks each against the tree it runs in, and printed, at `1abd974`:

    ```
    source-stamp: kernel .../0028-impl/bin/spinel-core-kernel: built from this tree's source (174 input(s); the binary's sha256 f479debcc4ceca64)
    source-stamp: reader .../0028-impl/bin/reader/spinel-typedump: built from this tree's source (112 input(s); the binary's sha256 bb6d68f6afe0fed7)
    ```

  - The kernel was built on 2026-10-26; its sources last changed on 2026-10-25.
- **The lane.**
  - `RT1186_PAIR=1 tests/doom-core/rt1186.sh`, without `TICS`, so each demo runs to its end and its counts are read after the drain; `REQUIRE_ALL=1`, so a skipped part fails.
  - `examples/doom/core/board/pair.rb` on the M7, `companion.rb` on the M33.
- **The channel.**
  - `channels/console.channel` as in 0027: `tic u32`, `len u8`, `text u8 x 119`, depth 16, slots of 160 bytes; ring ABI version 4, a 672-byte header.
  - The companion relays it with `every_ms 10, :relay, wake: :console`: released by the doorbell, and every 10 ms at the latest (Q3). Up to 4 gets a release, onto its `vcom` uart channel of depth 32.
  - `notify` is 0x01: MU1, GIR0 (Q1).
- **The clocks.** As in 0027: each core's DWT CYCCNT, the M7 at 792 MHz and the M33 at 240 MHz, 33/10, both from RC24M.

## The four equations, after the drain

From each demo's `pair-counts-<demo>.out`, as the lane printed them:

```
-- DEMO1
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 5027 + 0 = 5027, 5027
pair-counts: accepted = head - init_index: 5027 = 5027, 5027
pair-counts: taken = accepted: 5027 = 5027, 5027
pair-counts: taken = written + malformed + held: 5027 + 0 + 0 = 5027, 5027
pair-counts: frames on the console = written: 5027 = 5027, 5027
pair-counts: consumer: state 1, fault 0, tail 5027
-- DEMO2
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 3837 + 0 = 3837, 3837
pair-counts: accepted = head - init_index: 3837 = 3837, 3837
pair-counts: taken = accepted: 3837 = 3837, 3837
pair-counts: taken = written + malformed + held: 3837 + 0 + 0 = 3837, 3837
pair-counts: frames on the console = written: 3837 = 3837, 3837
pair-counts: consumer: state 1, fault 0, tail 3837
-- DEMO3
pair-counts: drained: two reads 100 ms apart equal, held 0
pair-counts: attempted = accepted + refused: 2135 + 0 = 2135, 2135
pair-counts: accepted = head - init_index: 2135 = 2135, 2135
pair-counts: taken = accepted: 2135 = 2135, 2135
pair-counts: taken = written + malformed + held: 2135 + 0 + 0 = 2135, 2135
pair-counts: frames on the console = written: 2135 = 2135, 2135
pair-counts: consumer: state 1, fault 0, tail 2135
```

Every equation closes exactly, as 0027 requires; nothing here allows a difference.

The frames, as `board-frames.rb` printed them:

```
board-frames: build 3172500cb75c9ea0, 5026 frame(s), every one the recorded frame; ended after 5026 tics; per tic min 9.2 ms, median 18.3 ms, max 34.2 ms (information, not a bound)
board-frames: build 1fb89c3c3617ebfd, 3836 frame(s), every one the recorded frame; ended after 3836 tics; per tic min 8.0 ms, median 16.8 ms, max 32.1 ms (information, not a bound)
board-frames: build 12305618a66b3b3d, 2134 frame(s), every one the recorded frame; ended after 2134 tics; per tic min 8.0 ms, median 20.8 ms, max 35.8 ms (information, not a bound)
```

The lane: 76 checked, 76 pass, 0 fail, 1589 s.

## The doorbell

```
-- DEMO1
pair-counts: doorbell: notify 0x01 (MU1, GIR0), rung 5026 of 5027 accepted, woken 5026
-- DEMO2
pair-counts: doorbell: notify 0x01 (MU1, GIR0), rung 3836 of 3837 accepted, woken 3836
-- DEMO3
pair-counts: doorbell: notify 0x01 (MU1, GIR0), rung 2133 of 2135 accepted, woken 2133
```

Each demo also passed `the M33 enabled the console channel's doorbell` (`SPC_DOORBELL console MU1 GIR0 enabled 0`) and `the doorbell rings and wakes: rung above 0, woken from 1 to rung`.

`woken` equals `rung` in every demo: each ring raised one interrupt.

The puts that did not ring, one in DEMO1 and DEMO2 and two in DEMO3:
- **The protocol.** A put rings only when it finds the consumer waiting. A put that finds `waiting` 0 does not ring, and its message is taken at the consumer's next release. That is the protocol, not a loss.
- **The first put.** The relay's first release is 10 ms after the M33's epoch, and before it no get has run, so `waiting` is 0. A put made before that release does not ring.
- **What the records show.** The wait histograms (`spc_channel_console_wait_hist`, bucket b holding 2^b to 2^(b+1) - 1 cycles at 240 MHz):

  ```
  DEMO1: b12(17.1us..)=30 b13(34.1us..)=4995 b14(68.3us..)=1 b21(8738.1us..)=1 sum=5027
  DEMO2: b12(17.1us..)=16 b13(34.1us..)=3819 b14(68.3us..)=1 b21(8738.1us..)=1 sum=3837
  DEMO3: b12(17.1us..)=7 b13(34.1us..)=2124 b14(68.3us..)=2 b17(546.1us..)=1 b21(8738.1us..)=1 sum=2135
  ```

  - Each demo has exactly one wait in bucket 21, 8.7 to 17.5 ms; it is the run's `max`.
  - DEMO2's and DEMO3's are above the 10 ms period (10764.442 and 11320.513 us). An unrung put made after the relay's first release waits for the next release, about a period at most; a wait well above the period is most simply a put made before the M33's epoch, so before the first release.
  - A board read early in a run, at 611 messages, found `accepted` one above `rung` and `lat_max` already 9637.713 us, and the same at 829 messages: the one unrung put and the one long wait both came among the first messages.
  - DEMO3's second unrung put waited 0.5 to 1.1 ms (bucket 17): a put made while the relay was taking (`waiting` 0), taken in the same pass.
- **Not shown.** No record matches a wait to its message: the consumer keeps the longest wait, not its message's number. Keeping it is an ABI addition (below).

## The wait from put to get

As printed:

```
-- 1abd974 DEMO1
pair-counts: wait console: n=5027 min=20.604 mean=47.677 max=9368.396 us p50<=68.263 p99<=68.263 us poll_max=10118.196 us sync_err=+-0.242 us drift: none seen above the rounds' own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
-- 1abd974 DEMO2
pair-counts: wait console: n=3837 min=20.592 mean=48.468 max=10764.442 us p50<=68.263 p99<=68.263 us poll_max=10146.433 us sync_err=+-0.242 us drift: none seen above the rounds' own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
-- 1abd974 DEMO3
pair-counts: wait console: n=2135 min=18.683 mean=51.64 max=11320.513 us p50<=68.263 p99<=68.263 us poll_max=10131.246 us sync_err=+-0.242 us drift: none seen above the rounds' own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
```

Against 0027's baseline, polling every millisecond:

| | 0027 mean | 0027 p99 | 0028 mean | 0028 p99 |
|---|---|---|---|---|
| DEMO1 | 491.03 us | <= 1092.263 us | 47.677 us | <= 68.263 us |
| DEMO3 | 497.799 us | <= 1092.263 us | 51.64 us | <= 68.263 us |

- The wait is now the interrupt's latency and the scheduler's dispatch, not the period: all but one or two messages of a demo wait at most 136.5 us (buckets 12 to 14).
- `max` is the first message's (above), and `poll_max` the 10 ms period: the relay is also released at its period when no message comes.
- No run is VOID: no drift was seen above the rounds' own error (the void rule is unchanged).

## The drift's estimate (Q5)

As printed:

```
-- DEMO1
pair-counts: drift estimate console: 11 rounds; the shortest trip's departure 61.063 +- 61.275 us at 83 s; the last round's 411.833 +- 411.881 us at 90 s; the longest trip 4667.721 us
-- DEMO2
pair-counts: drift estimate console: 14 rounds; the shortest trip's departure 42.975 +- 43.265 us at 56 s; the last round's 412.329 +- 412.442 us at 65 s; the longest trip 4495.692 us
-- DEMO3
pair-counts: drift estimate console: 16 rounds; the shortest trip's departure 63.158 +- 63.463 us at 16 s; the last round's 419.254 +- 419.444 us at 51 s; the longest trip 4895.071 us
```

How to read them:
- **Few rounds are answered.** A round is due once a second, but DEMO1 had 11 answered by 90 s, DEMO2 14 by 65 s, DEMO3 16 by 51 s.
  - The M7 answers in `spc_m7_serve_forever`, at its lowest priority, once a millisecond.
  - Its tic is `every_ms 1` and takes 8 to 36 ms (median 17 to 21 ms), so the scheduler thread is always behind and almost never sleeps, and the lowest priority rarely runs.
  - The companion waits 5 ms for an answer: only a round that falls in one of the M7's rare gaps is answered.
- **The estimate is weak.** Each departure is within 0.05 to 0.31 us of its own half trip. The M7 stamps its answer just before the companion sees it, at the end of the trip, so the midpoint the estimate measures from is half a trip away, and the error is as large as the value.
- **A possible improvement, not verified.** Measured from the round's end, t1, instead of its midpoint, the error would be the companion's poll of the answer, about the 0.05 to 0.31 us left above, rather than half the trip. That is a change of the companion's arithmetic, or of `pair-counts.rb`'s if the words line E keeps are enough.

## The board controls

`tests/doom-core/rt1186-pair-controls.sh` at `cebc350`: 32 checked, 32 pass, 440 s. The consoles' and the reads' own lines:

```
pair-id: SPC_CHANNEL_REFUSED cm7 3 90
consumer: P head 16 attempted 15469 accepted 16 refused 15453; C tail 0 state 0 taken 0
bell-notify: SPC_CHANNEL_REFUSED cm7 5 131, no frame relayed
bell-unrung: P head 1133 accepted 1133 rung 0; C tail 1133 taken 1133 woken 0
bell-unenabled: P head 1095 accepted 1095 rung 1; C tail 1094 taken 1094 woken 0
bell-unenabled: SPC_DOORBELL console MU1 GIR0 unenabled 0
```

`cacheable-cm7` and `cacheable-cm33` were refused as in 0027.

- **The doorbell's controls.**
  - A descriptor whose `notify` differs is refused by the M7's check, naming the flags word (word 130, plus 1).
  - A put that never rings, and a consumer that never enables the interrupt, both leave the relay taking at its period alone: the doorbell only wakes; the data path is the ring's.
  - With the interrupt never enabled, the first ring sets GIR0 and no handler clears it, so `rung` stays 1.
- **The first run of the controls** (`1abd974`) stopped, on two defects of the script, fixed in `cebc350`:
  - `bell-unrung`'s header read wrote nothing (gdbserver refused the connection), and the script then stopped on an unset parameter. A read that wrote nothing is now made once more after 3 s, and the figures print as `x`. In the second run both doorbell controls' first reads wrote nothing again and the second read succeeded (an open item, below).
  - The consumer control read `attempted 15456` for 16 accepted and 15441 refused, one above. The M7 is still putting while this control reads it, and a put stores `attempted` before `refused`, so one read can find `attempted` one above. This control alone now allows that one; the drained counts of `pair-counts.rb` stay exact. In 0027 the control passed (15475 = 16 + 15459) most likely because its read happened to fall between two puts.

## The other final runs

- **The `app.rb` lane, DEMO1, at `e30462c`.** 59 of 59, 1245 s: the network firmware and the launcher over ring ABI version 4.

  ```
  board-frames: build 1c91283dbbb72f7d, 5026 frame(s), every one the recorded frame; ended after 5026 tics; per tic min 9.6 ms, median 19.5 ms, max 38.5 ms (information, not a bound); boot 00000000602d1909; frame channel: 0 frame(s) and 0 message(s) dropped, 1587 frame(s) not sent
  net DEMO1: taken 172148 sent 0 discarded 172148 errors 0 retries 0 pending 0 in_send 0 fault 0 state 1 boot 602d1909 head 172148 tail 172148 consumer 1 dhcp 3222 ms
  ```

- **`tests/doom-core/rt1186-play.sh`, at `e30462c`.** 9 of 9, 167 s: the sender sent 351 to the last boot and its M33 received 351.
- **`tests/doom-core/rt1186-profile.sh`, at `e30462c`.** rc 0, 376 s, 503 sampled tics.
- **`tests/doom-core/audit.sh`, at `e30462c`.** 263 of 263, 804 s.
- **The host suites, at `9197843`.** The 16 commands `tools/test/affected.rb --base a6913fb` selected, each rc 0, among them `tests/app/build.sh` 113 of 113 and `tests/app/reserves.sh` 43 of 43; `cross.sh` and `effects.sh` first ran without the stack tool and passed when given it, and `verify-sources.sh` found `pair-counts.rb`'s pin stale, re-pinned in `1abd974`.

## Open items

- **The message of the longest wait.** Keeping, beside `lat_max`, the number of the message it was would match the longest wait to the unrung put. That adds an ABI word: the owner's decision.
- **The drift's rounds and their estimate.** The M7 answers too seldom, and the estimate measures from the midpoint. Measuring from t1 may shrink the error (not verified). An improvement that is only the host's arithmetic is a small next work; one that touches the firmware or the ABI goes to the owner.
- **The header read after a read.** The next read starts before the previous read's gdbserver has let the probe go; it is read now by the retry 3 s later. The fix is to wait for the previous gdbserver process to end before starting the next, a small harness change after this work.
  - **The fix, and what it left open (2026-10-27).** `54eb306` makes each read wait until no gdbserver or redlink server of the probe is left, before its own server and after it, and fails a read whose server never listens; the controls' retry is removed. On its one board run of `rt1186-pair-controls.sh` (30 of 32), `bell-unenabled`'s and `consumer`'s reads succeeded at once, but `bell-unrung`'s first read again wrote nothing. Its server listened and the probe was free, since neither new failure was named, and the previous read was `consumer`'s, minutes earlier: the previous gdbserver does not explain it. Its `gdb.log` and `gdbserver.log` had been replaced by the next control's read, so the cause is not known. `90137e7` keeps each control's read logs as `gdb-<control>.log` and `gdbserver-<control>.log`; in the second run (32 of 32) all three reads succeeded at the first try. When it recurs, its cause is read from those logs.
- **From 0027, still open.** The nominal 33/10 against the real clock ratio, some 0.1 ppm, not confirmed: no run here saw a drift above the rounds' own error.

## Follow-ups: ring ABI version 5 (2026-10-29)

The owner approved both open items above on 2026-10-29
([0028's amendment](0028-mu-doorbell.md#amendment-owner-2026-10-29-the-open-items-ring-abi-version-5)).
The final board runs ran once, at `8e1c1bf`, with the same tools as the host suites:
- this tree's pinned compiler (`eee3df25b`) and reader, built in its worktree;
- copies of the kernel, the stack tool and the adapter, whose source stamps match the tree.

play ran again at `b335384`, after its host part failed (below).

### The pair lane, DEMO1 to DEMO3

`RT1186_PAIR=1 tests/doom-core/rt1186.sh`, without `TICS`, `REQUIRE_ALL=1`:
rt1186: 76 checked, 76 pass, 0 fail, 0 lane(s) skipped; 1479 s; realtime profile, loop_bound unknown through DoomCore: not a realtime claim

```
-- DEMO1
board-frames: build d84615c7cbe468b9, 5026 frame(s), every one the recorded frame; ended after 5026 tics; per tic min 9.9 ms, median 20.8 ms, max 37.9 ms (information, not a bound)
-- DEMO2
board-frames: build dfd21056f4673c4a, 3836 frame(s), every one the recorded frame; ended after 3836 tics; per tic min 8.9 ms, median 19.0 ms, max 35.9 ms (information, not a bound)
-- DEMO3
board-frames: build 7155370982dd14b7, 2134 frame(s), every one the recorded frame; ended after 2134 tics; per tic min 9.2 ms, median 24.1 ms, max 39.9 ms (information, not a bound)
```

```
-- DEMO1
pair-counts: doorbell: notify 0x01 (MU1, GIR0), rung 5026 of 5027 accepted, woken 5026
-- DEMO2
pair-counts: doorbell: notify 0x01 (MU1, GIR0), rung 3836 of 3837 accepted, woken 3836
-- DEMO3
pair-counts: doorbell: notify 0x01 (MU1, GIR0), rung 2134 of 2135 accepted, woken 2134
```

```
-- DEMO1
pair-counts: wait console: n=5027 min=21.004 mean=37.97 max=8392.05 us p50<=68.263 p99<=68.263 us poll_max=10112.671 us sync_err=+-0.3 us drift: none seen above the rounds' own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
-- DEMO2
pair-counts: wait console: n=3837 min=23.871 mean=38.664 max=9614.183 us p50<=68.263 p99<=68.263 us poll_max=10106.133 us sync_err=+-0.383 us drift: none seen above the rounds' own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
-- DEMO3
pair-counts: wait console: n=2135 min=25.238 mean=41.089 max=9522.575 us p50<=68.263 p99<=136.529 us poll_max=10083.588 us sync_err=+-0.3 us drift: none seen above the rounds' own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz
```

### The longest wait's message

```
-- DEMO1
pair-counts: longest wait console: message 0 of 5027 accepted (0 is the first put), 8392.05 us
-- DEMO2
pair-counts: longest wait console: message 0 of 3837 accepted (0 is the first put), 9614.183 us
-- DEMO3
pair-counts: longest wait console: message 0 of 2135 accepted (0 is the first put), 9522.575 us
```

In every demo the longest wait is message 0, the first put. Each demo also has exactly one unrung put:
3 of 3 demos have `rung` one below `accepted`.
So the unrung put and the longest wait are the same message, as the earlier record could only infer.

### The drift's rounds, from the midpoint and from t1

```
-- DEMO1
pair-counts: drift estimate console: 105 rounds, 0 timed out; the shortest trip's departure 1.421 +- 1.802 us, from t1 in [-0.381, -0.215] us, at 66 s; the last round's 512.217 +- 512.542 us, from t1 in [-0.325, -0.158] us, at 105 s; the longest trip 1181.417 us, the largest g 0.167 us
-- DEMO2
pair-counts: drift estimate console: 77 rounds, 0 timed out; the shortest trip's departure 9.271 +- 9.633 us, from t1 in [-0.363, -0.196] us, at 16 s; the last round's 408.083 +- 408.469 us, from t1 in [-0.385, -0.219] us, at 77 s; the longest trip 1209.746 us, the largest g 0.167 us
-- DEMO3
pair-counts: drift estimate console: 56 rounds, 0 timed out; the shortest trip's departure 6.646 +- 6.967 us, from t1 in [-0.321, -0.154] us, at 15 s; the last round's 392.563 +- 392.967 us, from t1 in [-0.404, -0.238] us, at 56 s; the longest trip 1232.079 us, the largest g 0.167 us
```

- **Every round is answered.**
  - A round is due once a second. DEMO1 answered 105 by 105 s, DEMO2 77 by 77 s and DEMO3 56 by 56 s.
  - None timed out. Before this change, 11, 14 and 16 rounds were answered.
- **The bound from t1 is tight.**
  - The largest g is 0.167 us in every demo, so each departure measured from t1 is known within 0.167 us.
  - Measured from the midpoint, the error is half the trip: up to about 512 us.
- **No drift is seen.**
  - Every interval from t1 is negative, between -0.404 and -0.154 us. That is of the order of the alignment's own error, `sync_err` +-0.3 to +-0.383 us.
  - In each demo the shortest trip's interval and the last round's overlap, 39 to 61 s apart. So no drift above 0.167 us is seen between them.

### The tic, against 0028

The board's `F` lines, as `board-frames.rb` printed them:

| Demo | 0028 (`1abd974`) median, max | now median, max |
|---|---|---|
| DEMO1 | 18.3, 34.2 ms | 20.8, 37.9 ms |
| DEMO2 | 16.8, 32.1 ms | 19.0, 35.9 ms |
| DEMO3 | 20.8, 35.8 ms | 24.1, 39.9 ms |

- In the pair, the tic's median is 2.2 to 3.3 ms longer.
- The M7 now answers the rounds from `main` at priority 0, preempting the
  scheduler every millisecond. This is the one change on the M7's side.
- The cost is not measured stage by stage; the profile lane runs `app.rb`,
  not the pair. This is information, not a stop condition (the coordinator, 2026-10-29).
- No fault was recorded on either core.
- This lane judges no deadline: the M7's `every_ms 1` tic is behind by
  design, as before.

### The other final runs

- **`rt1186-pair-controls.sh`.** 32 of 32, 477 s.
- **The `app.rb` lane, DEMO1.** 59 of 59, 1118 s. Its board loop has no
  pair, so it shows only the version 5 header:

  ```
  board-frames: build 9509ecee971ee4bd, 5026 frame(s), every one the recorded frame; ended after 5026 tics; per tic min 9.2 ms, median 19.5 ms, max 35.7 ms (information, not a bound); boot 00000000602d4a08; frame channel: 0 frame(s) and 0 message(s) dropped, 1587 frame(s) not sent
  ```

  In 0028 the same lane printed a median of 19.5 ms and a max of 38.5 ms.
- **`rt1186-play.sh`.**
  - The first run failed in its host part, `tests/app/play.sh`. It checked
    the M7's header for version 4. Nothing was written to the board after
    the failure.
  - `play.sh` runs only inside this lane, so the host suites had not run it.
  - Fixed in `b335384`. The second run passed 9 of 9, 163 s.
- **`rt1186-profile.sh`.** rc 0, 376 s, 503 sampled tics. The total's
  median is 56.652 ms, against 56.498 ms in 0028.
- **The host suites, at `8e1c1bf`.**
  - `tests/app`: core-channel 57, contract 68, host 58, board 102,
    effects 23, cross 48, udp 46, reserves 43 and build 113, each all pass
    with no skip.
  - doom-core: board-controls 53, entries 35, source-pack 103 (its kernel
    lane included), state 277 and audit 263, each all pass.
  - `verify-sources.sh` rc 0, and imports 10 of 10.
- **Open items now settled.** The first two open items above, the longest
  wait's message and the drift's rounds, are settled here. The third, the
  header read after a read, has not recurred: no control's read failed.
