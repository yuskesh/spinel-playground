#!/bin/sh
# tests/app/build.sh -- decision 0014 Task 10: glue, the build pipeline, the
# stacks and the inventory.
#
#   KERNEL=... SPINEL_TYPEDUMP=... LLVM_PREFIX=... ZEPHYR_BASE=... \
#   ZEPHYR_SDK_INSTALL_DIR=... sh tests/app/build.sh      # west on the PATH
#
# What is checked, and against what:
#
#   1. The acceptance sample (tests/app/fixtures/build/sample) builds for
#      mps2/an521 through the eleven steps of 0014 §8 and publishes
#      firmware. The published build.json is recomputed: each thread's R
#      and the interrupt chain are the sums of their terms, every term names
#      its evidence kind, the interrupt limit is the image's
#      CONFIG_ISR_STACK_SIZE. The image is read independently of the
#      pipeline (llvm-nm): each stack object is R rounded to the 8-byte
#      stack alignment, and the size word the glue records is R. The
#      evidence is bound to the published DTS and .config (digests
#      recomputed here), and each evidence object is published byte for
#      byte. The vector classification covers every slot after word 0. The
#      link placed .ARM.exidx through Zephyr's script with no orphan
#      warning. Under QEMU the image boots, prints SPC_RUNNING, no failure,
#      and emits telemetry frames (skipped, named, without qemu-system-arm).
#   2. The same source builds for FRDM-MCXN947 with its own overlay. The
#      board's devicetree has no pwm-leds (Task 1), so the Pwm sample's
#      condition does not hold and no Pwm build is made; that is reported.
#   2b. A small application builds for FRDM-IMXRT1186 (decision 0021). Its
#      image boots from FlexSPI NOR, so the vector table follows the boot
#      header inside rom_start; the classification reads it at
#      _vector_table, and the other boards' offset is 0.
#   2c. The same application builds for the board's Cortex-M7 (decision
#      0023): thumbv7em objects; Armv7-M's reserved vector slot 7; the MPU
#      stack guard modelled -- each thread stack object is ROUND_UP(ROUND_UP(R,
#      8) + 64, 64) bytes at a 64-byte boundary, computed here by hand from R,
#      and not the unguarded R rounded to 8 -- and PendSV's reserve, 64, the
#      guard's re-programming chain. The build is a sysbuild with the M33
#      launcher: launcher.bin is published with the digest and offset
#      build.json records, and its vector table is the M33's at 0x1400b000
#      (after the boot header); the application runs in place from the NOR's
#      m7_code_partition (its vector table at 0x04100000, the NOR window plus
#      CONFIG_FLASH_LOAD_OFFSET), with the HyperRAM as zephyr,sram and LPUART1
#      as its console. Its console transport is interrupt-driven
#      (CONFIG_UART_INTERRUPT_DRIVEN from the board's conf): the transport
#      object defines the transmit callback, its frame is not on the transport
#      thread's sum, and the console LPUART is an interrupt source of the
#      inventory with its isr_lpuart reserve. The sample on mps2/an521, where
#      the option comes from Zephyr's board defaults, keeps the polled
#      transport: neither compile carries SPC_UART_TX_IRQ, and there is no
#      callback, while both of the M7's do.
#      The kept failing input of step 10's stack placement
#      (fixtures/build/rt1186/dtcm-at-zero.overlay): the data TCM rebuilt as
#      plain SRAM while zephyr,dtcm still chooses it links the scheduler stack
#      at address 0, which step 10 refuses, naming the RAM and the data TCM.
#      2e and 2f check that the companion's stacks lie in its DTCM.
#   2d. --failure-sites, a debugging aid (fixtures/build/fail-site, a planted
#      overflow of `*` on its line 9): the build publishes the entry's site
#      table, relocated to the application's file and line, and records its
#      stacks as a debugging build's; under QEMU main prints
#      SPC_FAILURE_SITE for the multiplication, and tools/doom/failure-site.rb
#      names app.rb:9. The same source built without the flag prints no
#      such line, publishes no table, its object defines no site global, and
#      its main.c differs from the flag's only by the failure-site lines.
#   2e. The same application with a Spinel companion on the M33
#      (fixtures/build/rt1186/companion.rb, --companion; decision 0027): one
#      sysbuild makes both; build.json's pair id is the digest of the two ids
#      it records, recomputed here; the companion's zephyr.bin is the
#      firmware's launcher.bin; its RAM is its DTCM, it releases the M7, and
#      it has no console; its main.c publishes the pair id and its own id at
#      PRE_KERNEL_1, and the M7's compares the same pair id. The control
#      --mutate-pair-id plants a companion that publishes another pair id
#      while the M7 checks the build's (the board refuses that pair at boot,
#      tests/doom-core/rt1186.sh); a malformed one is a usage error. Refused:
#      a udp: channel beside a companion (owner, 2026-10-26), and
#      --companion on a board whose table names no companion_board.
#   2f. A channel between the pair's cores declared by a contract
#      (fixtures/build/rt1186/channels/console.channel; decision 0027 stage
#      2): producer.rb on the M7 puts, consumer.rb on the M33 gets. The pair
#      id is recomputed over the two ids and the contract's sha256; the
#      companion's main.c writes a one-channel table (a 704-byte header,
#      slots to 3,264; ABI version 5) whose descriptor is the contract's, recomputed from
#      its bytes here; the M7 checks the table and its channel and has no
#      transport; the M7 links the put and the M33 the get. Controls, each
#      kept under fixtures/build/rt1186/controls and refused at step 1 by
#      name, with no firmware: (1) the contract built for mps2_an521, which
#      is neither end; (2) a ptr, an i64 and an f32 field, each with its own
#      code alone; (3) depth 1024, which does not fit the region, with its
#      bytes. A channel only one application names is refused too. The
#      relay (fixtures/build/rt1186/relay.rb, companion.rb's body): the M33,
#      whose application declares the uart: channel, has the console and the
#      M7 none; the M33's main.c prints the M7's lines and watches for its
#      fatal error, which the M7's generated handler records, while 2e's M7,
#      which keeps its console, still prints the ids itself.
#   2g. The doorbell of a contract channel (decision 0028): producer.rb on
#      the M7, woken.rb (relay.rb with `every_ms 10, :relay, wake:
#      :console`) on the M33. Both logs name MU1's GIR0, notify 0x01; the
#      companion writes it into descriptor 0's flags and the M7's check
#      wants the same word; the put writes MU1_B's GCR (0x4423_0114) and
#      calls nothing; the companion has Zephyr's MU driver, MU2 disabled,
#      and MU1_A's interrupt in its inventory with its reserve
#      (isr_mbox_nxp_imx_mu), registers the callback, enables it, and takes
#      a semaphore in place of its sleep; the M7 has no MU driver. The
#      board's controls, planted: --mutate-doorbell-unrung (no GCR write),
#      --mutate-doorbell-unenabled (no mbox_set_enabled) and
#      --mutate-doorbell-notify cm7 (the M7 wants notify 0x09). Refused,
#      with no firmware: wake: naming a channel that is no contract's, on
#      the core that produces it, and on an interrupt entry.
#   3. An application with an accepted provider of its own: compiled,
#      screened, measured, linked; its frame is in the evidence, the report
#      carries it as attestation, and the link map defines the symbol in
#      the measured object.
#   4. Controls, each input kept under tests/app/fixtures/build or as a
#      --mutate-* option of the build command, each refused at the step the
#      plan names, each leaving no firmware:
#        - the scheduler stack allocated at R - 1 (--mutate-stack -1): step 10;
#        - the Adc sampler's stack allocated at R - 1 (--mutate-adapter-stack -1):
#          step 10;
#        - the reserves table without the an521 GPIO ISR row (--mutate-reserves):
#          step 6, a source with no applicable reserve is unknown;
#        - CONFIG_ISR_STACK_SIZE=256, below the chain (--mutate-prj): step 8;
#        - CONFIG_FPU=y on FRDM-MCXN947, which has an FPU (--mutate-prj):
#          step 3 (on mps2/an521, which has none, Kconfig drops the symbol
#          and the .config never carries it -- not a control of ours);
#        - an extra connected handler on IRQ 90 (extra_handler.c linked by
#          --mutate-source): step 10, the slot has no inventory entry;
#        - vector slot 13, architecturally reserved, set non-zero in the
#          staged image (--mutate-reserved-slot 13): step 10;
#        - an enabled node with `interrupts` and a compatible with no irq
#          row (no-irq-row.overlay): unknown inventory, step 6;
#        - a .config value changed between steps 3 and 9 (--mutate-config):
#          step 10;
#        - a period of 150 us under the 100 us tick (bad-period): step 1,
#          naming CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000;
#        - a provider calling k_msleep (screened-provider): step 5, naming
#          z_impl_k_sleep;
#        - a provider calling printk, in no screen set (printk-provider):
#          step 5, naming printk -- a provider's evidence is its own frame,
#          so it may call nothing it does not define;
#        - a linked unit that was never measured (plain_unit.c by
#          --mutate-source, connecting nothing): step 10;
#        - a glue unit that disables an interrupt, and one that calls an
#          entry (glue_irq.c, glue_entry.c by --mutate-glue): step 5 --
#          glue is exempt from the block set only. The first found that
#          irq_disable() on Cortex-M expands to arm_irq_disable, which the
#          screen table did not list until this control tripped;
#        - an entry the kernel refuses (step7-refused, an unbounded loop):
#          step 7, and neither firmware nor staging remains;
#        - an unlisted `# spinel: int64` (decision 0019; an edited copy of
#          divides, which the table lists by its bytes): step 7,
#          naming the application's file and line, not the packed root; and
#          the same refusal with the kernel copied out of the checkout, since
#          the build names this tree's tools/core/int64-allow.tsv to it;
#        - the listed divides passes the int64 gate through its packed root
#          (stopping later, at D3's unattested 64-bit division helper), and
#          the table without its row refuses it again.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools;
# ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on the PATH are required for
# every check here (REQUIRE_ALL=1 makes their absence a failure, otherwise
# the suite skips, named). QEMU_WAIT bounds the boot wait in seconds.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
F="$ROOT/tests/app/fixtures/build"
RUBY="${RUBY:-ruby}"
LIB="$ROOT/tools/app/lib"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
QEMU_WAIT=${QEMU_WAIT:-20}
die() { echo "build: $*" >&2; exit 1; }
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
NM="$(dirname "$CC_BIN")/llvm-nm"
[ -x "$NM" ] || die "no llvm-nm beside $CC_BIN"
export KERNEL SPINEL_TYPEDUMP="$READER" CLANG="$CC_BIN"

W=$(mktemp -d "${TMPDIR:-/tmp}/app-build.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skips=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then echo "  FAIL $1 (REQUIRE_ALL=1; $2 checks)"; fail=$((fail + $2)); else echo "  skip $1 ($2 checks)"; skips=$((skips + $2)); fi; }
rb() { "$RUBY" -rjson -rdigest -e "$@"; }
sha() { "$RUBY" -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$1"; }

if [ -z "${ZEPHYR_BASE:-}" ] || [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || ! command -v west >/dev/null 2>&1; then
  skipped "the Zephyr environment (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR, west): every check of this suite" 40
  echo
  echo "build: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
  [ "$fail" = 0 ] || exit 1
  exit 0
fi

# build NAME [build options...] -> exit status; the log at $W/NAME.out, the
# output under $W/NAME
build() { n=$1; shift; "$TOOL" build --out "$W/$n" "$@" > "$W/$n.out" 2>&1 && echo 0 || echo $?; }
refused() { sed -n 's/^REFUSED: //p' "$W/$1/build.log" | head -1; }
nofw() { [ -e "$W/$1/firmware" ] && echo firmware || { [ -e "$W/$1/.staging" ] && echo staging || echo none; }; }

echo "build: 1. the acceptance sample on mps2/an521"
t0=$(date +%s)
rc=$(build sample --app "$F/sample/app.rb" --board mps2_an521 --board-overlay "$F/mps2_an521.overlay")
echo "  (sample build: $(( $(date +%s) - t0 )) s)"
ok "the sample builds and publishes firmware" "$rc:$(ls "$W/sample/firmware" 2>/dev/null | tr '\n' ' ')" \
   "0:board build.json config evidence link.log main.c objects report_command_poll.json report_report.json report_sample.json zephyr.dts zephyr.elf zephyr.map "
[ "$rc" = 0 ] || { echo "  --- $W/sample.out"; tail -5 "$W/sample.out"; die "the sample did not build; the rest of this suite reads its output"; }
FW="$W/sample/firmware"
ok "no staging remains after publication" "$([ -e "$W/sample/.staging" ] && echo staging || echo none)" none
# build.json recomputed
ok "every thread requirement and the interrupt chain are the sums of their terms; every verdict passes" \
   "$(rb 'b = JSON.parse(File.read(ARGV[0]))["stacks"]; t = b["threads"].map { |x| [x["name"], x["requirement"] == x["terms"].sum { |y| y["bytes"] }, x["verdict"]] }
          i = b["interrupt"]; puts (t + [["interrupt", i["requirement"] == i["chain"].sum { |y| y["bytes"] }, i["verdict"]]] + b["gates"].map { |g| [g["name"], true, g["verdict"]] }).map { |n, s, v| "#{n}=#{s}/#{v}" }.join(" ")' "$FW/build.json")" \
   "scheduler thread=true/pass transport thread=true/pass adc_sampler thread=true/pass interrupt=true/pass no FPU=true/pass" # the no-FPU gate cannot fail here: step 3 refuses the same condition first (the fpu-on-frdm control)
ok "every term names its evidence kinds (measurement, attestation, or the kernel's composite for an entry's kernel_stack); the interrupt limit is the image's CONFIG_ISR_STACK_SIZE" \
   "$(rb 'b = JSON.parse(File.read(ARGV[0]))["stacks"]; kinds = (b["threads"].flat_map { |x| x["terms"] } + b["interrupt"]["chain"]).flat_map { |y| y["evidence"].split("+") }.uniq.sort
          isr = File.read(ARGV[1])[/^CONFIG_ISR_STACK_SIZE=(\d+)$/, 1].to_i; puts "#{kinds.join(",")}:#{b["interrupt"]["limit"] == isr}"' "$FW/build.json" "$FW/config")" "attestation,declaration,measurement,static_proof:true"
ok "the interrupt chain carries the nested-entry hardware frame explicitly on every level above the lowest, and not on the lowest" \
   "$(rb 'c = JSON.parse(File.read(ARGV[0]))["stacks"]["interrupt"]["chain"]; puts c.each_with_index.map { |t, k| (t["detail"].include?("nested entry") == (k > 0)).to_s }.uniq.join' "$FW/build.json")" true
RS=$(rb 'puts JSON.parse(File.read(ARGV[0]))["stacks"]["threads"].find { |t| t["name"] == "scheduler thread" }["requirement"]' "$FW/build.json")
RT=$(rb 'puts JSON.parse(File.read(ARGV[0]))["stacks"]["threads"].find { |t| t["name"] == "transport thread" }["requirement"]' "$FW/build.json")
RA=$(rb 'puts JSON.parse(File.read(ARGV[0]))["stacks"]["threads"].find { |t| t["name"] == "adc_sampler thread" }["requirement"]' "$FW/build.json")
echo "  (R: scheduler $RS, transport $RT, adc_sampler $RA)"
ok "the Adc sampler thread has a requirement of its own: the unit's frames, the attested driver read path and kernel calls, the guard and the switch; no thread is unbudgeted" \
   "$(rb 'b = JSON.parse(File.read(ARGV[0])); t = b["stacks"]["threads"].find { |x| x["name"] == "adc_sampler thread" }; puts "#{t["verdict"]}:#{t["terms"].map { |x| x["name"] }.join(",")}:#{b["threads_unbudgeted"].size}:#{b["adapter_threads"].map { |a| a["object"] }.join}"' "$FW/build.json")" \
   "pass:adc_sampler frames,drv_adc_read,thread_kernel_calls,guard_area,thread_switch:0:spc_adc_stack"
# the image, read with llvm-nm independently of the pipeline
sizes() { "$NM" -S "$FW/zephyr.elf" | "$RUBY" -e 'l = STDIN.read.lines.map(&:split).find { |a| a[3] == ARGV[0] }; puts l ? l[1].to_i(16) : "absent"' "$1"; }
ok "the stack objects in the image are R rounded up to the 8-byte stack alignment (llvm-nm -S), the sampler's among them" \
   "$(sizes spc_scheduler_stack):$(sizes spc_transport_stack):$(sizes spc_adc_stack)" "$(( (RS + 7) / 8 * 8 )):$(( (RT + 7) / 8 * 8 )):$(( (RA + 7) / 8 * 8 ))"
ok "the size words the glue records read back as R from the image's rodata" \
   "$("$RUBY" -ropen3 -e '
      elf, nm, objcopy, readelf = ARGV
      syms = Open3.capture2(nm, "-S", elf).first.lines.map(&:split).select { |a| a.size == 4 }.to_h { |a| [a[3], [a[0].to_i(16), a[1].to_i(16)]] }
      base = Open3.capture2(readelf, "-S", "-W", elf).first.lines.filter_map { |l| l[/\]\s+rodata\s+\S+\s+([0-9a-f]+)/, 1] }.first.to_i(16)
      Open3.capture2(objcopy, "--dump-section", "rodata=" + elf + ".rodata.test", elf, "/dev/null")
      rod = File.binread(elf + ".rodata.test")
      puts %w[spc_scheduler_stack_size spc_transport_stack_size spc_adc_stack_size].map { |s| a, n = syms.fetch(s); n == 4 ? rod[a - base, 4].unpack1("V") : "size#{n}" }.join(":")' \
      "$FW/zephyr.elf" "$NM" "$(dirname "$CC_BIN")/llvm-objcopy" "$(dirname "$CC_BIN")/llvm-readelf")" "$RS:$RT:$RA"
# evidence and objects
ok "every evidence file is bound to the published DTS and .config (digests recomputed), and names an object published byte for byte" \
   "$(rb 'd, c = Digest::SHA256.file(ARGV[1]).hexdigest, Digest::SHA256.file(ARGV[2]).hexdigest
          r = Dir[ARGV[0] + "/evidence/*.json"].sort.map { |f| e = JSON.parse(File.read(f)); o = ARGV[0] + "/objects/" + File.basename(e["object"]["file"])
            e["dts_sha256"] == d && e["config_sha256"] == c && File.file?(o) && Digest::SHA256.file(o).hexdigest == e["object"]["sha256"] }
          puts "#{r.size}:#{r.uniq.inspect}"' "$FW" "$FW/zephyr.dts" "$FW/config")" "8:[true]"
ok "each report lists the five declared externs, calls the ones its entry names (sites > 0), every one with attested stack evidence, and extern_effects passes" \
   "$(rb 'puts Dir[ARGV[0] + "/report_*.json"].sort.map { |f| r = JSON.parse(File.read(f)); x = r["application"]["externs"]
          "#{r["entry"]}=#{x.size}/#{x.count { |e| e["sites"] > 0 }}/#{x.map { |e| e["stack"]["evidence"] }.uniq.join("+")}/#{r["properties"]["extern_effects"]["verdict"]}" }.join(" ")' "$FW")" \
   "command_poll=5/1/attestation/pass report=5/3/attestation/pass sample=5/1/attestation/pass"
# the vector table
ok "the vector classification covers every slot after word 0 (15 exceptions + CONFIG_NUM_IRQS), with 17 budgeted sources and 4 reserved slots" \
   "$(rb 'v = JSON.parse(File.read(ARGV[0]))["vector_slots"]; n = File.read(ARGV[1])[/^CONFIG_NUM_IRQS=(\d+)$/, 1].to_i
          puts "#{v.values.sum == 15 + n}:#{v["budgeted"]}:#{v["reserved"]}"' "$FW/build.json" "$FW/config")" "true:17:4"
ok "the inventory of build.json has 17 sources, each naming its reserve item, and the budgeted slots are exactly them; the absent drivers are listed" \
   "$(rb 'b = JSON.parse(File.read(ARGV[0])); i = b["inventory"]; puts "#{i.size}:#{i.all? { |s| s["reserve"].to_s != "" }}:#{i.size == b["vector_slots"]["budgeted"]}:#{b["absent_drivers"].size > 0}"' "$FW/build.json")" "17:true:true:true"
ok "the memory figures are the image's writable sections (llvm-size's data and bss), under the board's RAM" \
   "$(rb 'm = JSON.parse(File.read(ARGV[0]))["memory"]; sz = ARGV[1].split; puts "#{m["data"] == sz[1].to_i && m["bss"] == sz[2].to_i}:#{m["data"] + m["bss"] < m["limit"]}"' "$FW/build.json" "$("$(dirname "$CC_BIN")/llvm-size" "$FW/zephyr.elf" | tail -1)")" "true:true"
# .ARM.exidx
ok "the link log has no orphan-section warning, and the map places .ARM.exidx as an output section holding our objects' entries" \
   "$(grep -c 'orphan' "$FW/link.log" || true):$(grep -c '^\.ARM\.exidx' "$FW/zephyr.map"):$(grep -c '^ \.ARM\.exidx\.text\.spc_' "$FW/zephyr.map" | awk '{print ($1 > 0) ? "ours" : $1}')" "0:1:ours"
# QEMU
# the QEMU the configured build's own cache names (QEMU:FILEPATH, published
# in build.json), not a guess at the SDK's layout
QEMU=$(rb 'puts JSON.parse(File.read(ARGV[0]))["qemu"].to_s' "$FW/build.json")
if [ -n "$QEMU" ] && [ -x "$QEMU" ]; then
  # the board.cmake flags of mps2/an521 (boards/arm/mps2/board.cmake at the
  # pinned commit) without the second serial's pty. The console exists before
  # QEMU starts: the background command's redirection is made in the child,
  # and the wait loop below may read the file first
  : > "$W/sample.console"
  "$QEMU" -cpu cortex-m33 -machine mps2-an521 -m 16 -vga none -net none -nographic -icount shift=7,align=off,sleep=off -rtc clock=vm \
    -chardev stdio,id=con,mux=on -serial chardev:con -mon chardev=con,mode=readline -chardev null,id=hostS0 -serial chardev:hostS0 \
    -kernel "$FW/zephyr.elf" < /dev/null > "$W/sample.console" 2>&1 &
  qpid=$!
  i=0
  while [ "$i" -lt "$QEMU_WAIT" ] && [ "$(wc -c < "$W/sample.console")" -lt 4096 ]; do sleep 1; i=$((i + 1)); done
  kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
  ok "under QEMU the sample boots, prints SPC_RUNNING, records no failure and no init failure" \
     "$(grep -c 'SPC_RUNNING app' "$W/sample.console" || true):$(grep -c -e SPC_FAIL -e SPC_INIT_FAILED "$W/sample.console" || true)" "1:0"
  # computed into a variable before the call, and compared afterwards:
  # bash 3.2 (macOS /bin/sh) evaluates a multi-line command substitution a
  # second time, quoting lost, when it holds an index with a comma beside a
  # nested double quote and is passed as a function argument (the macOS implementer,
  # Task 10 Mac run; the plan's Target facts). The Ruby below has no
  # interpolation left, and its indexing sits in a function's body, called
  # only in an assignment: do not move it into an argument.
  #
  # The frames are decoded up to where QEMU's own message begins
  # (`qemu-system...`, which the kill makes it print), each in full: header
  # and six payload bytes. What is left before that message is the run's end
  # when it is nothing, or the prefix of one frame the kill cut (0xA5,
  # channel 0, length 6, fewer than nine bytes); anything else is named. A
  # cut frame followed by another frame is not an end, and is named too.
  decode_frames() {
    "$RUBY" -e 'b = File.binread(ARGV[0]).b; i = b.index("SPC_RUNNING app") or abort "no banner"; i = b.index("\xA5".b, i) or abort "no frame"
                stop = b.index("qemu-system".b, i) || b.bytesize
                n = 0; while i + 9 <= stop && b.getbyte(i) == 0xA5 && b.getbyte(i + 1) == 0 && b.getbyte(i + 2) == 6; n += 1; i += 9; end
                rest = b.byteslice(i, stop - i)
                cut = rest.bytesize < 9 && rest.bytes.first(3) == [0xA5, 0, 6].first(rest.bytesize)
                tail = rest.empty? || cut ? "to the end" : "then " + rest.byteslice(0, 9).unpack1("H*")
                puts n >= 10 ? "frames:" + tail : "only " + n.to_s' "$1" 2>&1 || true
  }
  frames=$(decode_frames "$W/sample.console")
  ok "the console after the banner decodes as a run of well-formed telemetry frames (0xA5, channel 0, length 6, six payload bytes), at least ten of them" "$frames" "frames:to the end"
  # the decoder's own controls, each a planted console: ten frames, then
  # QEMU's message right after a frame the kill cut (the run's end), or a cut
  # frame followed by another frame (not an end)
  "$RUBY" -e 'f = ->(k) { [0xA5, 0, 6].pack("C*") + [k, 1, 2, 3, 4, 5].pack("C*") }
              head = "SPC_RUNNING app\r\n".b + (0...10).map { |k| f.(k) }.join
              File.binwrite(ARGV[0], head + f.(10).byteslice(0, 5) + "qemu-system-arm: terminating on signal 15\n".b)
              File.binwrite(ARGV[1], head + f.(10).byteslice(0, 5) + f.(11) + "qemu-system-arm: terminating on signal 15\n".b)' \
    "$W/qemu-cut-end.console" "$W/qemu-cut-frame.console"
  frames=$(decode_frames "$W/qemu-cut-end.console")
  ok "  control: a last frame the kill cut, QEMU's message right after it, is the run's end" "$frames" "frames:to the end"
  frames=$(decode_frames "$W/qemu-cut-frame.console")
  ok "  control: a cut frame followed by another frame is named, not an end" "$(echo "$frames" | cut -c1-12)" "frames:then "
else
  skipped "QEMU: the build's CMake cache names no runnable QEMU:FILEPATH" 2
fi

ok "tools/app/zephyr/v4.4.2/dropped-flags.txt and the cross fixture's list are the same flags (comments aside)" \
   "$(rb 'a, b = ARGV.map { |f| File.readlines(f, chomp: true).reject { |l| l.start_with?("#") || l.empty? } }; puts a == b ? "same:#{a.size}" : "differ: #{(a - b + (b - a)).inspect}"' "$ROOT/tools/app/zephyr/v4.4.2/dropped-flags.txt" "$ROOT/tests/app/fixtures/cross/dropped-flags.txt")" "same:$(grep -vc '^#\|^$' "$ROOT/tests/app/fixtures/cross/dropped-flags.txt")"

echo "build: 2. FRDM-MCXN947"
t0=$(date +%s)
rc=$(build frdm --app "$F/sample/app.rb" --board frdm_mcxn947 --board-overlay "$F/frdm_mcxn947.overlay")
echo "  (FRDM build: $(( $(date +%s) - t0 )) s)"
ok "the sample builds for frdm_mcxn947 and publishes firmware with passing stack verdicts" \
   "$rc:$(rb 'b = JSON.parse(File.read(ARGV[0]))["stacks"]; puts (b["threads"] + [b["interrupt"]] + b["gates"]).map { |x| x["verdict"] }.uniq.join' "$W/frdm/firmware/build.json" 2>/dev/null || echo nobuild)" "0:pass"
ok "FRDM: the vector classification covers every slot (15 + CONFIG_NUM_IRQS)" \
   "$(rb 'v = JSON.parse(File.read(ARGV[0]))["vector_slots"]; n = File.read(ARGV[1])[/^CONFIG_NUM_IRQS=(\d+)$/, 1].to_i; puts v.values.sum == 15 + n' "$W/frdm/firmware/build.json" "$W/frdm/firmware/config" 2>/dev/null || echo nobuild)" true
ok "FRDM: the board's devicetree has no pwm-leds, so the Pwm sample's condition does not hold (no Pwm build is made)" \
   "$(grep -c 'compatible = "pwm-leds"' "$W/frdm/firmware/zephyr.dts" 2>/dev/null || true)" 0

echo "build: 2b. FRDM-IMXRT1186 (decision 0021)"
# The image boots from FlexSPI NOR, so the boot header comes first in
# rom_start and the vector table follows it: the classification must read the
# table at _vector_table, not at the section's start.
t0=$(date +%s)
rc=$(build rt1186 --app "$F/rt1186/app.rb" --board frdm_imxrt1186)
echo "  (RT1186 build: $(( $(date +%s) - t0 )) s)"
ok "the RT1186 application builds for frdm_imxrt1186 and publishes firmware with passing stack verdicts" \
   "$rc:$(rb 'b = JSON.parse(File.read(ARGV[0]))["stacks"]; puts (b["threads"] + [b["interrupt"]] + b["gates"]).map { |x| x["verdict"] }.uniq.join' "$W/rt1186/firmware/build.json" 2>/dev/null || echo nobuild)" "0:pass"
ok "RT1186: the vector classification covers every slot (15 + CONFIG_NUM_IRQS), read past the boot header" \
   "$("$RUBY" -rjson -I"$ROOT/tools/app/lib" -e 'require "core_app/inventory"; v = JSON.parse(File.read(ARGV[0]))["vector_slots"]; n = File.read(ARGV[1])[/^CONFIG_NUM_IRQS=(\d+)$/, 1].to_i
      off = CoreApp::Inventory.vector_table_offset(ARGV[2], symbols_tool: ARGV[3]); puts "#{v.values.sum == 15 + n}:#{off.positive?}"' \
      "$W/rt1186/firmware/build.json" "$W/rt1186/firmware/config" "$W/rt1186/firmware/zephyr.elf" "$ROOT/tools/core/object-symbols" 2>/dev/null || echo nobuild)" "true:true"
ok "the other boards' vector tables start rom_start: the offset is 0 for the mps2/an521 and FRDM-MCXN947 samples" \
   "$("$RUBY" -I"$ROOT/tools/app/lib" -e 'require "core_app/inventory"; puts ARGV[0..1].map { |e| CoreApp::Inventory.vector_table_offset(e, symbols_tool: ARGV[2]) }.join(":")' \
      "$W/sample/firmware/zephyr.elf" "$W/frdm/firmware/zephyr.elf" "$ROOT/tools/core/object-symbols" 2>/dev/null || echo nobuild)" "0:0"

echo "build: 2c. FRDM-IMXRT1186's Cortex-M7 (decision 0023)"
t0=$(date +%s)
rc=$(build rt1186cm7 --app "$F/rt1186/app.rb" --board frdm_imxrt1186_cm7)
echo "  (RT1186 M7 build: $(( $(date +%s) - t0 )) s)"
M7=$W/rt1186cm7/firmware
ok "the RT1186 application builds for frdm_imxrt1186_cm7, thumbv7em, with passing stack verdicts" \
   "$rc:$(rb 'b = JSON.parse(File.read(ARGV[0])); s = b["stacks"]; puts "#{b["target"]}:#{(s["threads"] + [s["interrupt"]] + s["gates"]).map { |x| x["verdict"] }.uniq.join}"' "$M7/build.json" 2>/dev/null || echo nobuild)" \
   "0:frdm_imxrt1186/mimxrt1186/cm7:pass"
ok "M7: the units are thumbv7em (the evidence names the target) and the configuration has the MPU stack guard, no PSPLIM guard" \
   "$(rb 'puts Dir[File.join(ARGV[0], "evidence", "*.json")].map { |f| JSON.parse(File.read(f))["target"] }.uniq.join(",")' "$M7" 2>/dev/null):$(grep -cE '^CONFIG_MPU_STACK_GUARD=y$' "$M7/config"):$(grep -c '^CONFIG_BUILTIN_STACK_GUARD=y$' "$M7/config" || true)" \
   "thumbv7em-unknown-none-eabi:1:0"
ok "M7: slot 7 is a reserved position (Armv7-M has no SecureFault), and every slot is classified" \
   "$(rb 'v = JSON.parse(File.read(ARGV[0]))["vector_slots"]; n = File.read(ARGV[1])[/^CONFIG_NUM_IRQS=(\d+)$/, 1].to_i; puts "#{v["reserved"]}:#{v.values.sum == 15 + n}"' "$M7/build.json" "$M7/config" 2>/dev/null || echo nobuild)" "5:true"
# R per thread from build.json, the objects from the image's symbols
"$ROOT/tools/core/object-symbols" --addresses --defined "$M7/zephyr.elf" > "$W/rt1186cm7.syms" 2>/dev/null || true
ok "M7: each thread stack object is R rounded to 8, plus the 64-byte guard, rounded to 64, at a 64-byte boundary -- and so not R rounded to 8" \
   "$(rb 'r = JSON.parse(File.read(ARGV[0]))["stacks"]["threads"].to_h { |t| [t["name"], t["requirement"]] }
          syms = File.read(ARGV[1]).lines.to_h { |l| a, z, _t, n = l.chomp.split("\t", 4); [n, [a.to_i(16), z.to_i(16)]] }
          out = { "scheduler thread" => "spc_scheduler_stack", "transport thread" => "spc_transport_stack" }.map do |t, sym|
            a, z = syms[sym]; want = ((r[t] + 7) / 8 * 8 + 64 + 63) / 64 * 64
            "#{z == want}#{a % 64 == 0}#{z != (r[t] + 7) / 8 * 8}"
          end
          puts out.join(":")' "$M7/build.json" "$W/rt1186cm7.syms" 2>/dev/null || echo nobuild)" \
   "truetruetrue:truetruetrue"
ok "M7: the launcher is published, the file build.json's digest names, at NOR offset 0, for the M33" \
   "$(rb 'l = JSON.parse(File.read(ARGV[0]))["launcher"] || {}; puts "#{l["board"]}:#{l["offset"]}:#{l["sha256"] == Digest::SHA256.file(ARGV[1]).hexdigest}"' "$M7/build.json" "$M7/launcher.bin" 2>/dev/null || echo nobuild)" \
   "frdm_imxrt1186/mimxrt1186/cm33:0:true"
ok "M7: the two vector tables -- the launcher's after the M33's boot header, the application's at the NOR window plus its load offset" \
   "$("$NM" "$M7/launcher.elf" 2>/dev/null | awk '$3 == "_vector_table" { print $1 }'):$("$NM" "$M7/zephyr.elf" 2>/dev/null | awk '$3 == "_vector_table" { print $1 }'):$(grep -E '^CONFIG_FLASH_(BASE_ADDRESS|LOAD_OFFSET)=' "$M7/config" | LC_ALL=C sort | cut -d= -f2 | tr '\n' ' ')" \
   "1400b000:04100000:0x4000000 0x100000 "
ok "M7: the HyperRAM is zephyr,sram and LPUART1 the console (the board's overlay)" \
   "$(grep -cE 'zephyr,sram = &hyperram0;|zephyr,console = &lpuart1;' "$M7/zephyr.dts"):$(grep -c '^CONFIG_SRAM_BASE_ADDRESS=0x28000000$' "$M7/config")" "2:1"
ok "M7: the console transport is interrupt-driven: the configuration, the transmit callback, kept off the thread's sum, and the console LPUART an inventory source with isr_lpuart" \
   "$(grep -c '^CONFIG_UART_INTERRUPT_DRIVEN=y$' "$M7/config"):$("$NM" "$M7/zephyr.elf" 2>/dev/null | awk '$3 == "spc_transport_uart_isr" { n++ } END { print n + 0 }'):$(rb 'b = JSON.parse(File.read(ARGV[0])); t = b["stacks"]["threads"].find { |x| x["name"] == "transport thread" }; on = t["terms"].any? { |x| x["detail"].to_s.include?("spc_transport_uart_isr") }; src = b["inventory"].count { |x| x["reserve"] == "isr_lpuart" }; puts "#{on ? "on" : "off"}:#{src}"' "$M7/build.json" 2>/dev/null)" \
   "1:1:off:1"
ok "M7: its own conf asks for the interrupt, so both of the transport's compiles carry SPC_UART_TX_IRQ" \
   "$(grep 'transport_uart\.c' "$W/rt1186cm7/build.log" 2>/dev/null | grep -c -- ' -DSPC_UART_TX_IRQ')" 2
ok "control: the sample on mps2/an521, whose Zephyr defaults also enable CONFIG_UART_INTERRUPT_DRIVEN, keeps the polled transport: no SPC_UART_TX_IRQ, no transmit callback" \
   "$(grep -c '^CONFIG_UART_INTERRUPT_DRIVEN=y$' "$FW/config"):$(grep 'transport_uart\.c' "$W/sample/build.log" 2>/dev/null | grep -c -- ' -DSPC_UART_TX_IRQ'):$("$NM" "$FW/zephyr.elf" 2>/dev/null | awk '$3 == "spc_transport_uart_isr" { n++ } END { print n + 0 }')" \
   "1:0:0"
ok "M7: the interrupt chain charges PendSV the guard's 64 bytes" \
   "$(rb 's = JSON.parse(File.read(ARGV[0]))["stacks"]["interrupt"]["chain"]; puts s.select { |t| t["name"].end_with?(": pendsv") }.map { |t| t["bytes"] }.join(",")' "$M7/build.json" 2>/dev/null || echo nobuild)" "64"
# the kept failing input of step 10's stack placement: the data TCM rebuilt as
# plain SRAM while zephyr,dtcm still chooses it puts the scheduler stack at 0
rc=$(build rt1186dz --app "$F/rt1186/app.rb" --board frdm_imxrt1186_cm7 --board-overlay "$F/rt1186/dtcm-at-zero.overlay")
ok "control: a scheduler stack linked at address 0, in neither the RAM nor the data TCM, is refused at step 10, naming both; no firmware" \
   "$rc:$(refused rt1186dz | grep -c "step 10: the image's spc_scheduler_stack object is at 0\.\.0x140, in none of the RAM (CONFIG_SRAM_BASE_ADDRESS) 0x28000000\.\.0x28800000 and the data TCM (zephyr,dtcm) 0x20000000\.\.0x20040000"):$(nofw rt1186dz)" "1:1:none"
echo "build: 2d. --failure-sites (a planted overflow)"
FS="$F/fail-site/app.rb"
rc_on=$(build fs-on --app "$FS" --board mps2_an521 --failure-sites)
rc_off=$(build fs-off --app "$FS" --board mps2_an521)
ok "the planted application builds with and without --failure-sites" "$rc_on:$rc_off" "0:0"
mul=$(awk -F'\t' '$6 == "checked *" { print $1 ":" $2 ":" $3; exit }' "$W/fs-on/firmware/sites/step.tsv" 2>/dev/null)
ok "the published table names the multiplication at the application's own line 9" "${mul#*:}" "$FS:9"
ok "build.json records the build's stacks as a debugging build's" \
   "$(rb 'puts JSON.parse(File.read(ARGV[0])).dig("failure_sites", "stacks").to_s.start_with?("debug:")' "$W/fs-on/firmware/build.json" 2>/dev/null || echo nobuild)" true
ok "without the flag: no table, no failure_sites in build.json, no site global in the entry's object" \
   "$([ -e "$W/fs-off/firmware/sites" ] && echo table || echo none):$(rb 'puts JSON.parse(File.read(ARGV[0])).key?("failure_sites")' "$W/fs-off/firmware/build.json"):$("$NM" "$W/fs-off/firmware/objects/core_step.o" | grep -c failure_site)" "none:false:0"
ok "the two main.c differ only by the failure-site lines" \
   "$(rb 'on = File.readlines(ARGV[0]); off = File.readlines(ARGV[1]); left = off.tally; extra = []
          on.each { |l| left[l].to_i > 0 ? left[l] -= 1 : extra << l }
          other = extra.reject { |l| l =~ /spc_fs|failure|k_thread_priority_set|k_msleep|\A\s*[{}]\s*\z|\A\s*(\/\*|\*)/ || l.strip.empty? }
          puts "missing=#{left.values.sum} other=#{other.size} added=#{extra.size > 0}"' "$W/fs-on/firmware/main.c" "$W/fs-off/firmware/main.c")" "missing=0 other=0 added=true"
if [ -n "$QEMU" ] && [ -x "$QEMU" ]; then
  for m in on off; do
    "$QEMU" -cpu cortex-m33 -machine mps2-an521 -m 16 -vga none -net none -nographic -icount shift=7,align=off,sleep=off -rtc clock=vm \
      -chardev stdio,id=con,mux=on -serial chardev:con -mon chardev=con,mode=readline -chardev null,id=hostS0 -serial chardev:hostS0 \
      -kernel "$W/fs-$m/firmware/zephyr.elf" < /dev/null > "$W/fs-$m.console" 2>&1 &
    qpid=$!
    i=0
    while [ "$i" -lt "$QEMU_WAIT" ] && ! grep -aq SPC_FAILURE_SITE "$W/fs-$m.console"; do sleep 1; i=$((i + 1)); done
    kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
  done
  ok "under QEMU, with the flag: SPC_FAILURE_SITE names step, ARITHMETIC and the multiplication's site" \
     "$(grep -a -o 'SPC_FAILURE_SITE [^ ]* [0-9]* [0-9]*' "$W/fs-on.console" | head -1)" "SPC_FAILURE_SITE step 2 ${mul%%:*}"
  ok "  and tools/doom/failure-site.rb names app.rb:9" \
     "$("$RUBY" "$ROOT/tools/doom/failure-site.rb" --firmware "$W/fs-on/firmware" < "$W/fs-on.console")" \
     "step: $FS:9: ARITHMETIC: checked * (failure site ${mul%%:*}, column 11)"
  ok "without the flag the same run prints no such line" \
     "$(grep -ac 'SPC_RUNNING app' "$W/fs-off.console"):$(grep -ac SPC_FAILURE_SITE "$W/fs-off.console")" "1:0"
else
  skipped "the --failure-sites runs under QEMU (no QEMU in build.json)" 3
fi

echo "build: 2e. a Spinel companion on the M33 (decision 0027)"
t0=$(date +%s)
rc=$(build rt1186pair --app "$F/rt1186/app.rb" --board frdm_imxrt1186_cm7 --companion "$F/rt1186/companion.rb")
echo "  (RT1186 pair build: $(( $(date +%s) - t0 )) s)"
PM=$W/rt1186pair/firmware
PC=$W/rt1186pair/companion/firmware
# the pair id recomputed here from the two ids build.json records
ok "pair: both images build; build.json's pair id is the digest of the two ids, each its own 16 hex digits; the companion is frdm_imxrt1186_cm33_amp's" \
   "$rc:$(rb 'p = JSON.parse(File.read(ARGV[0]))["pair"] || {}; c = p["companion"] || {}
              want = Digest::SHA256.hexdigest("spinel-pair 1\nprimary #{p["primary"]}\ncompanion #{c["id"]}\n")[0, 16]
              puts "#{p["id"] == want}:#{[p["primary"], c["id"]].all? { |x| x.to_s.match?(/\A\h{16}\z/) } && p["primary"] != c["id"]}:#{c["board"]}"' "$PM/build.json" 2>/dev/null || echo nobuild)" \
   "0:true:true:frdm_imxrt1186_cm33_amp"
ok "pair: the companion's zephyr.bin is the firmware's launcher.bin, the file build.json's digest names" \
   "$(rb 'l = JSON.parse(File.read(ARGV[0]))["launcher"] || {}; puts "#{l["companion"]}:#{l["sha256"] == Digest::SHA256.file(ARGV[1]).hexdigest}"' "$PM/build.json" "$PM/launcher.bin" 2>/dev/null || echo nobuild):$(cmp -s "$PM/launcher.bin" "$PC/zephyr.bin" && echo same || echo differ)" \
   "true:true:same"
# a stack the linker put outside the companion's RAM ran nowhere: the
# companion's table once kept zephyr,dtcm and its stack went to address 0
instack() { # elf symbol... -> each "symbol:in" when within 0x3000_0000 + 128 KB, the companion's DTCM
  e=$1; shift
  "$NM" -S "$e" 2>/dev/null | "$RUBY" -e 'syms = STDIN.read.lines.to_h { |l| a, z, _t, n = l.split; [n, [a.to_i(16), z.to_i(16)]] }
    puts ARGV.map { |s| a, z = syms[s]; "#{s}:#{a && a >= 0x30000000 && a + z <= 0x30020000 ? "in" : "out"}" }.join(" ") + " "' "$@"
}
ok "pair: the companion's scheduler stack lies in its DTCM, where its RAM is" "$(instack "$PC/zephyr.elf" spc_scheduler_stack)" "spc_scheduler_stack:in "
ok "pair: the companion's RAM is its DTCM, it releases the M7 and has no console" \
   "$(grep -cE '^CONFIG_SRAM_BASE_ADDRESS=0x30000000$|^CONFIG_SECOND_CORE_MCUX=y$' "$PC/config" 2>/dev/null):$(grep -c '^CONFIG_CONSOLE=y$' "$PC/config" 2>/dev/null || true)" "2:0"
# the words each image's glue carries, against build.json's ids
words() { rb 'h = ARGV[0].to_s; puts h.size == 16 ? "0x#{h[0, 8]}u 0x#{h[8, 8]}u" : "none"' "$1"; }
pid=$(rb 'puts JSON.parse(File.read(ARGV[0])).dig("pair", "id")' "$PM/build.json" 2>/dev/null)
cid=$(rb 'puts JSON.parse(File.read(ARGV[0])).dig("pair", "companion", "id")' "$PM/build.json" 2>/dev/null)
pairwords() { # main.c -> "<pair words> <companion words>" the glue stores or compares
  rb 's = File.read(ARGV[0]); g = ->(n) { s[/SPC_RING_W_#{n}, (0x\h{8}u)\)/, 1] || "-" }
      c = s[/phi != (0x\h{8}u) \|\| plo != (0x\h{8}u)/] ? [$1, $2] : nil
      puts(c ? c.join(" ") : [g.("PAIR_HI"), g.("PAIR_LO"), g.("COMPANION_HI"), g.("COMPANION_LO")].join(" "))' "$1" 2>/dev/null || echo nobuild
}
ok "pair: the companion publishes build.json's pair id and its own id at PRE_KERNEL_1, and the M7 checks build.json's pair id" \
   "$(pairwords "$PC/main.c"):$(grep -c 'SYS_INIT(spc_pair_publish, PRE_KERNEL_1, 0);' "$PC/main.c" 2>/dev/null):$(pairwords "$PM/main.c")" \
   "$(words "$pid") $(words "$cid"):1:$(words "$pid")"
# the control: the build plants a companion that publishes another pair id
PLANT=fedcba9876543210
rc=$(build rt1186pairx --app "$F/rt1186/app.rb" --board frdm_imxrt1186_cm7 --companion "$F/rt1186/companion.rb" --mutate-pair-id "$PLANT")
PX=$W/rt1186pairx/firmware
xid=$(rb 'puts JSON.parse(File.read(ARGV[0])).dig("pair", "id")' "$PX/build.json" 2>/dev/null)
ok "control --mutate-pair-id: the companion publishes the planted id, the M7 still checks the build's, so the two images disagree" \
   "$rc:$(pairwords "$W/rt1186pairx/companion/firmware/main.c" | cut -d' ' -f1,2):$(pairwords "$PX/main.c"):$([ "$xid" != "$PLANT" ] && echo differs)" \
   "0:$(words "$PLANT"):$(words "$xid"):differs"
ok "  and the build's log names the control" "$(grep -c "\[4\] pair: control: the companion publishes $PLANT" "$W/rt1186pairx/build.log" 2>/dev/null)" 1
rc=$("$TOOL" build --out "$W/pairbad" --app "$F/rt1186/app.rb" --board frdm_imxrt1186_cm7 --companion "$F/rt1186/companion.rb" --mutate-pair-id xyz > "$W/pairbad.out" 2>&1 && echo 0 || echo $?)
ok "  --mutate-pair-id that is not 16 hexadecimal digits is a usage error" "$rc:$(grep -c 'is 16 hexadecimal digits' "$W/pairbad.out")" "2:1"
# refusals, each planted here
rc=$(build pairudp --app "$ROOT/tests/app/fixtures/udp/app.rb" --board frdm_imxrt1186_cm7 --companion "$F/rt1186/companion.rb")
ok "pair: an M7 application with udp: channels is refused at step 1 beside a companion, naming the owner's choice; no firmware of either" \
   "$rc:$(refused pairudp | grep -c 'decision 0027, owner 2026-10-26'):$(nofw pairudp):$([ -e "$W/pairudp/companion/firmware" ] && echo companion || echo none)" "1:1:none:none"
rc=$(build pairan521 --app "$F/sample/app.rb" --board mps2_an521 --board-overlay "$F/mps2_an521.overlay" --companion "$F/rt1186/companion.rb")
ok "pair: --companion on a board whose table names no companion_board is refused, naming it" \
   "$rc:$(refused pairan521 | grep -c 'names no companion_board'):$(nofw pairan521)" "1:1:none"
echo "build: 2f. a channel between the pair's cores, declared by a contract (decision 0027 stage 2)"
t0=$(date +%s)
R=$F/rt1186
rc=$(build rt1186chan --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/consumer.rb")
echo "  (RT1186 contract pair build: $(( $(date +%s) - t0 )) s)"
CM=$W/rt1186chan/firmware
CC=$W/rt1186chan/companion/firmware
# the pair id over the two ids and the contract, recomputed here
ok "contract pair: both images build; the pair id covers the two ids and the contract's sha256" \
   "$rc:$(rb 'p = JSON.parse(File.read(ARGV[0]))["pair"] || {}; sha = Digest::SHA256.file(ARGV[1]).hexdigest
              want = Digest::SHA256.hexdigest("spinel-pair 1\nprimary #{p["primary"]}\ncompanion #{p.dig("companion", "id")}\nchannel console #{sha}\n")[0, 16]
              c = (p["channels"] || [])[0] || {}
              puts "#{p["id"] == want}:#{c["sha256"] == sha}:#{c.values_at("from", "to", "depth", "msg_bytes", "stride", "offset").join(",")}"' "$CM/build.json" "$R/channels/console.channel" 2>/dev/null || echo nobuild)" \
   "0:true:true:cm7,cm33,16,124,160,704"
# the companion's table and descriptor against the contract's own bytes
ok "contract pair: the companion writes one channel, a 704-byte header and slots to 3,264, and descriptor 0 is the contract's: digest, cm7 to cm33, 16 x 160, 124 bytes at 704" \
   "$(rb 's = File.read(ARGV[0]); d = Digest::SHA256.file(ARGV[1]).hexdigest
          w = (0..7).map { |i| s[/SPC_CH_D\(0u\) \+ #{i}u, (0x\h{8})u\)/, 1].to_i(16) }
          puts [s[/SPC_RING_W_N_CHANNELS, (\d+)u\)/, 1], s[/SPC_RING_W_HEADER_BYTES, (\d+)u\)/, 1], s[/SPC_RING_W_SLOTS_END, (\d+)u\)/, 1],
                w == [d[0, 8].to_i(16), d[8, 8].to_i(16), 0x10201, 16, 160, 124, 704, 0]].join(":")' "$CC/main.c" "$R/channels/console.channel" 2>/dev/null || echo nobuild)" \
   "1:704:3264:true"
ok "contract pair: the M7 checks the table and its channel, and has no transport (its one channel is not the UART's)" \
   "$(grep -c 'spc_channel_console_check()' "$CM/main.c"):$(grep -c 'SPC_RING_W_LAYOUT_HI, ' "$CM/main.c"):$(grep -c 'spc_transport_start' "$CM/main.c")" "1:1:0"
ok "contract pair: the M7 links the put, the M33 the get, each its own end" \
   "$("$NM" "$CM/zephyr.elf" 2>/dev/null | awk '$3 ~ /^spc_channel_console_(put|get)$/ { print $3 }' | tr '\n' ' '):$("$NM" "$CC/zephyr.elf" 2>/dev/null | awk '$3 ~ /^spc_channel_console_(put|get)$/ { print $3 }' | tr '\n' ' ')" \
   "spc_channel_console_put :spc_channel_console_get "
# control 1: a contract for a core the build is not for
rc=$(build chan-core --app "$R/producer.rb" --board mps2_an521 --board-overlay "$F/mps2_an521.overlay")
ok "control 1: a contract channel built for a board that is neither end (mps2_an521, no core) is refused at step 1, named; no firmware" \
   "$rc:$(refused chan-core | grep -c 'channel-not-this-core: producer.rb is built for mps2_an521 (core none), which is neither from (cm7) nor to (cm33) of channel console'):$(nofw chan-core)" "1:1:none"
# control 2: each refused type, its own planted contract
for t in ptr:channel-type-pointer i64:channel-type-int64 f32:channel-type-float; do
  n=${t%%:*}; code=${t#*:}
  rc=$(build "chan-$n" --app "$R/controls/$n.rb" --board frdm_imxrt1186_cm7 --companion "$R/consumer.rb")
  ok "control 2: a contract with an $n field is refused at step 1 with $code alone; no firmware" \
     "$rc:$(refused "chan-$n" | grep -c "$code"):$(grep -o 'channel-[a-z0-9-]*' "$W/chan-$n/build.log" | sort -u | tr '\n' ' '):$(nofw "chan-$n")" "1:1:$code :none"
done
# control 3: channels that do not fit the region
rc=$(build chan-big --app "$R/controls/big.rb" --board frdm_imxrt1186_cm7 --companion "$R/controls/big-consumer.rb")
ok "control 3: a contract of depth 1024 does not fit the region, refused with its bytes; no firmware of either" \
   "$rc:$(refused chan-big | grep -c 'channel-region: the channels need 164544 bytes (header 704, console 1024 x 160 = 163840); the region is 131072'):$(nofw chan-big):$([ -e "$W/chan-big/companion/firmware" ] && echo companion || echo none)" "1:1:none:none"
# the relay (decision 0027 stage 2): the console belongs to the core whose application declares the uart: channel
rc=$(build rt1186relay --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/relay.rb")
RM=$W/rt1186relay/firmware
RC=$W/rt1186relay/companion/firmware
ok "relay pair: it builds; the M33, whose relay declares the uart: channel, has the console and the M7 none" \
   "$rc:$(grep -c '^CONFIG_CONSOLE=y$' "$RC/config" 2>/dev/null):$(grep -c '^CONFIG_CONSOLE=y$' "$RM/config" 2>/dev/null):$(grep -c 'zephyr,console' "$RM/zephyr.dts" 2>/dev/null)" "0:1:0:0"
ok "relay pair: the M33's scheduler and transport stacks lie in its DTCM" "$(instack "$RC/zephyr.elf" spc_scheduler_stack spc_transport_stack)" \
   "spc_scheduler_stack:in spc_transport_stack:in "
ok "relay pair: the M33 prints the M7's lines from its header lines before the first relayed one, and watches for its fatal error; the M7 records one" \
   "$(grep -c -e 'spc_m33_report();' -e 'spc_m33_watch();' -e 'printk("SPC_M33_SESSION_ID ' -e 'printk("SPC_CHANNEL_REFUSED cm7 silent' "$RC/main.c"):$(grep -c 'void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf \*esf)' "$RM/main.c"):$(grep -c 'printk("SPC_PAIR_ID' "$RM/main.c")" "4:1:0"
ok "  and the M7 that keeps its console (2e: its application declares the uart: channel) still prints the pair's ids itself" \
   "$(grep -c 'printk("SPC_PAIR_ID' "$PM/main.c"):$(grep -c 'spc_m33_report' "$PC/main.c")" "1:0"
# controls 5 and 6, planted by the build; the board refuses them at run time (tests/doom-core/rt1186-pair-controls.sh)
rc=$(build chan-stopped --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/relay.rb" --mutate-consumer-stopped console)
ok "control 5: --mutate-consumer-stopped leaves the M33's check of console out, so it never takes; the M7 still checks its end" \
   "$rc:$(grep -c 'spc_channel_console_check()' "$W/chan-stopped/companion/firmware/main.c"):$(grep -c 'spc_channel_console_check()' "$W/chan-stopped/firmware/main.c")" "0:0:1"
rc=$(build chan-cache7 --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/relay.rb" --mutate-channel-cacheable cm7)
ok "control 6, cm7: a cacheable RAM region over the M7's 128 KB of the region, which Zephyr's MPU driver programs after the board's" \
   "$rc:$(grep -A5 'spc_cacheable: memory@20500000' "$W/chan-cache7/firmware/zephyr.dts" | grep -c -e 'reg = < 0x20500000 0x20000 >;' -e 'zephyr,memory-attr = < 0x100000 >;'):$(grep -c '^CONFIG_MEM_ATTR=y$' "$W/chan-cache7/firmware/config")" "0:2:1"
rc=$(build chan-cache33 --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/relay.rb" --mutate-channel-cacheable cm33)
ok "control 6, cm33: OCRAM2 cacheable RAM on the M33 (0x100000, not its own 0x200000, RAM_NOCACHE); the M7 untouched" \
   "$rc:$(grep -A6 'ocram2: memory@' "$W/chan-cache33/companion/firmware/zephyr.dts" | grep -c 'zephyr,memory-attr = < 0x100000 >;'):$(grep -c 'spc_cacheable' "$W/chan-cache33/firmware/zephyr.dts")" "0:1:0"
rc=$(build chan-half --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$F/rt1186/companion.rb")
ok "contract pair: a channel only one application names is refused, naming both" \
   "$rc:$(refused chan-half | grep -c 'channel-pair: channel console: producer.rb names it and companion.rb does not')" "1:1"
echo "build: 2g. a contract channel's doorbell over the MU (decision 0028)"
OBJDUMP="$(dirname "$CC_BIN")/llvm-objdump"
# the put's own instructions, its ring labels included: its GCR address as movw/movt, and whether it calls anything
putins() { "$OBJDUMP" -d --no-show-raw-insn "$1/objects/channel_console_put.o" 2>/dev/null | awk '/^Disassembly of section/ { p = 0 } /<spc_channel_console_put>:/ { p = 1; next } p'; }
gcr() { putins "$1" | grep -cE 'mov[wt]\s+r[0-9]+, #0x(114|4423)$'; }
calls() { putins "$1" | grep -cE '\sblx?\s'; }
# the descriptor's flags word the M7's check wants (the put object's .rodata, word 2) and the one the companion writes
want7() { "$OBJDUMP" -s -j .rodata.str4.4 "$1/objects/channel_console_put.o" 2>/dev/null | awk '$1 == "0000" { print $4 }'; }
rc=$(build rt1186wake --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/woken.rb")
WM=$W/rt1186wake/firmware
WC=$W/rt1186wake/companion/firmware
ok "doorbell pair: both images build; console's doorbell is MU1's GIR0, notify 0x01, in both images' logs" \
   "$rc:$(grep -c '\[1\] doorbell: channel console on MU1 GIR0, notify 0x01$' "$W/rt1186wake/build.log")" "0:2"
ok "doorbell pair: the companion writes notify 0x01 into descriptor 0's flags (0x01010201), and the M7's check wants the same word" \
   "$(grep -c 'SPC_CH_D(0u) + 2u, 0x01010201u);' "$WC/main.c"):$(want7 "$WM")" "1:01020101"
ok "doorbell pair: the put writes MU1_B's GCR (0x4423_0114) and calls nothing" "$(gcr "$WM"):$(calls "$WM")" "2:0"
ok "doorbell pair: the companion has Zephyr's MU driver, MU2 disabled, and MU1_A's interrupt in its inventory with its reserve" \
   "$(grep -c '^CONFIG_MBOX_NXP_IMX_MU=y$' "$WC/config"):$(grep -A6 'mbox@2430000 {' "$WC/zephyr.dts" | grep -c 'status = "disabled";'):$(rb 'j = JSON.parse(File.read(ARGV[0])); puts j["inventory"].select { |s| s["compatible"] == "nxp,mbox-imx-mu" }.map { |s| "#{s["name"]}=#{s["reserve"]}" }.join(",")' "$WC/build.json" 2>/dev/null)" \
   "1:1:mbox@4220000=isr_mbox_nxp_imx_mu"
ok "doorbell pair: the M7 has no MU driver; its put rings by itself" "$(grep -c '^CONFIG_MBOX=y$' "$WM/config")" "0"
ok "doorbell pair: the companion registers the callback on GIR0, enables it, and takes the semaphore in place of its sleep" \
   "$(grep -c -e 'mbox_register_callback(mu, 0u, spc_doorbell, NULL)' -e 'mbox_set_enabled(mu, 0u, true)' -e 'k_sem_take(&spc_wake_sem, K_TIMEOUT_ABS_TICKS' "$WC/main.c"):$(grep -c 'k_sleep(K_TIMEOUT_ABS_TICKS' "$WC/main.c")" "3:0"
# the controls of the board (tests/doom-core/rt1186-pair-controls.sh), planted by the build
rc=$(build wake-unrung --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/woken.rb" --mutate-doorbell-unrung console)
ok "control: --mutate-doorbell-unrung console: the put never writes the GCR; the companion is unchanged" "$rc:$(gcr "$W/wake-unrung/firmware"):$(grep -c 'mbox_set_enabled(mu, 0u, true)' "$W/wake-unrung/companion/firmware/main.c")" "0:0:1"
rc=$(build wake-unenabled --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/woken.rb" --mutate-doorbell-unenabled)
ok "control: --mutate-doorbell-unenabled: the companion registers the callback and never enables the interrupt; the put still rings" \
   "$rc:$(grep -c 'mbox_register_callback(mu, 0u' "$W/wake-unenabled/companion/firmware/main.c"):$(grep -c 'mbox_set_enabled(' "$W/wake-unenabled/companion/firmware/main.c"):$(gcr "$W/wake-unenabled/firmware")" "0:1:0:2"
rc=$(build wake-notify --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/woken.rb" --mutate-doorbell-notify cm7)
ok "control: --mutate-doorbell-notify cm7: the M7's check wants notify 0x09 while the companion writes 0x01" \
   "$rc:$(want7 "$W/wake-notify/firmware"):$(grep -c 'SPC_CH_D(0u) + 2u, 0x01010201u);' "$W/wake-notify/companion/firmware/main.c")" "0:01020109:1"
# refusals of wake:, at step 1 or by the declaration, with no firmware
rc=$(build wake-vcom --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/controls/wake-vcom.rb")
ok "wake: naming the uart: channel vcom, no contract channel, is refused at step 1; no firmware" \
   "$rc:$(refused wake-vcom | grep -c 'wake-channel: entry relay: wake: :vcom names no contract channel of wake-vcom.rb'):$(nofw wake-vcom)" "1:1:none"
rc=$(build wake-producer --app "$R/controls/wake-producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/woken.rb")
ok "wake: on the core that produces the channel is refused at step 1; no firmware" \
   "$rc:$(refused wake-producer | grep -c 'wake-channel: entry tick: wake: :console: this core (cm7) produces channel console; the doorbell wakes its consumer, cm33'):$(nofw wake-producer)" "1:1:none"
rc=$(build wake-isr --app "$R/producer.rb" --board frdm_imxrt1186_cm7 --companion "$R/controls/wake-isr.rb")
ok "wake: on an interrupt entry is refused by the declaration; no firmware" \
   "$rc:$(grep -c 'wake: releases a thread entry' "$W/wake-isr.out" "$W/wake-isr/build.log" 2>/dev/null | awk -F: '{ s += $2 } END { print (s > 0) ? 1 : 0 }'):$(nofw wake-isr)" "1:1:none"
echo "build: 3. an accepted application provider"
rc=$(build own --app "$F/own-provider/app.rb" --board mps2_an521)
ok "own-provider builds; its provider is compiled, screened and measured, and the evidence carries the frame" \
   "$rc:$(rb 'e = JSON.parse(File.read(ARGV[0])); puts "#{e["stack"]["bytes"].is_a?(Integer)}:#{e["stack"]["method"].include?("frame of spc_app_sensor_read")}:#{e["effects"]["row"]}"' "$W/own/firmware/evidence/spc_app_sensor_read.json" 2>/dev/null || echo nobuild)" \
   "0:true:true:application core_extern"
ok "the report carries the provider's frame as attestation, equal to the evidence, and the map defines the symbol in the measured object" \
   "$(rb 'r = JSON.parse(File.read(ARGV[0])); x = r["application"]["externs"].find { |e| e["symbol"] == "spc_app_sensor_read" }; e = JSON.parse(File.read(ARGV[1]))
          puts "#{x["stack"]["evidence"]}:#{x["stack"]["bytes"] == e["stack"]["bytes"]}"' "$W/own/firmware/report_poll.json" "$W/own/firmware/evidence/spc_app_sensor_read.json" 2>/dev/null || echo nobuild):$(awk '/provider_sensor\.o\)?$/ { f = 1; next } f && /spc_app_sensor_read$/ { print "defined"; exit } /\.o\)?$/ { f = 0 }' "$W/own/firmware/zephyr.map")" \
   "attestation:true:defined"

echo "build: 4. controls (each input kept; each refused at its step; no firmware)"
ctl() { # name expected-step expected-pattern build-args...
  n=$1; step=$2; pat=$3; shift 3
  rc=$(build "$n" "$@")
  r=$(refused "$n")
  ok "$n: refused at step $step ($pat), rc $rc, no firmware" \
     "$([ "$rc" != 0 ] && echo nonzero || echo zero):$(echo "$r" | grep -c "^step $step:" || true):$(echo "$r" | grep -c -- "$pat" || true):$(nofw "$n")" "nonzero:1:1:none"
  [ "$(echo "$r" | grep -c "^step $step:")" = 1 ] || echo "    (refused: $r)"
}
SAMPLE="--app $F/sample/app.rb --board mps2_an521 --board-overlay $F/mps2_an521.overlay"
ctl stack-r-minus-1 10 "spc_scheduler_stack_size word is $((RS - 1)); R is $RS" $SAMPLE --mutate-stack -1
ctl sampler-stack-r-minus-1 10 "spc_adc_stack_size word is $((RA - 1)); R is $RA" $SAMPLE --mutate-adapter-stack -1
# the reserves table without the an521 GPIO ISR row: the inventory's gpio sources have no applicable reserve
grep -v '^isr_gpio_cmsdk_ahb	' "$ROOT/tools/app/zephyr/v4.4.2/reserves.tsv" > "$W/reserves-no-gpio.tsv"
ok "control's input: the table it plants differs from the checked-in one by exactly the GPIO ISR row" \
   "$(diff "$ROOT/tools/app/zephyr/v4.4.2/reserves.tsv" "$W/reserves-no-gpio.tsv" | grep -c '^< isr_gpio_cmsdk_ahb'):$(diff "$ROOT/tools/app/zephyr/v4.4.2/reserves.tsv" "$W/reserves-no-gpio.tsv" | grep -c '^[<>]')" "1:1"
ctl no-reserve-for-source 6 "has no applicable reserve isr_gpio_cmsdk_ahb: unknown, and unknown refuses the build under realtime" $SAMPLE --mutate-reserves "$W/reserves-no-gpio.tsv"
ctl isr-stack-below 8 "CONFIG_ISR_STACK_SIZE is 256" $SAMPLE --mutate-prj CONFIG_ISR_STACK_SIZE=256
ctl fpu-on-frdm 3 "CONFIG_FPU=y" --app "$F/sample/app.rb" --board frdm_mcxn947 --board-overlay "$F/frdm_mcxn947.overlay" --mutate-prj CONFIG_FPU=y
ctl extra-handler 10 "irq 90 is connected to spc_extra_isr and has no inventory entry" $SAMPLE --mutate-source "$F/extra_handler.c"
ctl reserved-slot 10 "slot 13: an architecturally reserved position holds 0xdeadbeef" $SAMPLE --mutate-reserved-slot 13
ctl no-irq-row 6 "spinel,unknown-irq-source): no irq row" --app "$F/own-provider/app.rb" --board mps2_an521 --board-overlay "$F/no-irq-row.overlay"
ctl config-changed 10 "the .config changed between steps 3 and 9" $SAMPLE --mutate-config
ctl bad-period 1 "150 us is not a multiple of the tick, 100 us (CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000)" --app "$F/bad-period/app.rb" --board mps2_an521
ctl screened-provider 5 "drivers/sleepy.c calls z_impl_k_sleep" --app "$F/screened-provider/app.rb" --board mps2_an521
ctl printk-provider 5 "the provider drivers/loud.c calls printk, which it does not define" --app "$F/printk-provider/app.rb" --board mps2_an521
ctl unmeasured-object 10 "objects linked that were not measured: mutate_plain_unit.o" $SAMPLE --mutate-source "$F/plain_unit.c"
ctl glue-irq 5 "glue unit glue_irq.c calls arm_irq_disable" $SAMPLE --mutate-glue "$F/glue_irq.c"
ctl glue-entry 5 "glue unit glue_entry.c calls spinel_core_sample (entry" $SAMPLE --mutate-glue "$F/glue_entry.c"
ctl step7-refused 7 "spinel-core-kernel .*failed:" --app "$F/step7-refused/app.rb" --board mps2_an521
ok "step7-refused: the kernel named the unbounded loop, and no staging remains either" \
   "$(grep -c 'loop-unbounded' "$W/step7-refused.out" || true):$([ -e "$W/step7-refused/.staging" ] && echo staging || echo none)" "1:none"
# decision 0019, revised 2026-10-21: a `# spinel: int64` source that
# tools/core/int64-allow.tsv does not list is refused. The table lists divides
# (owner, 2026-10-22) by its bytes, so the control plants an edited copy, which
# is not listed; the refusal names the application's own file and line
# through the pack map, not the packed root
U="$W/int64-src"
mkdir -p "$U" && { cat "$F/divides/app.rb"; echo "# edited: these are not the listed bytes"; } > "$U/app.rb"
ctl int64-unlisted 7 "spinel-core-kernel .*failed:" --app "$U/app.rb" --board mps2_an521
ok "int64-unlisted: the refusal names the edited copy's app.rb:1 and the table, never the packed root" \
   "$(grep -c "^$U/app.rb:1: int-width-int64-refused: .*tools/core/int64-allow.tsv does not list this source" "$W/int64-unlisted.out" || true):$(grep -c 'pack/app.rb:' "$W/int64-unlisted.out" || true)" "1:0"
# the same with the kernel copied out of any checkout, as a frozen copy for a
# long run is: no int64 table lies beside it, and the build still reads this
# tree's, so the refusal is the same and names this tree's table
mkdir -p "$W/kernel-copy" && cp "$KERNEL" "$W/kernel-copy/" &&
  { [ ! -f "$(dirname -- "$KERNEL")/source-stamp.tsv" ] || cp "$(dirname -- "$KERNEL")/source-stamp.tsv" "$W/kernel-copy/"; }
rc=$("$TOOL" build --kernel "$W/kernel-copy/$(basename -- "$KERNEL")" --out "$W/int64-copied" --app "$U/app.rb" --board mps2_an521 \
     > "$W/int64-copied.out" 2>&1 && echo 0 || echo $?)
ok "int64-unlisted with a copied kernel: refused at step 7, the same refusal naming $ROOT/tools/core/int64-allow.tsv, no firmware" \
   "$([ "$rc" != 0 ] && echo nonzero || echo zero):$(refused int64-copied | grep -c '^step 7:' || true):$(grep -c "^$U/app.rb:1: int-width-int64-refused: .* $ROOT/tools/core/int64-allow.tsv does not list this source" "$W/int64-copied.out" || true):$(grep -c 'int64-allow-table' "$W/int64-copied.out" || true):$(nofw int64-copied)" \
   "nonzero:1:1:0:none"
# the listed divides: the kernel reads the packed root, whose require lines the
# packer rewrote, so the build lists that root in a table of its own under
# staging, derived from the row; the production build then passes the int64
# gate and stops at step 7 on D3's unattested __aeabi_ldivmod instead
ctl int64-listed 7 "__aeabi_ldivmod, the libgcc 64-bit division helper, whose stack is not attested" --app "$F/divides/app.rb" --board mps2_an521
ok "int64-listed: the log says the packed root is listed from divides' row, and no int64 refusal is printed" \
   "$(grep -c '^\[7\] int64: tests/app/fixtures/build/divides/app.rb is listed in ' "$W/int64-listed/build.log" || true):$(grep -c -e int-width-int64-refused -e int64-allow-table "$W/int64-listed.out" || true)" "1:0"
# the same build with the table less divides' row refuses it again, naming that
# table; the planted table's root reaches this tree's tests/ and examples/
# through links, so its other rows still resolve and the table itself is not
# refused
mkdir -p "$W/int64-norow/tools/core" && ln -sf "$ROOT/tests" "$W/int64-norow/tests" &&
  ln -sf "$ROOT/examples" "$W/int64-norow/examples"
grep -v '^tests/app/fixtures/build/divides/app\.rb	' "$ROOT/tools/core/int64-allow.tsv" > "$W/int64-norow/tools/core/int64-allow.tsv"
ok "control's input: the table it plants differs from the checked-in one by exactly divides' row" \
   "$(diff "$ROOT/tools/core/int64-allow.tsv" "$W/int64-norow/tools/core/int64-allow.tsv" | grep -c '^< tests/app/fixtures/build/divides/app\.rb'):$(diff "$ROOT/tools/core/int64-allow.tsv" "$W/int64-norow/tools/core/int64-allow.tsv" | grep -c '^[<>]')" "1:1"
ctl int64-row-removed 7 "spinel-core-kernel .*failed:" --app "$F/divides/app.rb" --board mps2_an521 --mutate-int64-allow "$W/int64-norow/tools/core/int64-allow.tsv"
ok "int64-row-removed: the refusal names divides/app.rb:1 and the planted table, and the table itself is not refused" \
   "$(grep -c "^$F/divides/app.rb:1: int-width-int64-refused: .* $W/int64-norow/tools/core/int64-allow.tsv does not list this source" "$W/int64-row-removed.out" || true):$(grep -c 'int64-allow-table' "$W/int64-row-removed.out" || true)" "1:0"
ok "control of the controls: the unmutated sample kept its firmware while every control left none" \
   "$(nofw sample):$(for n in stack-r-minus-1 sampler-stack-r-minus-1 no-reserve-for-source isr-stack-below fpu-on-frdm extra-handler reserved-slot no-irq-row config-changed bad-period screened-provider printk-provider unmeasured-object glue-irq glue-entry step7-refused int64-unlisted int64-listed int64-row-removed; do nofw $n; done | sort -u | tr '\n' ' ')" "firmware:none "

echo
echo "build: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
[ "$fail" = 0 ] || exit 1
