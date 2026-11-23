# OCRAM ring test (measurement pair, not a deliverable)

The second step of decision 0024's amendment ("Order of work"): the message
ring between the FRDM-IMXRT1186's cores, checked with fixed patterns from
the M7 before DOOM's frames go through it. The ring's ABI, version 3 since decision 0027 (the
test uses lines 0 to 4 and its own 5 to 7), is
`tools/app/ring/ring_abi.h`; the test's own words and patterns are `test_words.h`.

Two ordinary Zephyr images, written to the NOR together in place of the
DOOM image and replaced by it afterwards:

- `m33/`: tools/app/launcher's M33 image (the boot header, the XMCD, the M7
  released to run in place) plus the ring's initialisation, at PRE_KERNEL_1
  before the M7 is released, and the consumer and checker. It has no
  console; it writes its report into the test's words.
- `m7/`: the producer, built with the DOOM M7 application's board files
  (decision 0023), and the pair's console: every line starts with `R `.

The ring is copied, single-producer and single-consumer: a put copies the
message into a slot, a take copies it out. No UDP is sent here.

## What is checked

- **Where the ring is.** The first 128 KB of OCRAM2: 0x2050_0000 in the M7's
  view and 0x3050_0000 in the M33's. `build.sh` refuses an image with any
  section in OCRAM2 in either view, so nothing either image links or
  allocates statically (no stack, heap or driver buffer) is there. The M33's
  network probe (`tools/doom/net-probe`) links its driver's uncached buffers
  into its DTCM, at 0x3000_0000, not here.
- **The cache attributes, read from the MPUs at run time.** Neither image
  adds a region: Zephyr's own tables already make all of OCRAM2 Normal
  non-cacheable on both cores. The M7 prints every enabled region and
  requires the one that decides the ring to be TEX 001, C 0, B 0; the M33
  reports its region's MAIR attribute, which must be 0x44.
- **Both views reach the same memory.** The M33 writes a probe word before it
  releases the M7, the M7 reads it through its own alias and writes another,
  and the M33 reads that one. The run as a whole then reads and writes every
  slot from both cores.
- **The put's own refusals.** A length of 0 and of 1293 are refused with
  -EINVAL and leave head where it was; 1292 is accepted (it is seq 0's).
- **Short messages.** The first 7 messages are 1 to 7 bytes of a fixed
  pattern.
- **Normal messages, for 3 s.** 8 to 1292 bytes each: seq, the refusals so
  far, then a pattern of seq. The checker requires every byte and length,
  and that the gap in seq between two taken messages equals the refusals
  between them (u32 differences).
- **The counts' wrap.** head and tail start at 0xFFFF_FF00, so they cross 2^32
  after 256 messages.
- **Full.** The consumer is slower than the producer, so the ring is full most
  of the time and most attempts are refused.
- **A pause.** After 5,000 normal messages the M33 sets consumer_state to
  stopped, keeps its slots and its tail for 200 ms, and resumes; the order
  holds across it.
- **The end.** The M7 publishes attempted, accepted and refused, a barrier,
  then DONE. The M33 drains until head == tail and requires attempted ==
  accepted + refused, taken == accepted, and the refusals after the last
  taken message to close the count. It publishes its report, a barrier, then
  the status word; the M7 waits for the status and prints the report.
- **Faults and time-outs.** head - tail above depth, or a len of 0 or above
  max_len, stops the checker with a failure; so does no progress for 10 s,
  and each core gives up on the other after 10 s.
- **The kept failing input.** `build.sh OUT 1` builds the M7 with
  `SPC_RING_PLANT_EARLY_HEAD`: each put publishes head before it writes the
  slot, then waits until the consumer has taken that slot, so the consumer
  always reads a slot before it is written. The checker must fail. This
  shows the checker sees such a read; it is not a proof of the barriers'
  order, and a build without the barriers is not required to fail.

What is not checked: the M33's non-secure alias of OCRAM2 (the M33 runs
secure here), a reset of one core alone (outside the ABI, `tools/app/ring/ring_abi.h`), and
the DOOM firmware's boot id (the test writes a placeholder, 1).

## Building and running

```sh
export ZEPHYR_BASE=$HOME/toolchains/zephyr-v4.4.2/workspace/zephyr
export ZEPHYR_SDK_INSTALL_DIR=$HOME/zephyr-sdk-1.0.1
export PATH=$HOME/toolchains/zephyr-v4.4.2/.venv/bin:$PATH
sh tools/doom/ocram-ring/build.sh OUT        # OUT/nor.bin; OUT 1 for the planted M7
```

`nor.bin` is written at the NOR's start (`0x14000000`), as the DOOM lane
writes its image (`tests/doom-core/harness/rt1186-host.sh`, `rt_flash`); the
console is read from a reset until the line `R end`. Take the board's lock
first, and write the DOOM image back afterwards.

## Measured (2026-10-22)

On the board, after a system reset of both cores:

| build | M7 attempts / accepted / refused | M33 taken (normal + short) | errors | max occupancy | pause | final head = tail | `R end` |
|---|---|---|---|---|---|---|---|
| the pair | 1,042,565 / 23,506 / 1,019,059 | 23,506 + 7 | 0 | 64 (full) | 200 ms | 0x0000_5AD9 | ok |
| planted M7 | 30 / 30 / 0 | 0 + 0 | 1 (a len of 0, at the first message) | 1 | none | head 0xFFFF_FF01, tail 0xFFFF_FF00 | fail |

- The M7's region 4 (base 0x2050_0000, 256 KB, TEX 001 C 0 B 0, from the
  board's `cm7/mpu_regions.c`) decides the ring; the M33's region covering
  it is RBAR 0x3050_0001, RLAR 0x3053_FFE5, attribute 0x44.
- Both probe words were read through the other core's alias.
- The pair's head started at 0xFFFF_FF00 and ended at 0x0000_5AD9 after
  23,513 messages, across the wrap.
- In the pair, 23,513 messages in 3 s is about 7,800 a second, set by the
  consumer, which checks every byte; DOOM's 35 frames a second are 1,750
  messages a second. This rate is computed from the counts, not a
  measurement of the ring's own speed.
- An earlier run of the same pair with an extra 128 KB non-cacheable region
  of its own on the M7 gave the same result; the region duplicated the
  board's, and was removed.
