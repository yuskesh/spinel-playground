# M33 UDP probe (measurement image, not a deliverable)

A Zephyr application for the FRDM-IMXRT1186's Cortex-M33 alone. It is the
first step of decision 0024's amendment ("Order of work"): an M33-only UDP
sender at 35 frames a second, measured before the M7's ring and DOOM's
frames are connected to it. The M7 is not released; the image is written
to the NOR in place of the DOOM image and replaced by it afterwards.

It is ordinary Zephyr C, as the amendment's item 1 says the M33's network
firmware is: sockets and the NETC driver allocate and block.

## What it does

- Brings up the NETC switch's user port `swp0` (the cable is on switch port
  0, decision 0024's amendment, item 4) and takes an IPv4 address by DHCP.
- Gives the switch ports and the ENETC pseudo-MAC locally administered
  unicast MAC addresses in `app.overlay`.
- Sends a synthetic 320 × 200 8-bit screen in the wire format of 0024's
  clarification of 2026-10-22 (version 1): a palette (`0x50`) at the start
  and every second, and each frame as 50 pieces (`0x43`) of 1280 bytes.
  Byte (x, y) of tic t is (x + 2y + 3t) mod 256, so the picture moves.
- Chooses frames by time, at most 35 a second for 12 seconds. A frame whose
  time passed while the one before it was still being sent is not sent, and
  is counted as such.
- Prints its measurements on the console (LPUART1, the MCU-Link's VCOM), each
  line starting `P `:
  - the link's speed and duplex from the PHY, and the address DHCP gave;
  - each frame's service time, from the first piece's send to the last one's
    return (minimum, median, 99th percentile, maximum);
  - each send call's time, and its failures by errno: a send that finds no
    buffer (EAGAIN, ENOBUFS, ENOMEM) is retried after 100 us, any other
    failure loses the piece and is counted;
  - the driver's busy-wait for transmit completion. The pinned driver spins
    on `tx_done` between the HAL's send and its reclaim
    (`drivers/ethernet/nxp_imx_netc/eth_nxp_imx_netc.c`), so the probe wraps
    the HAL's `EP_SendFrame`, `EP_SendFrameCommon` and
    `EP_ReclaimTxDescCommon` with `--wrap` and times the gap. Zephyr's
    source is not changed;
  - the CPU's share over the sending window, from the idle thread's cycles;
  - every thread's stack high-water mark.

The send-call and busy-wait figures are kept in 1 µs bins up to 1023 µs, the
last bin holding everything above, so their medians and 99th percentiles
are bin values; their means and maxima are exact.

## The random source

The network stack calls `sys_rand_get` (a DHCP transaction id, an ephemeral
port), and the switch driver links a random-MAC function. The RT118x has no
entropy driver wired up at the pinned Zephyr (decision 0014's clarification
of 2026-10-22). This image takes `CONFIG_TEST_RANDOM_GENERATOR`, Zephyr's
non-random generator, because what it needs is narrow:

- a DHCP transaction id only has to differ from other clients' on the LAN
  for one exchange;
- the socket binds a fixed source port, so no ephemeral port is asked for;
- every port's MAC comes from the overlay, so the random MAC is never made.

It is not a choice for a deliverable image.

## Building and running

The network file is outside the repository, in the form
`tools/app/lib/core_app/net.rb` reads, with the address left to DHCP:

```
interface swp0
address dhcp
channel frames 192.0.2.14 5029
```

```sh
export ZEPHYR_BASE=$HOME/toolchains/zephyr-v4.4.2/workspace/zephyr
export ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1
export PATH=$HOME/toolchains/zephyr-v4.4.2/.venv/bin:$PATH
sh tools/doom/net-probe/build.sh NETFILE OUT        # OUT/build/zephyr/zephyr.bin
```

`zephyr.bin` begins with the boot header and the XMCD, and is written at the
NOR's start (`0x14000000`), as the DOOM lane writes its image
(`tests/doom-core/harness/rt1186-host.sh`, `rt_flash`). The console is read
from a reset until the line `P end`. Take the board's lock first, and write
the DOOM image back afterwards.

## Measured (2026-10-22)

Three runs on the board, each 12 s at 35 frames a second to the receiver
on a Mac (the network file's destination), received and recorded there by
the implementer with `net_view --record` and judged with
`tools/doom/net-viewer.rb --replay`. Every run: link 1000 Mb/s full duplex
on `swp0`, an address taken by DHCP, no failed send and no retry, and no
datagram lost on the network (the datagrams and complete frames the Mac counted equal
those the board sent; every absent frame is one the board did not send).

| run | code | frames sent / not sent | frame service median (max) | send call median (p99, max) | busy-wait median (mean, p99, max) | CPU busy |
|---|---|---|---|---|---|---|
| 1 | in place from the NOR | 407 / 13 | 29,466 µs (31,401) | 471 µs (615, 1,442) | 9 µs (15, 49, 377) | 100.0 % |
| A | in place from the NOR, the cache states printed | 372 / 48 | 32,179 µs (34,256) | 521 µs (681, 1,529) | 8 µs (16, 49, 474) | 100.0 % |
| C | the network code in the ITCM (`PROBE_RELOCATE=1`, 35,696 B) | 420 / 0 | 14,331 µs (15,178) | 173 µs (180, 516) | 5 µs (5, 6, 7) | 50.5 % |

- Both caches were already on (`P cache code on system on`, run A), so
  turning the code bus cache on is not a remedy. Moving the network code to
  the ITCM halved the service time (run C against runs 1 and A).
- Runs 1 and A differ by about 9 % in service time with code that differs
  only by one printed line; that difference is not explained.
- The frame's service time includes making the synthetic picture, a
  division and a remainder per byte. 50 sends at C's median take 8.65 ms of
  its 14.3 ms (computed from the medians, not measured apart).
- The driver's busy-wait for transmit completion is 5 µs a datagram from
  the ITCM, about 3 % of a send call.
- Memory: 75,888 B of the 128 KB DTCM (the driver's uncached buffers,
  22,232 B, among them); 149,672 B of image in the NOR for run 1 and
  150,872 B for run C, which copies 35,696 B of it to the ITCM at boot. Stack high-water marks: main 1,000
  of 4,096 B, rx_q[0] 816 of 1,504, netc_eth_rx 384 of 1,504, sysworkq 680
  of 1,560, net_mgmt 208 of 800, idle 64 of 320.
