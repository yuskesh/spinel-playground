# 0024: DOOM's frames from the FRDM-IMXRT1186 over the network

- Date: 2026-10-22
- Status: Accepted (owner, 2026-10-22): showing the board's frames on a host
  over Ethernet, rather than an LCD on the board or a second board. The
  transport choice below is within decision 0014's design.
- Scope: how the board lane of decisions 0021 and 0023 shows its screen. The
  entries, their contracts and the lane's acceptance are unchanged.

## Context

- The board lane computes each frame but shows none. Its console line carries
  the frame's FNV-1a 64 digests only.
- The surveys of 2026-10-22 looked at three ways to show the frames:
  - **An LCD-PAR-S035 on the board.** The board has no connector for it, so
    it needs 10 to 25 flying wires. Over SPI a 320×200 frame takes about
    68 ms, so it shows about every fourth tic.
  - **A second board with a display** (MIMXRT1170-EVKB and a MIPI panel).
    This is a purchase and a new board lane.
  - **The network.** Zephyr v4.4.2's `frdm_imxrt1186` describes the NETC
    switch and two YT8531 PHYs, and lists `netif:eth` for the M33 and for the
    M7 extmem variant. One 8-bit frame is 64,000 B. At about 52.6 frames a
    second that is about 3.4 MB/s, well within 100 Mbit/s.
- Decision 0014 already designs a `udp:` channel transport (§5, Transports):
  CORE puts messages in a fixed-capacity ring, and the transport thread does
  the blocking network work. It is refused today as not implemented.

## Decision

1. **The board sends its frames over UDP** (owner).
2. **Through 0014's `udp:` channel transport**, implemented as 0014 designs
   it. It is not a new extern contract.
   - Endpoints and the network interface come from Zephyr configuration and a
     file outside the repository, as 0014 says.
   - A full channel drops a frame and counts it. The tic does not wait for
     the network.
3. **The palette is sent once.** Frames are the 8-bit screen, split into
   messages no larger than one packet's payload.
4. **A host viewer** in Ruby receives the frames, maps them through the
   palette and shows them. Scaling and aspect ratio are the viewer's.

## Validation

- **Digest match, not an oracle.** The viewer computes each received frame's
  FNV-1a 64 and checks it against the board's own console line for that tic.
  Both sides are the same board run.
- **Drops are counted** and reported. A run with no drops is expected on a
  direct link.
- **Tic cost.** The tic median at `DEMOS=DEMO1 TICS=500`, in two comparisons
  labelled apart (the coordinator, 2026-10-22):
  - **The main one, the same application:** sending, against the channel
    switched off by the network file (port 0). The application, CORE and
    the compile conditions are the same and only the transport's setting
    differs; the network file reaches the image, so the two are two ELFs
    with two session ids, not one image switched at run time. Switched off,
    the M33 still takes its address by DHCP and publishes the boot id, then
    takes each message from the ring and discards it, counted apart from
    those sent, so the M7's copy and `put` are the same in both runs and
    only the sending differs. The tics not sent while waiting for the boot
    id are reported apart. Beside the median, the tic's maximum and
    quantiles and the drops are reported.
  - **For reference, a different build:** the board application without
    the channel (feature/32bit_doom 687298c), labelled as another build.

## Clarification (2026-10-22): the wire format and the reports

Agreed between the board side (the first implementer) and the viewer (the second implementer) on
2026-10-22, and recorded here so that both are held to it.

- **No transport header.** One UDP datagram is one channel message, its
  payload verbatim (decision 0014's `udp:` transport). The board sends to
  the host and port the network file names; the viewer's default port is
  5029.
- **Messages.** Every integer is little-endian. The first byte is the kind:
  - `0x50` (`P`), **the palette**: 768 bytes of RGB, PLAYPAL's palette 0,
    sent once at the start. A viewer started later has no palette.
  - `0x43` (`C`), **a piece of a frame**: the tic (u32, the same value as
    the console's `F` line), the piece's index (u16) and the frame's count
    of pieces (u16), then the data. A piece is 1280 bytes, four rows of
    320; a frame is the whole 320 × 200 screen, the status bar included,
    in 50 pieces. A message is at most 9 + 1280 = 1289 bytes, and the data
    is the message's length less 9.
- **Board-side drops.** When the channel is full in the middle of a frame,
  the board puts none of that frame's remaining pieces. Just before its
  `D` line it writes `N <frames dropped> <messages dropped>`, each 16
  hexadecimal digits with the first eight zero, the form of its other
  lines.
- **Transport failures.** A send that fails for good is counted in the
  image's `spc_transport_udp_errors`. The board lane reads it after the run
  and reports it, and a run with a non-zero count does not pass.
- **The viewer's reconciliation.** A frame the viewer misses is one with a
  piece missing, or none at all, among the tics the console reports.
  Missing frames less `N`'s frames dropped are network losses; the viewer
  also compares `N`'s messages with its own count of missing pieces.

## Amendment (owner, 2026-10-22): the M33 sends, and the stream's policy

The review of the send path (2026-10-22) found that the pinned NETC
driver copies each packet into one staging buffer and then busy-waits for
transmit completion (`drivers/ethernet/nxp_imx_netc/eth_nxp_imx_netc.c`,
`net_pkt_read` near line 488 and `while (!data->tx_done) {}` near line 527).
On the M7 that time would come out of the tic. The owner chose the following,
each on 2026-10-22.

1. **The M33 owns the network.** The launcher of decision 0023 grows into
   the network firmware: ordinary Zephyr C, not a CORE application, since
   socket and driver paths allocate and block.
   - NETC, its clocks, PHYs and interrupts are initialised on the M33 only.
     Unlocking NETC's IERB resets the whole block, so a second owner would
     reset the first.
   - The M7 keeps 0014's `put`. Its `udp:` channel's consumer is the M33: the
     ring is a copied single-producer, single-consumer message ring in OCRAM
     reserved in both cores' maps, with release/acquire publication and cache
     ownership stated in its ABI. This extends 0014's transport to a consumer
     on another core; the channel contract (fixed-size messages, a full ring
     refuses, delivered once, in order) is unchanged.
   - The M33's stacks, interrupts and memory are measured and reported. The
     network threads are disclosed as unbudgeted, as 0014 allows.
2. **At most 35 frames a second are sent**, chosen by time. Every tic still
   runs and is digested. A frame not sent by this choice is counted apart
   from a frame dropped because the ring was full.
3. **The palette is resent every second**, and every message carries a
   per-boot identifier, so that a viewer started late gets the palette and
   messages from different boots are never combined. This replaces
   Decision 3's "sent once".
4. **Network identity.** The M33 takes its IPv4 address by DHCP. The switch
   ports' MAC addresses are locally administered unicast values set in the
   M33 image's overlay; the board files' `00:00:00:…` values lie in another
   organisation's OUI. The cable is on switch port 0 (`swp0`, the RGMII jack
   J56; the link came up at 1 Gbit/s full duplex, the first implementer, 2026-10-22).
5. **The receiving host is a Mac on the same LAN** (its address comes from
   the network file outside the repository; port 5029), showing
   the frames with the Spinel-compiled SDL2 viewer in
   `examples/doom/net_view/`. `tools/doom/net-viewer.rb` judges recordings
   against the console.

**Order of work.** First an M33-only UDP sender at 35 frames a second,
measured (service time per frame, errors, memory). Then the OCRAM ring
checked with fixed byte patterns from the M7 (wrap, full, reset, cache).
Then DOOM's frames through both, with the tic median compared as Validation
says. A change to compression or deltas would be a further amendment.

## Clarification (2026-10-22): wire format version 2

Agreed between the board side (the first implementer) and the viewer (the second implementer), approved by
the coordinator on 2026-10-22. It replaces the first Clarification's messages and
reports for the Amendment's stream. The M33 measurement sender
(`feat/m33-udp-probe`) keeps version 1 until the ring carries DOOM's frames.

- **No transport header**, as before: one UDP datagram is one channel
  message. Every integer is little-endian.
- **A common header** opens every message, 6 bytes:
  - the kind (u8);
  - the version (u8), 2;
  - the boot id (u32).
- **The boot id.**
  - The M33 chooses it once per boot, when DHCP binds. It mixes the cycle
    counter with something timed by the network, such as the DHCP
    transaction's xid or the time the lease arrived. It is never a value
    fixed at reset, since reset timing is deterministic.
  - It is likely unique across boots, not guaranteed. The viewer's
    tic-backwards check below catches a collision within one stream.
  - 0 is reserved for "not yet known" and is never chosen, so a datagram
    with id 0 is malformed.
  - The M33 places the id in a shared word of the ring's ABI region:
    `boot_id`, line 1 of ring ABI version 1 (`tools/app/ring/ring_abi.h`),
    at byte 32 of OCRAM2's first 128 KB (0x2050_0020 for the M7, 0x3050_0020
    for the M33). It is 0 until the M33 writes it, once, after DHCP binds and
    after a barrier; the M7 loads it and never waits for it. The ring ABI's
    version and the wire's are separate.
  - **The M7 writes the id** into bytes 2–5 of every message it puts, as
    the non-zero value it read (the coordinator, 2026-10-22, after the review).
    While the id is still 0 it puts nothing: no `C`, `P` or `S`, and that
    tic's frame is counted as not sent. The M33 forwards every message
    verbatim, as 0014's `udp:` transport does, and knows nothing of this
    format.
- **Messages.**

  | Kind | Name | After the header | Size | Sent |
  |---|---|---|---|---|
  | `0x50` `P` | the palette | 768 bytes of RGB, PLAYPAL's palette 0 | 774 B | at boot and every second |
  | `0x43` `C` | a piece of a frame | tic (u32, the console's `F` tic), index (u8), count (u8, 50), 1280 bytes | 1292 B | each frame chosen to be sent |
  | `0x53` `S` | the M7's stream counts | latest tic (u32), then u32 counts since boot: frames sent, frames not sent, frames dropped, messages dropped | 26 B | by the M7, every second |

  - A `C` message is 1292 bytes, over the first Clarification's 1289. This
    keeps a piece at four rows of 320 and stays within the 1472 bytes of a
    UDP payload at an MTU of 1500, so nothing is fragmented. The `udp:`
    channel's size is its declaration's.
  - A frame is the whole 320 × 200 screen, the status bar included, in 50
    pieces; the last piece's data is the message's length less 12.
- **The palette** is resent every second. Each one replaces the palette the
  viewer holds for that boot, so a viewer started late has it within a
  second.
- **35 frames a second.** The M7 chooses by time which tics are sent, and
  keeps the average rate's phase (the coordinator, 2026-10-22): the period is
  ceil(Hz / 35) cycles of `Clock.cycles32`'s counter; a tic is due when
  `core_w32_sub(now, next_due)` is not negative; a sent frame moves
  `next_due` on by one period with `core_w32_add`; a tic more than a period
  late sets `next_due` to now plus a period instead, so no extra frame is
  sent to catch up, and a long halt is absorbed the same way. The
  comparison holds while the difference is below 2^31 cycles (about 2.7 s at
  792 MHz).
  does not copy the others into the ring. Every tic still runs, and the
  console still writes its `F` line.
  - Each tic is exactly one of: sent, not sent (by this choice), or dropped
    (the ring was full, as in the first Clarification). So in every `S`,
    frames sent + not sent + dropped equals the latest tic + 1.
  - A dropped frame has none of its remaining pieces put, as before.
- **The console** is the M7's, one console for one boot.
  - The M7 reads the shared word once a tic, without waiting. At the first
    tic it reads a non-zero id, it writes `B <boot id>`, 16 hexadecimal
    digits. `F` lines before it belong to the same boot. The M7 starts
    before DHCP binds, and CORE does not wait.
  - Just before `D`, the M7 writes
    `N <frames dropped> <messages dropped> <frames not sent>`, each 16
    hexadecimal digits.
  - The M33 has no console and sends no report of its own (there is no `T`
    message). The board lane reads its counts with the debugger once the run
    has drained: after `D` the M7 puts nothing more, and the lane waits,
    with a time-out, until the ring's head equals its tail and the M33 has
    no message pending or in a send, twice 100 ms apart, then reads
    `spc_transport_udp_errors` and the M33's other counts. The run is judged
    on those values, the final `N` line, and the Mac's recording of the
    same run, since a send that succeeded is no proof the host received it.
- **The viewer.**
  - Messages of different boots are never combined. Each boot has its own
    frames, palette and counts.
  - Within a boot, a piece whose tic is more than the reorder window below
    the highest tic seen, and not of a frame already closed, is a tic going
    backwards. It is reported, and fails the run, since it means two boots
    share an id.
  - With the console, the viewer judges the boot its `B` line names. A
    console without `B` or with two, or a stream without that boot, fails.
    The frames missing are the console's tics with no complete frame of
    that boot. The network lost the missing frames less `N`'s frames
    dropped and frames not sent. `S` is reported alongside, and
    an `S` whose counts do not add up to its latest tic + 1 fails.
  - A datagram of another version, with id 0, of an unknown kind or of the
    wrong size is bad, counted and not used.

## Clarification (2026-10-22): the tool's two new names, and the lanes

- **Two names, approved by the owner on 2026-10-22.**
  - `udp_consumer` is a fact of a board's table
    (`tools/app/zephyr/v4.4.2/boards/<board>.tsv`). Its one value,
    `ocram-ring-v1`, says that a `udp:` channel's consumer is the other core:
    the generated `put` writes the OCRAM ring of `tools/app/ring/ring_abi.h`,
    and `tools/app/launcher` is built as the network firmware. Only
    `frdm_imxrt1186_cm7` names it. An unknown value, a second `udp:` channel,
    a depth that is not a power of two and slots beyond the ring's 128 KB
    are refused at step 1. A board without the fact, and an application
    without a `udp:` channel, build as before, and the launcher stays the
    plain one.
  - `Clock::CYCLES_PER_SECOND` is a constant of the board package's `Clock`
    module: the frequency, in Hz, of the counter `Clock.cycles32` reads,
    `CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC` of the build's own `.config`, so the
    session id covers it. A configuration that reads its timer's frequency at
    run time (`CONFIG_TIMER_READS_ITS_FREQUENCY_AT_RUNTIME`) gives no
    constant, and an application that names it is refused. It is the one
    entry of `CONFIG_CONSTANTS` in `tools/app/lib/core_app/board.rb`; no
    other configuration value becomes a `Mod::NAME`.
- **The board lane runs on the M7 only.** The M33 now owns the network, so a
  DOOM run on the M33 cannot share the board with it: `tests/doom-core/rt1186.sh`
  defaults to `RT1186_CORE=cm7`, and `RT1186_CORE=cm33` is a named skip.
  Decision 0023's Consequences still hold: the M33 lane's tools stay, and the
  M33 target remains buildable for the application suites that use it.
- **The network file of a lane.** A lane builds the board application with
  `tests/app/fixtures/session/port0.net` unless `NET=` names another file:
  that file switches sending off (port 0, a documentation address), so the
  lane takes the same code path without sending. A run that sends is given a
  file outside the repository.

## Clarification (2026-10-22): Validation, measured

DEMO1's first 500 tics on the FRDM-IMXRT1186's M7 (`tests/doom-core/rt1186.sh`,
`RT1186_CORE=cm7 DEMOS=DEMO1 TICS=500`), each run after a system reset, the
tic's cycles from the console's `F` lines at 792 MHz:

| run | build | min | p10 | median | p90 | p99 | max |
|---|---|---|---|---|---|---|---|
| sending | feat/doom-net-ring 49d1cb5, a network file to the Mac | 9.74 | 14.23 | 18.59 | 23.22 | 27.51 | 29.76 ms |
| switched off | the same application, `port0.net` (another ELF) | 9.65 | 14.10 | 18.56 | 22.90 | 27.27 | 30.51 ms |
| reference, another build | feature/32bit_doom 879bdfa, no frames channel | 10.27 | 14.40 | 18.38 | 22.95 | 26.76 | 33.30 ms |

- Every run's 500 frames were the recorded ones (`tools/doom/board-frames.rb`).
- Sending against switched off: 0.03 ms on the median. Both runs copy and
  put the same messages, so this is the M33's sending as the M7's tic sees
  it.
- Against the reference build: 0.21 ms on the median. It is a different
  build, so this is the copy into the ring and the stream's own work together
  with whatever else differs between the two images, not a measure of the
  stream alone.
- **The M33**, read with the debugger at the console's 500th tic, the demo
  still running (so not a drained total): sending, 31,788 taken and 31,788
  sent; switched off, 31,715 taken and 31,715 discarded. Both runs had 0
  send errors, 0 retries and no fault, and DHCP bound at 3.2 s.
- **The Mac** (the third implementer, the v2 `net_view --record`, `net-viewer.rb --replay
  --console`): the sending run's boot gave 3,505 complete frames, none
  incomplete, late, duplicated or bad. Of the lane's 500 tics, 260 frames
  arrived, and all 260 match the console. No frame was sent before tic 125,
  while the boot id was not yet known. The last `S` (tic 5003) says 3,490
  sent, 1,514 not sent and 0 dropped. With the console read only to its
  500th tic there is no `N` line, so the viewer did not judge network loss;
  that the other tics were not sent rather than lost is read from `S` and
  from no incomplete frame, not judged.
