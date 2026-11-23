# 0027: Both FRDM-IMXRT1186 cores from Spinel, and a declared channel between them

- Date: 2026-10-26
- Status: Accepted (owner, 2026-10-26): the declaration is one shared
  `.channel` contract file that both applications read, with the generated
  API as below; a build with both the network firmware and an M33 Spinel
  application is refused, and how the two live together is decided later;
  no floating point in a message; stage 2 polls, with no doorbell, and
  measures the wait from `put` to `get`, and a doorbell over the MU follows
  stage 2 as its second part, under its own decision (owner, 2026-10-26); the
  console relay's line is `tic u32`, `len u8`, `text u8 × 119`, depth 16;
  the M33's table is `frdm_imxrt1186_cm33_amp`. The rest is the
  implementation plan, within those choices. The owner approved starting
  the implementation on 2026-10-26; the three RM facts it required were
  confirmed that day (Preconditions of implementation). The same day the
  owner chose the Acceptance's DOOM application (`pair.rb`, no `udp:`
  channel), the M7 printing both cores' ids, and `--companion` and
  `companion_board` as tool options, and then stage 2's choices (The first
  user, Stage 2's choices).
- Scope: stage 1, both images of the FRDM-IMXRT1186's two cores built by
  Spinel and combined by sysbuild; stage 2, a declared contract for a channel
  between the two cores, with the glue on both sides generated from it.
  Stages 3 and 4 are later work (Out of scope).

## Context

What exists on main at `de99736`. Zephyr paths are of the pinned tree,
v4.4.2 at `dccb09599635bdff17633fa7e9dab014b91dce90`. RM is IMXRT1180RM
Rev. 9, 2025-12-09 (its cover). §12.1 and §12.10 are cited as decisions 0021
and 0023 recorded them; the memory maps (§3.2, §3.3), the interrupt summary
(§4.2) and the MU chapter (§37) were read for this record on 2026-10-26.

### The two images today (decisions 0021, 0023, 0024, 0025)

- **The ROM starts the M33**, and the M7 stays in reset until the M33
  releases it (RM §12.1, §12.10; decision 0023, Context).
- **The M33 image is C, not Spinel.** `tools/app/launcher` boots from the NOR
  with the boot header and the XMCD, opens the TRDC and releases the M7
  (`tools/app/launcher/prj.conf:1-12`, `CONFIG_SECOND_CORE_MCUX=y`,
  `CONFIG_CM7_BOOT_FROM_FLASH=y`). Zephyr does the release in the SoC's
  reset hook and at PRE_KERNEL_2 (`soc/nxp/imxrt/imxrt118x/soc.c:852-859`,
  `Prepare_CM7`; `soc.c:866-899`, `second_core_boot`).
  - With a `udp:` channel the launcher is also the network firmware
    (decision 0024's amendment; `tools/app/launcher/net/README.md`): ordinary
    Zephyr C, because sockets and the NETC driver allocate and block.
- **The M7 image is the Spinel CORE application** of decision 0014
  (`examples/doom/core/board/app.rb`, `play.rb`), built by
  `spinel-core-app build` for the board table
  `tools/app/zephyr/v4.4.2/boards/frdm_imxrt1186_cm7.tsv`.
  - That table's `launcher` fact names `tools/app/launcher` for
    `frdm_imxrt1186/mimxrt1186/cm33`. `tools/app/lib/core_app/pipeline.rb:251-259`
    then writes a sysbuild `ExternalZephyrProject_Add` for it, and builds
    with `--sysbuild` (`pipeline.rb:927`).
- **The NOR layout both images share**
  (`tools/app/zephyr/v4.4.2/boards/frdm_imxrt1186_nor.overlay:6-24`):

  | NOR offset | content | written by |
  |---|---|---|
  | `0x000000` | boot header and XMCD; the launcher's code from `slot0` at `0x020000` (896 KB) | launcher build |
  | `0x100000` | the M7's code, run in place (`m7_code_partition`, 6,272 KB) | application build |
  | `0x720000` | the session image, to the end of the 16 MB NOR | `tools/doom/session-image.rb` |

  `tools/doom/nor-image.rb` writes the launcher and the application at their
  offsets.
- **The session id** (`tools/app/lib/core_app/session_steps.rb:229-261`) is
  the M7 build's. It covers every file under `tools/app`, and so the
  launcher's sources. It does not cover the launcher's configured devicetree,
  its `.config` or its binary; `build.json`'s `launcher` records the
  launcher's sha256 beside it (`docs/building.md`, section on the M7 board).
- **The M33 board table exists** for single-core use:
  `tools/app/zephyr/v4.4.2/boards/frdm_imxrt1186.tsv` (`single_core true`,
  `security secure,no-tfm`, `ram_bytes` the 8 MB HyperRAM). Decision 0024's
  clarification keeps it buildable for the application suites, and makes a
  DOOM run on the M33 a named skip.

### The same memory at different addresses

Read from the two cores' devicetrees, and checked against RM §3.2
(Table 4, the CM7's map) and §3.3 (Table 5, the CM33's). Each core sees one
physical memory through its own window.

| memory | M7 view | M33 view | source |
|---|---|---|---|
| HyperRAM, 8 MB (FlexSPI1) | `0x2800_0000` | `0x3800_0000` | `dts/arm/nxp/imxrt/nxp_rt118x_cm7.dtsi:34-37`, `nxp_rt118x_cm33.dtsi:47-50` |
| QSPI NOR (FlexSPI2) | `0x0400_0000` | `0x1400_0000` (secure alias) | `nxp_rt118x_cm7.dtsi:39-42`, `nxp_rt118x_cm33.dtsi:52-55` |
| OCRAM1, 512 KB | `0x2048_0000` | `0x3048_0000` | the `memory` node's ranges (`nxp_rt118x_cm7.dtsi:25-27`, `nxp_rt118x_cm33.dtsi:28-30`) over `nxp_rt118x.dtsi:1644-1647` |
| OCRAM2, 256 KB | `0x2050_0000` | `0x3050_0000` | the same ranges over `nxp_rt118x.dtsi:1657-1660` |
| M7 ITCM, 256 KB | `0x0` | `0x303c_0000` | `nxp_rt118x_cm7.dtsi:13-17`, `nxp_rt118x_cm33.dtsi:32-37` |
| peripherals | `0x4000_0000` | `0x5000_0000` | `nxp_rt118x_cm7.dtsi:29-32`, `nxp_rt118x_cm33.dtsi:39-45` |

- **The M33 has two aliases of each memory** (RM §3.3, Table 5): a secure one,
  which the column above gives and Zephyr's secure M33 build uses, and a
  non-secure one 0x1000_0000 below it.

  | memory | M33 non-secure | M33 secure |
  |---|---|---|
  | HyperRAM (FlexSPI1, 128 MB window) | `0x2800_0000` | `0x3800_0000` |
  | OCRAM1 | `0x2048_0000` | `0x3048_0000` |
  | OCRAM2 | `0x2050_0000` | `0x3050_0000` |
  | M7 DTCM (aliased, 256 KB) | `0x2040_0000` | `0x3040_0000` |
  | M7 ITCM (aliased, 256 KB) | `0x203C_0000` | `0x303C_0000` |
  | QSPI NOR (FlexSPI2) | `0x0400_0000` | `0x1400_0000` |

  The M33's non-secure addresses of HyperRAM, OCRAM and the NOR are the
  M7's own (RM §3.2, Table 4, where every row is non-secure). Zephyr's IPC
  sample names OCRAM2 as `0x2050_0000` on the M33
  (`samples/subsys/ipc/ipc_service/static_vrings/boards/frdm_imxrt1186_mimxrt1186_cm33.overlay:12-14`),
  the non-secure alias. The ring and the channels of this record keep the
  secure alias on the M33, as `ring_abi.h` does.
- **The M33 reaches the M7's DTCM** through an alias, `0x3040_0000` (S) and
  `0x2040_0000` (NS), 256 KB (RM §3.3, Table 5, "M7 DTCM (aliased)"; the next
  256 KB alias the DTCM further only when the M7's ITCM is configured to
  0 KB). The M7 likewise reaches the M33's System TCM at `0x2020_0000`
  (RM §3.2, Table 4). This record uses neither: the channel region stays in
  OCRAM2.
- The existing ring already lives with this: `tools/app/ring/ring_abi.h:79-86`
  defines `SPC_RING_M7_BASE` (`0x2050_0000`) and `SPC_RING_M33_BASE`
  (`0x3050_0000`), and every slot is reached as base plus offset.

### Caches and the shared region

- **Both cores cache.** The M7 has its L1 caches (`HAS_MCUX_CACHE`,
  `soc/nxp/imxrt/imxrt118x/Kconfig:38-40`). The M33 has the XCACHE
  (`HAS_MCUX_XCACHE`, `Kconfig:33-36`; `CACHE_TYPE` defaults to
  `EXTERNAL_CACHE` on the M33, `Kconfig.defconfig:41-43`). The SoC enables
  the data cache at start (`soc.c:847`).
- **What is cacheable, by Zephyr's tables:**
  - OCRAM2 is Normal non-cacheable on both: the M7's
    `boards/nxp/frdm_imxrt1186/cm7/mpu_regions.c:72-75`
    (`REGION_RAM_NOCACHE_ATTR`), the M33's `nxp_rt118x_cm33.dtsi:95-97`
    (`ATTR_MPU_RAM_NOCACHE`).
  - OCRAM1 is cacheable on both (`mpu_regions.c:67-70`,
    `ARM_MPU_SRAM_REGION_ATTR`; `nxp_rt118x_cm33.dtsi:91-93`, `ATTR_MPU_RAM`).
  - The HyperRAM is cacheable on the M7 when `hyperram0` is enabled
    (`mpu_regions.c:77-80`), as the DOOM application's overlay does
    (`tools/app/zephyr/v4.4.2/boards/frdm_imxrt1186_cm7.overlay:23-25`).
- **Non-cacheable is not shareable here.** `REGION_RAM_NOCACHE_ATTR` is
  Non-shareable, so the order between the cores comes from full-system
  barriers (`dmb 0xF`), not from the attribute (`ring_abi.h:18-22`,
  `spc_ring_dmb` at `ring_abi.h:121-130`).
- The ring's own board test reads both MPUs at run time and refuses a ring
  region that is not non-cacheable (`tools/doom/ocram-ring/README.md`, "The
  cache attributes").

### The two ISAs and their stack guards

- **M33:** Armv8-M Mainline (`thumbv8m.main-none-eabi`), DSP, single-precision
  FPU, TrustZone (`soc/nxp/imxrt/imxrt118x/Kconfig:10-19`). It has PSPLIM, so
  Zephyr implies `CONFIG_BUILTIN_STACK_GUARD`
  (`arch/arm/core/Kconfig:218`, `:229`). PSPLIM caught the overflow of
  2026-10-21 (decision 0021, decision 0023 Context).
- **M7:** Armv7E-M (`thumbv7em.none-eabi`), double-precision FPU
  (`Kconfig:20`), no TrustZone, no PSPLIM. Zephyr then selects
  `CONFIG_MPU_STACK_GUARD` (`arch/arm/core/Kconfig:230`). Decision 0023 item 3
  had the application tool model it: the guard sits below the stack buffer
  (`tools/app/zephyr/v4.4.2/reserve-harness/paths/frdm_imxrt1186_cm7/guard_area.tsv:2`),
  PendSV pushes 8 B more under it (`.../pendsv.tsv:2`), and the tool refuses
  `CONFIG_FPU_SHARING` with `CONFIG_MPU_STACK_GUARD`
  (`tools/app/lib/core_app/pipeline.rb:1001-1002`).
- Both are little-endian and 32-bit, and single-copy atomic on aligned `u8`,
  `u16` and `u32` (0014 §5 admits `u8`, `i32` and `u32` on the M33 for
  cross-context state). `i64` is refused on 32-bit targets (decision 0019's
  revision, owner 2026-10-21).

### The Messaging Unit and Zephyr's drivers

- **Two core-to-core MUs**, each with an A side for the M33 and a B side for
  the M7, all enabled in the SoC's devicetrees:

  | label | core | offset in the core's peripheral window | IRQ | source |
  |---|---|---|---|---|
  | `mbox1_a` | M33 | `0x0422_0000` (`0x5422_0000`) | 21 | `nxp_rt118x_cm33.dtsi:68-75` |
  | `mbox2_a` | M33 | `0x0243_0000` (`0x5243_0000`) | 22 | `nxp_rt118x_cm33.dtsi:77-84` |
  | `mbox1_b` | M7 | `0x0423_0000` (`0x4423_0000`) | 21 | `nxp_rt118x_cm7.dtsi:55-62` |
  | `mbox2_b` | M7 | `0x0244_0000` (`0x4244_0000`) | 22 | `nxp_rt118x_cm7.dtsi:64-71` |

  Each is `compatible = "nxp,mbox-imx-mu"` with four channels
  (`rx-channels = <4>`).
- **The RM agrees** (§37, Messaging Unit). There are two MU instances
  (§37.1), each with 4 transmit and 4 receive registers per side and 4
  general-purpose interrupts (§37.2.2). The interrupt summary (§4.2,
  Table 11) sends MUA's interrupt to the M33 ("to communicate with M33
  core") and MUB's to the M7, on IRQ 21 for MU1 and 22 for MU2, and the
  AIPS-1 and AIPS-2 maps (§3.4, §3.5) place MU1_A at `0x4422_0000`, MU1_B at
  `0x4423_0000`, MU2_A at `0x4243_0000` and MU2_B at `0x4244_0000`
  (non-secure; secure at `0x5…`). So the A sides are the M33's and the B
  sides the M7's, as the labels say.
- **The usable driver is `mbox`, not `ipm`.**
  - `drivers/mbox/mbox_nxp_imx_mu.c` binds `nxp_mbox_imx_mu` (line 19), with
    `CONFIG_MBOX_NXP_IMX_MU` on by default when such a node is enabled
    (`drivers/mbox/Kconfig.nxp_imx`). It has four channels of 4 bytes
    (`mbox_nxp_imx_mu.c:21-22`). A send with no message triggers the
    channel's general-purpose interrupt and ignores one already pending
    (signalling mode, `:62-77`); a send with a message writes one 32-bit
    word (`:82-91`).
  - `drivers/ipm/ipm_imx.c` binds `nxp,imx-mu` (line 7). No RT118x devicetree
    uses that compatible; the RT11xx, i.MX7/8 and i.MX6SX ones do.
- **Zephyr's own samples use it on this board:**
  `samples/drivers/mbox` (M33 `mboxes = <&mbox1_a 1>, <&mbox1_a 0>`, M7
  `<&mbox1_b 0>, <&mbox1_b 1>`, in each core's `boards/` overlay), and
  `samples/subsys/ipc/ipc_service/static_vrings`, whose shared memory is the
  first 32 KB of OCRAM2, where our ring is.
- **Not to be confused with the ELE's MU.** `second_core_boot` talks to the
  EdgeLock enclave through `MU_RT_S3MUA` (`soc.c:872`), a different unit.
- **The ring uses no MU today.** The M33's forwarder polls and sleeps
  100 µs when nothing moved (`tools/app/launcher/net/forward.c:281-349`);
  the M7's `get` is called once a tic.

### The channel that already crosses the cores

Decisions 0024 and 0025 already built one, by hand, for the network:
`tools/app/ring/ring_abi.h`, ABI version 2.

- The first 128 KB of OCRAM2. A header of twelve 32-byte lines, each with one
  writer; an outbound ring (M7 puts, M33 takes) and an inbound ring (M33
  puts, M7 takes).
- Running u32 head and tail, a power-of-two depth, release/acquire by
  barriers, a geometry check before use (`spc_ring_geometry_ok`), and only a
  whole-chip start supported (`ring_abi.h:24-71`).
- The M7's side is generated from 0014's `channel` declaration
  (`tools/app/templates/channel_xcore.c.erb`, `channel_xcore_in.c.erb`;
  geometry from `tools/app/lib/core_app/channels.rb:161-170`). The M33's side
  is hand-written C (`tools/app/launcher/net/ring_init.c`, `forward.c`).
- A channel's message is bytes: 0014 §5's `put(buf, n)` and `get(buf)`. The
  M33 forwards each message verbatim and knows nothing of its format.
- The board-table fact `udp_consumer ocram-ring-v1` is what makes the other
  core the consumer (decision 0024's clarification of the tool's two names).

What is missing for a general two-core program: the M33 side is not Spinel
and not generated; nothing types a message; the ring is tied to the `udp:`
transport; and nothing states that the two images agree on the channel.

## Stage 1: both images from Spinel

### The M33's target profile

A second board table for the M33 as the companion of the M7, beside the
single-core one, which stays as it is.

- **`frdm_imxrt1186_cm33_amp`** (the owner's name, 2026-10-26) over
  `frdm_imxrt1186/mimxrt1186/cm33`:
  - RAM is the M33's DTCM, 128 KB at `0x3000_0000`, as the launcher's
    overlay does today (`tools/app/launcher/app.overlay:1-25`). The HyperRAM
    stays the M7's alone.
  - `CONFIG_SECOND_CORE_MCUX=y` and `CONFIG_CM7_BOOT_FROM_FLASH=y`, from the
    launcher's `prj.conf`. The image keeps the boot header and the XMCD at
    NOR 0.
  - No console. LPUART1 is the M7's until stage 2's first user moves it
    (below).
  - `security secure,no-tfm`, as the single-core table.
  - The target is the existing `thumbv8m.main-none-eabi` route of the M33
    lane (decision 0021), with PSPLIM as its stack guard. The M7's table
    keeps the MPU guard of decision 0023.
  - Its own reserves rows (`tools/app/zephyr/v4.4.2/reserves.tsv`), traced
    for this configuration, since `CONFIG_SECOND_CORE_MCUX` adds init work.
- **The M7's table names the pair's board; the build names its application.**
  The M7's table carries the fact `companion_board frdm_imxrt1186_cm33_amp`,
  and `spinel-core-app build --companion APP.rb` builds APP.rb for that board
  in place of `tools/app/launcher` (owner, 2026-10-26: tool options, not
  vocabulary; `docs/building.md`). Without `--companion`, the plain launcher
  is built, as today.
- **What the M33 application may be.** A 0014 CORE application with its own
  `every_*` work and channels. The network firmware stays C: sockets and
  the NETC driver allocate and block, which CORE refuses (0024's amendment).
  A build with both a `udp:` channel, which needs the network firmware, and
  an M33 Spinel application is refused by name (owner, 2026-10-26). Whether
  the network code later becomes the M33 application's transport thread or
  stays a separate C image is decided later (Out of scope / later).

### The image layout

Unchanged in the NOR. Only the M33 image's origin changes.

| NOR offset | image | core | code runs | RAM |
|---|---|---|---|---|
| `0x000000` | boot header, XMCD | — | — | — |
| `0x020000` | the M33 application (`slot0`, at most 896 KB) | M33 | in place, `0x1402_0000` in its view | DTCM, 128 KB |
| `0x100000` | the M7 application (`m7_code_partition`) | M7 | in place, `0x0410_0000` in its view | HyperRAM `0x2800_0000`, DTCM |
| `0x720000` | the session image | M7 | read in place | — |

- OCRAM2's first 128 KB is the channel region of stage 2 and is linked by
  neither image (`ring_abi.h:10-13`). The rest of OCRAM2 and all of OCRAM1
  are unassigned.
- The build refuses an M33 application that reaches `0x100000`, as it
  refuses M7 code that reaches `0x720000` today.

### One build, one id over both images

- **One `spinel-core-app build`** makes both applications in one sysbuild:
  the M7 application as the default image, the M33 application as the
  `ExternalZephyrProject_Add` image that `pipeline.rb:251-259` already
  writes for the launcher.
- **Each image keeps its own id**, computed as `session_id` does today
  (application source, board, `tools/app`, configured devicetree, `.config`,
  flags, clang, Zephyr, objects).
- **A pair id** covers both: a digest over the two ids and the digest of every
  channel contract the pair uses (stage 1 has none). Both images embed it.
  The M33 has no console in stage 1, so the M7 prints for both (owner,
  2026-10-26):
  - The M33 writes its own id and the pair id into line 11 of the channel
    region's header (`SPC_RING_W_PAIR_*`, `ring_abi.h`), then a magic word,
    at `PRE_KERNEL_1`, before Zephyr's `second_core_boot` releases the M7 at
    `PRE_KERNEL_2` (`soc/nxp/imxrt/imxrt118x/soc.c`).
  - The M7 prints the two as `SPC_PAIR_ID` and `SPC_COMPANION_ID` after its
    `SPC_SESSION_ID`, compares the pair id with its own, and zeros the words.
    Without the magic, or on a mismatch, it prints `SPC_PAIR_REFUSED` and
    refuses every cross-core channel. This catches two images written from
    different builds, which a NOR written in two steps allows.
- `build.json` records both images and the pair id. `tools/doom/nor-image.rb`
  writes both from the one build directory.

## Stage 2: the core-to-core channel contract

### What a message may hold

- **Values that can be copied:** `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, and
  fixed-length arrays of those (byte strings are `u8` arrays). The layout is
  the declaration's order, each field at its natural alignment,
  little-endian, with no padding the declaration does not name.
- **Refused:** `i64` and `u64` (decision 0019's revision), every floating-point
  type, `f32` included (owner, 2026-10-26), objects, strings of variable
  length, and any pointer or address.
- **An address is an offset.** A field that refers to memory is an `offset`
  into a region the contract declares, never a pointer. Each side's
  generated code turns it into its own address with its own base (the
  `SPC_RING_M7_BASE` / `SPC_RING_M33_BASE` pattern), and checks the offset
  and the extent against the region's size before it touches anything.
  - In stage 2 only the channel's own slots are such a region, and an
    `offset` field into any other region is refused. Who may write a shared
    region and when is an ownership rule, which AGENTS.md does not let us
    infer; a bulk-buffer region needs its own contract (Out of scope / later).
- **Each core's heap stays its own.** Nothing on one core's GC heap or arena
  is named by the other. A message is copied into the slot by `put` and out
  of it by `get`.

### Cache policy

Two options, per region:

1. **Non-cacheable by the MPU.** The ring and its header are in OCRAM2, which
   Zephyr's tables already make non-cacheable on both cores. No cache
   maintenance; each access goes to OCRAM. This is what the ring does today.
2. **Cacheable, with maintenance.** The producer cleans the slot's lines
   before it publishes the head; the consumer invalidates them after reading
   the head and before reading the slot. Slots and the header must be
   32-byte aligned and padded (they already are: `ring_abi.h:24-25`,
   `spc_ring_geometry_ok`'s 32-byte stride). It is faster for large
   messages and has more ways to go wrong: a missed invalidate reads stale
   data without any error.

**The plan: option 1 for every stage-2 channel.** Its region must be one the
board table names as non-cacheable on both cores, and each image checks its
MPU at start, as the ring test does. Option 2 waits for a measured need,
such as frame-sized messages in HyperRAM.

### The ring, polled

- **The ring is ABI version 2's** (`ring_abi.h`), generalised: the header
  names each channel's geometry, and a channel has one producer core and one
  consumer core. The publication rules stay as they are: release by a
  barrier before the head store, acquire by a barrier after the head load,
  and a slot released only after it is copied.
- **The region holds every channel of the pair.** The build lays the channels
  out and refuses a set that does not fit, as `channels.rb` refuses one that
  exceeds 128 KB today. Adding channels changes the header, so the ABI
  version moves to 3; both images come from one build, so no compatibility
  with version 2 is kept (decision 0025's precedent).
- **The consumer polls** (owner, 2026-10-26). A consumer on the M33 polls
  from its thread, as the forwarder does today (`forward.c:281-349`); a
  consumer on the M7 calls `get` from its periodic work. Stage 2 uses no MU.
  - The wait this costs is measured in stage 2: the time from a `put` to its
    `get`, from the system counter both cores read, or else from the two
    cores' aligned clocks (Stage 2's choices), reported
    beside the lane's figures. The figure is kept as the baseline that the
    doorbell's run is compared with.
  - A doorbell over the MU follows stage 2 as its second part (owner,
    2026-10-26; Out of scope / later). Stage 2 itself polls only.

### Failures

- **The ring is full.** `put` returns 0, writes nothing and counts the
  refusal (0014 §5: capacity is a contract). The producer decides whether to
  drop or retry at its next period; the channel never waits.
- **The other core has not started.**
  - The M33 initialises the region before it releases the M7 (PRE_KERNEL_1
    before PRE_KERNEL_2, `ring_abi.h:59-64`), so the M7 never sees an
    uninitialised header on a whole-chip start.
  - A consumer that has not started taking leaves the ring to fill, and
    `put` then refuses, counted. Each consumer's state word (`STOPPED`,
    `TAKING`, `ring_abi.h:115-116`) tells the producer and the lane which it
    is.
  - The M7 reads magic, a barrier, then the geometry and the pair id. If any
    is off, every channel answers 0 and the console names the reason
    (`SPC_RING_REFUSED`, as `channel_xcore_in.c.erb` does now).
- **A fault.** `head - tail` above depth, or a length of 0 or above the
  slot, is the producer's fault. The consumer stops taking, sets its state to
  fault, and the lane reports it by name.
- **A reset of one core alone** is outside the contract, as it is today
  (`ring_abi.h:66-71`).

### The declaration: one shared contract file (owner, 2026-10-26)

```text
core-channel 1
channel console
from cm7
to cm33
depth 16
field tic u32
field len u8
field text u8 count 119
```

```ruby
# in each application
channel :console, contract: "channels/console.channel"
```

- The message is written once. Each application's build reads the same file
  and knows its direction from the core it is built for; an application
  built for a core that is neither `from` nor `to` is refused.
- The generated API is typed: `Console.put(tic, len, text)` takes each scalar
  field as an argument and each array field as a buffer of its count,
  bounds-checked, and returns 1 when queued and 0 when full. `get` copies a
  message into the caller's buffers and returns 1, or 0 when empty.
- It follows the entries' `.contract` files
  (`examples/doom/core/entries/doom_core_input.contract`), and the eBPF
  port's single record schema that both its producer and consumer read
  (`tools/ebpf/src/spinel_ebpf/capabilities.rb:772-860`).
- The file's digest is part of the pair id, so two images built from
  different versions of the contract are refused at boot.

The two cores are two programs: the one fact they must share is kept in one
place, and a mismatch is then impossible by construction rather than
detected.

#### Not taken

Two other spellings were weighed, with the same semantics.

**A. 0014's `channel`, with the other core as its transport.**

```ruby
# M7 application
channel :console, :out, size: 124, depth: 16, core: :cm33
# M33 application
channel :console, :in, size: 124, depth: 16, core: :cm7
```

- Closest to today: one new transport keyword, like `udp: true`.
- Messages stay bytes, so nothing types them. The checker can only compare
  `size` and `depth` between the two applications.

**B. A typed message in each application.**

```ruby
message :ConsoleLine, tic: :u32, len: :u8, text: [:u8, 119]
channel :console, :out, message: :ConsoleLine, depth: 16, core: :cm33
```

- Typed `put` and `get` (`Console.put(tic, len, text)`).
- Written twice, once in each application, and the checker requires the two
  to be identical, field by field.

## The first user: the console through the M33

Decision 0023 item 6 kept a fallback: "If the M7 cannot reach it, the M33
launcher relays the console over a mailbox. The relay is the fallback and
needs its own review." The M7 reached LPUART1 directly
(`frdm_imxrt1186_cm7.overlay:10-29`), so the relay was never built.

With stage 1 there are two Spinel applications and one VCOM. The relay is
the first user:

- the M33 application owns LPUART1;
- the M7 puts each console line into the `console` channel above: `tic`
  (u32), `len` (u8) and `text` (u8 × 119), depth 16 (owner, 2026-10-26),
  and the M33 writes it to the UART, then its own lines;
- every `put` call is counted, a retried line on each try; after the run has
  drained, the lane reads the channel's producer, consumer and measurement
  lines with the debugger and reports the counts (owner, 2026-10-26). No new
  console line carries them, and `pair.rb` has no `N` line;
- the M7's tic no longer spends time on the UART.

It is small, it exercises both directions of ownership (the M7 produces, the
M33 consumes and owns a device) and the lane can judge it without a network.

### Stage 2's choices (2026-10-26)

The owner's, on the implementer's implementation design:

- **The M7's console lines go through the M33.** The M7 writes its ids, its
  refusals and a fatal error into its own header lines (14 and 15), and the
  M33 prints them, with three new lines: `SPC_M33_SESSION_ID`,
  `SPC_CHANNEL_REFUSED` and `SPC_M7_FATAL`. The lane takes the M33's banner as
  the run's start. The M7's `k_sys_fatal_error_handler` is generated; any
  other M7 `printk` is lost.
- **The counts** are read as above, and close by four equations: on the M7,
  attempted = accepted + refused; across the cores, accepted = taken; on the
  M33, taken = written + malformed + held; and the relayed lines the lane
  decodes = written.
- **`i8`, `u16` and `i16`.** Their arrays are refused by name for now. Their
  scalars pass through the wider parameter (`i32` or `u32`) with a domain
  guard. The application tool's element set does not grow.
- **The wait's stamp.** If the system counter (SYS_CTR at `0x442B_0000`,
  CNTCV0/1, 24 MHz) runs and both cores can read it, the stamp reads it. Only
  reading it is approved, not writing CNTCR to start it. If it is stopped,
  the two cores' SysTick clocks are aligned instead. At start the M33
  exchanges its time with the M7 16 times, and the round with the shortest
  round trip gives the offset and its error, `sync_err`. The two clocks'
  rates are converted by each build's `CYCLES_PER_SECOND`. A second exchange
  at the end measures the drift, and a drift above `sync_err` voids the
  figures, by name. An exchange that does not finish within 100 ms is
  reported as "not measured". Whether the counter runs is read on the board.
- **The counter read (owner, 2026-10-26).** The system counter is stopped:
  read on the board on 2026-10-26 (the implementer), its CNTCR is 0 and CNTCV0 read
  0 twice, a second apart; its 24 MHz source is the RC oscillator, RC24M
  (`OSC_RC24M_CTRL` bit 25 is 0). So the alignment above is made, with each
  core's DWT cycle counter, CYCCNT (`0xE000_1004`), as the clock.
  - The reason: a channel's put and get call nothing outside their unit,
    which is what makes their stack evidence the unit's own frame. A clock
    behind a call (`k_cycle_get_32`) would break that, and CYCCNT is a single
    load.
  - The glue turns the counter on at start by setting DEMCR.TRCENA and
    DWT_CTRL.CYCCNTENA, each by an OR, so a debugger that already set them
    is not disturbed. It never writes the counter, and touches nothing else
    of the DWT.
  - Both counters run at the core clock, each build's `CYCLES_PER_SECOND`
    (792 MHz on the M7, 240 MHz on the M33, 33/10). Both come from RC24M, so
    the ratio is fixed while the absolute rate carries the RC oscillator's
    error. Every figure in time is reported with that caveat.

The implementation's, within those (the coordinator):

- `put` counts every call, retries included.
- The build knows each table's core from a board fact, `core` (`cm7`,
  `cm33`).
- ABI version 3 keeps version 2's lines 0 to 11 and appends the channel
  table. `tools/doom/ocram-ring` moves to version 3.
- Every `offset` field is refused in stage 2.
- The wait's figures are kept in a results record beside this decision.
- The UART belongs to the core whose application declares a `uart:` channel,
  and both applications declaring one is refused.

## Acceptance

On the board, through the existing lane `tests/doom-core/rt1186.sh`, during
the work at `DEMOS=DEMO1 TICS=500`, and DEMO1 to DEMO3 once at the end
(decision 0023's practice).

The DOOM application judged is `examples/doom/core/board/pair.rb`, with
`companion.rb` on the M33, chosen by `RT1186_PAIR=1` (owner, 2026-10-26).
`app.rb` streams its frames over a `udp:` channel and prints the `B` and `N`
lines of that stream, and a `udp:` channel is refused beside an M33 Spinel
application; `pair.rb` has neither. Both run the same tic, which they share
through `demo_tic.rb` (`require_relative`, a helper file of definitions only;
`docs/building.md`). The `Frame` declaration stays in each application,
since a helper file holds no modules. The `app.rb` lane is unchanged.

- **Stage 1.** Both images come from one build. The M7 prints its own id, the
  pair id and the M33's id, and the lane checks all three against
  `build.json` before the first frame. `pair.rb`'s frames are the recorded
  ones.
- **Stage 2.** `pair.rb`'s console lines arrive through the M33. The lane's
  existing checks of the `F` and `D` lines pass on the relayed console, and
  the relay's counts close: lines put = lines written + refused, by the four
  equations of Stage 2's choices, read after the run has drained.
- **Negative controls**, each planted by the build and each refused by name:
  - an application that names a contract for a core it is not built for;
  - a pointer, an `i64` or an `f32` field in a contract;
  - a set of channels that does not fit the region;
  - two images with different pair ids together: the build plants a
    companion that publishes another pair id than the M7 checks
    (`--mutate-pair-id`, a test option; the coordinator, 2026-10-26), which is what
    the M7 sees of two builds written together, and the M7 refuses the
    channels at boot, which the M33 prints;
  - the consumer stopped: the ring fills, `put` refuses, and the count is
    reported;
  - a channel region mapped cacheable on one core: the start-up MPU check
    refuses it.
- **Stack guards.** A planted overflow on each core is caught at run time:
  PSPLIM on the M33, the MPU guard on the M7.

No oracle is involved: every check compares the board run with its own
build's records or with the recorded frames the lane already uses.

### What the board runs so far show (2026-10-26)

The final runs and their figures are recorded in [0027-results.md](0027-results.md).

- **Stage 1 passed on the board** at `67a13a7` (`RT1186_PAIR=1 DEMOS=DEMO1
  TICS=500`, 54 of 54). The M7 printed the three ids `build.json` records,
  before its first frame, and its first 500 frames were the recorded ones.
- **That image's companion was broken, and the pass does not show
  otherwise.** Its scheduler stack was linked at address `0x0000_0000`,
  which is not RAM on the M33. The cause: the companion's table rebuilt the
  data TCM as plain SRAM and still chose it as `zephyr,dtcm`, by which the
  glue places that stack.
  - The M7 reads only the pair words, which the M33 writes at `PRE_KERNEL_1`,
    before its scheduler starts. So the pass shows those words, not that the
    M33 kept running once its scheduler started.
  - That run's M33 had no console, so a fault there would not have shown.
  - The first stage 2 run, at `8e95d93`, had the same placement. There the
    M33 owns the console, and it faulted as its scheduler thread started
    (`HARD FAULT`, a bus fault on the vector table read), after printing the
    M7's ids and before relaying any line. Both cores' start-up checks had
    passed.
- **The fix and the guard.** The companion's table drops `zephyr,dtcm`. Step
  10 of the build now refuses a thread stack linked outside the image's RAM
  and its data TCM. A kept overlay that links the M7's stack at 0 is the
  check's failing input.
- **Still to show.** That the fixed companion runs is shown by the stage 2
  lane, when the relay prints the frames, and by the final DEMO1 to DEMO3
  runs.
- **A note for whoever moves the ring ABI's version next.** A board lane's
  suite, `tests/app/play.sh`, held version 2's hand-derived figures, and the
  move to version 3 missed it: the affected-test selection does not run
  board suites. A search of the tests found no other version 2 ring figure.

## Out of scope / later

Stage 3, one Ruby source split into the two cores' programs, and stage 4, a
Ractor-like surface over the channels, are later work. Stage 3 has a
precedent in the eBPF port: `tools/ebpf/src/spinel_ebpf/partition.rb` walks
each method, fixes a call graph and tags each method for the kernel or the
host (`decide_tag!`, `partition.rb:1364-1379`), and
`tools/ebpf/src/spinel_ebpf/capabilities.rb` holds which builtins each side
may use. A two-core split would need the same two things: a per-core
capability set (the M33 owns the network, the M7 the HyperRAM) and a
partition that refuses a method both sides reach unless a channel separates
them. Neither is designed here.

Also later, each its own decision:

- **The network firmware beside an M33 Spinel application:** as the M33
  application's transport thread, or as a separate C image. Until then the
  two are refused together.
- **A doorbell over the MU**, the second part after stage 2 (owner,
  2026-10-26: it is added, not decided on after the measurement), under its
  own decision. Its starting point: signalling mode (`mbox_send` with no
  message), a register write that neither allocates nor blocks and ignores
  an interrupt already pending (`mbox_nxp_imx_mu.c:62-77`); the consumer
  waits on it under a time-out and falls back to polling when the time-out
  expires; one MU1 channel per direction, as Zephyr's `samples/drivers/mbox`
  uses `mbox1_a` and `mbox1_b`. Stage 2's polled `put`-to-`get` wait is the
  baseline its run is compared with.
  - Also for that decision: the drift is now only a lower bound, since a
    round's trip can be long. Keeping each drift round's trip in the header,
    so that it becomes an estimate, adds ABI words, and is that decision's
    to take.
- **Shared bulk regions** addressed by `offset`, for example a frame buffer in
  OCRAM1. They need an ownership contract of their own.

## Preconditions of implementation

Three RM facts were to be confirmed before implementation. They were, on
2026-10-26, from IMXRT1180RM Rev. 9, and none changes this record's contract:

- **The MU** is §37. MU1 and MU2 each pair an A side, the M33's, with a B
  side, the M7's (§4.2 Table 11, §3.4, §3.5), as the devicetree labels say
  (The Messaging Unit and Zephyr's drivers).
- **The M33's aliases** of OCRAM and HyperRAM are secure at `0x3…` and
  non-secure at `0x2…` (§3.3 Table 5; The same memory at different
  addresses).
- **The M7's DTCM** is reachable from the M33 through its alias at
  `0x3040_0000` (S) / `0x2040_0000` (NS) (§3.3 Table 5). Stages 1 and 2 do not
  use it.

## Consequences

- The M33 image becomes a Spinel application for applications that ask for
  one. The plain launcher and the network firmware stay as they are for the
  others.
- The ring ABI moves to version 3, and decision 0024's `udp_consumer
  ocram-ring-v1` becomes one use of the general channel region.
- The M7 lane's tools and tables stay; the M33 gains a second table.
- Decision 0023 item 6's relay becomes stage 2's first user.
