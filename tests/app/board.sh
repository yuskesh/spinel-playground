#!/bin/sh
# tests/app/board.sh -- decision 0014 Task 7: board package generation.
#
# What is checked, and against what:
#
#   1. The devicetree fixtures are the recorded ones: the two real zephyr.dts
#      and .config files carry the digests in fixtures/dts/digests.txt.
#   2. Generated modules. For each real board the generated counts equal the
#      devicetree's enabled instances, counted here by awk over the DTS text
#      (an independent reading, not the generator's); names, aliases and
#      labels become the documented constants; board.tsv names every instance
#      by its controller channel. The synthetic devicetrees exercise the
#      rules the real boards do not: an I2C expander instance is not isr_ok
#      and is split into LedI2c; an unknown driver is not isr_ok and not
#      proven non-blocking, in LedUnattested; the mixed devicetree covers
#      every class, a disabled instance and io-channel names.
#   3. The screen, one kept control each: adapter objects calling k_malloc,
#      k_sleep, irq_connect_dynamic and an entry symbol are refused naming the
#      symbol and its set; an object calling only a driver operation passes.
#   4. Resolution: an application over Pwm resolves against the mixed board
#      and is unknown-member against mps2/an521.
#   5. Task 6's host fixtures re-run against the generated packages of both
#      real boards, with the same expectations, plus an application that
#      names the board's members by alias constants.
#   6. Controls: a devicetree construct the reader does not admit is refused
#      naming the line; an effect row whose applies_when does not hold leaves
#      the instance unattested; a moved fixture digest is noticed.
#
# The adapters' own C and the generated board_port.c are parsed here with
# clang -fsyntax-only against stand-in headers (fixtures/boards/zephyr-stubs),
# which establishes that they are well-formed C over the names they use and
# nothing about Zephyr's real API: compiling them against Zephyr v4.4.2 needs
# a configured build's generated headers, which Task 10's pipeline supplies.
# The screen runs on five hand-written control objects, not on the adapters.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures"
DTS="$FIX/dts"
APPS="$FIX/apps"
BAPPS="$FIX/boards"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"
die() { echo "board: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
export LLVM_PREFIX="${LLVM_PREFIX:-$(dirname "$(dirname "$CC_BIN")")}"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
"$RUBY" -e 'require "prism"; exit(RUBY_VERSION >= "3.1" ? 0 : 1)' >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' ($("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null)) is below 3.1 or cannot load prism, which the application tool needs.
       Prism ships with Ruby 3.3 and later; set RUBY=<such a ruby>, or install the prism gem."

W=$(mktemp -d "${TMPDIR:-/tmp}/app-board.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
sha() { "$RUBY" -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$1"; }

gen() { # board dts config -> exit status; package under $W/$1
  "$RUBY" "$TOOL" board --dts "$2" --config "$3" --board "$1" --out "$W/$1" > "$W/$1.out" 2>&1 && echo 0 || echo $?
}
# module count from the generator's own summary line
count() { sed -n "s/^module $2 count \([0-9]*\) .*/\1/p" "$W/$1.out"; }
# Enabled children of the node with this compatible, read from the DTS text:
# a child block that does not say status = "disabled". Independent of the
# generator (awk over the text, brace depth), so the two readings can differ.
dts_children() { # dts compatible
  awk -v c="compatible = \"$2\"" '
    index($0, c) && depth == 0 { inside = 1; next }
    inside && /\{/ { depth++; if (depth == 1) { child = 1; disabled = 0 } }
    inside && depth >= 1 && /status = "disabled"/ { disabled = 1 }
    inside && /\}/ { if (depth == 1 && child) { if (!disabled) n++; child = 0 } depth--; if (depth < 0) { inside = 0; depth = 0 } }
    END { print n + 0 }' "$1"
}
admit() { # app board -> `admitted` or the codes
  rm -rf "$W/admit"
  if "$RUBY" "$TOOL" admit --app "$1" --board "$W/$2/board.rb" --board-tsv "$W/$2/board.tsv" \
       --out "$W/admit" --kernel "$KERNEL" --clang "$CC_BIN" --typedump "$READER" > "$W/admit.out" 2>&1; then
    echo admitted
  else
    sed -n 's/^[^:]*:[0-9]*: \([a-z][a-z0-9-]*\): .*/\1/p' "$W/admit.out" | LC_ALL=C sort -u | tr '\n' ' '
  fi
}
run_host() { # app-dir board stimulus -> exit status; trace and summary under $W/<board>-<name>
  n="$2-$(basename "$1")"
  "$RUBY" "$TOOL" run-host --app "$1/app.rb" --board "$W/$2/board.rb" --board-host "$W/$2/board_host.rb" \
    --stimulus "$3" --trace "$W/$n.trace" > "$W/$n.summary" 2>&1 && echo 0 || echo $?
}
expect_lines() { # trace-stem expect-file -> lines not found in order, count (as host.sh)
  cut -f2- "$W/$1.trace" > "$W/$1.noseq"
  awk -v summary="$W/$1.summary" '
    NR == FNR { trace[NR] = $0; n = NR; next }
    /^$/ { next }
    /^#/ { next }
    /^summary / { want = substr($0, 9); found = 0
                  while ((getline line < summary) > 0) if (index(line, want)) found = 1
                  close(summary)
                  if (!found) { print "    missing: " $0; missing++ }
                  next }
    { hit = 0; for (i = pos + 1; i <= n; i++) if (trace[i] == $0) { pos = i; hit = 1; break }
      if (!hit) { print "    missing (in order): " $0; missing++ } }
    END { print missing + 0 }
  ' "$W/$1.noseq" "$2"
}

echo "board: 1. the devicetree fixtures are the recorded ones"
# digests: the files a digests file names, in order, each `ok` or `MOVED`
digests() { (cd "$1" && while read -r d f; do [ "$(sha "$f")" = "$d" ] && echo "ok $f" || echo "MOVED $f"; done < "$2") | LC_ALL=C sort | tr '\n' ' '; }
ok "digests.txt names exactly the real fixture files on disk" \
   "$(cut -d' ' -f3- "$DTS/digests.txt" | LC_ALL=C sort | tr '\n' ' ')" \
   "$(cd "$DTS" && find mps2_an521 frdm_mcxn947 frdm_imxrt1186 frdm_imxrt1186_cm7 -type f | LC_ALL=C sort | tr '\n' ' ')"
ok "every recorded digest matches its file" "$(digests "$DTS" digests.txt)" \
   "ok frdm_imxrt1186/config ok frdm_imxrt1186/zephyr.dts ok frdm_imxrt1186_cm7/config ok frdm_imxrt1186_cm7/zephyr.dts ok frdm_mcxn947/config ok frdm_mcxn947/zephyr.dts ok mps2_an521/config ok mps2_an521/zephyr.dts "

echo "board: 2. generated modules"
ok "mps2/an521 generates" "$(gen mps2_an521 "$DTS/mps2_an521/zephyr.dts" "$DTS/mps2_an521/config")" 0
ok "frdm_mcxn947 generates" "$(gen frdm_mcxn947 "$DTS/frdm_mcxn947/zephyr.dts" "$DTS/frdm_mcxn947/config")" 0
ok "frdm_imxrt1186 generates" "$(gen frdm_imxrt1186 "$DTS/frdm_imxrt1186/zephyr.dts" "$DTS/frdm_imxrt1186/config")" 0
ok "frdm_imxrt1186_cm7 generates (the board's Cortex-M7, decision 0023)" "$(gen frdm_imxrt1186_cm7 "$DTS/frdm_imxrt1186_cm7/zephyr.dts" "$DTS/frdm_imxrt1186_cm7/config")" 0
for b in mps2_an521 frdm_mcxn947 frdm_imxrt1186 frdm_imxrt1186_cm7; do
  ok "$b: Led count equals the enabled gpio-leds children of the DTS" \
     "$(count $b Led)" "$(dts_children "$DTS/$b/zephyr.dts" gpio-leds)"
  ok "$b: Button count equals the enabled gpio-keys children of the DTS" \
     "$(count $b Button)" "$(dts_children "$DTS/$b/zephyr.dts" gpio-keys)"
  ok "$b: Clock has one instance, and no Adc or Pwm module (the DTS has neither)" \
     "$(count $b Clock):$(grep -cE '^module (Adc|Pwm)' "$W/$b.out" || true)" "1:0"
  ok "$b: every module is isr_ok and non-blocking, with an effect row" \
     "$(grep -c '^module [A-Za-z]* count [0-9]* isr_ok true blocking false effects.tsv:[0-9]*$' "$W/$b.out")" "$(grep -c '^module' "$W/$b.out")"
  ok "$b: board.tsv has one row per instance, each on a controller channel" \
     "$(grep -vc '^#' "$W/$b/board.tsv"):$(grep -v '^#' "$W/$b/board.tsv" | cut -f4 | grep -c ':[0-9]*$')" \
     "$(( $(count $b Led) + $(count $b Button) + $(count $b Clock) )):$(( $(count $b Led) + $(count $b Button) ))"
  ok "$b: the provenance records the DTS and .config digests" \
     "$(grep -c "\"dts_sha256\": \"$(sha "$DTS/$b/zephyr.dts")\"" "$W/$b/provenance.json"):$(grep -c "\"config_sha256\": \"$(sha "$DTS/$b/config")\"" "$W/$b/provenance.json")" "1:1"
  "$CC_BIN" -fsyntax-only -Wall -Wextra -I "$BAPPS/zephyr-stubs" -I "$ROOT/tools/app" "$W/$b/board_port.c" > "$W/$b.port.err" 2>&1 && rc=0 || rc=$?
  ok "$b: the generated board_port.c is well-formed C over the stand-in headers, no diagnostic" "$rc:$(grep -c . "$W/$b.port.err")" "0:0"
done
for c in led button pwm adc clock; do
  # every unit of the class: the adapter and, for adc, its sampler glue
  rc=0; n=0; : > "$W/$c.adapter.err"
  for f in "$ROOT/tools/app/adapters/$c"/*.c; do
    n=$((n + 1))
    "$CC_BIN" -fsyntax-only -Wall -Wextra -I "$BAPPS/zephyr-stubs" -I "$ROOT/tools/app/adapters/$c" "$f" >> "$W/$c.adapter.err" 2>&1 || rc=$?
  done
  want=1; [ "$c" = adc ] && want=2 # adc: adapter.c and the sampler glue
  ok "adapters/$c: its $want C unit(s) are well-formed C over the stand-in headers, no diagnostic" "$n:$rc:$(grep -c . "$W/$c.adapter.err")" "$want:0:0"
done
ok "mps2/an521: alias, label and node-name constants (led0, USERLED0, led_0) all name instance 0, inside the Led module" \
   "$(grep -cE '^  (LED0|USERLED0|LED_0) = 0$' "$W/mps2_an521/board.rb"):$(grep -c '^LED_' "$W/mps2_an521/board.rb" || true)" "3:0"
ok "no generated package writes a constant at top level: every board's constants are in their module (0014 D5)" \
   "$(cat "$W"/*/board.rb "$W"/*/board_host.rb 2>/dev/null | grep -cE '^[A-Z][A-Z0-9_]* = ' || true)" 0
ok "frdm_mcxn947: the disabled led_2 is absent and led_3 (alias led0) is instance 1" \
   "$(grep -c 'LED_2' "$W/frdm_mcxn947/board.rb" || true):$(grep -c '^  LED_3 = 1$' "$W/frdm_mcxn947/board.rb"):$(grep -c '^  LED0 = 1$' "$W/frdm_mcxn947/board.rb")" "0:1:1"
hz=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$DTS/frdm_imxrt1186_cm7/config")
ok "frdm_imxrt1186_cm7: Clock::CYCLES_PER_SECOND is the .config's CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC ($hz), inside module Clock (decision 0024)" \
   "$(awk '/^module /{m=$2} m == "Clock" && /^  CYCLES_PER_SECOND = / {print $3}' "$W/frdm_imxrt1186_cm7/board.rb")" "$hz"
{ cat "$DTS/frdm_imxrt1186_cm7/config"; echo CONFIG_TIMER_READS_ITS_FREQUENCY_AT_RUNTIME=y; } > "$W/runtime.config"
ok "control: a configuration that reads its timer's frequency at run time generates, and gives no Clock::CYCLES_PER_SECOND" \
   "$(gen runtime_hz "$DTS/frdm_imxrt1186_cm7/zephyr.dts" "$W/runtime.config"):$(grep -c CYCLES_PER_SECOND "$W/runtime_hz/board.rb" || true)" "0:0"
ok "every member taking an index carries the D2 guard with its module's count" \
   "$(grep -c 'guards: \["index < 2 else bounds"\]' "$W/mps2_an521/board.rb")" 2
ok "frdm_mcxn947: the guard carries each module's own count (Button 1, Led 2)" \
   "$(awk '/^module Button/ { m = "B" } /^module Led/ { m = "L" } /guards:/ { sub(/.*guards: /, ""); print m ":" $0 }' "$W/frdm_mcxn947/board.rb" | tr '\n' ' ')" \
   "B:[\"index < 1 else bounds\"] L:[\"index < 2 else bounds\"] "
ok "board_port.c names each instance's node with DT_PATH, in devicetree order" \
   "$(grep -o 'DT_PATH([a-z_0-9, ]*)' "$W/mps2_an521/board_port.c" | tr '\n' ' ')" \
   "DT_PATH(gpio_keys, button_0) DT_PATH(gpio_keys, button_1) DT_PATH(leds, led_0) DT_PATH(leds, led_1) "
ok "board_port.c defines spc_board_<module>_<fn> for every declared member" \
   "$(grep -cE '^(int32_t spc_board_led_set\(uint32_t index, uint32_t duty\)|int32_t spc_board_button_read\(uint32_t index\)|int64_t spc_board_clock_uptime_us\(void\)|int64_t spc_board_clock_cycles\(void\))$' "$W/mps2_an521/board_port.c")" 4

ok "expander generates" "$(gen expander "$DTS/synthetic/expander.dts" "$DTS/synthetic/config")" 0
ok "expander: the memory-mapped LEDs stay in Led (2) and the expander instance is split into LedI2c (1)" \
   "$(count expander Led):$(count expander LedI2c)" "2:1"
ok "expander: LedI2c is not isr_ok and blocking, from the pcal6416a row; its board.tsv row is on the i2c bus" \
   "$(grep -c '^module LedI2c count 1 isr_ok false blocking true effects.tsv' "$W/expander.out"):$(grep -c '^LedI2c	0	led_ext	/soc/i2c@40010000/pcal6416a@20:4	nxp,pcal6416a	i2c	false	true' "$W/expander/board.tsv")" "1:1"
ok "expander: LedI2c declares set with isr_ok: false, and the alias led2 names its instance 0" \
   "$(grep -c 'isr_ok: false' "$W/expander/board.rb"):$(grep -c '^  LED2 = 0$' "$W/expander/board.rb")" "1:1"
ok "unknown generates" "$(gen unknown "$DTS/synthetic/unknown.dts" "$DTS/synthetic/config")" 0
ok "unknown: the instance on the driver with no row is LedUnattested, not isr_ok, blocking unknown, evidence none" \
   "$(grep -c '^module LedUnattested count 1 isr_ok false blocking unknown none$' "$W/unknown.out"):$(grep -c '^LedUnattested	0	led_new	/soc/gpio@40020000:0	vendor,new-gpio	mmio	false	unknown	none$' "$W/unknown/board.tsv")" "1:1"
ok "mixed generates" "$(gen mixed "$DTS/synthetic/mixed.dts" "$DTS/synthetic/config")" 0
ok "mixed: Adc 2, Button 2, Led 1 (led_1 disabled), Pwm 2, Clock 1" \
   "$(count mixed Adc):$(count mixed Button):$(count mixed Led):$(count mixed Pwm):$(count mixed Clock)" "2:2:1:2:1"
ok "mixed: ADC channels are named by io-channel-names and are two devices of one controller" \
   "$(grep -cE '^  (BATTERY = 0|LIGHT = 1)$' "$W/mixed/board.rb"):$(grep '^Adc' "$W/mixed/board.tsv" | cut -f4 | tr '\n' ' ')" "2:/soc/adc@40040000:0 /soc/adc@40040000:3 "
ok "mixed: the pwm-led0 alias becomes Pwm::PWM_LED0, and the label 'Green LED' becomes Led::GREEN_LED" \
   "$(grep -cE '^  (PWM_LED0 = 0|GREEN_LED = 0)$' "$W/mixed/board.rb")" 2
ok "mixed: board.tsv names every node: 8 rows, 8 distinct devices" \
   "$(grep -vc '^#' "$W/mixed/board.tsv"):$(grep -v '^#' "$W/mixed/board.tsv" | cut -f4 | LC_ALL=C sort -u | wc -l | tr -d ' ')" "8:8"
ok "mixed: board_port.c holds the ADC table by index and the PWM specs" \
   "$(grep -c 'ADC_DT_SPEC_GET_BY_IDX(DT_PATH(zephyr_user), [01])' "$W/mixed/board_port.c"):$(grep -c 'PWM_DT_SPEC_GET(DT_PATH(pwmleds, pwm_led_[01]))' "$W/mixed/board_port.c")" "2:2"
"$CC_BIN" -fsyntax-only -Wall -Wextra -I "$BAPPS/zephyr-stubs" -I "$ROOT/tools/app" "$W/mixed/board_port.c" > "$W/mixed.port.err" 2>&1 && rc=0 || rc=$?
ok "mixed: board_port.c with every class is well-formed C over the stand-in headers (the ADC words and the latest function are distinct names)" "$rc:$(grep -c . "$W/mixed.port.err")" "0:0"
# The expander package byte for byte: board.rb, board.tsv and board_port.c
# against the recorded expectation, so an extra module, member, guard or row
# cannot pass a count.
for f in board.rb board.tsv board_port.c; do
  ok "expander: generated $f equals the recorded expectation byte for byte" \
     "$(cmp -s "$W/expander/$f" "$DTS/synthetic/expander.expected/$f" && echo same || echo "differs: $(diff "$DTS/synthetic/expander.expected/$f" "$W/expander/$f" | head -3 | tr '\n' ';')")" same
done

echo "board: 3. the screen"
XFLAGS="--target=thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft -mthumb -Os -ffreestanding -c"
for c in alloc block irqconfig entry clean; do
  # shellcheck disable=SC2086
  "$CC_BIN" $XFLAGS "$BAPPS/screen/$c.c" -o "$W/$c.o" 2>"$W/$c.err" || die "the screen control $c did not compile: $(cat "$W/$c.err")"
done
screen() { "$RUBY" "$TOOL" screen --object "$W/$1.o" --entry spinel_core_sample > "$W/$1.screen" 2>&1 && echo passed || sed -n 's/.*: screen: \([A-Za-z_0-9]*\) (\([a-z]*\)).*/\1:\2/p' "$W/$1.screen" | tr '\n' ' '; }
ok "control: an adapter calling k_malloc is refused by the alloc set" "$(screen alloc)" "k_malloc:alloc "
ok "control: an adapter calling k_sleep is refused by the block set" "$(screen block)" "k_sleep:block "
ok "control: an adapter calling irq_connect_dynamic is refused by the irqconfig set" "$(screen irqconfig)" "irq_connect_dynamic:irqconfig "
ok "control: an adapter calling an entry symbol is refused as a call back into CORE" "$(screen entry)" "spinel_core_sample:entry "
ok "an adapter calling only a driver operation passes the screen" "$(screen clean)" passed
# The three ways a call back into CORE is named: the spinel_core_ export
# prefix (above), the spc_entry_ wrapper prefix Task 10's glue uses, and a
# name passed with --entry.
# shellcheck disable=SC2086
"$CC_BIN" $XFLAGS "$BAPPS/screen/wrapper.c" -o "$W/wrapper.o" 2>"$W/wrapper.err" || die "the screen control wrapper did not compile: $(cat "$W/wrapper.err")"
ok "control: an adapter calling a generated entry wrapper (spc_entry_*) is refused" "$(screen wrapper)" "spc_entry_blink:entry "
ok "control: a name passed with --entry is refused, and without it the same object passes" \
   "$("$RUBY" "$TOOL" screen --object "$W/clean.o" --entry gpio_pin_set_raw > /dev/null 2>&1 && echo passed || echo refused):$("$RUBY" "$TOOL" screen --object "$W/clean.o" > /dev/null 2>&1 && echo passed || echo refused)" "refused:passed"
ok "the control objects are ELF, read through tools/core/object-symbols" \
   "$("$ROOT/tools/core/object-symbols" --undefined "$W/alloc.o" | cut -f2)" "k_malloc"
# Provider evidence: written, read back, and bound only to its own configuration.
ok "evidence: a file written for one configuration binds to it, and each mismatch is named" \
   "$("$RUBY" -I"$ROOT/tools/app/lib" -rcore_app/evidence -e '
      d = CoreApp::Evidence.write(ARGV[0], symbol: "spc_board_led_set", object: ARGV[1], target: "thumbv8m.main-none-eabi", board: "mps2_an521", release: "v4.4.2",
                                  dts_sha256: "d", config_sha256: "c", flags_sha256: "f", stack_bytes: 24, stack_method: "0010 step 2", effects: { "isr_ok" => true, "blocking" => false, "row" => "effects.tsv:11" })
      r = CoreApp::Evidence.read(ARGV[0])
      same = CoreApp::Evidence.bound?(r, symbol: "spc_board_led_set", target: "thumbv8m.main-none-eabi", dts_sha256: "d", config_sha256: "c", flags_sha256: "f")
      other = CoreApp::Evidence.bound?(r, symbol: "spc_board_led_set", target: "thumbv8m.main-none-eabi", dts_sha256: "d", config_sha256: "x", flags_sha256: "f")
      sym = CoreApp::Evidence.bound?(r, symbol: "spc_board_pwm_set", target: "thumbv8m.main-none-eabi", dts_sha256: "d", config_sha256: "c", flags_sha256: "f")
      File.write(ARGV[1], "changed")
      obj = CoreApp::Evidence.bound?(r, symbol: "spc_board_led_set", target: "thumbv8m.main-none-eabi", dts_sha256: "d", config_sha256: "c", flags_sha256: "f")
      puts [same[0], other[1].to_s.start_with?("config_sha256 is"), sym[1].to_s.start_with?("symbol is"), obj[1].to_s.start_with?("the object'"'"'s sha256 is")].join(":")' "$W/ev.json" "$W/clean.o")" "true:true:true:true"

echo "board: 4. resolution"
ok "an application over Pwm resolves against the mixed board" "$(admit "$BAPPS/pwm/app.rb" mixed)" admitted
got=$(admit "$BAPPS/pwm/app.rb" mps2_an521)
case " $got " in
  *" unknown-member "*) ok "the same application is unknown-member against mps2/an521 (printed: $got)" yes yes ;;
  *) ok "the same application is unknown-member against mps2/an521" "$got" unknown-member ;;
esac

echo "board: 5. Task 6's host fixtures against the generated packages"
for b in mps2_an521 frdm_mcxn947; do
  for n in sched-overrun sched-cross-delay sched-missed sched-together sched-failure sched-cut channels; do
    rc=$(run_host "$APPS/$n" "$b" "$APPS/$n/stimulus.tsv")
    ok "$b/$n: runs, and every expected line is present in order (exit $rc)" "$rc:$(expect_lines "$b-$n" "$APPS/$n/expect.txt" | tail -1)" "0:0"
  done
  ok "$b/leds: the alias-named members are admitted by the kernel and the checks" "$(admit "$BAPPS/leds/app.rb" "$b")" admitted
  rc=$(run_host "$BAPPS/leds" "$b" "$BAPPS/leds/stimulus.tsv")
  ok "$b/leds: the button level follows the gpio stimulus, and led0 is the board's own instance (exit $rc)" \
     "$rc:$(expect_lines "$b-leds" "$BAPPS/leds/expect.$b.txt" | tail -1)" "0:0"
done

echo "board: 6. controls"
# The i.MX RT1180's peripherals sit under a `zephyr,memory-region` window that
# maps them with `ranges`, which the bus rule reads as memory mapped. Without
# the `ranges` line the window maps nothing the reader can see, and the LEDs
# must fall back to unattested: the rule rests on that property, not the name.
grep -v 'ranges = < 0x0 0x50000000 0x40000000 >;' "$DTS/frdm_imxrt1186/zephyr.dts" > "$W/noranges.dts"
ok "control's input: one ranges line is gone" "$(( $(wc -l < "$DTS/frdm_imxrt1186/zephyr.dts") - $(wc -l < "$W/noranges.dts") ))" 1
ok "control: a memory-region window without ranges is not memory mapped, so frdm_imxrt1186's LEDs are unattested" \
   "$(gen noranges "$W/noranges.dts" "$DTS/frdm_imxrt1186/config"):$(grep -c '^module LedUnattested count 3 ' "$W/noranges.out")" "0:1"
# A `/delete-node/` line inserted before the leds node: a construct a final
# zephyr.dts never holds and the reader refuses, naming that line. Inserted
# by line with awk (no `\t` in sed, which BSD sed reads as a `t`).
badline=$(grep -n "compatible = \"gpio-leds\"" "$DTS/mps2_an521/zephyr.dts" | cut -d: -f1)
awk -v at="$badline" 'NR == at { print "\t/delete-node/ &led_0;" } { print }' "$DTS/mps2_an521/zephyr.dts" > "$W/bad.dts"
ok "control: a devicetree construct the reader does not admit is refused naming its line" \
   "$(gen bad "$W/bad.dts" "$DTS/mps2_an521/config"):$(grep -c "line $badline:" "$W/bad.out")" "1:1"
awk 'NR == 5 { print "\tstatus = \"maybe\";" } { print }' "$DTS/synthetic/unknown.dts" > "$W/status.dts"
ok "control: a status value that is neither okay nor disabled is refused by name" \
   "$(gen status "$W/status.dts" "$DTS/synthetic/config"):$(grep -c 'status "maybe" is neither' "$W/status.out")" "1:1"
# gpio0's own status line (the one after its compatible) set to disabled
awk '/compatible = "arm,mmio32-gpio"/ { hit = 1 } hit && /status = "okay"/ { sub(/"okay"/, "\"disabled\""); hit = 0 } { print }' "$DTS/synthetic/unknown.dts" > "$W/ctl.dts"
ok "control: an instance whose controller is disabled is refused" \
   "$(gen ctl "$W/ctl.dts" "$DTS/synthetic/config"):$(grep -c 'controller /soc/gpio@40000000 is disabled' "$W/ctl.out")" "1:1"
# led_1's label made "LED0", the label of led_0 in the same module
sed 's|label = "LED1";|label = "LED0";|' "$DTS/synthetic/expander.dts" > "$W/collide.dts"
ok "control: a label that would name two instances of one module by one constant is refused" \
   "$(gen collide "$W/collide.dts" "$DTS/synthetic/config"):$(grep -c 'Led::LED0 would name instance 0 and instance 1' "$W/collide.out")" "1:1"
sed 's|compatible = "synthetic,i2c";|compatible = "synthetic,bridge";|' "$DTS/synthetic/expander.dts" > "$W/bridge.dts"
ok "control: a controller under an unrecognised bus is recorded as bus unknown, unattested" \
   "$(gen bridge "$W/bridge.dts" "$DTS/synthetic/config"):$(grep -c '^LedUnattested	0	led_ext	/soc/i2c@40010000/pcal6416a@20:4	nxp,pcal6416a	unknown	false	unknown	none$' "$W/bridge/board.tsv")" "0:1"
grep -v '^CONFIG_GPIO=y$' "$DTS/mps2_an521/config" > "$W/nogpio.config"
ok "control: with CONFIG_GPIO unset the gpio rows do not apply and the LEDs are unattested" \
   "$(gen nogpio "$DTS/mps2_an521/zephyr.dts" "$W/nogpio.config"):$(count nogpio LedUnattested):$(count nogpio Led)" "0:2:"
# The digest loop of check 1 over a copy of one fixture, perturbed by one
# byte after its digest was recorded: the loop must say MOVED.
mkdir -p "$W/moved/mps2_an521"
cp "$DTS/mps2_an521/config" "$W/moved/mps2_an521/config"
grep 'mps2_an521/config$' "$DTS/digests.txt" > "$W/moved/digests.txt"
printf '\n' >> "$W/moved/mps2_an521/config"
ok "control: a moved fixture digest is noticed by check 1's loop" "$(digests "$W/moved" digests.txt)" "MOVED mps2_an521/config "

echo
echo "board: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ] || exit 1
