#!/bin/sh
# tests/app/host.sh -- decision 0014 Task 6: declarations, packaging, the
# cross-entry checks and the host runner.
#
# What is checked, and against what:
#
#   1. Declarations and packaging. The accepted application reads into the
#      declared states, triggers, channels and entries; its packed root is one
#      file whose map accounts for every line and whose digest is recorded;
#      packing twice gives the same bytes.
#   2. Cross-entry checks. One fixture per diagnostic code under
#      fixtures/apps/<code>/, each admitted through `spinel-core-app admit`
#      (the kernel on every entry, then CoreApp::AppChecks over the reports)
#      and expected to print that code; the accepted multi-context
#      application prints none. `net-unbounded` is spinel/net.rb's refused
#      control: a put_dec looping while the value is non-zero, refused as
#      loop-unbounded under application rules.
#   3. The host runner. Each fixture with a stimulus runs on the virtual
#      clock; its expect.txt lists trace lines (sequence number removed) and
#      summary lines that the run must contain (trace lines are an ordered
#      subsequence of the trace, whole records; a summary line is a substring
#      of the tool's output). The scheduling fixtures are
#      the plan's five cost-driven cases plus the horizon cut; `channels`
#      exercises both inbound drop reasons; `accepted` is the idle-time run
#      with gaps and no cost lines, reaching H and the end marker.
#   4. Controls on the runner: an edited expectation fails; a stimulus item at
#      the horizon is refused; a failure the stimulus does not declare fails
#      the run.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/app/fixtures"
APPS="$FIX/apps"
BOARD="$FIX/synthetic-board"
TOOL="$ROOT/tools/app/bin/spinel-core-app"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"
die() { echo "host: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
# The tool reads declarations with Prism (Ruby 3.3 and later, or the gem) and
# its library uses Ruby 3 syntax. Checked here, as closure.sh checks it, so a
# Ruby too old stops the lane with its reason instead of a syntax error inside
# a library that a caller reading the exit status cannot tell from a refusal.
"$RUBY" -e 'require "prism"; exit(RUBY_VERSION >= "3.1" ? 0 : 1)' >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' ($("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null)) is below 3.1 or cannot load prism, which the application tool needs.
       Prism ships with Ruby 3.3 and later; set RUBY=<such a ruby>, or install the prism gem."

W=$(mktemp -d "${TMPDIR:-/tmp}/app-host.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }

admit() { # name -> the codes printed, sorted, or `admitted`
  rm -rf "$W/admit-$1"
  if "$RUBY" "$TOOL" admit --app "$APPS/$1/app.rb" --board "$BOARD/board.rb" --board-tsv "$BOARD/board.tsv" \
       --out "$W/admit-$1" --kernel "$KERNEL" --clang "$CC_BIN" --typedump "$READER" > "$W/admit-$1.out" 2>&1; then
    echo admitted
  else
    sed -n 's/^[^:]*:[0-9]*: \([a-z][a-z0-9-]*\): .*/\1/p' "$W/admit-$1.out" | LC_ALL=C sort -u | tr '\n' ' '
  fi
}

run_host() { # name -> exit status; trace and summary under $W
  "$RUBY" "$TOOL" run-host --app "$APPS/$1/app.rb" --board "$BOARD/board.rb" --board-host "$BOARD/board_host.rb" \
    --stimulus "${2:-$APPS/$1/stimulus.tsv}" --trace "$W/$1.trace" > "$W/$1.summary" 2>&1 && echo 0 || echo $?
}

# The trace lines of an expectation are an ORDERED SUBSEQUENCE of the trace:
# each must match a whole record after the previous match, so the order of
# selections, skips, preemptions and CANCEL-after-FAIL is part of the claim.
# Summary lines are substrings of the tool's output. POSIX awk, so BSD awk
# reads it too.
expect_lines() { # name [expect-file] -> the lines NOT found in order, count
  cut -f2- "$W/$1.trace" > "$W/$1.noseq"
  awk -v summary="$W/$1.summary" '
    NR == FNR { trace[NR] = $0; n = NR; next }
    /^$/ { next }
    /^summary / { want = substr($0, 9); found = 0
                  while ((getline line < summary) > 0) if (index(line, want)) found = 1
                  close(summary)
                  if (!found) { print "    missing: " $0; missing++ }
                  next }
    { hit = 0; for (i = pos + 1; i <= n; i++) if (trace[i] == $0) { pos = i; hit = 1; break }
      if (!hit) { print "    missing (in order): " $0; missing++ } }
    END { print missing + 0 }
  ' "$W/$1.noseq" "${2:-$APPS/$1/expect.txt}"
}

echo "host: 1. declarations and packaging"
"$RUBY" "$TOOL" package --app "$APPS/accepted/app.rb" --board "$BOARD/board.rb" --out "$W/pkg" > "$W/pkg.out" 2>&1 || die "package failed: $(cat "$W/pkg.out")"
ok "the accepted application declares 4 states, 3 triggers, 2 channels, 3 entries" \
   "$("$RUBY" -I"$ROOT/tools/app/lib" -rcore_app/declarations -e 'a = CoreApp::Declarations.read(ARGV[0]); puts [a.states.size, a.triggers.size, a.channels.size, a.entries.size].join(",")' "$APPS/accepted/app.rb")" "4,3,2,3"
ok "one contract per entry, each version 2 with its trigger's context" \
   "$(for e in sample report command_poll; do sed -n '1p;4p' "$W/pkg/pack/$e.contract" | tr '\n' ' '; done)" \
   "core-contract 2 context interrupt core-contract 2 context thread core-contract 2 context thread "
ok "the cross state is marked cross in every contract naming it, and only it" \
   "$(grep -h '^param' "$W/pkg/pack/"*.contract | grep -c ' cross$')/$(grep -h '^param' "$W/pkg/pack/"*.contract | grep -c 'param reading')" "2/2"
ok "the channel externs carry their guards and static" \
   "$(grep -c 'guard n >= 1 else argument guard n <= 16 else bounds guard n <= len(data) else bounds' "$W/pkg/pack/report.contract"):$(grep -c 'static len(data) >= 8 else channel-buffer' "$W/pkg/pack/command_poll.contract")" "1:1"
ok "the packed root's map accounts for every line" \
   "$(tail -n +2 "$W/pkg/pack/app.rb.map" | grep -v '^#' | awk -F'\t' 'NR==1{s=$1} {e=$2} END{print s "-" e}')" "1-$(wc -l < "$W/pkg/pack/app.rb" | tr -d ' ')"
ok "the recorded digest is the packed file's" \
   "$(cut -d' ' -f1 "$W/pkg/pack/app.rb.sha256")" "$("$RUBY" -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$W/pkg/pack/app.rb")"
ok "the packed root holds no require and no core_extern" "$(grep -cE '^require|^[^#]*core_extern' "$W/pkg/pack/app.rb" || true)" 0
"$RUBY" "$TOOL" package --app "$APPS/accepted/app.rb" --board "$BOARD/board.rb" --out "$W/pkg2" > /dev/null 2>&1
ok "packing twice gives the same bytes" "$(cmp -s "$W/pkg/pack/app.rb" "$W/pkg2/pack/app.rb" && echo same || echo differ)" same
ok "the channel C names both rings' CORE ends, each in its own unit" \
   "$(grep -c '^int32_t spc_channel_telemetry_put(' "$W/pkg/channels/channel_telemetry_put.c"):$(grep -c '^int32_t spc_channel_commands_get(' "$W/pkg/channels/channel_commands_get.c")" "1:1"

echo "host: 2. cross-entry checks, one fixture per code"
ok "the accepted multi-context application is admitted" "$(admit accepted)" admitted
ok "an application with its own core_extern is admitted, and its packed root holds no core_extern" \
   "$(admit own-extern):$(grep -cE '^[^#]*core_extern' "$W/admit-own-extern/pack/app.rb" || true):$(grep -c '^# packed: core_extern' "$W/admit-own-extern/pack/app.rb")" "admitted:0:2"
ok "device-owner: two contexts on two instances with distinct nodes, named by board constants, are admitted" "$(admit device-owner-indexed)" admitted
# DECISION 0014 D5: the packer emits a module's constants whether or not the
# application declares its own member on that module. Without them the packed
# root would carry `module Led` with the application's declaration commented
# out and no LED0 in it, and the entry would be refused unresolved-constant.
ok "an application that declares its own member on a board module still resolves that module's board constants" \
   "$(admit own-extern-board):$(grep -c '^  LED0 = 0$' "$W/admit-own-extern-board/pack/app.rb")" "admitted:1"
got=$(admit device-owner-computed)
case " $got " in
  *" device-owner "*) ok "device-owner: a computed index reaches every instance of the module, and is refused (printed: $got)" yes yes ;;
  *) ok "device-owner: a computed index reaches every instance of the module, and is refused" "$got" device-owner ;;
esac
for code in shared-writer device-owner channel-end channel-buffer unknown-member member-effect guards-in-source; do
  got=$(admit "$code")
  case " $got " in
    *" $code "*) ok "$code is refused as $code (printed: $got)" yes yes ;;
    *) ok "$code is refused as $code" "$got" "$code" ;;
  esac
done
got=$(admit member-effect-blocking)
ok "member-effect-blocking: a blocking instance and one of unknown blocking (printed: $got)" \
   "$(grep -cE 'whose blocking is (true|unknown)' "$W/admit-member-effect-blocking.out")" 2
for d in decl-two-triggers decl-no-def decl-nonliteral decl-udp decl-param-not-state decl-unknown-bound; do
  ok "$d is refused as declaration" "$(admit "$d")" "declaration "
done
ok "decl-unknown-bound: refused because only core_session's DoomCore members may declare an unknown bound (decision 0021)" \
   "$(grep -c 'is admitted only for the DoomCore members core_session generates' "$W/admit-decl-unknown-bound.out")" 1
got=$(admit net-unbounded)
case " $got " in
  *" loop-unbounded "*) ok "spinel/net.rb control: the unbounded put_dec is refused as loop-unbounded" yes yes ;;
  *) ok "spinel/net.rb control: the unbounded put_dec is refused as loop-unbounded" "$got" loop-unbounded ;;
esac
ok "the fixtures on disk are exactly the ones this script names" \
   "$(ls "$APPS" | LC_ALL=C sort | tr '\n' ' ')" \
   "accepted channel-buffer channel-end channels decl-no-def decl-nonliteral decl-param-not-state decl-two-triggers decl-udp decl-unknown-bound device-owner device-owner-computed device-owner-indexed guards-in-source member-effect member-effect-blocking net-unbounded own-extern own-extern-board sched-cross-delay sched-cut sched-failure sched-missed sched-overrun sched-together shared-writer unknown-member "

echo "host: 3. the host runner"
for n in accepted sched-overrun sched-cross-delay sched-missed sched-together sched-failure sched-cut channels; do
  rc=$(run_host "$n")
  ok "$n runs to the end marker (exit $rc)" "$rc:$(grep -c 'ENDMARK' "$W/$n.trace")" "0:1"
  ok "$n: every expected trace and summary line is present" "$(expect_lines "$n")" 0
done
ok "the idle-time run processes every admitted release: 29 + 5 + 2 selections, none skipped, cut or cancelled" \
   "$(grep 'selected' "$W/accepted.summary")" "selected 36 skipped 0 cancelled 0 cut 0"
ok "the idle-time run's last selection is the last admitted release before H" \
   "$(grep 'SELECT' "$W/accepted.trace" | grep -c 'clock=29000	release=29')" 1
ok "sequence numbers have no gap" "$(awk -F'\t' '$1 != NR-1 {bad=1} END{print bad+0}' "$W/accepted.trace")" 0
ok "the failure's CANCEL names its FAIL" \
   "$(awk -F'\t' '$2=="FAIL"{f=$1} $2=="CANCEL"{split($NF,a,"="); print (a[2]==f) ? "linked" : "unlinked"}' "$W/sched-failure.trace")" linked
ok "the failing context stops and the other continues: slow keeps selecting after the FAIL" \
   "$(awk -F'\t' '$2=="FAIL"{f=1} f && $2=="SELECT" && $3==0 {n++} f && $2=="START" && $3==3 {isr++} END{print n+0 ":" isr+0}' "$W/sched-failure.trace")" "4:0"
ok "channel-full drops happen only at occupancy == depth (1), oversize only above size (4)" \
   "$(grep -c 'DROP' "$W/channels.trace"):$(grep 'drop commands' "$W/channels.summary" | tr '\n' ' ')" "2:drop commands oversize 1 drop commands channel_full 1 "

echo "host: 4. controls"
# Line 1 of the expectation is a's first SELECT; the release it names is
# changed. Addressed by line, because BSD sed has no \t.
sed '1s/release=1/release=2/' "$APPS/sched-overrun/expect.txt" > "$W/edited.txt"
grep -q 'release=2' "$W/edited.txt" || die "the control's edit did not apply"
mkdir -p "$W/apps/edited"; cp "$APPS/sched-overrun/app.rb" "$APPS/sched-overrun/stimulus.tsv" "$W/apps/edited/"; cp "$W/edited.txt" "$W/apps/edited/expect.txt"
APPS_SAVED=$APPS; APPS=$W/apps
rc=$(run_host edited)
ok "control: an edited expectation is reported missing" "$(expect_lines edited | tail -1)" 1
APPS=$APPS_SAVED
# The order is the claim: the same lines with two of them swapped (b's SELECT
# at 4500 before a's SELECT at 1000) must fail, and the swapped line is the
# one reported.
awk 'NR == 1 { first = $0; next } NR == 2 { print; print first; next } { print }' "$APPS/sched-overrun/expect.txt" > "$W/swapped.txt"
ok "control: two expected trace lines in the wrong order are reported" \
   "$(expect_lines sched-overrun "$W/swapped.txt" | tail -1):$(expect_lines sched-overrun "$W/swapped.txt" | grep -c 'missing (in order): SELECT.0.0.clock=1000')" "1:1"
printf 'horizon_us 4000\ndrain_us 100\nadc 4000 0 1\n' > "$W/late.tsv"
ok "control: a stimulus item at the horizon is refused" \
   "$(run_host accepted "$W/late.tsv"):$(grep -c 'not strictly before the horizon' "$W/accepted.summary")" "1:1"
printf 'horizon_us 10000\ndrain_us 1000\n' > "$W/undeclared.tsv"
ok "control: a failure the stimulus does not declare fails the run" \
   "$(run_host sched-failure "$W/undeclared.tsv"):$(grep -c 'differ from the stimulus' "$W/sched-failure.summary")" "1:1"
printf 'horizon_us 12000\ndrain_us 1000\ninbound 11000 commands 01\n' > "$W/unconsumed.tsv"
ok "control: an inbound message nobody consumes fails the run" \
   "$(run_host channels "$W/unconsumed.tsv"):$(grep -c '^unconsumed commands msg' "$W/channels.summary")" "1:1"

echo
echo "host: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ] || exit 1
