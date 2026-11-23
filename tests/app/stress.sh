#!/bin/sh
# tests/app/stress.sh -- decision 0014 Task 12: production primitives under
# preemption.
#
# The application is tests/app/stress/app.rb, built exactly as production
# (no recorder, no masks) with the build's sampling source (`--stress`: CMSDK
# timer 1 of mps2/an521, a period that is not a multiple of the tick). It
# runs both directions at once: an interrupt entry puts while the transport
# thread drains, and the transport thread puts UART input while an interrupt
# entry gets. The console is read for three things:
#
#   HITS -- the sampling source's count of preempted PCs inside each ring
#   span (Task 8's labels). Only the thread side of each direction can be
#   preempted by it -- the interrupt side runs inside the system clock's
#   handler, above the source's priority -- so the spans required are the
#   transport's: telemetry get (copy, publication) and commands put (copy,
#   publication). A run with no hit in one of them is INCONCLUSIVE, and this
#   suite fails it rather than passing it.
#
#   CONTENT -- every outbound frame carries a sequence and a checksum,
#   checked off the wire (stress/check_wire.rb); every inbound message is
#   checked by the consumer entry, which prints STRESS_FAIL on a checksum
#   that does not match (1), a half-written shared word (2) or a sequence
#   that did not rise (3), and counts what it received (STRESS_SEEN), so a
#   consumer that never ran cannot pass as one whose checks held.
#
#   THE NEGATIVE CONTROL -- the same application with the commands ring's
#   put mutated to publish its head before the copy and to hold that window
#   open on every other put. Both detectors must refuse it: the label check,
#   statically, because moving the store empties the publication span; and
#   the run, dynamically, because the consumer sees sequences go backwards. (Every other put: a window held
#   on EVERY put makes the ring a two-deep delay line whose output is
#   complete and in order, only late, which no content check can see --
#   measured, 200 of 200 windows entered, no failure. The plan's control
#   assumed the opposite; this is the recorded correction.)
#
# The artifact checks are Task 5's on this build: the optimised IR carries
# atomics exactly on the cross-context state, and each ring publication in
# the linked image is one store-release inside its label span.
#
# Runs at icount shift 5: at the board's default 7 the interrupt entries use
# the CPU and the transport thread does not run (measured: no frame in 15 s).
#
# Environment: ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR, west and the tools of
# tests/app/build.sh (KERNEL, SPINEL_TYPEDUMP, LLVM_PREFIX). Without them the
# Zephyr section is skipped, named; REQUIRE_ALL=1 fails the skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY="${RUBY:-ruby}"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
APP="$ROOT/tests/app/stress/app.rb"
WIRE="$ROOT/tests/app/stress/check_wire.rb"
die() { echo "stress: $*" >&2; exit 1; }
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${LLVM_PREFIX:-}" ]; then BIN=$LLVM_PREFIX/bin
else die "set LLVM_PREFIX to the official LLVM 23.1.1; this script refuses to guess"
fi
QEMU_WAIT=${QEMU_WAIT:-120}
PERIOD_US=${STRESS_PERIOD_US:-37}
SAMPLES=${STRESS_SAMPLES:-500000} # the commands publication span is two instructions: 100000 samples hit it 0, 1 and 3 times in three builds, so 500000
SHIFT=5

W=$(mktemp -d "${TMPDIR:-/tmp}/app-stress.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skips=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then echo "  FAIL $1 (REQUIRE_ALL=1; $2 checks)"; fail=$((fail + $2)); else echo "  skip $1 ($2 checks)"; skips=$((skips + $2)); fi; }

echo "stress: 1. the wire checker, on bytes of its own"
# three good frames, a harness line cut into the middle of the second, then
# the report: the checker must read three frames and cut one line; the same
# bytes with one payload bit flipped must show one bad check
"$RUBY" -e '
  f = ->(s) { [0xA5, 0, 8].pack("C*") + [s, (s * 2654435761) & 0x7fffffff].pack("VV") }
  good = "boot\n".b + f.(1) + f.(2).byteslice(0, 5) + "STRESS_SEEN n=1000 last=7 fails=0,0,0\r\n".b + f.(2).byteslice(5..) + f.(3) + "STRESS samples=1\n".b
  File.binwrite(ARGV[0], good)
  bad = good.dup; bad.setbyte(good.index([0xA5, 0, 8].pack("C*")) + 7, bad.getbyte(good.index([0xA5, 0, 8].pack("C*")) + 7) ^ 1)
  File.binwrite(ARGV[1], bad)' "$W/good.bin" "$W/bad.bin"
ok "three frames around a cut line read clean; one flipped bit is one bad check" \
   "$("$RUBY" "$WIRE" "$W/good.bin") / $("$RUBY" "$WIRE" "$W/bad.bin")" \
   "wire frames=3 bad_check=0 not_rising=0 junk=0 lines=1 / wire frames=3 bad_check=1 not_rising=0 junk=0 lines=1"

if [ -z "${ZEPHYR_BASE:-}" ] || [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || ! command -v west >/dev/null 2>&1; then
  skipped "the Zephyr environment (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR, west): the stress builds and runs" 11
  echo
  echo "stress: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
  [ "$fail" = 0 ] || exit 1
  exit 0
fi

# the inbound stimulus: 20000 commands frames, sequence s and (s * 7 + 11) & 0xffff
"$RUBY" -e 'o = "".b; (1..20000).each { |s| c = (s * 7 + 11) & 0xffff; o << [0xA5, 1, 4, s & 0xff, s >> 8, c & 0xff, c >> 8].pack("C*") }; File.binwrite(ARGV[0], o)' "$W/in.bin"

build() { # out-dir extra-args... -> exit status
  d=$1; shift
  "$RUBY" "$TOOL" build --app "$APP" --board mps2_an521 --stress "$PERIOD_US,$SAMPLES" --out "$d" "$@" > "$d.out" 2>&1 && echo 0 || echo $?
}
run() { # firmware-dir console -> seconds taken
  qemu=$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["qemu"].to_s' "$1/build.json")
  [ -x "$qemu" ] || die "no QEMU named by $1/build.json"
  : > "$2"
  "$qemu" -cpu cortex-m33 -machine mps2-an521 -m 16 -vga none -net none -nographic \
    -icount shift=$SHIFT,align=off,sleep=off -rtc clock=vm \
    -chardev file,id=con,path="$2",input-path="$W/in.bin" -serial chardev:con -monitor none \
    -chardev null,id=hostS0 -serial chardev:hostS0 -kernel "$1/zephyr.elf" > "$2.qemu" 2>&1 &
  qpid=$!
  i=0
  while [ "$i" -lt "$QEMU_WAIT" ] && ! grep -aq STRESS_END "$2"; do sleep 1; i=$((i + 1)); done
  kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
  echo "$i"
}
text() { LC_ALL=C tr -c '[:print:]\n' '.' < "$1"; }
fails() { text "$1" | grep -o 'STRESS_FAIL kind=[0-9]*' | sort | uniq -c | awk '{printf "%s%s", sep, $3 "x" $1; sep=","}'; }
labels() { "$RUBY" "$TOOL" labels --object "$1" --channel telemetry --channel commands > "$1.labels" 2>&1 && echo clean || echo "findings: $(tr '\n' ' ' < "$1.labels")"; }

echo "stress: 2. the production build and its artifacts"
t0=$(date +%s)
ok "the stress application builds as production with the sampling source, which the inventory budgets (interrupt level 2)" \
   "$(build "$W/stress"):$("$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); puts j["inventory"].any? { |s| s["name"] == "stress_timer" } && j["stacks"]["interrupt"]["chain"].any? { |t| t["name"].include?("stress_timer") }' "$W/stress/firmware/build.json" 2>/dev/null || echo none)" "0:true"
FW="$W/stress/firmware"
ok "the ring labels of both channels are placed in the linked image (labels.rb)" "$(labels "$FW/zephyr.elf")" clean
for e in produce consume check; do "$BIN/llvm-dis" "$FW/objects/core_$e.bc" -o "$W/$e.ll"; done
ok "the optimised IR carries atomics exactly on the cross state: produce's two stores and check's two loads of shared; consume's private state is plain" \
   "$(for e in produce consume check; do printf '%s=%s ' "$e" "$(grep -cE '(load|store) atomic i32[ ,].*monotonic, align 4' "$W/$e.ll" || true)"; done)" "produce=2 consume=0 check=2 "
# each publication span holds one store-release: the head (put) or tail (get)
ok "each ring publication in the image is one store-release inside its label span" \
   "$("$RUBY" -ropen3 -e '
      elf, nm, objdump = ARGV
      syms = Open3.capture2(nm, elf).first.lines.map(&:split).select { |a| a.size == 3 }.to_h { |a, _t, n| [n, a.to_i(16)] }
      out = %w[telemetry commands].flat_map { |c| %w[put get].map { |op|
        lo = syms.fetch("spc_ring_#{c}_#{op}_pub_begin"); hi = syms.fetch("spc_ring_#{c}_#{op}_pub_end")
        dis = Open3.capture2(objdump, "-d", "--no-show-raw-insn", "--start-address=0x%x" % lo, "--stop-address=0x%x" % hi, elf).first
        "#{c}_#{op}=#{dis.lines.count { |l| l =~ /:\s+stl\s/ }}" } }
      puts out.join(" ")' "$FW/zephyr.elf" "$BIN/llvm-nm" "$BIN/llvm-objdump")" \
   "telemetry_put=1 telemetry_get=1 commands_put=1 commands_get=1"
echo "  (build: $(( $(date +%s) - t0 )) s)"

echo "stress: 3. the run, both directions at once (icount shift $SHIFT, sampling every $PERIOD_US us)"
secs=$(run "$FW" "$W/run.txt")
REPORT=$(text "$W/run.txt" | grep -o 'STRESS samples=.*' | head -1)
echo "  (${secs} s: ${REPORT:-no report})"
hit() { echo "$REPORT" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
# `nested` (samples taken over another handler, not classified) is reported,
# not asserted: nothing here plants a handler for it to catch
ok "the run reaches its report: every sample taken" "$(hit samples)" "$SAMPLES"
got=""
for s in telemetry_get_copy telemetry_get_pub commands_put_copy commands_put_pub; do
  n=$(hit "$s"); got="$got$s=$([ "${n:-0}" -gt 0 ] && echo hit || echo INCONCLUSIVE) "
done
ok "every span of the preemptible side is hit at least once (else the run is inconclusive, and not a pass)" \
   "$got" "telemetry_get_copy=hit telemetry_get_pub=hit commands_put_copy=hit commands_put_pub=hit "
ok "no content failure anywhere in the run: checksum, shared word, sequence" "$(fails "$W/run.txt")" ""
ok "the inbound consumer was live: it received at least 1000 messages" \
   "$(text "$W/run.txt" | grep -o 'STRESS_SEEN n=[0-9]*' | tail -1 | sed 's/.*n=//' | awk '{print ($1 >= 1000) ? "live" : "only " $1}')" live
WIRE_OUT=$("$RUBY" "$WIRE" "$W/run.txt")
echo "  ($WIRE_OUT)"
ok "every outbound frame off the wire carries its checksum and a rising sequence, and there are at least 1000 of them" \
   "$(echo "$WIRE_OUT" | awk '{for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] } print ((v["frames"] >= 1000) ? "many" : v["frames"]) ":" v["bad_check"] ":" v["not_rising"] ":" v["junk"]}')" "many:0:0:0"

echo "stress: 4. the negative control: a ring that publishes before its copy"
ok "the mutated build builds, and the label check refuses its image statically: the publication span is empty" \
   "$(build "$W/neg" --mutate-ring-early-publish commands):$(grep -c 'MUTATED: channel commands publishes before its copy' "$W/neg/build.log"):$(labels "$W/neg/firmware/zephyr.elf" | grep -c 'spc_ring_commands_put_pub: begin [0-9a-f]* does not precede end')" "0:1:1"
secs=$(run "$W/neg/firmware" "$W/neg.txt")
echo "  (${secs} s: $(fails "$W/neg.txt"))"
ok "the negative control fails: the consumer sees sequences that did not rise" \
   "$(text "$W/neg.txt" | grep -c 'STRESS_FAIL kind=3' | awk '{print ($1 > 0) ? "fails" : "passed"}')" fails

echo
echo "stress: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
[ "$fail" = 0 ] || exit 1
