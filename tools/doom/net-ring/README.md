# The network path's test pair (measurement, not a deliverable)

DOOM's stream without DOOM: an M7 test producer (`m7/`) puts the board
application's messages, in wire format 3 (decisions 0024 and 0025), from a synthetic
screen, into the OCRAM ring; the M33 is `tools/app/launcher` built as the
network firmware (`tools/app/launcher/net/README.md`), which sends each one
verbatim. It judges the M33 firmware and the viewer before the application
tool generates the channel, and apart from DOOM's own cost.

The producer runs 600 tics at 35 a second. At each tic it loads the boot id
once and puts nothing while it is 0 (the tic's frame is not sent); at the
first tic of each second it puts the palette before the frame and the stream
counts after it; it chooses frames by time, at most 35 a second, keeping the
average's phase, and puts a chosen frame as 50 pieces. Byte (x, y) of tic t
is (x + 2y + 3t) mod 256. It prints its counts and `R end`.

```sh
sh tools/doom/net-ring/build.sh NETFILE OUT    # OUT/nor.bin
```

`NETFILE` is the network file, outside the repository, with a
`channel frames HOST PORT` line. `build.sh` writes the network firmware's two
headers for a channel of 1301 bytes and depth 64, as the board application
declares it, builds both images, refuses either with a section in OCRAM2,
and joins them into the NOR image. Take the board's lock, write the image at
the NOR's start, read the console to `R end`, read the M33's `spc_net` with
the debugger, and write the DOOM image back.

## Measured (2026-10-22)

One run to the receiver on a Mac, recorded there by the implementer with the v2
`net_view --record` and judged with `tools/doom/net-viewer.rb --replay`:

- The producer: 600 tics, 487 frames sent, 113 not sent (the tics before the
  boot id arrived, 3.2 s of DHCP), 0 dropped, 0 palette and 0 stats drops,
  24,378 messages put.
- The M33, read with the debugger after the run: 24,378 taken and 24,378
  sent, 0 errors, 0 retries, no fault, head = tail.
- The Mac: that boot's 487 frames all complete, every `S` adding up, no bad
  datagram. The recording also held 33 frames of an earlier boot, the one
  the NOR write's own reset starts before the lane's reset; the viewer kept
  the two boots apart by their ids.
