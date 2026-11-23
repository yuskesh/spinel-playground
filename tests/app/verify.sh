#!/bin/sh
# tests/app/verify.sh -- decision 0014 Task 11: the verification build, the
# trace and the checks.
#
#   KERNEL=... SPINEL_TYPEDUMP=... LLVM_PREFIX=... sh tests/app/verify.sh          # decoder fixtures, the mutations
#   ... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... sh tests/app/verify.sh          # plus the QEMU runs
#
# What is checked, and against what:
#
#   1. The decoder: every record kind of trace_schema.tsv decodes from its
#      byte fixture (tests/app/fixtures/trace/<KIND>.bin) to its text line,
#      and encodes back to the same bytes; an unknown kind, a short record,
#      a record over the body limit and a body the fields do not consume
#      are each refused, naming the reason. The schema names every kind
#      once, with the codes the plan fixes.
#   2. The checks and the replay over a fixture trace (a real run's,
#      tests/app/fixtures/trace/sample-run): the unmutated trace passes with
#      62 invocations replayed; every mutation of 0014 §10 applied by
#      tests/app/mutate.rb fails, and the first failure names the check's
#      own rule; a truncated trace has no gap (its end marker is missing),
#      the gap rule has its own mutation.
#   3. With the Zephyr environment: `spinel-core-app verify` builds the
#      acceptance sample's verification image for mps2/an521 (the recorder,
#      the stimulus thread, the nesting source), runs it under QEMU to the
#      end line, decodes the trace, runs the four checks and the replay, and
#      reports: every release has a class and the counts are the periods',
#      nesting is observed (the system clock's records inside the nesting
#      handler's START and END), the painted stacks' high-water marks stay
#      within their static values, the D3 figures are present. A second run,
#      the `divides` fixture, shows the __aeabi_ldivmod counter counting and
#      is the expected-failure lifecycle run (an i64 overflow at release 5:
#      FAIL, the remaining releases cancelled, the run still passing because
#      the stimulus declares it). A control: the same console verified
#      against a stimulus declaring the wrong failure fails.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools;
# ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR and west on the PATH enable the runs
# (REQUIRE_ALL=1 makes their absence a failure).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures"
RUBY="${RUBY:-ruby}"
LIB="$ROOT/tools/app/lib"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
die() { echo "verify: $*" >&2; exit 1; }
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
export KERNEL SPINEL_TYPEDUMP="$READER" CLANG="$CC_BIN"

W=$(mktemp -d "${TMPDIR:-/tmp}/app-verify.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skips=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { if [ "${REQUIRE_ALL:-0}" = 1 ]; then echo "  FAIL $1 (REQUIRE_ALL=1; $2 checks)"; fail=$((fail + $2)); else echo "  skip $1 ($2 checks)"; skips=$((skips + $2)); fi; }
rb() { "$RUBY" -I"$LIB" -rcore_app/trace -rjson -e "$@"; }

echo "verify: 1. the decoder and its fixtures"
ok "trace_schema.tsv names the 20 kinds once each, ids 0..19, with the plan's codes" \
   "$(rb 'sc = CoreApp::Trace.schema; puts "#{sc.ids.size}:#{sc.ids.values.sort == (0..19).to_a}:#{sc.codes["ENQ"]["result"]["queued"]}#{sc.codes["ENQ"]["result"]["full"]}#{sc.codes["DEQ"]["result"]["dequeued"]}#{sc.codes["DEQ"]["result"]["empty"]}#{sc.codes["DROP"]["reason"]["oversize"]}#{sc.codes["DROP"]["reason"]["channel_full"]}"')" "20:true:010112"
ok "every kind has exactly one byte fixture named for it, which decodes to its text line of that kind and encodes back to the same bytes" \
   "$(rb 'bad = []; names = Dir[ARGV[0] + "/*.txt"].map { |t| File.basename(t, ".txt") }.sort
          names.each do |k|
            t = ARGV[0] + "/" + k + ".txt"; b = ARGV[0] + "/" + k + ".bin"; r = CoreApp::Trace.from_text(File.read(t))
            bad << k unless r.kind == k && File.file?(b) && CoreApp::Trace.encode(r) == File.binread(b) && CoreApp::Trace.decode(File.binread(b)).first.line == File.read(t).chomp
          end
          puts "#{names == CoreApp::Trace::KINDS.sort ? "the kinds" : names.inspect}:#{bad.inspect}"' "$FIX/trace")" "the kinds:[]"
ok "the four refusals: an unknown kind, a short record, a body over the limit, a body the fields do not consume" \
   "$(rb 'puts %w[unknown-kind short over-limit body-mismatch].map { |x| begin; CoreApp::Trace.decode(File.binread(ARGV[0] + "/refuse-#{x}.bin")); "accepted"; rescue CoreApp::Trace::DecodeError => e; e.message[/unknown kind|truncated|exceeds the limit|body_len says/] || e.message; end }.join("|")' "$FIX/trace")" \
   "unknown kind|truncated|exceeds the limit|body_len says"
ok "control: a byte fixture with one bit flipped in its body no longer decodes to its line" \
   "$(rb 'b = File.binread(ARGV[0]); b[25] = (b.getbyte(25) ^ 1).chr; puts CoreApp::Trace.decode(b).first.line == File.read(ARGV[1]).chomp' "$FIX/trace/LOAD.bin" "$FIX/trace/LOAD.txt")" false

# Sections 2 and 3 run the verify CLI, whose replay re-executes every
# invocation under CRuby and compares it with the trace: an oracle.
if "$ROOT/tools/oracle/gate" tests/app/verify.sh replay-fixture; then
  echo "verify: 2. the checks and the replay over the sample run's trace, and the mutations"
  SR="$FIX/trace/sample-run"
  VOUT="$W/text"; mkdir -p "$VOUT"
  vt() { "$TOOL" verify --app "$FIX/build/sample/app.rb" --board mps2_an521 --stimulus "$FIX/stimulus/sample.tsv" --out "$VOUT" --board-dir "$SR" --trace-text "$1" > "$W/vt.out" 2>&1 && echo 0 || echo $?; }
  ok "the unmutated trace passes: 712 records, 62 invocations replayed, every release classified" \
     "$(vt "$SR/trace.txt"):$(rb 'r = JSON.parse(File.read(ARGV[0])); puts "#{r["verdict"]}:#{r["records"]}:#{r["invocations"]}:#{r["replayed"]}:#{r["releases"].values.map { |h| h.values.sum }.join("+")}"' "$VOUT/verify/text/report.json")" \
     "0:pass:712:62:62:49+9+4"
  mut() { # name pattern
    "$RUBY" "$ROOT/tests/app/mutate.rb" "$1" "$SR/trace.txt" "$W/mut-$1.txt" || die "mutation $1 did not apply"
    rc=$(vt "$W/mut-$1.txt")
    first=$(sed -n '2p' "$W/vt.out")
    ok "mutation $1 fails, naming the rule: $2" "$([ "$rc" != 0 ] && echo refused || echo accepted):$(echo "$first" | grep -c -- "$2" || true)" "refused:1"
    [ "$(echo "$first" | grep -c -- "$2" || true)" = 1 ] || echo "    (first failure: $first)"
  }
  mut drop-inbound-silent "appears in no RX or DROP record"
  mut drop-inbound-counted "DROP channel_full on commands at occupancy 0, below depth"
  mut full-drop-below-depth "DROP channel_full on commands at occupancy 1, below depth 2"
  mut duplicate-message "ENQ on commands has msg_id 1; 2 is next"
  mut corrupt-payload "the payload is not the enqueued one"
  mut load-older-value "record 130: reading\[0\] loaded 0; the latest store before it holds 1198"
  mut load-regresses "record 357: reading\[0\] loaded 2497; the latest store before it holds 299"
  mut truncate "0 end markers; one is required"
  mut no-end-marker "0 end markers; one is required"
  mut drain-timed-out "the end marker says the drain did not complete"
  mut overflow "the record buffer of context 5 overflowed"
  mut select-older-release "the clock reading 65610 allows exactly 2"
  mut unjustified-skip "recorded skipped 1..1; the clock reading justifies 0..0"
  mut release-unclassified "release 49 has no terminal class"
  mut cancel-without-fail "CANCEL names FAIL 7, which is not a FAIL record"
  mut selected-never-started "release 49 was selected and never started"
  mut sequence-gap "sequence gap: 355 is followed by 357"
  ok "the two load mutations touch different records (fifteen distinct defects among the seventeen, plus the gap and the never-started run)" \
     "$(diff "$W/mut-load-older-value.txt" "$W/mut-load-regresses.txt" > /dev/null && echo same || echo differ)" differ
  ok "control: a truncated trace has no gap -- what it lacks is its end marker; the gap rule is exercised by sequence-gap" \
     "$(rb 'a = CoreApp::Trace.from_text_file(ARGV[0]); puts a.each_cons(2).count { |x, y| y.seq != x.seq + 1 }' "$W/mut-truncate.txt")" 0
fi

if [ -z "${ZEPHYR_BASE:-}" ] || [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ] || ! command -v west >/dev/null 2>&1; then
  skipped "the Zephyr environment (ZEPHYR_BASE, ZEPHYR_SDK_INSTALL_DIR, west): the QEMU runs" 12
elif ! "$ROOT/tools/oracle/gate" tests/app/verify.sh replay-qemu; then
  :
else
  echo "verify: 3. the runs under QEMU"
  t0=$(date +%s)
  rc=$("$TOOL" verify --app "$FIX/build/sample/app.rb" --board mps2_an521 --board-overlay "$FIX/build/mps2_an521.overlay" \
       --stimulus "$FIX/stimulus/sample.tsv" --out "$W/sample" > "$W/sample.out" 2>&1 && echo 0 || echo $?)
  echo "  (sample: build, run and checks in $(( $(date +%s) - t0 )) s)"
  R="$W/sample/verify/report.json"
  ok "the sample's verification run passes: every check, every invocation replayed, 9 frames compared with the wire" \
     "$rc:$(rb 'r = JSON.parse(File.read(ARGV[0])); puts "#{r["verdict"]}:#{r["invocations"] == r["replayed"]}:#{r["wire_frames_compared"]}:#{r["failures"].size}"' "$R" 2>/dev/null || echo norun)" "0:pass:true:9:0"
  [ "$rc" = 0 ] || { tail -5 "$W/sample.out"; die "the sample's verification run failed; the rest of this section reads its report"; }
  ok "the releases are the periods' under the 50 ms horizon: sample 49 (1 ms), report 9 (5 ms), command_poll 4 (10 ms), all run" \
     "$(rb 'r = JSON.parse(File.read(ARGV[0]))["releases"]; puts r.map { |k, v| "#{k}=#{v.map { |c, n| "#{c}:#{n}" }.join(",")}" }.join(" ")' "$R")" "sample=run:49 report=run:9 command_poll=run:4"
  ok "the channels: 9 telemetry messages enqueued and handed to the UART, 2 commands consumed, none stranded; the third command dropped as oversize" \
     "$(rb 'r = JSON.parse(File.read(ARGV[0])); t = r["channels"]["telemetry"]; c = r["channels"]["commands"]; puts "#{t["enqueued"]}/#{t["handed"]}/#{t["stranded"]}:#{c["enqueued"]}/#{c["stranded"]}"' "$R"):$(grep -c '	DROP	' "$W/sample/verify/trace.txt")" "9/9/0:2/0:1"
  ok "nesting is observed: the nesting handler's START and END bracket system-clock records, at least 60 expiries in 50 ms at 700 us" \
     "$(rb 'recs = CoreApp::Trace.from_text_file(ARGV[0]); nest = recs.select { |x| x.entry == 255 && %w[START END].include?(x.kind) && x.context >= 3 }.group_by(&:context).max_by { |_, v| v.size }
            ctx, evs = nest; starts = evs.select { |x| x.kind == "START" }
            inside = starts.count { |s| e = evs.find { |x| x.kind == "END" && x.seq > s.seq }; e && recs.any? { |x| x.seq > s.seq && x.seq < e.seq && x.kind == "SELECT" && x.context != ctx } }
            puts "#{starts.size >= 60}:#{inside >= 10}"' "$W/sample/verify/trace.txt")" "true:true"
  ok "the painted stacks: scheduler, transport, Adc sampler and interrupt high-water marks within their static values" \
     "$(rb 'r = JSON.parse(File.read(ARGV[0])); puts r["stacks"].map { |s| "#{s["name"]}=#{s["within"]}" }.join(",")' "$R")" "scheduler=true,transport=true,adc_sampler=true,interrupt=true"
  ok "the verification build owns its one literal stack: threads_unbudgeted is the stimulus thread alone, and the sampler's excluded init frame is published rather than dropped" \
     "$(rb 'b = JSON.parse(File.read(ARGV[0])); u = b["threads_unbudgeted"]; a = b["adapter_threads"].find { |x| x["name"] == "adc_sampler" }
            puts "#{u.map { |t| t["entry"] }.join(",")}:#{u.map { |t| t["stack"] }.join(",")}:#{u.all? { |t| t["measured_frames"].any? }}:#{a["excluded"].keys.join(",")}:#{a["excluded"].values.all? { |v| v.to_i > 0 }}"' "$W/sample/firmware/build.json")" \
     "spc_stimulus_thread:1024:true:spc_adapter_adc_init:true"
  ok "the D3 figures: instructions per invocation for each of the three entries, no 64-bit division in the sample, the method stated" \
     "$(rb 'r = JSON.parse(File.read(ARGV[0]))["instructions"]; puts "#{r["entries"].size}:#{r["entries"].all? { |e| e["per_invocation"].to_i > 0 }}:#{r["entries"].sum { |e| e["ldivmod_calls"] }}:#{r["method"].include?("icount")}"' "$R")" "3:true:0:true"
  ok "the recorder dropped nothing and the transport drained: SPC_END dropped=0, passes counted" \
     "$(LC_ALL=C grep -ao 'SPC_END dropped=[0-9]*' "$W/sample/verify/console.bin" | head -1):$(rb 'puts JSON.parse(File.read(ARGV[0]))["transport_passes"].to_i > 10' "$R")" "SPC_END dropped=0:true"
  # the divides run: the ldivmod counter, and the expected-failure lifecycle
  t0=$(date +%s)
  rc=$("$TOOL" verify --app "$FIX/build/divides/app.rb" --board mps2_an521 --stimulus "$FIX/stimulus/divides.tsv" --out "$W/divides" > "$W/divides.out" 2>&1 && echo 0 || echo $?)
  echo "  (divides: build, run and checks in $(( $(date +%s) - t0 )) s)"
  RD="$W/divides/verify/report.json"
  ok "divides: the run passes with its declared failure (step, release 5, ARITHMETIC): 5 run, 4 cancelled by the failure" \
     "$rc:$(rb 'r = JSON.parse(File.read(ARGV[0])); puts "#{r["verdict"]}:#{r["releases"]["step"].sort.map { |k, v| "#{k}:#{v}" }.join(",")}"' "$RD" 2>/dev/null || echo norun):$(grep -c '	FAIL	' "$W/divides/verify/trace.txt" 2>/dev/null || true)" \
     "0:pass:cancelled:4,run:5:1"
  ok "divides: __aeabi_ldivmod counted -- 4 calls over the 4 invocations that reached the division, each with instructions" \
     "$(rb 'e = JSON.parse(File.read(ARGV[0]))["instructions"]["entries"][0]; puts "#{e["ldivmod_calls"]}:#{e["ldivmod_instructions"] > 0}:#{e["ldivmod_instructions"] < e["instructions"]}"' "$RD" 2>/dev/null || echo norun)" "4:true:true"
  # the control: the same console, a stimulus declaring the wrong failure
  sed 's/^expect_failure step 5 2$/expect_failure step 4 2/' "$FIX/stimulus/divides.tsv" > "$W/divides-wrong.tsv"
  mkdir -p "$W/divides-wrong" && cp -R "$W/divides/firmware" "$W/divides-wrong/firmware"
  rc=$("$TOOL" verify --app "$FIX/build/divides/app.rb" --board mps2_an521 --stimulus "$W/divides-wrong.tsv" --out "$W/divides-wrong" --no-build --console "$W/divides/verify/console.bin" > "$W/divides-wrong.out" 2>&1 && echo 0 || echo $?)
  ok "control: the divides console against a stimulus declaring the failure at release 4 is refused, naming both" \
     "$rc:$(grep -c 'are not the stimulus' "$W/divides-wrong.out" || true)" "1:1"
  ok "control: the production build of divides is refused at step 7, naming the unattested 64-bit division helper (D3)" \
     "$("$TOOL" build --app "$FIX/build/divides/app.rb" --board mps2_an521 --out "$W/divides-prod" > "$W/divides-prod.out" 2>&1 && echo 0 || echo $?):$(grep -c '__aeabi_ldivmod, the libgcc 64-bit division helper, whose stack is not attested' "$W/divides-prod.out" || true)" "1:1"
fi

echo
echo "verify: $((pass + fail)) checked, $pass pass, $fail fail, $skips skipped"
[ "$fail" = 0 ] || exit 1
