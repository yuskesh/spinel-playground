# edge-twin — one kernel on a device and at the edge

`kern.rb` is compiled through the freestanding profiles twice, with command
lines that differ only in `--profile`. One build runs on a Cortex-M33 under
Zephyr (QEMU), and the other in an edge Worker (workerd). The device writes an
audit log; the edge replays the same kernel over it and reports the first row
where the two disagree.

```sh
./build.sh              # kern.wasm, plus the Zephyr images (needs ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR)
./build.sh --no-device  # the worker half only
./run_demo.sh           # the narrated demo: device, replay, forgeries, trap
```

The Zephyr builds live outside the repository, in `$EDGE_TWIN_BUILD` (default
`$TMPDIR/spinel-edge-twin`). Without Zephyr, `build.sh` now fails unless given
`--no-device`; it used to skip the device half and still exit 0.

## The worker's answers (`POST /audit`)

| Status | Meaning |
|---|---|
| 200 | the log replays exactly: ACCEPT |
| 409 | the log and the replay disagree: REJECT, naming the first disagreeing row |
| 422 | the kernel trapped on a reading outside its declared domain (`abs(x) <= 100000`). The worker answers and stays up |

The same trap on the device is a fatal Zephyr panic. The contract is the same;
the platforms differ in what a trap does.

## Checked

`tests/edge/run.sh` runs the whole story:

- the device writes its 1048 data rows under QEMU;
- the edge accepts them (200);
- three forgeries are caught (409 each): a raised reading, an alarm relabelled
  as normal, and a deleted row with the indices renumbered;
- an out-of-domain reading is 422 at the edge, and the worker still serves
  afterwards;
- the device panics on the same reading and runs nothing after the trap.
