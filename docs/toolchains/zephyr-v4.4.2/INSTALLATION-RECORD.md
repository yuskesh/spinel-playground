# Zephyr v4.4.2 installation record

Pinned on 2026-09-22 for decision [0014](../../decisions/0014-core-applications-on-zephyr.md),
Task 1 of [its plan](../../decisions/0014-core-applications-on-zephyr-plan.md).
The installation lives outside the repository. Nothing in the repository
depends on its path: the tool and `tests/app/platform-facts.sh` read
`ZEPHYR_BASE` and `ZEPHYR_SDK_INSTALL_DIR` and refuse to run without them.

## The release

- Release: **Zephyr v4.4.2**, tag object `671f64aa79924606253238f801c494c84b02c2a0`,
  commit `dccb09599635bdff17633fa7e9dab014b91dce90` ("release: Zephyr 4.4.2",
  2026-08-06). Both from `git ls-remote --tags https://github.com/zephyrproject-rtos/zephyr 'v4.4.2*'`
  (the `^{}` row is the commit).
- Why this one: the newest tagged 4.4.x on 2026-09-22 (v4.4.0, v4.4.1,
  v4.4.2). Its `SDK_VERSION` file says `1.0.1`, the SDK both hosts already
  have; so do v4.4.0's and v4.4.1's. It has `mps2/an521/cpu0` under QEMU and
  `frdm_mcxn947/mcxn947/cpu0`, and the SDK has Debian x86_64 and macOS arm64
  builds. The existing `~/sdk/zephyrproject` workspace on both hosts is a
  development snapshot (`v4.4.0-3236-g7fd932b9357`) and is not reused.
- SDK: **Zephyr SDK 1.0.1** (`sdk_version` file), `arm-zephyr-eabi-gcc (Zephyr SDK 1.0.1) 14.3.0`,
  GNU ld 2.43.1. Its host tools supply the `dtc` (1.7.0) and the
  `qemu-system-arm` the build uses (below).
- west manifest: `zephyr/west.yml` at that commit, with the project filter
  `-.*,+cmsis,+cmsis_6,+hal_nxp,+picolibc`. `west list` after `west update`:

  | project | path | revision |
  |---|---|---|
  | zephyr (manifest) | `zephyr` | `dccb09599635bdff17633fa7e9dab014b91dce90` |
  | cmsis | `modules/hal/cmsis` | `512cc7e895e8491696b61f7ba8066b4a182569b8` |
  | cmsis_6 | `modules/hal/cmsis_6` | `30a859f44ef8ab4dc8f84b03ed586fd16ccf9d74` |
  | hal_nxp | `modules/hal/nxp` | `7554bc0f6f6c284972eba7b2c17b16fbb9cc0ad0` |
  | picolibc | `modules/lib/picolibc` | `01254932e8e81085817ed61fd858648584ffe37c` |

  The filter keeps the workspace at 2.6 GB with shallow clones. If a later
  task needs another module, the filter is widened and this table updated.

## Python, inside the installation only

- `python3 -m venv "$ROOT/.venv"`, Python **3.13.5** on Debian.
- `west==1.5.0` pinned by pip.
- `zephyr/scripts/requirements-base.txt` at the pinned commit, sha256
  `ceff4012613375d167ccd085ef19875c79045359f006f678ff9f4df3c4aa7206`.
- `pip freeze` after installation: 41 lines, sha256
  `952c32b3b33b6411ca89ce8d0abda40f302e36338407e67f436c73bf57173fc0` (Debian).
- The venv is put first on `PATH` in the same command that runs `west`. No
  `.py` file enters the repository; Python runs only through `west` and
  Zephyr's CMake, as the plan's global constraint says.

## What is deliberately not done

- **No `west zephyr-export`, and nothing written to `~/.cmake/packages`.** On
  the Mac that registry is shared with other Zephyr projects and lists four
  Zephyr trees and SDK 0.17.0. Debian's pre-existing
  `~/.cmake/packages/Zephyr-sdk` entry (SDK 1.0.1) was left as found, and its
  fingerprint was unchanged after every run below.
- No conda environment, and no `west` from another project.

## `ZEPHYR_SDK_INSTALL_DIR` is not authoritative; the CMake log is

Measured on both hosts on 2026-09-22 (the Mac first). The pinned
`cmake/modules/FindZephyr-sdk.cmake:81-83` passes `ZEPHYR_SDK_INSTALL_DIR`
to `find_package` as `HINTS`, which excludes nothing: when the path names no
SDK, CMake continues with its default search and can find another SDK. The
configure then succeeds and says nothing. Debian, with a
`--cmake-only` configure of `hello_world` for `mps2/an521/cpu0`:

| `ZEPHYR_SDK_INSTALL_DIR` | extra CMake argument | rc | `-- Found toolchain:` line |
|---|---|---|---|
| env `/nonexistent` | none | 0 | `zephyr 1.0.1 ($HOME/zephyr-sdk-1.0.1)`: silently the registered SDK |
| env `/nonexistent` | `-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF` | 1 | none: `Could not find a package configuration file provided by "Zephyr-sdk"` |
| env real SDK | `-DZEPHYR_SDK_INSTALL_DIR=/nonexistent` | 1 | `zephyr 1.0.1 (/nonexistent)`: the version of the SDK it found, the path of the variable; the include of `/nonexistent/cmake/zephyr/host-tools.cmake` then fails |
| env `/nonexistent` | `-DZephyr-sdk_DIR=/nonexistent` | 0 | `zephyr 1.0.1 ($HOME/zephyr-sdk-1.0.1)` |

On Debian the fall-through goes through the package registry (row 2 fails
without it); on the Mac it also succeeded with the registry off, because a
`$HOME` prefix on `PATH` lets CMake match `$HOME/zephyr-sdk*/cmake`
(`--debug-find-pkg`). Turning the registry off is therefore no defence.

**The defence is the log.** `platform-facts.sh`, and the application tool
after it, pass `-DZEPHYR_SDK_INSTALL_DIR` explicitly, then read back
`-- Found toolchain: zephyr <version> (<path>)` and refuse unless `<version>`
equals the `sdk_version` file at the intended path and `<path>` equals the
canonical intended path. Row 3 shows why both halves are compared: the
printed path can be the variable rather than the directory found. The same
line is compared for `ZEPHYR_BASE` (`-- Zephyr version: 4.4.2 (<path>)`).
The script's control configures with `ZEPHYR_SDK_INSTALL_DIR=/nonexistent`
in the environment (row 1, the silent case) and requires the comparison to
refuse; and the whole script run that way fails first with
`cmake_sdk is '1.0.1 /nonexistent', expected 'absent /nonexistent'`.

## Install commands (Debian; the Mac's one difference is in its section below)

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2; TAG=v4.4.2
mkdir -p "$ROOT" && cd "$ROOT"
python3 -m venv "$ROOT/.venv"
export PATH="$ROOT/.venv/bin:$PATH"
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet west==1.5.0
west init -m https://github.com/zephyrproject-rtos/zephyr --mr "$TAG" "$ROOT/workspace"
cd "$ROOT/workspace"
west config manifest.project-filter -- '-.*,+cmsis,+cmsis_6,+hal_nxp,+picolibc'
west update --narrow -o=--depth=1
python3 -m pip install --quiet -r "$ROOT/workspace/zephyr/scripts/requirements-base.txt"
git -C zephyr rev-parse HEAD                 # dccb09599635bdff17633fa7e9dab014b91dce90
git -C zephyr describe --tags --exact-match  # v4.4.2
cat zephyr/SDK_VERSION                       # 1.0.1
```

Debian wall clock: 96 s (venv and west 3 s, `west init` and `west update`
90 s, requirements 3 s).

## Install paths

| host | `ZEPHYR_BASE` | `ZEPHYR_SDK_INSTALL_DIR` | venv |
|---|---|---|---|
| Debian x86_64 | `$HOME/toolchains/zephyr-v4.4.2/workspace/zephyr` | `$HOME/zephyr-sdk-1.0.1` | `$HOME/toolchains/zephyr-v4.4.2/.venv` |
| macOS arm64 | `$HOME/toolchains/zephyr-v4.4.2/workspace/zephyr` | `$HOME/zephyr-sdk-1.0.1` | `$HOME/toolchains/zephyr-v4.4.2/.venv` |

## `qemu-system-arm`

The build's `run` target uses the SDK's QEMU, not the distribution's:
`$ZEPHYR_SDK_INSTALL_DIR/hosttools/sysroots/x86_64-pokysdk-linux/usr/bin/qemu-system-arm`,
`QEMU emulator version 10.0.2 (v10.0.2-20-g5828172dcf-dirty)` on Debian
(`QEMU:FILEPATH` in the build directory's `CMakeCache.txt` names it; the Mac's is `hosttools/usr/bin/qemu-system-arm`, also 10.0.2). Debian's `/usr/bin/qemu-system-arm`
is 10.0.11 and is not used. The board runs with
`-cpu cortex-m33 -machine mps2-an521 -icount shift=7,align=off,sleep=off -rtc clock=vm`,
and QEMU never exits by itself because Zephyr idles; `platform-facts.sh`
stops it through the `qemu.pid` file the run target writes.

## Use

```sh
ROOT=$HOME/toolchains/zephyr-v4.4.2
env PATH="$ROOT/.venv/bin:$PATH" \
    ZEPHYR_BASE="$ROOT/workspace/zephyr" \
    ZEPHYR_SDK_INSTALL_DIR="$HOME/zephyr-sdk-1.0.1" \
    sh tests/app/platform-facts.sh
```

The first Zephyr build after installation (`hello_world` for
`mps2/an521/cpu0`, 142 build steps) took 5 s on Debian; it is installation,
timed separately from `platform-facts.sh`.

## The official LLVM's `ld.lld` does not run on this Debian host (2026-09-23)

Found in Task 8 of decision 0014, when the two-channel fixture was first
linked for `thumbv8m`:

```
$ /opt/llvm-23.1.1/bin/clang --target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp \
    -mfloat-abi=soft -mthumb -Os -ffreestanding -nostdlib -fuse-ld=lld \
    -Wl,-e,spc_main -o two.arm.elf arm_main.arm.o
/opt/llvm-23.1.1/bin/ld.lld: error while loading shared libraries: libicui18n.so.70: cannot open shared object file: No such file or directory
$ ldd /opt/llvm-23.1.1/bin/ld.lld | grep 'not found'
	libicui18n.so.70 => not found
	libicuuc.so.70 => not found
	libicudata.so.70 => not found
```

(Debian 13.6, `cat /etc/debian_version`.) The compiler is unaffected: every
`-c` build on this branch is the official clang's. Links for the target use
the SDK's GNU linker, `$ZEPHYR_SDK_INSTALL_DIR/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-ld`
(`GNU ld (Zephyr SDK 1.0.1) 2.43.1`), which is what `west build` links with;
`tests/app/channel.sh` finds it with `find "$ZEPHYR_SDK_INSTALL_DIR" -name
arm-zephyr-eabi-ld`. Tasks 10 and 11 of the plan link through `west build`,
so no later task expects `ld.lld` on Debian. Not fixed here: installing ICU
70 or another LLVM package is a host change outside this record.

## Platform facts established on Debian (2026-09-22)

`tests/app/platform-facts.sh` printed 35 facts with the command behind each;
0 required facts failed; 23 s wall clock including its three controls. The
answers that the 0014 plan asked for:

| fact | answer |
|---|---|
| CMake used `ZEPHYR_BASE` | yes: `-- Zephyr version: 4.4.2 (…/workspace/zephyr)` equals the canonical `ZEPHYR_BASE` |
| CMake used SDK 1.0.1 at `ZEPHYR_SDK_INSTALL_DIR` | yes: `-- Found toolchain: zephyr 1.0.1 (…/zephyr-sdk-1.0.1)` |
| `zephyr.dts` after configure | present |
| `compile_commands.json` | present (Zephyr exports it by default) |
| QEMU banner | `Hello World! mps2/an521/cpu0` within 1 s |
| `k_cycle_get_64()` inside a `k_timer` expiry that busy-waits 2000 µs | advances: before 250471, after 300688, delta 50217 cycles at 25 MHz (`CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=25000000`); `k_is_in_isr()` = 1 |
| condition for that | `CONFIG_CORTEX_M_SYSTICK_64BIT_CYCLE_COUNTER=y` in the probe's `prj.conf`; SysTick at 25 MHz is below the 60 MHz at which Zephyr enables it by default. The control build with it off reads 0 twice, so the count is required, and the dedicated hardware timer of 0014 §4 is not needed |
| ADC and GPIO emulators with an overlay | build; `device_is_ready` = 1 for both |
| `mps2/an521` ADC or PWM nodes | 0 |
| lower-priority hardware timer for nesting | `timer0`, `timer1` (`arm,cmsdk-timer`) and `dtimer0` (`arm,cmsdk-dtimer`), devicetree priority `0x3` |
| `mps2/an521/cpu0` security | `CONFIG_TRUSTED_EXECUTION_SECURE=y`, `CONFIG_ARM_TRUSTZONE_M=y`, `CONFIG_ARM_MPU=y`, `CONFIG_BUILD_WITH_TFM` unset, `CONFIG_FPU` unset |
| `mps2/an521/cpu0` SRAM | `ssram2_3`, 4194304 bytes |
| `frdm_mcxn947/mcxn947/cpu0` configures | yes (`--cmake-only`) |
| its `gpio-leds` / `pwm-leds` | 1 / 0: no `pwm-leds`, so the `Pwm` sample's condition does not hold on this release |
| its configuration | `CONFIG_TRUSTED_EXECUTION_SECURE=y`, `CONFIG_ARM_MPU=y`, `CONFIG_SECOND_CORE_MCUX` unset, `CONFIG_FPU` unset; `sram0` 327680 bytes of the 512 KB |
| control: the probe without the 64-bit count | `k_cycle_get_64()` reads 0 before and after, so `probe_cycles_advance` would fail |
| control: `ZEPHYR_SDK_INSTALL_DIR=/nonexistent` in the environment | configure rc 0, log names `1.0.1 $HOME/zephyr-sdk-1.0.1`; the comparison refuses |
| control: empty `ZEPHYR_BASE` | exit 2, `ZEPHYR_BASE is empty` |

The board tables are `tools/app/zephyr/v4.4.2/boards/mps2_an521.tsv` and
`frdm_mcxn947.tsv`. These are Debian results; the Mac's run is recorded by the
Mac host.

## macOS arm64 installation (2026-09-22)

The same release, SDK, manifest, filter and commands as Debian, into the same
`ROOT` (`$HOME/toolchains/zephyr-v4.4.2`), with **one difference**: the venv is
created by absolute path,

```sh
/opt/homebrew/bin/python3.13 -m venv "$ROOT/.venv"
```

because `python3` on this Mac's `PATH` is another project's conda environment,
which the installation must not use or modify. From the next line on, the venv
is first on `PATH` and every command is Debian's.

- Python **3.13.3** (Homebrew), the minor version Debian uses.
- `west` 1.5.0.
- `requirements-base.txt` sha256 `ceff4012…c4aa7206`, as on Debian.
- `pip freeze`: 41 lines, sha256
  `952c32b3b33b6411ca89ce8d0abda40f302e36338407e67f436c73bf57173fc0`,
  **byte-identical to Debian's** despite the patch-level difference.
- `west list`: the five revisions of the table above, identical.
- `git -C zephyr rev-parse HEAD` is `dccb0959…`, and
  `git describe --tags --exact-match` is `v4.4.2`.
- Wall clock 169 s: venv and `west` 7 s, `west init` 129 s, `west update` 25 s,
  requirements 8 s. The difference from Debian's 96 s is the clone, which is
  network time, not host time.
- 2.5 GB: workspace 2.4 GB, venv 42 MB.

**The SDK.** The Mac has exactly one complete SDK 1.0.1, at
`$HOME/zephyr-sdk-1.0.1` (`cmake/`, `gnu/`, `hosttools/`, `sdk_version`). A
second directory, `$HOME/sdk/zephyr-sdk-1.0.1`, is a hand-extracted
`arm-zephyr-eabi/` toolchain with no `cmake/` and no `sdk_version`: its gcc is
the same build, but `find_package(Zephyr-sdk)` cannot select it, and nothing
here uses it.

**The shared registry.** `~/.cmake/packages` was fingerprinted before the
installation (16 files, the path and content of each). The fingerprint was
unchanged after the installation, after every build and every control below,
and after `platform-facts.sh`.

**`ZEPHYR_SDK_INSTALL_DIR` on the Mac.** The measurements behind the Mac
sentence in the section on the SDK variable: a `--cmake-only` configure of
`hello_world` for `mps2/an521/cpu0`, with `ZEPHYR_SDK_INSTALL_DIR=/nonexistent`
in the environment.

| extra CMake argument | rc | `-- Found toolchain:` line |
|---|---|---|
| none | 0 | `zephyr 1.0.1 ($HOME/zephyr-sdk-1.0.1)` |
| `-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF` | 0 | the same: Debian's row 2 fails here |
| `-DZephyr-sdk_DIR=/nonexistent/cmake` | 0 | the same |

With the registry off, `--debug-find-pkg=Zephyr-sdk` names the file found,
`$HOME/zephyr-sdk-1.0.1/cmake/Zephyr-sdkConfig.cmake`, under "Standard system
environment variables": `$HOME/bin` and `$HOME/.local/bin` are on this Mac's
`PATH`, and CMake takes the parent of each as a search prefix.

**QEMU.** `west build -t run` uses the SDK's
`hosttools/usr/bin/qemu-system-arm`, 10.0.2, as the QEMU section says.
Homebrew's `qemu-system-arm` 10.0.0 is not used by the build. Run by hand, with
`-cpu cortex-m33 -machine mps2-an521 -nographic -vga none -net none -kernel zephyr.elf`
and no `-icount`, it boots the same image and prints the same two lines.

The first Zephyr build after installation (`hello_world` for
`mps2/an521/cpu0`) took 11 s.

## Platform facts established on macOS arm64 (2026-09-22)

`tests/app/platform-facts.sh` at `00dace8`, run as in "Use" above: 35 facts
with the command behind each, 0 required facts failed, rc 0, 42 s wall clock
including its three controls.

**Every answer in Debian's table holds on the Mac, value for value.** That
includes the timer probe's cycle counts, which are the same numbers:
`before=250471 after=300688 delta=50217`, `in_isr=1`. This is expected, not a
coincidence. The run target uses `-icount shift=7,align=off,sleep=off`, so
QEMU's virtual time counts instructions and does not depend on the host.

| fact | macOS arm64 |
|---|---|
| CMake used `ZEPHYR_BASE` | `$HOME/toolchains/zephyr-v4.4.2/workspace/zephyr`, equal to the canonical `ZEPHYR_BASE` |
| CMake used SDK 1.0.1 at `ZEPHYR_SDK_INSTALL_DIR` | `1.0.1 $HOME/zephyr-sdk-1.0.1` |
| `zephyr.dts`, `compile_commands.json` | present, present |
| QEMU | `$HOME/zephyr-sdk-1.0.1/hosttools/usr/bin/qemu-system-arm`, 10.0.2; banner printed |
| timer probe | as Debian's, above |
| ADC and GPIO emulators | build; `adc_ready=1 gpio_ready=1` |
| `mps2/an521` | 0 ADC or PWM nodes; `timer0`, `timer1`, `dtimer0` at priority `0x3`; `ssram2_3` 4194304 bytes; 25 MHz |
| `mps2/an521/cpu0` security | `TRUSTED_EXECUTION_SECURE`, `ARM_MPU`, `ARM_TRUSTZONE_M` set; `BUILD_WITH_TFM`, `FPU` unset |
| `frdm_mcxn947/mcxn947/cpu0` | configures; `gpio-leds` 1, `pwm-leds` 0; `sram0` 327680 bytes; `TRUSTED_EXECUTION_SECURE`, `ARM_MPU` set; `SECOND_CORE_MCUX`, `FPU` unset |
| control: probe without the 64-bit count | reads 0 before and after |
| control: `ZEPHYR_SDK_INSTALL_DIR=/nonexistent` | configure rc 0, log names `1.0.1 $HOME/zephyr-sdk-1.0.1`; the comparison refuses |
| control: empty `ZEPHYR_BASE` | exit 2 |

The differences from Debian are the host's own. The QEMU binary sits at
`hosttools/usr/bin/` rather than under a Poky sysroot, and the wall clock is
42 s against 23 s. That wall-clock difference has not been attributed.

One observation for Task 2, from the Mac's `compile_commands.json` for
`kernel/init.c`. The line carries exactly the plan's
`-mcpu=cortex-m33+nodsp -mthumb -mabi=aapcs -mfp16-format=ieee -mtp=soft -mcmse`,
and it has **no `-mfloat-abi=` and no `-mfpu=`**. Soft float comes from GCC's
default for `arm-zephyr-eabi`, not from a flag. Target flags taken from these
compile commands therefore do not give Clang a float ABI, and it has to be
supplied.
