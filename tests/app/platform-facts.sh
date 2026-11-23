#!/bin/sh
#
# tests/app/platform-facts.sh -- decision 0014, Task 1: the platform facts.
#
#   ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... sh tests/app/platform-facts.sh
#
# It builds hello_world and the timer probe of tests/app/fixtures/platform for
# mps2/an521/cpu0, runs both under QEMU, configures the FRDM-MCXN947 target
# and FRDM-IMXRT1186's CM33 core (decision 0021), and prints one line per
# fact:
#
#   fact <name> <value>   # <the command that produced it>
#
# A fact that 0014 requires is checked; a fact that 0014 only asks about
# (does the FRDM board have pwm-leds?) is printed with its answer. The script
# exits 1 if any required fact does not hold, and 2 if it cannot start.
#
# ZEPHYR_BASE and ZEPHYR_SDK_INSTALL_DIR are required and passed explicitly to
# every west line; nothing here registers anything in ~/.cmake/packages. The
# CMake log is read back to confirm which Zephyr tree and which SDK the build
# actually used, because the package registry can override both.
#
# The venv of the pinned installation must be first on PATH in the command
# that runs this script (docs/toolchains/zephyr-<release>/INSTALLATION-RECORD.md).
# OUT selects the build directory (default: a fresh mktemp -d, kept).
# QEMU_WAIT is the number of seconds to wait for QEMU's last line (default 30).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROBE="$ROOT/tests/app/fixtures/platform/timer-probe"
BOARD=mps2/an521/cpu0
FRDM=frdm_mcxn947/mcxn947/cpu0
RT1186=frdm_imxrt1186/mimxrt1186/cm33
RT1186_CM7=frdm_imxrt1186/mimxrt1186/cm7
QEMU_WAIT=${QEMU_WAIT:-30}

die() { echo "platform-facts: $*" >&2; exit 2; }
[ -n "${ZEPHYR_BASE:-}" ] || die "ZEPHYR_BASE is empty: set it to the pinned Zephyr tree"
[ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || die "ZEPHYR_SDK_INSTALL_DIR is empty: set it to the pinned SDK"
[ -d "$ZEPHYR_BASE/boards" ] || die "ZEPHYR_BASE=$ZEPHYR_BASE has no boards/"
command -v west >/dev/null 2>&1 || die "no west on PATH (put the installation's venv first)"
# ZEPHYR_SDK_INSTALL_DIR is deliberately not checked here. It is not
# authoritative: the pinned FindZephyr-sdk.cmake passes it as a HINTS entry,
# so when it names nothing CMake falls through to its default search and can
# find an SDK under $HOME (measured on the Mac, 2026-09-22). The defence is the
# CMake log, compared below; the nonexistent-SDK control near the end shows it.
export ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR

OUT=${OUT:-$(mktemp -d)}
mkdir -p "$OUT"
t_start=$(date +%s)
fails=0

# fact NAME VALUE COMMAND
fact() { printf 'fact %s %s   # %s\n' "$1" "$2" "$3"; }
# require NAME VALUE EXPECTED COMMAND
require() {
	fact "$1" "$2" "$4"
	if [ "$2" != "$3" ]; then
		echo "platform-facts: $1 is '$2', expected '$3'" >&2
		fails=$((fails + 1))
	fi
}

# canonical DIR: the path as the CMake log prints it (it resolves symlinks);
# a directory that does not exist is printed as given
canonical() { (CDPATH= cd -- "$1" 2>/dev/null && pwd -P) || echo "$1"; }

# sdk_from_log LOG: "<version> <path>" of the SDK the configure actually used
sdk_from_log() { sed -n 's/^-- Found toolchain: zephyr \([^ ]*\) (\(.*\))$/\1 \2/p' "$1" | head -1; }
# intended_sdk DIR: what the log must say for DIR
intended_sdk() { echo "$(cat "$1/sdk_version" 2>/dev/null || echo absent) $(canonical "$1")"; }

# build BOARD SOURCE BUILDDIR [extra cmake args...]
build() {
	b=$1; src=$2; d=$3; shift 3
	west build -p always -b "$b" "$src" -d "$d" -- \
		-DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" "$@" > "$d.log" 2>&1
}

# run_qemu BUILDDIR MARKER: runs the image, waits for MARKER on the console,
# stops QEMU through the pid file west's run target writes, keeps the console
# in BUILDDIR.console. QEMU never exits by itself: Zephyr idles.
run_qemu() {
	d=$1; marker=$2
	rm -f "$d/qemu.pid"
	west build -d "$d" -t run > "$d.console" 2>&1 < /dev/null &
	runner=$!
	i=0
	while [ "$i" -lt "$QEMU_WAIT" ] && ! grep -q "$marker" "$d.console"; do
		sleep 1; i=$((i + 1))
	done
	[ -f "$d/qemu.pid" ] && kill "$(cat "$d/qemu.pid")" 2>/dev/null
	kill "$runner" 2>/dev/null
	wait "$runner" 2>/dev/null
	echo "$i"
}

# ---- hello_world: the CMake log, the two files, the banner ------------------
H="$OUT/hello"
build "$BOARD" "$ZEPHYR_BASE/samples/hello_world" "$H"; hrc=$?
# The log is compared before the build's own result is judged, so that a wrong
# SDK is named as such and not only as a failed build.

used_base=$(sed -n 's/^-- Zephyr version: [^ ]* (\(.*\))$/\1/p' "$H.log" | head -1)
require cmake_zephyr_base "$used_base" "$(canonical "$ZEPHYR_BASE")" \
	"sed -n 's/^-- Zephyr version: [^ ]* (\\(.*\\))\$/\\1/p' $H.log | head -1"
require cmake_sdk "$(sdk_from_log "$H.log")" "$(intended_sdk "$ZEPHYR_SDK_INSTALL_DIR")" \
	"sed -n 's/^-- Found toolchain: zephyr \\([^ ]*\\) (\\(.*\\))\$/\\1 \\2/p' $H.log | head -1, against sdk_version and the canonical ZEPHYR_SDK_INSTALL_DIR"
require zephyr_dts "$([ -s "$H/zephyr/zephyr.dts" ] && echo present || echo absent)" present \
	"test -s $H/zephyr/zephyr.dts"
require compile_commands "$([ -s "$H/compile_commands.json" ] && echo present || echo absent)" present \
	"test -s $H/compile_commands.json"
[ "$hrc" -eq 0 ] || { echo "platform-facts: hello_world build failed (rc=$hrc), see $H.log" >&2; exit 1; }

waited=$(run_qemu "$H" 'Hello World!')
banner=$(grep -c 'Hello World! mps2/an521/cpu0' "$H.console")
require qemu_banner "$banner" 1 "grep -c 'Hello World! mps2/an521/cpu0' $H.console (after ${waited}s)"
qemu=$(sed -n 's/^QEMU:FILEPATH=//p' "$H/CMakeCache.txt")
fact qemu_binary "$qemu" "sed -n 's/^QEMU:FILEPATH=//p' $H/CMakeCache.txt (the run target's QEMU, the SDK's)"
fact qemu_version "$("$qemu" --version 2>/dev/null | head -1 | tr ' ' '_')" "$qemu --version | head -1"

# ---- the board's devicetree: no ADC, no PWM, CMSDK timers at priority 3 ----
DTS="$H/zephyr/zephyr.dts"
n=$(grep -Ec 'compatible = "[^"]*(adc|pwm)[^"]*"' "$DTS" || true)
require an521_adc_pwm_nodes "$n" 0 "grep -Ec 'compatible = \"[^\"]*(adc|pwm)[^\"]*\"' $DTS"
timers=$(grep -B1 'compatible = "arm,cmsdk-d\{0,1\}timer"' "$DTS" | sed -n 's/^[[:space:]]*\([a-z0-9_]*\): .*/\1/p' | tr '\n' ',' | sed 's/,$//')
fact an521_cmsdk_timers "$timers" "grep -B1 'compatible = \"arm,cmsdk-d\\{0,1\\}timer\"' $DTS"
[ -n "$timers" ] || { echo "platform-facts: no CMSDK timer for nesting" >&2; fails=$((fails + 1)); }
prio=$(grep -A3 'compatible = "arm,cmsdk-timer"' "$DTS" | sed -n 's/.*interrupts = < \(0x[0-9a-f]*\) \(0x[0-9a-f]*\) >.*/\2/p' | sort -u | tr '\n' ',' | sed 's/,$//')
fact an521_cmsdk_timer_priorities "$prio" "interrupts = < irq prio > of the arm,cmsdk-timer nodes in $DTS"
sram=$(sed -n 's/.*zephyr,sram = &\([a-z0-9_]*\);.*/\1/p' "$DTS" | head -1)
sram_size=$(grep -A4 "^[[:space:]]*$sram: " "$DTS" | sed -n 's/.*reg = < 0x[0-9a-f]* \(0x[0-9a-f]*\) >.*/\1/p' | head -1)
fact an521_sram_bytes "$sram=$((sram_size))" "zephyr,sram node's reg size in $DTS"
fact an521_sys_clock_hz "$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$H/zephyr/.config")" "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC in $H/zephyr/.config"
for k in CONFIG_TRUSTED_EXECUTION_SECURE CONFIG_ARM_MPU CONFIG_ARM_TRUSTZONE_M CONFIG_BUILD_WITH_TFM CONFIG_FPU; do
	fact "an521_$k" "$(grep "^$k=" "$H/zephyr/.config" || echo unset)" "grep ^$k= $H/zephyr/.config"
done

# ---- the timer probe with the emulator overlay -----------------------------
P="$OUT/probe"
build "$BOARD" "$PROBE" "$P" -DEXTRA_DTC_OVERLAY_FILE="$PROBE/emul.overlay" \
	|| { echo "platform-facts: timer probe build failed, see $P.log" >&2; exit 1; }
require probe_emul_build "$(grep -Ec 'compatible = "zephyr,(adc|gpio)-emul"' "$P/zephyr/zephyr.dts" || true)" 2 \
	"grep -Ec 'compatible = \"zephyr,(adc|gpio)-emul\"' $P/zephyr/zephyr.dts"
require probe_64bit_counter "$(grep -c '^CONFIG_TIMER_HAS_64BIT_CYCLE_COUNTER=y' "$P/zephyr/.config")" 1 \
	"grep -c ^CONFIG_TIMER_HAS_64BIT_CYCLE_COUNTER=y $P/zephyr/.config"

waited=$(run_qemu "$P" 'PROBE end')
line=$(grep '^PROBE timer' "$P.console" | head -1 | tr -d '\r')
delta=$(echo "$line" | sed -n 's/.* delta=\([0-9]*\) .*/\1/p')
in_isr=$(echo "$line" | sed -n 's/.* in_isr=\([0-9]*\).*/\1/p')
fact probe_timer_line "$(echo "$line" | tr ' ' '_')" "grep '^PROBE timer' $P.console (after ${waited}s)"
require probe_expiry_in_isr "${in_isr:-none}" 1 "in_isr= of that line"
require probe_cycles_advance "$([ "${delta:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no)" yes "delta= of that line is greater than 0"
emul=$(grep '^PROBE emul' "$P.console" | head -1 | tr -d '\r')
require probe_emul_ready "$(echo "$emul" | sed 's/^PROBE emul //' | tr ' ' '_')" "adc_ready=1_gpio_ready=1" "grep '^PROBE emul' $P.console"

# ---- the control of the clock fact: without the 64-bit count, the same probe
# reads 0 twice and the check above must fail. This is the input that makes
# probe_cycles_advance a check.
C="$OUT/probe32"
build "$BOARD" "$PROBE" "$C" -DEXTRA_DTC_OVERLAY_FILE="$PROBE/emul.overlay" \
	-DCONFIG_CORTEX_M_SYSTICK_64BIT_CYCLE_COUNTER=n \
	|| { echo "platform-facts: 32-bit control build failed, see $C.log" >&2; exit 1; }
waited=$(run_qemu "$C" 'PROBE end')
cdelta=$(grep '^PROBE timer' "$C.console" | head -1 | tr -d '\r' | sed -n 's/.* delta=\([0-9]*\) .*/\1/p')
require control_32bit_counter_reads_zero "64bit=$(grep -c '^CONFIG_TIMER_HAS_64BIT_CYCLE_COUNTER=y' "$C/zephyr/.config") delta=${cdelta:-none}" "64bit=0 delta=0" \
	"the probe built with -DCONFIG_CORTEX_M_SYSTICK_64BIT_CYCLE_COUNTER=n, $C.console (after ${waited}s)"

# ---- FRDM-MCXN947: configures; gpio-leds and pwm-leds ----------------------
F="$OUT/frdm"
if west build -p always -b "$FRDM" "$ZEPHYR_BASE/samples/hello_world" -d "$F" --cmake-only -- \
	-DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" > "$F.log" 2>&1; then
	require frdm_configures yes yes "west build -b $FRDM --cmake-only ($F.log)"
	FD="$F/zephyr/zephyr.dts"
	fact frdm_gpio_leds "$(grep -c 'compatible = "gpio-leds"' "$FD")" "grep -c 'compatible = \"gpio-leds\"' $FD"
	fact frdm_pwm_leds "$(grep -c 'compatible = "pwm-leds"' "$FD")" "grep -c 'compatible = \"pwm-leds\"' $FD"
	sram=$(sed -n 's/.*zephyr,sram = &\([a-z0-9_]*\);.*/\1/p' "$FD" | head -1)
	sram_size=$(grep -A4 "^[[:space:]]*$sram: " "$FD" | sed -n 's/.*reg = < 0x[0-9a-f]* \(0x[0-9a-f]*\) >.*/\1/p' | head -1)
	fact frdm_sram_bytes "$sram=$((sram_size))" "zephyr,sram node's reg size in $FD"
	for k in CONFIG_TRUSTED_EXECUTION_SECURE CONFIG_ARM_MPU CONFIG_SECOND_CORE_MCUX CONFIG_FPU; do
		fact "frdm_$k" "$(grep "^$k=" "$F/zephyr/.config" || echo unset)" "grep ^$k= $F/zephyr/.config"
	done
else
	require frdm_configures no yes "west build -b $FRDM --cmake-only ($F.log)"
fi

# ---- FRDM-IMXRT1186 (decision 0021): configures; its memories ---------------
# The CM33 core's build: zephyr,sram is the 8 MB HyperRAM the ROM initialises
# from the XMCD on a NOR boot, and the image runs in place from the 16 MB QSPI
# NOR at 0x1400_0000 (secure alias). One CPU node; the Cortex-M7 runs its own
# image.
F="$OUT/rt1186"
if west build -p always -b "$RT1186" "$ZEPHYR_BASE/samples/hello_world" -d "$F" --cmake-only -- \
	-DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" > "$F.log" 2>&1; then
	require rt1186_configures yes yes "west build -b $RT1186 --cmake-only ($F.log)"
	FD="$F/zephyr/zephyr.dts"
	fact rt1186_gpio_leds "$(grep -c 'compatible = "gpio-leds"' "$FD")" "grep -c 'compatible = \"gpio-leds\"' $FD"
	fact rt1186_pwm_leds "$(grep -c 'compatible = "pwm-leds"' "$FD")" "grep -c 'compatible = \"pwm-leds\"' $FD"
	sram=$(sed -n 's/.*zephyr,sram = &\([a-z0-9_]*\);.*/\1/p' "$FD" | head -1)
	sram_size=$(grep -A4 "^[[:space:]]*$sram: " "$FD" | sed -n 's/.*reg = < 0x[0-9a-f]* \(0x[0-9a-f]*\) >.*/\1/p' | head -1)
	require rt1186_sram_bytes "$sram=$((sram_size))" "hyperram0=8388608" "zephyr,sram node's reg size in $FD"
	fact rt1186_cpus "$(grep -c '^[[:space:]]*cpu[0-9]*: cpu@' "$FD")" "grep -c 'cpuN: cpu@' $FD"
	for k in CONFIG_TRUSTED_EXECUTION_SECURE CONFIG_ARM_MPU CONFIG_FPU CONFIG_FLASH_BASE_ADDRESS CONFIG_FLASH_SIZE \
		CONFIG_SRAM_BASE_ADDRESS CONFIG_XIP CONFIG_BOOT_FLEXSPI_NOR CONFIG_EXTERNAL_MEM_CONFIG_DATA \
		CONFIG_UART_MCUX_LPUART_ISR_SUPPORT; do
		fact "rt1186_$k" "$(grep "^$k=" "$F/zephyr/.config" || echo unset)" "grep ^$k= $F/zephyr/.config"
	done
else
	require rt1186_configures no yes "west build -b $RT1186 --cmake-only ($F.log)"
fi

# ---- FRDM-IMXRT1186's Cortex-M7 (decision 0023): configures; its memories --
# The stock CM7 target: zephyr,sram is the 256 KB DTCM, one CPU node (the
# M33 runs the launcher), no PSPLIM, so HW_STACK_PROTECTION is an MPU stack
# guard.
F="$OUT/rt1186-cm7"
if west build -p always -b "$RT1186_CM7" "$ZEPHYR_BASE/samples/hello_world" -d "$F" --cmake-only -- \
	-DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" > "$F.log" 2>&1; then
	require rt1186_cm7_configures yes yes "west build -b $RT1186_CM7 --cmake-only ($F.log)"
	FD="$F/zephyr/zephyr.dts"
	sram=$(sed -n 's/.*zephyr,sram = &\([a-z0-9_]*\);.*/\1/p' "$FD" | head -1)
	sram_size=$(grep -A4 "^[[:space:]]*$sram: " "$FD" | sed -n 's/.*reg = < 0x[0-9a-f]* \(0x[0-9a-f]*\) >.*/\1/p' | head -1)
	require rt1186_cm7_sram_bytes "$sram=$((sram_size))" "dtcm=262144" "zephyr,sram node's reg size in $FD"
	fact rt1186_cm7_cpus "$(grep -c '^[[:space:]]*cpu[0-9]*: cpu@' "$FD")" "grep -c 'cpuN: cpu@' $FD"
	for k in CONFIG_CPU_CORTEX_M7 CONFIG_ARM_MPU CONFIG_FPU CONFIG_MPU_STACK_GUARD CONFIG_BUILTIN_STACK_GUARD \
		CONFIG_ARM_MPU_REGION_MIN_ALIGN_AND_SIZE CONFIG_FLASH_BASE_ADDRESS CONFIG_SRAM_BASE_ADDRESS CONFIG_XIP; do
		fact "rt1186_cm7_$k" "$(grep "^$k=" "$F/zephyr/.config" || echo unset)" "grep ^$k= $F/zephyr/.config"
	done
else
	require rt1186_cm7_configures no yes "west build -b $RT1186_CM7 --cmake-only ($F.log)"
fi

# ---- the control of the SDK fact: a nonexistent ZEPHYR_SDK_INSTALL_DIR in
# the environment must be refused by the log comparison. On both hosts this
# configure SUCCEEDS and silently uses an SDK CMake finds on its own (the
# package registry on Debian, a $HOME prefix on the Mac; 2026-09-22). What
# happened is printed; the comparison refuses either way.
K="$OUT/sdkctl"
ZEPHYR_SDK_INSTALL_DIR=/nonexistent west build -p always -b "$BOARD" "$ZEPHYR_BASE/samples/hello_world" \
	-d "$K" --cmake-only > "$K.log" 2>&1
krc=$?
kused=$(sdk_from_log "$K.log")
fact control_nonexistent_sdk_configure "rc=$krc used=$(echo "${kused:-none}" | tr ' ' '_')" \
	"ZEPHYR_SDK_INSTALL_DIR=/nonexistent west build -b $BOARD --cmake-only ($K.log)"
require control_nonexistent_sdk_refused "$([ "$kused" != "$(intended_sdk /nonexistent)" ] && echo refused || echo accepted)" refused \
	"the cmake_sdk comparison applied to $K.log against /nonexistent"

# ---- the control: an empty ZEPHYR_BASE fails by name ------------------------
ctl=$(ZEPHYR_BASE= sh "$0" 2>&1 >/dev/null); rc=$?
require control_empty_zephyr_base "rc=$rc $(echo "$ctl" | grep -c 'ZEPHYR_BASE is empty')" "rc=2 1" \
	"ZEPHYR_BASE= sh $0"

echo "platform-facts: $fails required facts failed, builds in $OUT, $(( $(date +%s) - t_start )) s"
[ "$fails" -eq 0 ]
