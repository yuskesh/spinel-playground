# Devicetree fixtures for `tests/app/board.sh`

`mps2_an521/`, `frdm_mcxn947/`, `frdm_imxrt1186/` and `frdm_imxrt1186_cm7/` hold the final `zephyr.dts` and `.config`
(as `config`, with its comment lines removed: they name the workspace's
absolute path, and only the `CONFIG_` lines carry a value) that Zephyr
v4.4.2 (commit `dccb0959`) wrote for
`samples/hello_world` on `mps2/an521/cpu0` (built and run under QEMU) and on
`frdm_mcxn947/mcxn947/cpu0`, `frdm_imxrt1186/mimxrt1186/cm33` and `frdm_imxrt1186/mimxrt1186/cm7` (configured only; the last two for decisions 0021 and 0023), as `tests/app/platform-facts.sh`
produces them (Task 1 of decision 0014). `digests.txt` records their sha256;
`board.sh` refuses a fixture whose digest moved, so a regenerated file is a
deliberate change with a new digest, never a silent one.

`synthetic/` holds hand-written devicetrees in the same flattened form, each
for one generator rule that the two real boards do not exercise:

- `expander.dts`: one LED on an I2C GPIO expander (`nxp,pcal6416a` under an
  I2C controller) beside two on a memory-mapped controller -- the expander
  instance is not `isr_ok`, is blocking, and is split into `LedI2c`;
- `unknown.dts`: a LED on a controller whose compatible has no effect-table
  row -- not `isr_ok`, blocking unknown, split into `LedUnattested`;
- `mixed.dts`: `gpio-leds`, `gpio-keys`, `pwm-leds` and `zephyr,user`
  `io-channels` together, with an alias and a disabled instance, so every
  class and the count, name, alias, label and status rules are covered in
  one file.

## Notice

The four real devicetrees are derived from the Zephyr Project's devicetree
sources (`zephyr/dts/...`, `zephyr/boards/...`), Copyright (c) the Zephyr
Project contributors, licensed under the Apache License, Version 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>). They are Zephyr's build
output for the boards named above at commit `dccb0959`, unmodified apart from
the `.config` comment lines noted, and are tracked here only as test inputs.
The synthetic devicetrees are original.
