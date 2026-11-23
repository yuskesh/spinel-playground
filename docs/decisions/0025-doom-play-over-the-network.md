# 0025: Playing DOOM on the FRDM-IMXRT1186 from a host keyboard

- Date: 2026-10-23
- Status: Accepted (owner, 2026-10-23: the recommended set, with 2(a) and
  5(a)). The owner asked for it on 2026-10-23. It was implemented on
  `feature/doom-play`, merged as `6e23735`; the Clarification at the end
  records the measured validation.
- Scope: a second board application for DOOM on the FRDM-IMXRT1186's
  Cortex-M7 that takes its input from a host keyboard over Ethernet, and the
  host side that sends it. The demo application (`examples/doom/core/board/app.rb`)
  and its lane stay as they are.
- Not in scope: authentication. Restricting the sender to one host address
  (point 7 under Decision) chooses whom the board listens to; it does not
  authenticate anyone.

## Context

What exists on main at c7786d7. Each point names where it was read.

- **The board application plays a demo.**
  - `examples/doom/core/board/app.rb` takes each tic's command from the demo
    lump inside the IWAD the session image holds:
    `Image::DEMO_OFFSET + 13 + 4 * t`, decoded as `examples/doom/lib/doom/demo.rb`
    decodes it.
  - Its tic is the step entry and then the render entry. It never calls the
    input entry.
  - It runs `every_ms 1, :tic`, so one tic runs per 1 ms release. It does not
    wait for 35 Hz: a tic longer than the period skips releases (its header).
  - It stops with a console line `X <tic> reborn …` when `game_pl_playerstate`
    is `PST_REBORN` (2) before the step. A failing entry or the mode check
    also writes an `X` line and stops the loop.
- **The session image needs a demo.**
  - `tools/doom/session-image.rb` takes `--catalog`, `--snapshot`, `--out`,
    `--schema`, `--fields` and `--demo NAME`. `--demo` only records where the
    demo lump is (`#demo NAME offset N tics T playpal P`).
  - The map and skill come from the snapshot. The snapshot is written by
    `tests/doom-core/native/open.rb` (`open WAD DEMO SCRIPT OUTDIR`), which
    takes the map, episode and skill from the demo's header and has no other
    way to choose them.
  - The three demo headers in the shareware IWAD hold the following (read
    from the lumps on 2026-10-23):

    | Demo | Version | Skill byte | Episode | Map | Tics |
    | --- | --- | --- | --- | --- | --- |
    | DEMO1 | 109 | 2 | 1 | 5 | 5026 |
    | DEMO2 | 109 | 2 | 1 | 3 | 3836 |
    | DEMO3 | 109 | 2 | 1 | 7 | 2134 |

  - `bin/doom.rb` takes `-warp E M` (default 1 1) and `-skill N` (1 to 5,
    default 2). Whether its `-skill` numbering equals the demo header's byte
    is **unconfirmed**.
- **The input entry exists and is built for the board.**
  - `examples/doom/core/entries/doom_core_input.contract` takes `state`,
    `xi`, `cmd` (`core_command`, i16 × 5), `down` (`key_state_down`, u8 × 256),
    the key script's three buffers, `demo_buf` and `demo_max`, and the
    scalars `scripted`, `tic` and `recording`.
  - With `scripted` 0 it builds the tic's command from `down`
    (`examples/doom/core/src/doomentry.rb`). With `recording` it also
    quantises the angle and writes the tic into `demo_buf`.
  - `tools/app`'s session package generates `DoomCore.input` beside
    `DoomCore.step` and `DoomCore.render`
    (`tools/app/lib/core_app/session.rb`). `tests/doom-core/rt1186.sh`
    builds all three entries for the target.
  - Whether `DoomCore.input` runs correctly on the board is **unconfirmed**:
    no board application calls it.
- **The host plays interactively through the same entries.**
  - `bin/doom.rb -core` (`core_play`, `core_loop`) prepares the session,
    seals the original objects, and then runs each tic as:
    `video.pump`, then `NativeLoop.keys` (`key_state_down` cleared, then set
    to 1 for each of `TiccmdBuilder::WATCHED_KEYS` that SDL reports down),
    then `NativeLoop.input` (`scripted` 0), step, render, present.
  - It paces to 35 Hz unless `-nopace` is given.
  - `WATCHED_KEYS` has 18 codes: the arrows, `,` and `.` (strafe), fire
    (RCTRL), use (space), strafe (RALT), speed (RSHIFT), and the digits 1 to 8.
    Other keys are ignored on purpose (`read_keys`'s comment).
- **Decision 0014 designs `udp:` for both directions; only `:out` is
  implemented.**
  - 0014 §5 designs `:in` channels: `Name.get(buf)` returns the message's
    length, or 0 when the queue is empty. The transport is the producer.
    An inbound message is dropped only when it is longer than `size` or the
    channel is full, and each drop is counted by reason.
  - 0014's clarification of 2026-10-22 implements `udp:` for `:out` only.
    "DOOM needs no inbound UDP, and an `:in` channel would add a receive path
    to budget." The declaration reader refuses `udp:` on an `:in` channel by
    name (`tools/app/lib/core_app/declarations.rb`).
  - `:in` channels over `uart:` are implemented, and the host runner fills
    them from a stimulus file (`tools/app/lib/core_app/host_runner.rb`).
- **On this board the M33 owns the network** (0024's amendment).
  - The M7's `udp:` channel writes the OCRAM ring (`tools/app/ring/ring_abi.h`,
    ABI version 1). The M33's network firmware (`tools/app/launcher/net/`)
    takes the messages and sends each as one datagram.
  - The ring has one direction, M7 to M33. The tool refuses more than one
    `udp:` channel (`tools/app/lib/core_app/pipeline.rb`).
  - The frames channel (size 1292, depth 64) takes 160 + 64 × 1312 =
    84,128 B of the ring's 131,072 B. That leaves 46,944 B (computed from
    `channels.rb`'s `ring_geometry`).
  - The M33's socket is bound to the destination's port and connected to it
    (`forward.c`). It does not receive.
- **The tic's time on the M7.** The first implementer ran the board lane on 2026-10-22
  with `RT1186_CORE=cm7 DEMOS="DEMO1 DEMO2 DEMO3" sh tests/doom-core/rt1186.sh`
  at f4f3aff, and it passed 79 of 79.
  - DEMO1's tics had a median of 19.7 ms.
  - The longest tic, in DEMO3, took 41.7 ms.

  At 35 Hz a tic has 28.6 ms, so some tics already take longer.
- **Death and the level's end.**
  - Decision 0008 keeps rebirth and level reload "an explicit failure, not a
    silently continued game". Full refuses `PST_REBORN` before the step, and
    the board writes `X … reborn`.
  - The exit switch (special 11) sets `game_exit_requested`
    (`examples/doom/lib/doom/specials.rb`, and `stepspec.rb` in the port).
    Nothing in `bin/doom.rb`, `examples/doom/core/src` or the board
    application reads it. What a player sees after pressing it is
    **unconfirmed**.
  - The E1M8 exit sector raises `LevelError` in the original. The port turns
    every `LevelError` into `core_fail(:capacity)`, which stops the board
    loop with an `X` line.

## Options

### Where the input enters

1. **0014's `udp:` on an `:in` channel**, implemented as §5 designs it. The
   board application calls `Keys.get(buf)` and copies the keys into
   `key_state_down`.
2. **A new extern** that reads a shared word or buffer the M33 fills. This is
   a new platform contract, which 0014 asks to avoid when a channel can carry
   the data.

Option 1 is the decision. As with 0024, it is not a new extern contract.

### How the inbound path reaches the M7

The network is the M33's, so the `:in` channel's producer is the M33.

1. **A second ring in the same 128 KB region**, M33 to M7. The frames ring
   leaves 46,944 B. The layout grows, so the ring ABI's version changes.
2. **A separate region** for the inbound ring. This changes both images'
   link and MPU checks.

1 is the decision.
- The ring ABI becomes version 2.
- One build makes the M7 and M33 images together, so version 2 keeps no
  compatibility with version 1.
- The demo application moves to version 2 as well, and its lane is rerun
  once on it.

### Not taken (owner, 2026-10-23)

- The pace: as fast as possible, like the demo application (`every_ms 1`);
  or 35 Hz with catch-up by steps without rendering, which changes what is
  drawn.
- The map: a choice at run time, which needs a level load that 0008 keeps
  out of CORE. A map and skill chosen at build time remains a possible
  follow-up.
- The key message: the whole 256-byte `key_state_down` every tic; or only
  the changes, which lose a release with its datagram.
- Loss: keeping the last state with no time-out, where a lost release keeps
  the player running; or stopping the run on a gap.
- Death and the level's end: rebirth and level change, which would reverse
  0008's "explicit failure" and need their own decision.
- Latency: a target figure set before any measurement.

## Decision

1. **A second board application, `examples/doom/core/board/play.rb`.** The
   demo application and its lane are unchanged.
   - It shares the session package, the console channel and the frames
     channel with the demo application.
   - Per tic, it takes the newest key state from the inbound channel and
     writes `key_state_down`. It then calls `DoomCore.input(0, t, 0)` and
     runs the step and render as `app.rb` does, with the same mode and
     rebirth checks.
   - If the input entry fails, the step and render are not called. The loop
     stops with `X <tic> input <status>`, which keeps 0007's rule that the
     storage of a failed call is not used again.
   - It sends the frame as 0024 does.
   - The session image is the demo application's, built from a demo's
     snapshot (point 11). The demo's commands and tic count are not
     used. The run continues until it stops (point 14) or the board is reset.
2. **0014's `udp:` on `:in` channels, implemented as §5 designs it.**
   - The declaration is `channel :keys, :in, size: s, depth: d, udp: true`.
     With point 5's message, `size` is 17 and `depth` is a power of two
     (16).
   - 0014's queue is unchanged: first in, first out, and a message is
     dropped only when it is too long or the channel is full, each counted.
     Messages are never empty, and `get` returning 0 means only "empty".
     Merging several messages into one state is the M7 application's work
     (point 6), not the channel's.
   - On this board the producer is the M33. It receives with a socket of its
     own and puts each datagram into the inbound ring, verbatim. It knows
     nothing of the message's format, as in 0024.
   - **The M33's receive stage**, in order. Each datagram falls in exactly
     one of these:
     - **refused by the filter**: its source address is not the network
       file's host address (point 7). The M33 reads the address from the
       received datagram's source and never from the payload.
     - **empty**: a datagram of 0 bytes. 0014 has no empty message, so it is
       refused here and counted apart.
     - **too long**: longer than `size`. The M33 detects that a datagram
       exceeds `size`, by `ZSOCK_MSG_TRUNC` or by a receive buffer one byte
       longer than `size` that comes back full. The cut payload is never
       queued. The count needs no original length, and none is measured.
       Whether Zephyr v4.4.2 supports `ZSOCK_MSG_TRUNC` on this socket is
       **unconfirmed**; the longer buffer is the fallback.
     - **full**: the inbound ring is full.
     - **queued**.

     So, on the M33: received = refused + empty + too long + full + queued.
     The filter's refusals and the empty ones are their own counts and are
     not mixed with the channel's two drops.
   - **Fair service on the M33.** One thread does both directions, as a
     state machine that never waits inside one step.
     - Each turn makes **one** send attempt, then a receive pass, then the
       next turn.
     - The send attempt is either the held message, if one is held, or the
       next message from the outbound ring.
     - A send that finds no buffer keeps that one message held for the next
       turn. Holding is bounded: one message at a time, never taken past by
       a later `:out` message, so the frame order is kept.
     - A message is held for at most a fixed number of turns. Past it, the
       message is dropped and counted as an error, as `forward.c` counts any
       other send failure.
     - The receive pass takes at most the datagrams already waiting, up to
       the inbound depth, without blocking.
     - Today's `send_one` retries in a `for (;;)` loop until the message
       goes. Called as it is, it could hold the receive back without limit,
       so it becomes this one-attempt step.
     - This bounds what the thread itself does. If the network driver call
       does not return, nothing here bounds it, and no realtime promise is
       made.
     - The socket's receive buffer is the only other place a datagram waits,
       and its size is the socket's configuration.
   - **The network file.** It gains one line form for an `:in` channel; the
     `:out` line is unchanged:

     ```
     channel frames 192.0.2.1 5029        # :out, as now: the host and the port it sends to
     inbound keys 5030 from 192.0.2.1     # :in: the board's local port, and the one host it accepts
     ```

     - The board binds a separate socket to the local port (5030 above). It
       does not share the `:out` socket, which stays bound and connected to
       the host's port as `forward.c` does now.
     - Only the address is restricted, not the source port, since the
       viewer's port is its own.
     - Port 0 switches the `:in` channel off: no socket is opened and the
       channel stays empty, so `get` always returns 0.
     - A missing, repeated or malformed `inbound` line, or one for a channel
       that is not `udp:` `:in`, is refused naming the line, as the file's
       other lines are.
     - This form is part of what the owner approves.
3. **The host side.** The second implementer's `examples/doom/net_view` gains:
   - key capture, reading `Doom::Video#key` for the 18 `WATCHED_KEYS` after
     each `pump`, as `read_keys` does;
   - a send of the key message to the board, through `sp_udp_shim.c`.
   The viewer keeps showing frames as it does now.

   What the second implementer read in the code on 2026-10-23 (nothing was run):
   - `video.key(c)` returns the SDL shim's `keydown[c]`, which only `pump`
     updates. net_view's live loop calls `pump` every pass, so reading the
     18 keys after it gives what `read_keys` gives. The shim's key table maps
     i/j/k/l to the arrows' codes, maps both shift, ctrl and alt keys to the
     same codes, and ignores key repeat; the viewer inherits all of that.
     ESC makes the shim quit, which ends the viewer.
   - The send can use the receiving socket (`sendto`). The board then sees
     the viewer's receiving port as the source.
   - An `ffi_func` `:str` argument passes a `const char *` without a length
     (`vendor/spinel/src/ffi_spec.c`). A key message with a 0 byte therefore
     needs the length as a separate `:int` argument. Whether every byte past
     a 0 reaches the shim is **unconfirmed**.
   - The key state when the window has no focus is **unconfirmed**.
   - On the Mac the arrows once arrived as Right Command and Left Option, for
     a cause not found (the shim's comment, decision 0006 task 4); i/j/k/l
     are the fallback. Whether the macOS application firewall blocks the
     receive is **unconfirmed** (the first implementer has run the viewer on the Mac).
4. **Three identifiers**, kept apart:
   - the **board's boot id**: 0024's, chosen by the M33 once per boot and
     carried in every frame message;
   - the **controller's session id**: chosen by the viewer when it starts,
     u32, never 0;
   - the **build's session id**: the 16 hex digits `tools/app` already
     records and puts in the image as `spc_session_id`
     (`session_steps.rb`'s `session_id`, emitted by `Session.c_source`).
     It is a hash over the application, the providers, `tools/app`, the
     network file, the configuration, the image's files and the entries'
     objects, among others; the session image's `image.sha256` is one of its
     inputs. No message carries it. It is named here so the other two are
     not taken for it.
5. **The input wire.** One datagram is one message, little-endian:

   | Offset | Field |
   | --- | --- |
   | 0 | kind `K` (0x4B), u8 |
   | 1 | version 1, u8 |
   | 2 | the controller's session id, u32 |
   | 6 | the board's boot id it is meant for, u32 |
   | 10 | sequence number, u32 |
   | 14 | key state |

   - The key state is a 3-byte mask (point 12), and the message is 17
     bytes.
   - Bit i of the mask is `WATCHED_KEYS[i]`, in this fixed order:

     | Bit | Key | Code | Bit | Key | Code |
     | --- | --- | --- | --- | --- | --- |
     | 0 | right (RIGHTARROW) | 0xae | 9 | speed (RSHIFT) | 0xb6 |
     | 1 | left (LEFTARROW) | 0xac | 10 | 1 | 49 |
     | 2 | up (UPARROW) | 0xad | 11 | 2 | 50 |
     | 3 | down (DOWNARROW) | 0xaf | 12 | 3 | 51 |
     | 4 | strafe left (COMMA) | 44 | 13 | 4 | 52 |
     | 5 | strafe right (PERIOD) | 46 | 14 | 5 | 53 |
     | 6 | fire (RCTRL) | 0x9d | 15 | 6 | 54 |
     | 7 | use (SPACE) | 32 | 16 | 7 | 55 |
     | 8 | strafe (RALT) | 0xb8 | 17 | 8 | 56 |

   - Bit 0 is the first mask byte's least significant bit. The upper 6 bits
     of the third byte must be 0, and a message with any of them set is bad.
   - Another kind, another version, session id 0, or another length is bad.
   - A message whose boot id is not the board's own is bad. The viewer sends
     `K` only once it knows the boot it is showing, from that boot's frame
     messages. A datagram delayed from before a reset therefore cannot act
     on the new boot.
   - The viewer advances the sequence number by 1, modulo 2^32, on every
     send, heartbeats included, so it wraps.
   - Within one controller session, numbers so far apart that the
     comparison would be ambiguous (a difference of 2^31 or more) are not
     handled. The rule in point 13 calls them stale.
   - The mask has 0 bytes, so the shim's send takes the length as an
     argument and sends all 17 bytes.
6. **The M7's side of a tic**, before the input entry:
   - It takes messages with `Keys.get` until the channel is empty or it has
     taken `depth` of them, whichever comes first. The bound keeps the tic's
     work bounded when messages keep arriving.
   - The tic keeps a **candidate** and a **high-water** sequence number. At
     the tic's start the high-water is the last applied number, and there is
     no candidate. The messages are taken in order, and each is exactly one
     of:
     - **bad**: point 5's checks, a wrong boot id, or a session id that is
       not the bound controller's (point 7);
     - **stale**: valid, but not newer than the high-water, compared as in
       point 13. It is counted and dropped;
     - **a new candidate**: valid and newer than the high-water. The
       high-water moves to its number. If there was a candidate, that one
       becomes **superseded**.

     At the tic's end the candidate, if any, is **applied**, and its mask
     becomes the key state. So, on the M7:
     dequeued = bad + stale + superseded + applied.
   - The order these rules give, with 10 applied last:

     | Arrives in the tic | Result |
     | --- | --- |
     | 12, then 11 | 12 applied, 11 stale |
     | 12, then 12 | the first 12 applied, the second stale |
     | 12, then 13 | 12 superseded, 13 applied |

   - **A controller's first message.** The board is fully unbound only at
     boot. A time-out releases the keys, but the board keeps the last
     controller's session id and its high-water.
     - **The same session resumes** after a time-out by the ordinary
       comparison against the kept high-water. A delayed copy of a number
       it already applied is stale, does not resume play and does not
       extend anything.
     - **A first message without comparison** happens only at boot, or when
       a different session takes over after the time-out. That first valid
       message in the tic order binds its session id at once, before the
       next message is looked at. It is a candidate without a sequence
       comparison, and the high-water is replaced by its number.
     - A later message of another session in the same tic is then bad and
       cannot take the candidate's place.
     - A later message of the same session is compared against the new
       high-water as usual, so the first number is never judged stale
       against itself.
   - The difference between the messages the viewer sent and what the M33
     received is loss in the network. It is reported as that and never
     charged to the ring's drops.
   - "Tics with an applied message" is a count of tics, kept apart from the
     message counts.
   - The key state is then written to `key_state_down`, and the input entry
     is called.
7. **Who may control the board.** This restricts who is listened to; it is
   not authentication. Anyone who can send from the host's address can
   control the board.
   - The M33 accepts datagrams only from the network file's host address,
     read from the datagram's source (point 2).
   - The M7 binds to the first valid session id it sees after its boot.
   - A different session id is accepted only after the bound controller has
     timed out (point 13); that is how a
     restarted viewer takes over. The new controller starts from every key
     released, and the high-water is replaced by its first message's number
     (point 6). The timed-out controller itself resumes only by a number
     newer than its kept high-water.
   - Once a controller has taken over, the old session id is a different id
     like any other. Its delayed packets are bad and cannot take the board
     back until the new controller times out in its turn.
   - A board boot starts unbound, with every key released and nothing kept
     from the last boot. A viewer learns the new boot id from the frames and
     addresses its messages to it.
8. **The console** gains a per-second `I` line of the M7's counts: dequeued,
   bad, stale, superseded, applied, tics with an applied message, and
   time-outs. The M33's receive counts (point 2) are in its `spc_net` counts,
   read as 0024's are. `tools/doom/board-frames.rb` reads the `I` line. No
   figure becomes a realtime claim.
9. **Budgets.**
   - The M7: `play.rb`'s tic adds the inbound ring's `get` (copy and
     barriers), the decode and `DoomCore.input` to what `app.rb`'s tic does.
     Its stack and loop bounds are checked by the build as `app.rb`'s are.
     That is the M7's build obstacle to clear: whatever the actual build of
     `play.rb` refuses.
   - The M33: the network thread is ordinary Zephyr C, outside the CORE
     budget, as in 0024. Times measured there are lower bounds, not limits,
     and are reported as such.
   - The M7 application's production build still lacks the attested
     reserves of the `udp:` path (0014's clarification of 2026-10-22). That
     is a disclosure about the M33's side and the transport, not a defect of
     `play.rb`; the two are reported apart.

### The owner's choices (2026-10-23)

The owner accepted the recommended option for every point: 1(a), 2(a),
3(b), 4(a) with 500 ms, 5(a) and 6(a). The options not taken are listed
under Options, "Not taken".

10. **The tic's pace: 35 Hz.** The pace applies to the whole tic, step
    included. It does not thin out frames. Times are kept by
    `Clock.cycles32`, and P is the period, 28.6 ms.
    - The rule (the coordinator, 2026-10-23): the next tic starts at
      max(this tic's start + P, this tic's end).
    - A tic that fits waits until P after its own start. A late tic is
      followed at once by the next, with no further wait. With 40 ms tics,
      the run then goes at 25 Hz, not at about 14.6 Hz as a full period of
      waiting after each late tic would give.
    - Missed time is not caught up: no extra step runs.
    - The tic's time is measured from before the input entry to after the
      frame's `put`: input, step, render and the frame's pieces into the
      ring.
    - While tics are longer than a period, the game runs slower than real
      time.
11. **The map and skill: an existing demo's snapshot**, taken as they are.
    The image is the demo application's. The demo's commands and tic count
    are not used, and the run lasts until it stops or the board is reset.
    - DEMO1's header holds E1M5 and skill byte 2.
    - Only E1M3, E1M5 and E1M7 have been run on the board.
    - Whether the skill byte means what `bin/doom.rb`'s `-skill` of the same
      number means is **unconfirmed**.
    - A chosen map and skill (`open.rb` with `-warp`/`-skill`-style
      arguments) is a possible follow-up, not part of this decision.
12. **The key message: the 18 watched keys as a 3-byte bit mask**, in the
    fixed order of point 5, with the sequence number. The viewer sends it at
    35 Hz and again on every change.
    - A state message repairs itself after a loss.
    - The mask is the only input the entry reads anyway: the board sets
      nothing outside `WATCHED_KEYS`.
    - The mask has 0 bytes, so the shim's send takes its length as an
      argument.
13. **Loss and reordering: keep the last state, with a 500 ms time-out.**
    - Sequence numbers are compared as u32 serial numbers. A message is
      newer when its number minus the high-water (point 6), modulo 2^32, is
      between 1 and 2^31 − 1. The same number, a difference of exactly
      2^31, and an older number are all stale.
    - The time-out is 500 ms after the M7 last **applied** a new, valid
      message (point 6). It is not a promise about 500 ms of silence on the
      network, nor about how old a packet is.
    - A stale message, a message from another session and a bad message are
      counted and not used. None of them extends the time-out.
    - When the time-out passes, every key is released. It is counted once,
      when the state goes from active to expired. The next applied message
      makes the state active again.
    - Before the first message every key is released, and the time-out
      count is 0.
    - The viewer sends an all-released message when it loses focus and when
      it ends, and keeps sending all-released heartbeats while unfocused.
      The send just before the end is best effort; the time-out is the
      backstop.
14. **Death and the level's end: stop as now, and add a stop for the exit.**
    - Death itself does not stop the run. The player lies dead, the game
      goes on, and frames are still sent. Pressing use then sets
      `PST_REBORN`, and only that stops the run.
    - Death followed by use stops with `X <tic> reborn` before the step, as
      today.
    - The exit stops with `X <tic> exit`. After a tic's step succeeds, the
      application checks `game_exit_requested` before the next step; when it
      is 1, it stops there, so no step runs after the exit.
    - The exit is its own stop. It is not recast as CAPACITY or any other
      CORE failure.
    - A board reset starts a new game.
15. **Latency: measure, and set no target.**
    - Each rendered tic's frame carries where its input came from. A
      sequence number in the per-second `S` message alone would not say
      which frame used which input. A sequence number alone also cannot
      tell controller A's 7 from controller B's 7 after a takeover
      (the reviewer).
    - The frame header gains three fields:
      - the controller's session id (u32);
      - the sequence number of the key state the tic used (u32);
      - the input's state (u8): 0 no input, 1 held from an applied message,
        2 released by the time-out.
    - "No input" is session 0 and sequence 0. It covers a tic before the
      first message, and every frame of the demo application, which takes no
      keys. After a time-out the frame keeps the last controller and
      sequence with state 2. Exact spellings are the implementation's.
    - A piece of state 0 with a session or sequence other than 0, or of
      state 1 or 2 with session 0, is a bad datagram (the coordinator, 2026-10-23).
    - **Frame wire version 3** (the coordinator, 2026-10-23). A `C` message is a
      21-byte header and then 1,280 bytes of the screen, all little-endian:

      | Offset | Field |
      | --- | --- |
      | 0 | kind `C` (0x43), u8 |
      | 1 | version 3, u8 |
      | 2 | the board's boot id, u32 |
      | 6 | tic, u32 |
      | 10 | piece index, u8 |
      | 11 | piece count (50), u8 |
      | 12 | the controller's session id, u32 |
      | 16 | the sequence number the tic used, u32 |
      | 20 | the input's state, u8: 0 no input, 1 holding an applied message's state, 2 released by the time-out |
      | 21 | 1,280 bytes of the screen |

      - The version is one value of the common header, so `P`, `C` and `S`
        all carry version 3. The contents of `P` and `S` are unchanged.
      - The viewer counts a message of any kind with a version other than 3
        as bad. It does not accept version 2.
      - The viewer sends `K` only when given `--keys ADDR:PORT`, and only once
        it knows the boot id it is showing. Without `--keys` it only shows,
        as now.
      - With `--keys PORT`, the address is the source of the first datagram
        of the boot shown. A new boot's source replaces it, and a datagram
        of the same boot from another address does not (the coordinator,
        2026-10-23).
    - The header grows from 12 to 21 bytes, so a piece is 21 + 1,280 =
      1,301 bytes, and the frames channel's `size` becomes 1301.
      - The ring slot stays 1,312 bytes, (4 + 1,301 + 31) / 32 × 32, so the
        outbound ring keeps its 84,128 bytes.
      - The C header, the channel's size and the ring geometry change
        together.
    - All 50 pieces of a frame carry the same three fields. The viewer
      refuses a frame whose pieces disagree, as incomplete.
    - This raises the version of 0024's frame wire to 3, and both board
      applications send version 3. A version 2 viewer counts every version 3
      datagram as bad (its rule for another version), so the viewer and
      `tools/doom/net_frames.rb` change in the same step.
    - **How the viewer matches.**
      - Frames are still assembled on (the board's boot id, the tic), as
        now. A held sequence number spans several tics, so the input fields
        never identify a frame.
      - The key for **latency matching** is (the board's boot id, the
        controller's session id, the sequence number). It is matched to the
        time the viewer sent that message from that session.
      - It reports two spans: from the key sample to the frame's receipt,
        and from the key sample to the call of `present`.
      - When the same sequence number is held over several frames, the span
        is counted once, at the first frame received (or presented) with it.
      - It does not match superseded numbers, frames that are missing,
        frames with state 0 or 2, or another controller's numbers.
      - Neither span is when the frame appeared on the screen, and the
        reports do not call it that.
    - **The parts known today.**
      - Up to one tic period of waiting.
      - The tic itself: DEMO1's median 19.7 ms, from the first implementer's run in
        Context.
      - The M33's send of the frame's 50 datagrams. 0024's probe gives one
        datagram's send as 173 µs (median) from ITCM
        (`tools/app/launcher/net/README.md`).
      - The receive path's time is **unconfirmed**.
      - The viewer has never measured the time from receipt to display. Its
        loop waits at most 20 ms in a poll. While datagrams keep arriving,
        it shows the next frame only 28 ms after the last one
        (`net_view.rb`). These are limits in the code, not measurements
        (the second implementer).

## Validation

No oracle: the checks are the tool's refusals and the application's own
accept/reject rules. Comparing the board's frames with a host run of the same
keys would be an oracle, so it is not part of this validation; it would be the owner's call.
Every check below plants its own failing input, and each has a control that
must fail.

- **Declarations and the network file** (`tests/app`):
  - `udp:` on an `:in` channel is accepted.
  - Each of these is refused by name: `size` over 1472, an endpoint in the
    source, both transports on one channel, and a board without a
    `udp_consumer`.
  - The `inbound` line: missing, repeated, malformed, or naming a channel
    that is not `udp:` `:in`, each refused naming the line. Port 0 builds,
    with no receive socket.
- **The command from a mask, by hand.** For each case below, the expected
  `core_command` is worked out by hand from `inputport.rb`'s rules and
  written down before any run, as `tests/core-report/expect.tsv` is:
  - right, left, and both together;
  - strafe left, strafe right, and turning with strafe held;
  - speed held with forward;
  - fire, and use;
  - two weapon digits held together (which one wins);
  - turning held across the sixth tic (`IN_SLOWTURNTICS`), the boundary of
    the slow turn;
  - every key released.

  These cases run twice: through the host runner, and on the board through
  the built object. The host runner alone cannot find a wiring fault between
  the ring, the mask and `key_state_down`.
- **The M7's message rules**, in the host runner with an inbound stimulus
  file, and the same stimuli on the board:
  - no message: every key is released, and the time-out count is 0;
  - each bad kind is counted and not used: kind, version, length, session
    id 0, a reserved bit set, and a wrong boot id (a datagram from before a
    reset);
  - stale: the same sequence number, a difference of exactly 2^31, and an
    older one;
  - the sequence number wrapping past 2^32 − 1 is newer, not stale;
  - within one tic, after 10 was applied: 12 then 11 applies 12 and counts
    11 stale; 12 then 12 applies one and counts the other stale; 12 then 13
    counts 12 superseded and applies 13;
  - an unbound board receiving, in one tic, a valid message of session A and
    then one of session B: A is bound and its message is the candidate, and
    B's is bad;
  - a new controller's first number is applied without comparison, and the
    same number following it in the tic is stale;
  - the time-out: counted once, and the next applied message resumes play;
  - a stale, bad or other-session message arriving during the time-out
    does not extend it;
  - a new controller after the time-out starts from all keys released, and
    an old session's delayed packet does not take it back;
  - after A applied 12 and timed out: A's delayed 12 is stale and play stays
    released; A's 13 resumes play; B's first message, whatever its number,
    takes over;
  - focus lost: the viewer's all-released message and heartbeats release the
    keys before the time-out would;
  - the full 17-byte message, with 0 bytes inside it, arrives whole;
  - the counts: dequeued = bad + stale + superseded + applied, every tic.
- **The M33's receive stage**, on the board, with a scripted sender:
  - a datagram from another address is refused by the filter;
  - an empty datagram is counted as empty;
  - a datagram longer than `size` is counted as too long, and nothing of it
    reaches the ring;
  - while a frame message is held for retry, key datagrams are still
    received and queued, and the held message is not overtaken by a later
    frame message;
  - a burst larger than the depth fills the channel and is counted as full;
  - received = refused + empty + too long + full + queued, and the frames
    keep flowing while it receives.
- **The stops, from short planted states** (`tests/doom-core`, as the
  rebirth control already does):
  - death alone: the run continues;
  - death followed by use: `X <tic> reborn`, and no step after it;
  - the exit switch: `X <tic> exit` before the next step, and no step after
    it;
  - the input entry failing: `X <tic> input <status>`. A control must show
    the step and render are not called and the poisoned state is not read
    afterwards.
- **The build**: `play.rb` builds for `frdm_imxrt1186_cm7`. The inbound
  ring's geometry is checked against both images' maps, as the outbound one
  is. Its stack and bounds pass, or the actual refusal is reported.
- **The demo lane on ring ABI version 2**: the board lane
  (`tests/doom-core/rt1186.sh`) and `tests/app` are rerun once.
- **The frame metadata** (wire version 3), checked in `tools/doom/net_frames.rb`
  and the viewer with recorded input:
  - a frame whose 50 pieces disagree on the three fields is refused;
  - demo frames carry "no input";
  - after a takeover, A's and B's equal sequence numbers are not matched
    to each other's send times;
  - a held number is matched once.
- **The latency spans** (point 15) are reported, not judged.
- The play itself, with a person at the keyboard, is a demonstration, not a
  check.

## Consequences

- The ring ABI becomes version 2, with no compatibility with version 1. The
  demo application runs on it too, and its lane is rerun once.
- 0024's frame wire goes to version 3: each frame carries the controller's
  session id, the sequence number used and the input's state, in all 50
  pieces. The frames channel's `size` becomes 1301; the ring slot and the
  outbound ring's 84,128 bytes do not change. The demo application, the
  viewer and `tools/doom/net_frames.rb` change in the same step.
- The M33's send loop becomes one attempt per turn with one bounded held
  message, in place of `send_one`'s retry loop.
- The network file gains the `inbound` line.
- 0014 gains a clarification for `udp:` on `:in` channels. Its queue rules
  are unchanged.
- The M33's firmware gains a receiving socket and the fair service of point
  2: a second network path, outside the CORE budget, as 0014's
  clarification foresaw.

## Clarification (2026-10-23): Validation, measured

The lanes ran on the FRDM-IMXRT1186's M7 from `feature/doom-play` before its
merge as `6e23735`. Tic times are the console's `F` cycles at 792 MHz
(`CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC`), observed values, not a realtime bound.

- **The demo lane is unchanged** (`tests/doom-core/rt1186.sh`, DEMO1, 500
  tics, ring ABI v2, frame wire v3): 57 of 57 checks passed, tic median
  18.6 ms. The profile lane's median was 20.0 ms.
- **The play lane** (`tests/doom-core/rt1186-play.sh`, the scripted key
  sender, at `6103443`): 9 of 9 checks passed in 157 s.
  - The board dequeued 351 messages: 3 bad, 0 stale, 7 superseded and 341
    applied. Input timed out twice.
  - The 3 bad messages are the lane's planted ones (`BAD=3`, a reserved
    bit set); the board used none of them. The sender logged 7 late
    messages, so the lane allowed 3 to 10 bad.
  - The M33 received and queued 351, with 0 errors and 0 lost.
  - Send to frame, matched on (boot, controller, seq): min 12.9, median 33.6
    and max 50.3 ms. Tic median 14.7 ms.
- **The owner's play from a Mac keyboard** (2026-10-23, the image the third implementer
  built from `6103443` with a network file outside the repository, build id
  `09909e657f89aa2b`):
  - Tics 0 to 7340. The run ended at tic 7341 with `X ... reborn`, after the
    player died and pressed use.
  - The board dequeued 7,375 messages: 0 bad, 0 stale, 168 superseded and
    7,207 applied. Input never timed out.
  - Tic min 10.2, median 13.4, max 24.9 ms over 7,341 tics.
  - The Mac's recording (`net-viewer.rb --replay`): 7,119 complete frames
    for that boot, none incomplete, late, duplicated or backwards. The last
    `S` said 7,119 sent, 222 not sent and 0 dropped, so no sent frame was
    lost. The 124 absent frames are frames the board did not send.
  - These figures are from the console capture and the recording read on
    the day. Both were deleted afterwards at the owner's instruction, so they
    cannot be re-derived from this repository.
- Physical keys on the Mac worked in the owner's play. Before it, only
  synthetic key events had been checked.
