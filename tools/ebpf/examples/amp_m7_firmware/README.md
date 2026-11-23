# amp_m7_firmware — amp-m7 firmware (Zephyr, FRDM-IMX95)

**P008 S2 (current)**: a minimal Zephyr M7 firmware that links the **fixed-ABI reusable runtime** (`src/runtime/amp/amp_m7_runtime.{c,h}` = libamp_m7)
and **receives probes through staging**. The firmware is **built only once, independent of the probe**,
and the A55 places a single-pass blob in the shared-memory staging area (`AMP_STAGING_BASE`) → on remoteproc restart the
M7 loader reads it (**fixed firmware, swapped blob**). `src/amp_firmware.c` starts the runtime with SYS_INIT and
runs the installed blob on a 1 Hz timer. The runtime owns the helper table (literal-jump, E361) / ring producer
(`amp_ring.h` + cache flush) / blob loader (abi_version gate + zeroing IVARS). It is built on openamp's
`samples/subsys/ipc/openamp_rsc_table` (known-good boot + resource_table = avoids the FCCU loop)
(`main_remote.c` verbatim). The A55 places the blob with `a55_stage.c` and reads the ring with `a55_drain.c`.

- **Fixed ABI** (`include/spnl/amp_abi_imx95m7.h`): helper table = ITCM top `0x0003FF00`, IVARS = DTCM top
  `0x2003FF00`, ring = `0x88400000`, staging = `0x88420000`. The ITCM/DTCM tops are reserved by the board overlay
  (shrinking `&itcm`/`&dtcm` + memory-region).
- **MPU/XN**: the imx95 M7 has ITCM=RX/DTCM=RW+XN with `CONFIG_ARM_MPU=y`/`CONFIG_XIP=y`. At boot the runtime
  writes the helper table + copies the blob in a **window where the MPU is temporarily disabled**, and from then on runs with ITCM=RX (the method is in
  the opening comment of `amp_m7_runtime.c`). **Confirming MPU/XN on the real machine is a remaining item of P008 S0** (see the RUNBOOK).
- **The procedure on the real machine is `docs/experiments/results/E363/RUNBOOK.md`**.
- **The 2-pass reference of E360** (`src/amp_producer.c` + `build-amp-blob.sh` = embedded in the firmware) is kept on disk
  (not linked by CMakeLists). The current method is staging.

## Build (Mac / Zephyr workspace)

```bash
cd ~/sdk/zephyrproject && source .venv/bin/activate
export ZEPHYR_BASE=$PWD/zephyr ZEPHYR_TOOLCHAIN_VARIANT=zephyr \
       ZEPHYR_SDK_INSTALL_DIR=$HOME/sdk/zephyr-sdk-1.0.1
west build -p always -b imx95_evk/mimx9596/m7 \
    /path/to/checkout/tools/ebpf/examples/amp_m7_firmware -d /tmp/amp-m7
# output: /tmp/amp-m7/zephyr/zephyr.elf (.resource_table built in)
```

## Load (A55 remoteproc, assuming M7=off)

```bash
scp /tmp/amp-m7/zephyr/zephyr.elf root@192.0.2.24:/lib/firmware/amp-m7.elf
ssh root@192.0.2.24 '
  RP=/sys/class/remoteproc/remoteproc1
  echo stop > $RP/state 2>/dev/null; sleep 1
  echo amp-m7.elf > $RP/firmware
  echo start > $RP/state; sleep 4
  cat $RP/state'                       # => running
# SM-side liveness: scripts/board/sm-cmd.sh "lm info"  => 001: M7 = on
```

## Check (read the shared ring from the A55)

```bash
# quick: watch the prod index (0x88400010) grow with devmem2
ssh root@192.0.2.24 'for i in 1 2 3; do devmem2 0x88400010 w; sleep 1; done'

# properly: build + run the drain tool on the board
scp a55_drain.c root@192.0.2.24:/tmp/; scp -r ../../include root@192.0.2.24:/tmp/
ssh root@192.0.2.24 'gcc -O2 -I/tmp/include /tmp/a55_drain.c -o /tmp/a55_drain && /tmp/a55_drain'
# => [a55_drain] rec #0: value=1 ... / #1: value=2 ... flow at 1 Hz
```

## Teardown

```bash
ssh root@192.0.2.24 'echo stop > /sys/class/remoteproc/remoteproc1/state'
```

## Pitfalls (from the working record of the reference m7avb)

- **resource_table is required**: without it, an FCCU fault right after start → SM resets LM1 → loop. This firmware is
  based on openamp, so it is built in.
- **The firmware name must be given explicitly** (`echo amp-m7.elf > .../firmware`). The default name lookup fails.
- **The M7 console (LPUART3, ser2net port 7895)** can be silent depending on clock state. Check liveness with
  `lm info` / remoteproc `state` / the shared ring's prod index (it does not depend on RPMsg connectivity).
- If after a cold boot the SM auto-boots the flash demo and remoteproc is `attached`, do
  `sm-cmd "lm 1 shutdown"` → unbind/bind → firmware/start.
