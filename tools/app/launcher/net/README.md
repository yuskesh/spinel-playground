# The launcher as the network firmware

`tools/app/launcher` is the FRDM-IMXRT1186's M33 image (decision 0023): it
boots from the NOR and releases the Cortex-M7. When the application has a
`udp:` channel on a board whose table names `udp_consumer ocram-ring-v1`
(decision 0024's amendment and its clarification of the tool's two names),
`spinel-core-app build` also builds it as the network firmware: it passes
the image `SPC_GEN_DIR`, a directory of two generated headers, with
`net.conf` as its `EXTRA_CONF_FILE` and `net.overlay` as its
`EXTRA_DTC_OVERLAY_FILE` (as sysbuild variables, `launcher_...`), and the
launcher's `CMakeLists.txt` adds this directory's sources. Without
`SPC_GEN_DIR` the launcher is the plain one.

It is ordinary Zephyr C, not a CORE application: sockets and the NETC
driver allocate and block (0024's amendment, item 1).

## What it does

1. `ring_init.c`, at PRE_KERNEL_1, before Zephyr's `second_core_boot`
   releases the M7 at PRE_KERNEL_2: initialises the OCRAM ring
   (`tools/app/ring/ring_abi.h`) with the channel's geometry
   (`spc_ring_geometry.h`): magic cleared first, the geometry, head = tail,
   the boot id 0, a barrier, magic last.
2. `forward.c`, on the main thread: brings up the network file's interface
   (`spc_net.h`) and takes its address by DHCP, or the file's address;
   chooses the boot id once (the cycle counter's halves and the uptime at the
   address's arrival, mixed, never 0) and publishes it in the ring after a
   barrier; binds a socket to the destination's port and connects it; then
   forwards every message the M7 puts, verbatim, as one datagram. It knows
   nothing of the messages' format: the M7 writes the wire's boot id into
   them (0024's wire format 2).
3. A send that finds no buffer is retried after 100 µs, the one message
   held, and no later one is taken until it has gone or failed; any other
   failure, or a short send, counts one error and drops that message. A
   destination port of 0 switches sending off: each message is taken and
   discarded, counted apart from those sent.

## Its counts

`spc_net` (`forward.c`) holds them together so that one debugger read takes
them all: errors (the lane's `spc_transport_udp_errors`), taken, sent,
discarded, retries, pending, in_send, fault, the boot id, the state, the
DHCP time and this core's tail. `tests/doom-core/harness/rt1186-net.sh`
reads them after a run. A fault (head - tail above depth, or a length of 0
or above max_len) stops the forwarding, and the ring's consumer_state says
so.

## Its configuration

- The network code (net, ip, the Ethernet and DSA layers, the Ethernet
  drivers) runs from the M33's ITCM: from the NOR a datagram's send took
  471 µs (median), from the ITCM 173 µs (`tools/doom/net-probe/README.md`).
- Locally administered MAC addresses (`net.overlay`).
- The DTCM is its RAM, as the plain launcher's.
- `CONFIG_TEST_RANDOM_GENERATOR`, Zephyr's non-random generator, for the
  DHCP transaction id only; `net.conf` says why. A true random source is
  still open (decision 0014's clarification of 2026-10-22).
- No console: LPUART1 is the M7's.
