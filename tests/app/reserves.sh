#!/bin/sh
# tests/app/reserves.sh -- decision 0014 Task 9: attested reserves and driver
# rows.
#
#   sh tests/app/reserves.sh                                            # tables and applicability
#   ... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... sh tests/app/reserves.sh   # plus the .su builds and QEMU
#
# What is checked, and against what:
#
#   1. The tables read, and their shape holds: rows and path files are in
#      bijection; every compatible of effects.tsv has an irq row; the
#      vector classes have their counts.
#   2. Applicability: the eight items of 0014 §9 (its seven plus the SVC
#      handler's) have one applicable row on each real board under the
#      application's configuration; a row whose applies_when does not hold
#      is ignored and the verdict is `unknown`, naming the item (controls:
#      the hello_world .config alone, another board's name,
#      CONFIG_TIMESLICING removed); two rows applying to one item is
#      refused; `=n` means not set.
#   3. With the Zephyr environment: the reserve harness is built for every
#      real board under both fragments with CONFIG_STACK_USAGE=y, and every
#      applicable reserve whose path has .su steps is recomputed from the
#      fresh .su files and must equal the row's bytes -- the attestation is
#      checked against its own justification; the rows whose path is a
#      hardware-frame or assembly literal alone (thread_switch, pendsv, svc,
#      guard_area, and Task 10's drv_adc_latest, whose Zephyr part is an
#      inline atomic read) are named as not recomputable. A path step the build
#      cannot settle (missing, ambiguous, or a non-static frame) fails the
#      row. Every handler symbol of the pinned vector table is classified
#      or is a budgeted source.
#   4. With the Zephyr environment: the harness runs under QEMU on
#      mps2/an521 in both configurations, paints its stacks, drives the
#      SysTick dispatch (a timer expiring over a spinning thread, then with
#      the thread waiting on it) and the scheduler thread's kernel-call
#      chain (a sleep, a timer start and stop, UART polling), and prints
#      RESERVES_HELD when no high-water mark exceeds the reserves those
#      paths sum to. WHAT THE RUN DOES NOT DRIVE, and so cannot refute: the
#      isr_<driver> rows (no UART input reaches QEMU's console, so the
#      console ISR never runs; the FRDM rows run on no host), and the
#      thread_switch frame at the mark (the kernel-call chain is deeper on
#      the worker's stack than the exception frame). Two controls: with
#      timer_dispatch lowered below its path the run prints
#      RESERVES_REFUTED; with CONFIG_TIMESLICING=n the interrupt-stack mark
#      falls to the k_timer branch's sum, which is what shows that the
#      time-slice branch the row attests is the one that raised it. A held
#      run is falsification evidence, never the reserve.
#
# KERNEL is not needed; RUBY selects the Ruby, CLANG (or LLVM_PREFIX) names
# the LLVM whose readobj and nm read the built image, and with ZEPHYR_BASE,
# ZEPHYR_SDK_INSTALL_DIR and west on the PATH the builds and the QEMU runs
# happen (REQUIRE_ALL=1 makes their absence a failure).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ZT="$ROOT/tools/app/zephyr/v4.4.2"
H="$ZT/reserve-harness"
DTS="$ROOT/tests/app/fixtures/dts"
RUBY="${RUBY:-ruby}"
LIB="$ROOT/tools/app/lib"
die() { echo "reserves: $*" >&2; exit 1; }
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
export LLVM_PREFIX="${LLVM_PREFIX:-$(dirname "$(dirname "$CC_BIN")")}"
QEMU_WAIT=${QEMU_WAIT:-30}

W=$(mktemp -d "${TMPDIR:-/tmp}/app-reserves.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skips=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then echo "  FAIL $1 (REQUIRE_ALL=1; $2 checks)"; fail=$((fail + $2)); else echo "  skip $1 ($2 checks)"; skips=$((skips + $2)); fi; }
rb() { "$RUBY" -I"$LIB" -rcore_app/reserves -e "$@"; }

echo "reserves: 1. the tables"
ok "reserves.tsv reads: 61 rows (Task 9's 20, Task 10's drv_<member> rows per board plus the an521 GPIO ISR, the Adc sampler's drv_adc_read per board, decision 0021's 13 for frdm_imxrt1186 and decision 0028's MU interrupt beside them, decision 0023's 15 for frdm_imxrt1186_cm7, two of them its interrupt-driven console's), in bijection with the path files, each row's board in its path" \
   "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); files = Dir[File.join(ARGV[1], "reserve-harness/paths/*/*.tsv")].map { |f| f.sub(ARGV[1] + "/", "") }.sort
          puts "#{rows.size}:#{rows.map(&:evidence).sort == files ? "bijection" : "mismatch " + ((rows.map(&:evidence) - files) + (files - rows.map(&:evidence))).inspect}:#{rows.count { |r| r.evidence.include?("/" + r.applies_when[/board=([a-z0-9_]+)/, 1] + "/") }}"' "$ZT/reserves.tsv" "$ZT")" "61:bijection:61"
ok "every compatible of effects.tsv has an irq row" \
   "$(rb 'irq = CoreApp::Reserves.read_irq_rows(ARGV[0]).map(&:compatible); eff = File.readlines(ARGV[1]).reject { |l| l.start_with?("#") }.map { |l| l.split("\t")[0] }; puts (eff - irq).inspect' "$ZT/irq-rows.tsv" "$ZT/effects.tsv")" "[]"
ok "vector-classes.tsv has one reset, seven terminal and three default symbols" \
   "$(rb 'v = CoreApp::Reserves.read_vector_classes(ARGV[0]); puts v.group_by(&:klass).transform_values(&:size).sort.map { |k, n| "#{k}=#{n}" }.join(",")' "$ZT/vector-classes.tsv")" "default=3,reset=1,terminal=7"

echo "reserves: 2. applicability"
ITEMS=$(rb 'puts CoreApp::Reserves::ITEMS.join(" ")')
ok "the items are the seven of 0014 section 9 plus svc" "$ITEMS" "thread_switch thread_kernel_calls isr_entry_exit pendsv svc timer_dispatch uart_calls guard_area"
# The application's configuration: the board's recorded .config (a
# hello_world build's) plus the production fragment the application build
# adds (the 64-bit cycle counter among it, which changes the SysTick
# handler's frame and so timer_dispatch's row asks for it).
for b in mps2_an521 frdm_mcxn947 frdm_imxrt1186 frdm_imxrt1186_cm7; do
  cat "$DTS/$b/config" "$H/prod.conf" > "$W/$b.config"
  ok "$b: every item of 0014 section 9 has one applicable row under the application's configuration" \
     "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); v = CoreApp::Reserves.verdict(rows, ARGV[3].split(" "), cfg, ARGV[2]); puts v[0] == :pass ? "pass:" + v[1].map { |k, r| "#{k}=#{r.bytes}" }.join(",") : v.inspect' "$ZT/reserves.tsv" "$W/$b.config" "$b" "$ITEMS")" \
     "pass:thread_switch=36,thread_kernel_calls=128,isr_entry_exit=8,pendsv=$([ $b = frdm_imxrt1186_cm7 ] && echo 64 || echo 0),svc=8,timer_dispatch=144,uart_calls=$([ $b = mps2_an521 ] && echo 0 || echo 16),guard_area=0"
done
ok "control: under the hello_world .config alone (no 64-bit cycle counter) timer_dispatch has no row and is unknown" \
   "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); p CoreApp::Reserves.verdict(rows, ARGV[2].split(" "), cfg, "mps2_an521")' "$ZT/reserves.tsv" "$DTS/mps2_an521/config" "$ITEMS")" \
   "[:unknown, [\"timer_dispatch\"]]"
ok "control: under the other board's name the board-bound rows do not apply, and the verdict is unknown naming every item" \
   "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); p CoreApp::Reserves.verdict(rows, ARGV[2].split(" "), cfg, "nucleo_f401re")' "$ZT/reserves.tsv" "$W/mps2_an521.config" "$ITEMS")" \
   "[:unknown, [\"thread_switch\", \"thread_kernel_calls\", \"isr_entry_exit\", \"pendsv\", \"svc\", \"timer_dispatch\", \"uart_calls\", \"guard_area\"]]"
grep -v '^CONFIG_TIMESLICING=y$' "$W/mps2_an521.config" > "$W/noslice.config"
ok "control: with CONFIG_TIMESLICING unset the timer_dispatch row does not apply and only that item is unknown" \
   "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); p CoreApp::Reserves.verdict(rows, ARGV[2].split(" "), cfg, "mps2_an521")' "$ZT/reserves.tsv" "$W/noslice.config" "$ITEMS")" \
   "[:unknown, [\"timer_dispatch\"]]"
printf 'CONFIG_FPU=y\n' >> "$W/noslice.config"
ok "control: a =n predicate fails when the symbol is set (CONFIG_FPU=y makes the rows naming it inapplicable: 5 of 8 items unknown)" \
   "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); v = CoreApp::Reserves.verdict(rows, ARGV[2].split(" "), cfg, "mps2_an521"); puts "#{v[0]}:#{v[1].sort.join(",")}"' "$ZT/reserves.tsv" "$W/noslice.config" "$ITEMS")" "unknown:pendsv,svc,thread_kernel_calls,thread_switch,timer_dispatch"
# a second pendsv row for the same board with other bytes, by line (BSD sed has no \t)
awk -F'\t' -v OFS='\t' '{ print } $1 == "pendsv" && $4 ~ /board=mps2_an521/ { $2 = 4; print }' "$ZT/reserves.tsv" > "$W/dup.tsv"
ok "control's input: the duplicate row exists and differs in bytes" "$(grep -c '^pendsv	4	' "$W/dup.tsv"):$(grep -c '^pendsv	0	' "$W/dup.tsv")" "1:3"
ok "control: two rows applying to one item are refused, not chosen between" \
   "$(rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); begin; CoreApp::Reserves.applicable(rows, "pendsv", cfg, "mps2_an521"); puts "chose"; rescue CoreApp::Reserves::Error => e; puts e.message; end' "$W/dup.tsv" "$W/mps2_an521.config")" "reserves: 2 rows apply to pendsv on mps2_an521; one is required"

if [ -n "${ZEPHYR_BASE:-}" ] && [ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ] && command -v west > /dev/null 2>&1; then
  export ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR
  echo "reserves: 3. every reserve recomputed from a fresh CONFIG_STACK_USAGE=y build"
  printf '/* placeholder for the .su builds */\n' > "$W/reserves.h"
  for i in $ITEMS; do
    printf '#define SPC_RESERVE_%s 0u\n' "$(echo $i | tr '[:lower:]' '[:upper:]')" >> "$W/reserves.h"
  done
  for pair in "mps2/an521/cpu0 mps2_an521" "frdm_mcxn947/mcxn947/cpu0 frdm_mcxn947" "frdm_imxrt1186/mimxrt1186/cm33 frdm_imxrt1186" "frdm_imxrt1186/mimxrt1186/cm7 frdm_imxrt1186_cm7"; do
    set -- $pair
    for cf in prod verify; do
      d="$W/$2-$cf"
      # a board whose table names Kconfig and devicetree files of its own (the
      # Cortex-M7: an interrupt-driven console) gets them as the application does
      bconf=$(awk -F'\t' '$1 == "zephyr_conf" { print $2 }' "$ZT/boards/$2.tsv")
      bovl=$(awk -F'\t' '$1 == "zephyr_overlays" { print $2 }' "$ZT/boards/$2.tsv")
      xconf="$H/$cf.conf"; [ -n "$bconf" ] && xconf="$xconf;$ZT/boards/$bconf"
      xovl=""; for o in $bovl; do xovl="${xovl:+$xovl;}$ZT/boards/$o"; done
      west build -p always -b "$1" "$H" -d "$d" -- -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" \
        -DEXTRA_CONF_FILE="$xconf" ${xovl:+-DEXTRA_DTC_OVERLAY_FILE="$xovl"} -DSPC_RESERVES_DIR="$W" > "$d.log" 2>&1 || die "the harness did not build for $2 ($cf); see $d.log"
      ok "$2 $cf: the build writes .su files and its .config sets what the fragment asks" \
         "$(find "$d" -name '*.su' | wc -l | awk '{print ($1 > 50) ? "many" : $1}'):$(grep -cE '^CONFIG_(STACK_USAGE|CORTEX_M_SYSTICK_64BIT_CYCLE_COUNTER)=y$' "$d/zephyr/.config")" "many:2"
      ok "$2 $cf: every applicable reserve with .su steps equals the sum of its path over this build's frames; the literal-only rows are named" \
         "$(rb '
            rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); su = CoreApp::Reserves.su_index(ARGV[2])
            bad = []; recomputed = []; literal = []
            rows.select { |r| CoreApp::Reserves.applies?(r.applies_when, cfg, ARGV[3]) }.each do |r|
              s = CoreApp::Reserves.path_sum(File.join(ARGV[4], r.evidence), su)
              bad << "#{r.item}: row #{r.bytes}, path #{s.bytes}#{s.missing.empty? ? "" : " (" + s.missing.join("; ") + ")"}" if s.bytes != r.bytes || !s.missing.empty?
              (s.su_steps > 0 ? recomputed : literal) << r.item
            end
            puts bad.empty? ? "recomputed #{recomputed.size}: #{recomputed.join(",")}; literal-only #{literal.size}: #{literal.join(",")}" : bad.join(" | ")' "$ZT/reserves.tsv" "$d/zephyr/.config" "$d" "$2" "$ZT")" \
         "$(case $2 in
              (mps2_an521) echo 'recomputed 10: thread_kernel_calls,isr_entry_exit,timer_dispatch,uart_calls,isr_uart_cmsdk_apb,isr_gpio_cmsdk_ahb,drv_led_set,drv_button_read,drv_clock,drv_adc_read; literal-only 5: thread_switch,pendsv,svc,guard_area,drv_adc_latest' ;;
              (frdm_mcxn947) echo 'recomputed 12: thread_kernel_calls,isr_entry_exit,timer_dispatch,uart_calls,isr_lpuart,isr_gpio_mcux_port,isr_lpadc,drv_led_set,drv_button_read,drv_clock,drv_pwm_set,drv_adc_read; literal-only 5: thread_switch,pendsv,svc,guard_area,drv_adc_latest' ;;
              # the console LPUART of the RT1186 is polled (no ISR support compiled), and it carries the rows the DOOM board application needs;
              # its harness builds Zephyr's MU driver (boards/frdm_imxrt1186_mimxrt1186_cm33.conf), as a doorbell's consumer does (decision 0028)
              (frdm_imxrt1186) echo 'recomputed 10: thread_kernel_calls,isr_entry_exit,timer_dispatch,uart_calls,isr_lpadc,drv_clock,isr_gpio_mcux_rgpio,drv_led_set,drv_button_read,isr_mbox_nxp_imx_mu; literal-only 4: thread_switch,pendsv,svc,guard_area' ;;
              # the Cortex-M7 (decision 0023): its MPU stack guard puts a call chain under PendSV, so pendsv has .su steps
              (frdm_imxrt1186_cm7) echo 'recomputed 11: thread_kernel_calls,isr_entry_exit,pendsv,timer_dispatch,isr_lpadc,drv_clock,isr_gpio_mcux_rgpio,drv_led_set,drv_button_read,uart_calls,isr_lpuart; literal-only 3: thread_switch,svc,guard_area' ;;
            esac)"
    done
  done
  ok "control: a path step the build cannot settle fails the row, naming it" \
     "$(printf 'function\tsource\tnote\nno_such_function\tsu\tx\n' > "$W/bad.tsv"; rb 'su = CoreApp::Reserves.su_index(ARGV[1]); s = CoreApp::Reserves.path_sum(ARGV[0], su); puts s.missing.join' "$W/bad.tsv" "$W/mps2_an521-prod")" "no_such_function: no .su entry in this build"
  ok "control: a name defined in two files is refused unqualified and settled by su:<file>" \
     "$(printf 'function\tsource\tnote\nsys_clock_set_timeout\tsu\tx\n' > "$W/amb.tsv"; printf 'function\tsource\tnote\nsys_clock_set_timeout\tsu:drivers/timer/cortex_m_systick.c\tx\n' > "$W/qual.tsv"; rb 'su = CoreApp::Reserves.su_index(ARGV[2]); a = CoreApp::Reserves.path_sum(ARGV[0], su); q = CoreApp::Reserves.path_sum(ARGV[1], su); puts "#{a.missing.size}:#{q.bytes}:#{q.missing.size}"' "$W/amb.tsv" "$W/qual.tsv" "$W/mps2_an521-prod")" "1:24:0"
  "$ROOT/tools/core/object-symbols" --defined "$W/mps2_an521-prod/zephyr/zephyr.elf" > "$W/vec.syms" || die "object-symbols failed on the image"
  ok "the vector class symbols are all defined in the mps2/an521 image" \
     "$(rb 'v = CoreApp::Reserves.read_vector_classes(ARGV[0]).map(&:symbol); syms = File.read(ARGV[1]).lines.map { |l| l.split("\t")[1].to_s.strip }; puts (v - syms).inspect' "$ZT/vector-classes.tsv" "$W/vec.syms")" "[]"
  # the other direction: every handler the pinned vector_table.S names is a
  # class or a budgeted source (the timer, PendSV and SVC, the inventory's)
  ok "every .word handler of the pinned vector_table.S is a vector class or a budgeted source" \
     "$(rb 'v = CoreApp::Reserves.read_vector_classes(ARGV[0]).map(&:symbol); words = File.read(ARGV[1]).scan(/^\s*\.word\s+([A-Za-z_]\w*)/).flatten.uniq - ["z_main_stack"]; puts (words - v - %w[sys_clock_isr z_arm_pendsv z_arm_svc]).inspect' "$ZT/vector-classes.tsv" "$ZEPHYR_BASE/arch/arm/core/cortex_m/vector_table.S")" "[]"
  ok "control: a path with no step is refused, not summed to 0" \
     "$(printf 'function\tsource\tnote\n' > "$W/empty.tsv"; rb 'su = CoreApp::Reserves.su_index(ARGV[1]); s = CoreApp::Reserves.path_sum(ARGV[0], su); puts s.missing.join' "$W/empty.tsv" "$W/mps2_an521-prod")" "the path has no step"
  ok "control: a step on a non-static (dynamic) frame is refused, naming the qualifier" \
     "$(printf 'function\tsource\tnote\nrb_insert\tsu\tx\n' > "$W/dyn.tsv"; rb 'su = CoreApp::Reserves.su_index(ARGV[1]); s = CoreApp::Reserves.path_sum(ARGV[0], su); puts s.missing.join' "$W/dyn.tsv" "$W/mps2_an521-prod")" "rb_insert: its frame is dynamic, not static; no reserve rests on it"

  echo "reserves: 4. the falsification harness under QEMU"
  # the harness's own frames on the thread path, from its .su: z_thread_entry + worker_entry
  WF=$(rb 'su = CoreApp::Reserves.su_index(ARGV[0]); puts su["worker_entry"].first[0] + su["z_thread_entry"].first[0]' "$W/mps2_an521-prod")
  EF=$(rb 'su = CoreApp::Reserves.su_index(ARGV[0]); puts su["expiry"].first[0]' "$W/mps2_an521-prod")
  ok "the harness's own frames are read from its .su (worker_entry + z_thread_entry, expiry)" "$WF:$EF" "40:0"
  run_harness() { # dir board conf header [extra cmake args] -> marker line
    d=$1; b=$2; cf=$3; hdr=$4; shift 4
    west build -p always -b "$b" "$H" -d "$d" -- -DZEPHYR_SDK_INSTALL_DIR="$ZEPHYR_SDK_INSTALL_DIR" -DEXTRA_CONF_FILE="$H/$cf.conf" \
      -DSPC_RESERVES_DIR="$hdr" -DCONFIG_COMPILER_OPT="\"-DSPC_HARNESS_WORKER_FRAMES=$WF -DSPC_HARNESS_EXPIRY_FRAMES=$EF\"" "$@" > "$d.log" 2>&1 || die "the harness run build failed; see $d.log"
    set -- "$d"
    # the harness's own frames, read again from THIS build's .su, must be the ones the budget used
    [ "$(rb 'su = CoreApp::Reserves.su_index(ARGV[0]); puts su["worker_entry"].first[0] + su["z_thread_entry"].first[0]' "$1")" = "$WF" ] || die "the harness's frames changed between the .su build and $1"
    rm -f "$1/qemu.pid"
    west build -d "$1" -t run > "$1.console" 2>&1 < /dev/null &
    runner=$!
    i=0
    while [ "$i" -lt "$QEMU_WAIT" ] && ! grep -qE 'RESERVES_HELD|RESERVES_REFUTED_END|RESERVES_ERROR' "$1.console"; do sleep 1; i=$((i + 1)); done
    if [ -f "$1/qemu.pid" ]; then kill "$(cat "$1/qemu.pid")" 2>/dev/null || true; fi
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    grep -o 'RESERVES worker_used=[0-9]* worker_budget=[0-9]* isr_used=[0-9]* isr_budget=[0-9]* expiries=[0-9]*' "$1.console" | head -1 | sed 's/^RESERVES //' > "$1.marks"
    grep -oE 'RESERVES_HELD|RESERVES_REFUTED_END|RESERVES_ERROR' "$1.console" | head -1
  }
  for cf in prod verify; do
    mkdir -p "$W/hdr-$cf"
    rb 'rows = CoreApp::Reserves.read(ARGV[0]); cfg = CoreApp::Reserves.read_config(File.read(ARGV[1])); v = CoreApp::Reserves.verdict(rows, ARGV[2].split(" "), cfg, "mps2_an521"); abort v.inspect unless v[0] == :pass; File.write(ARGV[3], CoreApp::Reserves.header(v[1]))' \
      "$ZT/reserves.tsv" "$W/mps2_an521-$cf/zephyr/.config" "$ITEMS" "$W/hdr-$cf/reserves.h" || die "no header for $cf"
    r=$(run_harness "$W/run-$cf" mps2/an521/cpu0 $cf "$W/hdr-$cf")
    echo "  (mps2/an521 $cf: $(cat "$W/run-$cf.marks"))"
    ok "mps2/an521 $cf: no high-water mark exceeds its reserve (falsification evidence, not the reserve)" "$r" RESERVES_HELD
    ok "mps2/an521 $cf: the timer expired at least five times, so the timer dispatch path ran" \
       "$(sed -n 's/.*expiries=\([0-9]*\).*/\1/p' "$W/run-$cf.marks" | awk '{print ($1 >= 5) ? "yes" : $1}')" yes
  done
  # The control for the time-slice branch: with CONFIG_TIMESLICING=n
  # z_time_slice is not called, and the interrupt-stack mark must fall below
  # the sliced run's -- the branch the row attests is one that raises the
  # mark. Measured on Debian, 2026-09-23: 112 against 136, and the attested
  # 144 covers the 136. The 112 is the k_timer branch with the periodic
  # timer's own re-arm: sys_clock_isr 16 + sys_clock_announce_locked 32 +
  # z_timer_expiration_handler 24 + z_add_timeout 40, settled by
  # reserve-harness/settle (0014) -- the 16 bytes this comment used to call
  # unexplained were an enumeration that omitted the re-arm.
  r=$(run_harness "$W/run-noslice" mps2/an521/cpu0 prod "$W/hdr-prod" -DCONFIG_TIMESLICING=n)
  echo "  (mps2/an521 prod, CONFIG_TIMESLICING=n: $(cat "$W/run-noslice.marks"))"
  isr_with=$(sed -n 's/.*isr_used=\([0-9]*\).*/\1/p' "$W/run-prod.marks")
  isr_without=$(sed -n 's/.*isr_used=\([0-9]*\).*/\1/p' "$W/run-noslice.marks")
  ok "control: without time slicing the interrupt-stack mark falls below the sliced run's, and both are under the attested 144" \
     "$(awk -v a="$isr_without" -v b="$isr_with" 'BEGIN { print (a > 0 && a < b && b <= 144) ? "yes" : a " vs " b }')" yes
  mkdir -p "$W/hdr-low"
  sed 's/^#define SPC_RESERVE_TIMER_DISPATCH [0-9]*u$/#define SPC_RESERVE_TIMER_DISPATCH 8u/' "$W/hdr-prod/reserves.h" > "$W/hdr-low/reserves.h"
  grep -q 'TIMER_DISPATCH 8u' "$W/hdr-low/reserves.h" || die "the lowered header did not apply"
  r=$(run_harness "$W/run-low" mps2/an521/cpu0 prod "$W/hdr-low")
  ok "control: with timer_dispatch lowered to 8 bytes the harness refutes the reserves" "$r:$(grep -c 'RESERVES_REFUTED isr:' "$W/run-low.console")" "RESERVES_REFUTED_END:1"
else
  skipped "the .su builds, the recomputation and the QEMU harness (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on PATH are needed)" 21
fi

echo
echo "reserves: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
[ "$fail" = 0 ] || exit 1
