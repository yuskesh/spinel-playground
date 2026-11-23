#!/bin/sh
# tests/doom-core/screens.sh — the ORIGINAL's screens, recorded and re-checked.
#
#   sh tests/doom-core/screens.sh [DIR]          check the recordings
#   RECORD=1 sh tests/doom-core/screens.sh [DIR] write them
#
# WHY A RECORDING EXISTS AT ALL. Every comparison in tests/doom-core runs the
# port BESIDE the original and compares the two: source-port.rb adds a line at
# each of the original's producer sites and keeps the original's line, so the
# oracle needs the original to be running. THE MILESTONE REMOVES THE ORIGINAL.
# 0008's exit criterion is that the tick and full CPU rendering are reached
# THROUGH the native entries in the playable program, and at that point there is
# nothing beside the port to compare it against -- so the only check that
# survives the cutover is one that compares against WHAT THE ORIGINAL PRODUCED,
# recorded before it was removed. This file is that recording and the check that
# it still holds.
#
# IT IS TAKEN WITH THE INSTRUMENTATION DISABLED. The recorder is
# examples/doom/bin/sim_demo.rb, which loads the unmodified library and runs the
# demo with the renderer in job mode 0 -- no patched copy, no port, no native
# library. What it digests is the original's own framebuffer.
#
# TWO DIGESTS PER FRAME, both fnv1a64 over the 8-bit framebuffer:
#   viewhash   the 3D view, the top 168 rows
#   fullhash   the whole 320x200 screen, status bar and HUD included
# The pair localises a difference to the view or to the furniture around it,
# which one digest cannot do.
#
# WHAT A DIGEST CANNOT CATCH, stated because the choice is deliberate. It says
# THAT a frame differs and never WHICH PIXEL: a failing check names the gametic
# and the file, and whoever chases it re-runs that tic and compares the bytes.
# Raw frames would localise immediately and cost 700 MB for the three demos
# against 410 KB for the digests; the digests are kept in the tree and the raw
# bytes are a rerun away. fnv1a64 is not cryptographic -- it detects accidental
# change, not a constructed collision, which is the threat model here.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/doom-core/harness/retired.sh"
DIR=${1:-${TMPDIR:-/tmp}/screens.$$}
WADFILE=${WAD:-$ROOT/doom1.wad}
RUBY=${RUBY:-ruby}
FIX=$ROOT/tests/doom-core/fixtures/screens
SIM=$ROOT/examples/doom/bin/sim_demo.rb
pass=0
fail=0
skip=0
skips=""
skipped() { # name, reason
  echo "  SKIP $1 ($2)"
  skip=$((skip + 1))
  skips="$skips  - $1: $2
"
}
ok() { # name got want
  if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
  else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi
}
[ -f "$WADFILE" ] || { echo "screens.sh: no IWAD at $WADFILE; set WAD" >&2; exit 2; }
[ -f "$SIM" ] || { echo "screens.sh: no recorder at $SIM" >&2; exit 2; }
mkdir -p "$DIR" || exit 2

# The three demos and their tic counts, from 0008's exit criteria.
DEMOS='DEMO1:5026 DEMO2:3836 DEMO3:2134'

run_one() { # demo tics outfile
  d=$1; t=$2; out=$3
  mkdir -p "$DIR/$d"
  "$RUBY" "$SIM" "$WADFILE" "$d" "$t" "$DIR/$d" frame > "$DIR/$d/sim.log" 2>&1 || return 1
  [ -f "$DIR/$d/frames.tsv" ] || return 1
  cp "$DIR/$d/frames.tsv" "$out"
}

if [ "${RECORD:-}" = 1 ]; then
  mkdir -p "$FIX"
  rev=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
  # The fallback used to be `sha256sum ... | cut || shasum ...`, whose status
  # is cut's, so it never ran; chosen by what exists instead.
  wadsum=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$WADFILE"; else shasum -a 256 "$WADFILE"; fi | cut -d' ' -f1)
  for e in $DEMOS; do
    d=${e%:*}; t=${e#*:}
    echo "recording $d, $t tics"
    run_one "$d" "$t" "$DIR/$d.raw" || { echo "screens.sh: $d failed to record" >&2; exit 2; }
    {
      echo "# tests/doom-core/fixtures/screens/$d.tsv — the ORIGINAL's screens, recorded."
      echo "#"
      echo "# Taken by examples/doom/bin/sim_demo.rb with the unmodified library and"
      echo "# the renderer in job mode 0: no port, no patched copy, no native library."
      echo "# Regenerate with RECORD=1 sh tests/doom-core/screens.sh."
      echo "#"
      echo "# demo\t$d"
      echo "# tics\t$t"
      echo "# revision\t$rev"
      echo "# iwad\tsha256:$wadsum"
      echo "# renderer\tjob_mode 0, setblocks 10, resscale 1"
      echo "# digest\tfnv1a64 over the 8-bit framebuffer"
      grep -v '^#gametic' "$DIR/$d.raw"
    } > "$FIX/$d.tsv"
    echo "  wrote $FIX/$d.tsv ($(grep -vc '^#' "$FIX/$d.tsv") frames)"
  done
  exit 0
fi

echo "== the original still produces the recorded screens =="
for e in $DEMOS; do
  d=${e%:*}; t=${e#*:}
  g=$FIX/$d.tsv
  if [ ! -f "$g" ]; then ok "$d has a recording" no yes; continue; fi
  run_one "$d" "$t" "$DIR/$d.raw" || { ok "$d re-runs" no yes; continue; }
  grep -v '^#' "$g" > "$DIR/$d.want"
  grep -v '^#gametic' "$DIR/$d.raw" > "$DIR/$d.got"
  ok "$d frame count" "$(wc -l < "$DIR/$d.got")" "$(wc -l < "$DIR/$d.want")"
  if cmp -s "$DIR/$d.got" "$DIR/$d.want"; then
    ok "$d reproduces every recorded frame" yes yes
  else
    first=$(diff "$DIR/$d.want" "$DIR/$d.got" | grep -m1 '^[0-9]' | cut -d, -f1 | tr -dc '0-9')
    ok "$d reproduces every recorded frame" "differs first at line $first" yes
    diff "$DIR/$d.want" "$DIR/$d.got" | head -6 | sed 's/^/        /'
  fi
done

# THE INPUT THAT MAKES THE CHECK FAIL, kept rather than described. A recording
# nobody has seen rejected is a recording nobody knows can be rejected, and this
# check is the only thing standing between a wrong original and everything after
# it. The fixture is DEMO3's recording with ONE digest altered.
echo "== the check rejects a recording the original does not produce =="
REJ=$FIX/DEMO3-rejected.tsv
if [ ! -f "$REJ" ]; then
  ok "the rejected fixture exists" no yes
else
  grep -v '^#' "$REJ" > "$DIR/rej.want"
  if [ -f "$DIR/DEMO3.got" ]; then
    if cmp -s "$DIR/DEMO3.got" "$DIR/rej.want"; then
      ok "the altered recording is refused" no yes
    else
      ok "the altered recording is refused" yes yes
    fi
    # And it differs in exactly the way intended: one line, not a shifted file.
    n=$(diff "$DIR/rej.want" "$DIR/DEMO3.got" | grep -c '^[<>]')
    ok "and differs in exactly one frame" "$n" 2
  else
    ok "the rejected fixture is compared" no yes
  fi
fi

# AND THE RECORDING MUST NOT BE A PROPERTY OF ONE RENDERING PATH. It is taken in
# job mode 0, the plain CPU path, while every comparison in tests/doom-core runs
# job mode 2. If the framebuffer differed between the two, the golden would be of
# a different original than the one the port is checked against, and the check
# above would be sound about the wrong thing. Measured on the cheapest demo,
# which is 35 s.
echo "== the recording does not depend on the job mode =="
mkdir -p "$DIR/jm2"
if "$RUBY" "$SIM" "$WADFILE" DEMO3 2134 "$DIR/jm2" frame,jobstat > "$DIR/jm2/sim.log" 2>&1 &&
   [ -f "$DIR/jm2/frames.tsv" ]; then
  grep -v '^#gametic' "$DIR/jm2/frames.tsv" > "$DIR/jm2.got"
  grep -v '^#' "$FIX/DEMO3.tsv" > "$DIR/jm2.want"
  if cmp -s "$DIR/jm2.got" "$DIR/jm2.want"; then
    ok "DEMO3 in job mode 2 gives the job mode 0 recording" yes yes
  else
    ok "DEMO3 in job mode 2 gives the job mode 0 recording" \
       "differs in $(diff "$DIR/jm2.want" "$DIR/jm2.got" | grep -c '^<') frame(s)" yes
  fi
else
  ok "DEMO3 re-runs in job mode 2" no yes
fi

# THE PORT COMPARISON IS NOT BOUNDED. It stopped at frame 59 while the port drew
# no HUD -- the recording carries the message line from frame 60, at y = 0,
# inside the view -- and a check asserted that bound until porting the HUD made
# it fail by passing, as it said it would. The session and adapter routes kept a
# bound of their own for a while, because the status bar's and the HUD's
# parameters had no rows in fields.tsv and so those routes drew no furniture;
# the rows exist now.
#
# SO EVERY ROUTE IS COMPARED OVER THE WHOLE DEMO, not a sample of it. This was
# 600 frames. 12e8db4 chose that as a FLOOR -- past the first message switching
# off at tic 408, the last moment the HUD's copied state changed within reach --
# and it was then read as a length to stop at. (42837d9 said here that the 600
# was inherited from the case matrix rather than chosen; the history says
# otherwise. The case matrix's 600 is a second floor, past the first sky column
# at tic 572 -- tests/doom-core/tick.sh -- that happens to be the same number.)
# Nothing requires stopping early: measured on DEMO1's 5026 frames, every route
# agrees on every view and every full-screen digest.
# The four routes run side by side, because each is several minutes alone.
# EVERY DEMO, NOT ONE. The three are different maps -- DEMO1 E1M5, DEMO2 E1M3,
# DEMO3 E1M7 -- so each reaches code the others may not, and a port checked on
# one of them is claimed for the other two. PORT_DEMOS narrows the set for a run
# that is iterating; a narrower set is reported as a skip, so REQUIRE_ALL=1
# refuses it and a partial run cannot read as a full one.
#
# THE COST IS WALL TIME, AND SCREENS_JOBS IS THE KNOB. Demos x routes run side by
# side, with the leaf-modes runs and the job-mode-1 recording runs below (three
# per demo), at most SCREENS_JOBS at once (21 by default, every run at once); the
# section then takes about as long
# as its slowest run, the adapter over DEMO1. A host with fewer cores lowers the
# cap and waits longer; it does not check less.
ALL_DEMOS="DEMO1 DEMO2 DEMO3"
PORT_DEMOS=${PORT_DEMOS:-$ALL_DEMOS}
SCREENS_JOBS=${SCREENS_JOBS:-21}
for d in $PORT_DEMOS; do
  case " $ALL_DEMOS " in *" $d "*) ;; *) echo "screens.sh: PORT_DEMOS names $d, which is not one of $ALL_DEMOS" >&2; exit 2 ;; esac
done
[ "$PORT_DEMOS" = "$ALL_DEMOS" ] ||
  skipped "the demos PORT_DEMOS leaves out" "PORT_DEMOS is '$PORT_DEMOS', not '$ALL_DEMOS'"
tics_of() { for e in $DEMOS; do [ "${e%:*}" = "$1" ] && echo "${e#*:}"; done; }
# A demo's session layout: HARNESS_SESSION_ROOT/<demo>/gen, one per map. DEMO1's
# is also HARNESS_SESSION_DIR, which is all an older build printed.
session_of() {
  if [ -n "${HARNESS_SESSION_ROOT:-}" ] && [ -d "$HARNESS_SESSION_ROOT/$1/gen" ]; then echo "$HARNESS_SESSION_ROOT/$1/gen"
  elif [ "$1" = DEMO1 ] && [ -n "${HARNESS_SESSION_DIR:-}" ] && [ -d "$HARNESS_SESSION_DIR" ]; then echo "$HARNESS_SESSION_DIR"
  fi
}

# AND THE PORT IS CHECKED AGAINST THE RECORDING, which is the half that survives
# the cutover. The live comparison in source-port.rb needs the original running
# beside the port; this one does not, so having it green BEFORE the original is
# removed makes the cutover a deletion rather than a new oracle stood up when
# nothing else is watching.
#
# THE ROUTES. The pure Ruby route needs nothing built. The others are the same
# check with the port's side compiled, laid out in a session, or reached through
# the adapter; each needs an artifact this file does not build, so each SAYS SO
# when it is absent rather than passing over it: a route that never ran must not
# read the same as a route that ran and agreed. REQUIRE_ALL=1 turns those into
# failures, as elsewhere here.
if stage1_lanes_run; then
echo "== the port produces the recorded screens on every route, over all of $PORT_DEMOS =="
SP=$ROOT/tests/doom-core/source-port.rb
running=0
route_start() { # demo, route, then the environment as NAME=VALUE words; runs in the background
  demo=$1; route=$2; shift 2
  if [ "$running" -ge "$SCREENS_JOBS" ]; then wait; running=0; fi
  ( t0=$(date +%s)
    env "$@" SOURCE_PORT_DEMO="$demo" SOURCE_PORT_GOLDEN="$FIX/$demo.tsv" \
      "$RUBY" "$SP" "$WADFILE" frame "$(tics_of "$demo")" none < /dev/null > "$DIR/route-$demo-$route.out" 2>&1
    echo "rc=$? seconds=$(( $(date +%s) - t0 ))" >> "$DIR/route-$demo-$route.out" ) &
  running=$((running + 1))
  runs="$runs $demo:$route"
}
# THE LEAF ORACLE RUNS IN JOB MODE 2 AND THE PROGRAM'S DEFAULT IS JOB MODE 0.
# The route runs above check every ported leaf at every call, in mode 2; the
# playable program (bin/doom.rb without -jobs) draws in mode 0. The mode-2
# checks stand for the shipped default only because every leaf sees the same
# calls, returns the same results and leaves the same state in both modes, and
# THIS IS WHAT ASSERTS IT: tests/doom-core/leaf-modes.rb digests the original's
# leaf calls, in each mode, over every demo, and the two must agree. It is not a
# duplicate of the leaf checks -- it runs no port -- and deleting it leaves the
# mode-2 checks standing for a configuration nobody compared them with.
LM=$ROOT/tests/doom-core/leaf-modes.rb
modes_start() { # demo, mode; runs in the background
  if [ "$running" -ge "$SCREENS_JOBS" ]; then wait; running=0; fi
  ( t0=$(date +%s)
    "$RUBY" "$LM" --audit "$HARNESS_AUDIT_DIR" "$WADFILE" "$1" "$(tics_of "$1")" "$2" \
      < /dev/null > "$DIR/modes-$1-$2.out" 2>&1
    echo "rc=$? seconds=$(( $(date +%s) - t0 ))" >> "$DIR/modes-$1-$2.out" ) &
  running=$((running + 1))
}
have_audit() { [ -n "${HARNESS_AUDIT_DIR:-}" ] && [ -f "${HARNESS_AUDIT_DIR:-}/state-use.tsv" ]; }
# THE RECORDING IN THE MODE THE PROGRAM CAN QUEUE IN. bin/doom.rb's -jobs selects
# job mode 1 -- the executor with its strict checks -- and it has no switch for
# mode 2, which every lane here runs. The recording was taken in mode 0. So the
# original is replayed in mode 1 over every demo and must give the recording:
# otherwise the lanes' mode-2 evidence would be about a configuration the program
# cannot ship, and the direct path's mode 0 about the only one it can.
jm1_start() { # demo; runs in the background
  if [ "$running" -ge "$SCREENS_JOBS" ]; then wait; running=0; fi
  mkdir -p "$DIR/jm1-$1"
  ( "$RUBY" "$SIM" "$WADFILE" "$1" "$(tics_of "$1")" "$DIR/jm1-$1" frame,jobs < /dev/null > "$DIR/jm1-$1/sim.log" 2>&1
    echo "rc=$?" >> "$DIR/jm1-$1/sim.log" ) &
  running=$((running + 1))
}
route_judge() { # demo, route
  demo=$1; route=$2; out=$DIR/route-$demo-$route.out; tics=$(tics_of "$demo")
  if grep -q '^rc=0 ' "$out"; then
    ok "$demo $route played $demo" "$(sed -n 's/^demo \([A-Z0-9]*\) .*/\1/p' "$out")" "$demo"
    ok "$demo $route compared $tics frames" \
       "$(sed -n 's/^frames compared against the recording \([0-9]*\),.*/\1/p' "$out")" "$tics"
    ok "$demo $route disagreed with none of them" \
       "$(sed -n 's/.*golden-disagree \([0-9][0-9]*\).*/\1/p' "$out" | head -1)" 0
    ok "$demo $route agreed on the full screen of every one" \
       "$(sed -n 's/.*full screen agreeing \([0-9]*\)$/\1/p' "$out")" "$tics"
    # The same run compares every renderer leaf with the original at every call
    # (frame mode does, whatever else it checks); these two lines are what makes
    # that comparison a check. Before them it ran here and nothing read it.
    ok "$demo $route: no renderer leaf disagreed at any call" \
       "$(sed -n 's/.* leaf-disagree \([0-9]*\).*/\1/p' "$out" | head -1)" 0
    ok "$demo $route: and every leaf was called" \
       "$(sed -n 's/^leaves calls \([^ ]*\) .*/\1/p' "$out" | tr ',' '\n' | grep -c '=0$')" 0
    # The walls' seg loop: every wall column the original pushed inside it was
    # pushed by the port's loop too, and only DEMO2 has masked-texture walls
    # (measured: DEMO2 from frame 53, DEMO1 and DEMO3 none), so its openings
    # write is compared there and nowhere else.
    sl=$(sed -n 's/^segloop columns \([0-9]*\) masked-calls \([0-9]*\) original-pushes \([0-9]*\)$/\1 \2 \3/p' "$out")
    set -- $sl
    ok "$demo $route: the port's seg loop pushed every wall column the original's did" \
       "$([ -n "$sl" ] && [ "$1" -gt 0 ] && [ "$1" = "$3" ] && echo yes || echo "no ($sl)")" yes
    ok "$demo $route: the seg loop's masked-column branch was compared $( [ "$demo" = DEMO2 ] && echo 'in some calls' || echo 'in none')" \
       "$( [ -n "$sl" ] && { [ "$demo" = DEMO2 ] && [ "$2" -gt 0 ] || { [ "$demo" != DEMO2 ] && [ "$2" = 0 ]; }; } && echo yes || echo "no ($sl)")" yes
    # The things' copy runs to the tick's high-water mark; copy.tsv writes the
    # bound, and no run may pass it.
    am=$(sed -n 's/^copy mobj alloc-max \([0-9]*\) .*/\1/p' "$out")
    ok "$demo $route: the things' copy stayed within its bound of $MOBJ_BOUND" \
       "$([ -n "$am" ] && [ "$am" -le "$MOBJ_BOUND" ] && echo yes || echo "no ($am)")" yes
    [ -n "$am" ] && [ "$am" -gt "$mobj_seen" ] && mobj_seen=$am
  else
    ok "$demo $route runs" no yes
    tail -3 "$out" | sed 's/^/        /'
  fi
}
# The bound copy.tsv writes for the things' copy, and the largest high-water mark
# any run reached: the two must be the same number, so the bound is measured and
# stays measured.
MOBJ_BOUNDS=$(awk -F"$(printf '\t')" '!/^#/ && $3 ~ /^mobj_alloc:/ { sub(/^mobj_alloc:/, "", $3); print $3 }' \
  "$ROOT/tests/doom-core/fixtures/source/copy.tsv" | sort -u)
MOBJ_BOUND=$(echo "$MOBJ_BOUNDS" | head -1)
ok "every copy row bounded by the tick's high-water mark writes the same bound" \
   "$(echo "$MOBJ_BOUNDS" | grep -c .)" 1
mobj_seen=0
runs=""
section_start=$(date +%s)
for demo in $PORT_DEMOS; do
  sess=$(session_of "$demo")
  route_start "$demo" ruby
  if [ -n "${HARNESS_SOURCE_LIB:-}" ] && [ -f "${HARNESS_SOURCE_LIB:-}" ]; then
    route_start "$demo" compiled SOURCE_PORT_NATIVE="$HARNESS_SOURCE_LIB"
  else
    skipped "the compiled route over $demo" "HARNESS_SOURCE_LIB names no library; build it with tests/doom-core/harness/build-artifacts.sh"
  fi
  if [ -n "${HARNESS_SOURCE_LIB:-}" ] && [ -f "${HARNESS_SOURCE_LIB:-}" ] && [ -n "$sess" ]; then
    route_start "$demo" session SOURCE_PORT_NATIVE="$HARNESS_SOURCE_LIB" SOURCE_PORT_SESSION="$sess"
  else
    skipped "the session route over $demo" "no library, or no $demo layout under HARNESS_SESSION_ROOT; build them with tests/doom-core/harness/build-artifacts.sh"
  fi
  if [ -n "${HARNESS_ADAPTER_LIB:-}" ] && [ -f "${HARNESS_ADAPTER_LIB:-}" ] && [ -n "$sess" ]; then
    route_start "$demo" adapter SOURCE_PORT_NATIVE="$HARNESS_ADAPTER_LIB" SOURCE_PORT_SESSION="$sess" \
                                SOURCE_PORT_ADAPTER="$HARNESS_ADAPTER_LIB"
  else
    skipped "the adapter route over $demo" "no adapter library, or no $demo layout under HARNESS_SESSION_ROOT; build them with tests/doom-core/harness/build-artifacts.sh"
  fi
  jm1_start "$demo"
  if have_audit; then
    modes_start "$demo" 0
    modes_start "$demo" 2
  else
    skipped "the leaf calls in job modes 0 and 2 over $demo" "HARNESS_AUDIT_DIR names no audit; build-artifacts.sh writes one under its directory"
  fi
done
wait
section_end=$(date +%s)
for r in $runs; do route_judge "${r%:*}" "${r#*:}"; done
[ "$PORT_DEMOS" = "$ALL_DEMOS" ] &&
  ok "the things' copy bound is the demos' own high-water mark" "$mobj_seen" "$MOBJ_BOUND"
for demo in $PORT_DEMOS; do
  grep -v '^#gametic' "$DIR/jm1-$demo/frames.tsv" > "$DIR/jm1-$demo.got" 2>/dev/null
  grep -v '^#' "$FIX/$demo.tsv" > "$DIR/jm1-$demo.want"
  ok "$demo in job mode 1, the strict executor, gives the job mode 0 recording" \
     "$(sed -n 's/^rc=//p' "$DIR/jm1-$demo/sim.log")|$(grep -c 'jobmode=1 ' "$DIR/jm1-$demo/sim.log")|$(wc -l < "$DIR/jm1-$demo.got" | tr -d ' ')|$(cmp -s "$DIR/jm1-$demo.got" "$DIR/jm1-$demo.want" && echo same || echo differs)" \
     "0|1|$(tics_of "$demo")|same"
done
if have_audit; then
  for demo in $PORT_DEMOS; do
    for m in 0 2; do
      # and printed a line for every leaf it derived: two empty runs must not agree
      grep '^leaf ' "$DIR/modes-$demo-$m.out" > "$DIR/modes-$demo-$m.leaves"
      ok "$demo leaf calls in job mode $m ran over the whole demo, one line per leaf" \
         "$(sed -n 's/^leaf-modes \([A-Z0-9]*\) mode \([02]\) tics \([0-9]*\) leaves \([0-9]*\) .*/\1 \2 \3 \4/p' "$DIR/modes-$demo-$m.out")" \
         "$demo $m $(tics_of "$demo") $(grep -c . "$DIR/modes-$demo-$m.leaves")"
    done
    ok "$demo: every leaf was called" "$(grep -c ' calls 0 ' "$DIR/modes-$demo-0.leaves")" 0
    ok "$demo: every leaf's calls, results and writes are the same in job modes 0 and 2" \
       "$(diff "$DIR/modes-$demo-0.leaves" "$DIR/modes-$demo-2.leaves" | grep '^[<>]' | cut -d' ' -f2,3 | sort -u | tr '\n' ' ')" ""
  done
fi
# What the section cost, run by run: the figure to reason about SCREENS_JOBS with.
echo "  wall $((section_end - section_start))s at SCREENS_JOBS=$SCREENS_JOBS;" \
     "$(for r in $runs; do printf '%s %ss, ' "$r" "$(sed -n 's/^rc=[0-9]* seconds=//p' "$DIR/route-${r%:*}-${r#*:}.out")"; done)" \
     "$(have_audit && for d in $PORT_DEMOS; do for m in 0 2; do printf '%s:modes%s %ss, ' "$d" "$m" "$(sed -n 's/^rc=[0-9]* seconds=//p' "$DIR/modes-$d-$m.out")"; done; done)"
# WHAT THE DEMOS DO NOT REACH, stated rather than assumed. The status bar's "n/a"
# and its key-box erase are taken by no recorded demo, which is why the check
# below drives them directly; if a demo ever reaches one, this says so.
for demo in $PORT_DEMOS; do
  ok "$demo takes neither of the status bar's rare branches" \
     "$(sed -n 's/^furniture branches //p' "$DIR/route-$demo-ruby.out")" "na 0 key-erase 0"
done

# THE INPUT THAT MAKES THE PORT CHECK FAIL: DEMO1's recording with frame 42
# altered, over 60 frames on the Ruby route.
echo "== the port check rejects a recording the port does not produce =="
SOURCE_PORT_GOLDEN="$FIX/DEMO1-rejected.tsv" "$RUBY" "$SP" "$WADFILE" frame 60 none > "$DIR/port.out" 2>&1
ok "exactly one frame disagrees" "$(sed -n 's/.*golden-disagree \([0-9][0-9]*\).*/\1/p' "$DIR/port.out" | head -1)" 1
ok "and it is the frame that was altered" \
   "$(sed -n 's/^first golden-disagree frame \([0-9]*\) .*/\1/p' "$DIR/port.out")" 42

# THE BOUNDARY COPY. Each buffer it carries, left out, must turn the comparison
# red -- the copy's targets start poisoned so this holds even for a buffer that
# never changes -- AND FIRST AT THE FRAME copy.tsv WRITES BESIDE IT. "Red
# somewhere" is not enough: a poison that equals the truth until late shows late,
# and hud_message_on once passed 400 frames that way. Eighty frames reach every
# expected frame: the status bar's three at 0, flattranslation at 8 when the
# first flat animates, the HUD's two at 60, the first message.
echo "== each buffer the boundary copy carries is needed, from its frame =="
# Read from a file, not a pipe: a piped loop runs in a subshell and its passes
# and failures would not be counted.
grep -v '^#' "$ROOT/tests/doom-core/fixtures/source/copy.tsv" > "$DIR/copy-rows.tsv"
while IFS="$(printf '\t')" read -r b first bound; do
  SOURCE_PORT_COPY_SKIP=$b "$RUBY" "$SP" "$WADFILE" frame 80 none < /dev/null > "$DIR/copy-$b.out" 2>&1
  red=0
  for k in frame-disagree plane-disagree screen-disagree leaf-disagree; do
    v=$(sed -n "s/.* $k \\([0-9]*\\).*/\\1/p" "$DIR/copy-$b.out" | head -1)
    red=$((red + ${v:-0}))
  done
  ok "leaving out $b turns the comparison red" "$([ "$red" -gt 0 ] && echo yes || echo no)" yes
  ok "and first shows at frame $first" \
     "$(sed -n "s/^copy skipped $b first disagreement frame \\([0-9a-z]*\\) expected .*/\\1/p" "$DIR/copy-$b.out")" "$first"
done < "$DIR/copy-rows.tsv"

# AND THE COPY CARRIES EXACTLY WHAT IT MUST, derived rather than remembered. It
# needs the audit's state-use table, which the artifacts build writes.
echo "== the boundary copy carries exactly what ported readers need =="
CC=$ROOT/tests/doom-core/copy-check.rb
if [ -n "${HARNESS_AUDIT_DIR:-}" ] && [ -f "${HARNESS_AUDIT_DIR:-}/state-use.tsv" ]; then
  SU=$HARNESS_AUDIT_DIR/state-use.tsv
  "$RUBY" "$CC" --state-use "$SU" > "$DIR/copy-check.out" 2>&1
  ok "the copy carries exactly the required buffers" "$?" 0
  # Its failing inputs, both directions, built here rather than kept as files.
  grep -v '^#' "$ROOT/tests/doom-core/fixtures/source/copy.tsv" | sed 1d > "$DIR/copy-missing.tsv"
  "$RUBY" "$CC" --state-use "$SU" --copy "$DIR/copy-missing.tsv" > "$DIR/copy-missing.out" 2>&1
  ok "a required buffer left out is refused by name" \
     "$(grep -c 'is read by a ported definition and is not in the copy' "$DIR/copy-missing.out")" 1
  # the extra buffer is one no ported definition reads today, chosen by the
  # check itself: a fixed name stops being unread when its first reader moves
  UNREAD=$("$RUBY" "$CC" --state-use "$SU" --list-unread | head -1)
  { grep -v '^#' "$ROOT/tests/doom-core/fixtures/source/copy.tsv"; echo "$UNREAD"; } > "$DIR/copy-extra.tsv"
  "$RUBY" "$CC" --state-use "$SU" --copy "$DIR/copy-extra.tsv" > "$DIR/copy-extra.out" 2>&1
  ok "a buffer nothing ported reads is refused by name" \
     "$([ -n "$UNREAD" ] && grep -c "$UNREAD is in the copy and no ported definition reads it" "$DIR/copy-extra.out")" 1
else
  skipped "the copy check" "HARNESS_AUDIT_DIR names no audit; build-artifacts.sh writes one under its directory"
fi

else
  stage1_retired "the port beside the original on every route, and the boundary copy"
fi

# DUPLICATED HELPERS HAVE NOT DRIFTED. A helper separate entries use is copied
# into each closure rather than shared, and a copy that drifts is a divergence we
# made ourselves. Cheap and needs nothing built; its failing input is a copy of
# the sources with one character changed in one copy.
echo "== duplicated helpers are still their originals =="
DC=$ROOT/tests/doom-core/dup-check.rb
"$RUBY" "$DC" > "$DIR/dup.out" 2>&1
ok "every listed copy is its original, renamed" "$?" 0
mkdir -p "$DIR/dupsrc"
cp "$ROOT"/examples/doom/core/src/*.rb "$DIR/dupsrc/"
sed 's/  v >= 0x8000 ? v - 0x10000 : v/  v >= 0x8000 ? v - 0x10001 : v/' \
  "$ROOT/examples/doom/core/src/hud.rb" > "$DIR/dupsrc/hud.rb"
"$RUBY" "$DC" --root "$DIR/dupsrc" > "$DIR/dup-drift.out" 2>&1
ok "a copy changed by one character is refused by name" \
   "$(grep -c 'dc_hud_i16 has drifted from dc_i16' "$DIR/dup-drift.out")" 1
# The column entry's copy lives in the source fixture, not among the units, so
# its drift is planted there: one character in dc_sp_draw_column.
mkdir -p "$DIR/dupfix"
cp "$ROOT"/tests/doom-core/fixtures/source/src/*.rb "$DIR/dupfix/"
sed 's/    frac = core_w32_add(frac, fracstep)$/    frac = core_w32_add(frac, fracstep + 1)/' \
  "$ROOT/tests/doom-core/fixtures/source/src/entries.rb" > "$DIR/dupfix/entries.rb"
"$RUBY" "$DC" --fixture "$DIR/dupfix" > "$DIR/dup-fixdrift.out" 2>&1
ok "and so is the source fixture's copy" \
   "$(diff "$ROOT/tests/doom-core/fixtures/source/src/entries.rb" "$DIR/dupfix/entries.rb" | grep -c '^[<>]')|$(grep -c 'dc_sp_draw_column has drifted from dc_draw_column' "$DIR/dup-fixdrift.out")|$(grep -c 'FAIL' "$DIR/dup-fixdrift.out")" "2|1|1"

# THE STATUS BAR'S TWO RARE BRANCHES, which no recorded demo takes: the ready
# weapon's "n/a" and a key box erased to draw another key (source-port.rb's
# `furniture branches` line counts both, and all three demos print 0). The
# check drives them on synthetic frames through the original and the port, and
# is shown failing over two copies of the port, each with one branch broken.
echo "== the status bar's branches no demo reaches =="
SBB=$ROOT/tests/doom-core/statusbar-branches.rb
SBSRC=$ROOT/examples/doom/core/src/statusbar.rb
"$RUBY" "$SBB" "$WADFILE" > "$DIR/sbb.out" 2>&1; rc=$?
ok "the port draws both as the original does" "$rc|$(tail -1 "$DIR/sbb.out")" \
   "0|statusbar-branches: 4 frames, na 1, key-erase 1, disagree 0"
sed 's/^      if old_keybox\[i\] != -1$/      if false/' "$SBSRC" > "$DIR/sb-noerase.rb"
sed 's/? SB_NA : ammo\[ammokind\]/? 0 : ammo[ammokind]/' "$SBSRC" > "$DIR/sb-nona.rb"
for m in noerase nona; do
  "$RUBY" "$SBB" "$WADFILE" "$DIR/sb-$m.rb" > "$DIR/sbb-$m.out" 2>&1; rc=$?
  ok "a port with the $m branch broken differs in one line and is refused" \
     "$(diff "$SBSRC" "$DIR/sb-$m.rb" | grep -c '^[<>]')|$rc|$(grep -c 'differs' "$DIR/sbb-$m.out" | sed 's/^0$/none/;s/^[1-9][0-9]*$/some/')" "2|1|some"
done

# THE RENDERER'S LEAVES ARE CHECKED AT EACH CALL, NOT ON THE SCREEN. Their
# callers are not ported, so the original still computes every pixel from its
# own copies and nothing a leaf does can move one: the recorded screens above are
# a CONTROL for them, which must not move, and not evidence. The evidence is
# source-port.rb running each leaf beside the original at every call and
# comparing its result and writes. The route runs above assert that over every
# frame of every demo on every route -- no disagreement, every leaf called --
# which is what covers the rare branches: check_plane makes a new plane 120 times
# in DEMO1's first 600 frames, all in the first 40, and 3362 times over the
# whole demo.
#
# THE WALLS' SEG LOOP IS THE EXCEPTION, AND THE SCREEN SEES IT: its port pushes
# the wall jobs the port's executor draws (the lane's own push stands aside
# inside the original's loop), so the recorded screens above are evidence for
# it as well as its per-call check.
#
# THIS SECTION SHOWS THE CHECK CAN FAIL: a broken copy of each leaf
# (fixtures/source/leaf-mutants.tsv) must make the first disagreement land on
# that leaf. THE 120 IS THE LENGTH OF THOSE RUNS AND NOTHING ELSE, and it is a
# cost decision: twelve runs of 120 frames on the Ruby route take seconds, where
# one run over the whole of DEMO1 takes about 400 s. It is also a floor -- the
# latest first occurrence among the broken branches is clip_value's openings
# branch, at DEMO1 frame 110 -- and a floor is a minimum: a mutant that first
# shows after frame 120 would pass here, and the whole-demo check above is what
# would still see the port it describes. A row that cannot show in DEMO1's
# first 120 frames names its own file, demo, length and first frame, each
# measured; the first frame is then asserted too.
if stage1_lanes_run; then
echo "== a broken copy of each renderer leaf is caught at that leaf =="
LEAVES=$ROOT/examples/doom/core/src/leaves.rb
SEGS=$ROOT/examples/doom/core/src/segs.rb
LEAFMUT=$ROOT/tests/doom-core/fixtures/source/leaf-mutants.tsv
mkdir -p "$DIR/leaves"
grep -v '^#' "$LEAFMUT" > "$DIR/leaves/rows.tsv"
while IFS="$(printf '\t')" read -r m entry lines expr file demo frames first; do
  if [ "${file:-leaves}" = segs ]; then src=$SEGS; var=SOURCE_PORT_SEGS; else src=$LEAVES; var=SOURCE_PORT_LEAVES; fi
  sed "$expr" "$src" > "$DIR/leaves/$m.rb"
  ( env SOURCE_PORT_DEMO="${demo:-DEMO1}" "$var=$DIR/leaves/$m.rb" "$RUBY" "$SP" "$WADFILE" frame "${frames:-120}" none \
      < /dev/null > "$DIR/leaves/$m.out" 2>&1 ) &
done < "$DIR/leaves/rows.tsv"
wait
while IFS="$(printf '\t')" read -r m entry lines expr file demo frames first; do
  if [ "${file:-leaves}" = segs ]; then src=$SEGS; else src=$LEAVES; fi
  at=$(sed -n 's/^first leaf-disagree frame \([0-9]*\) [a-z]* .*/\1/p' "$DIR/leaves/$m.out")
  [ "${first:--}" = - ] && at=-
  ok "a $(basename "$src") with $m broken differs where it should and first disagrees at $entry${demo:+ ($demo, ${frames} frames)}" \
     "$(diff "$src" "$DIR/leaves/$m.rb" | grep -c '^[<>]')|$(sed -n 's/^first leaf-disagree frame [0-9]* \([a-z]*\) .*/\1/p' "$DIR/leaves/$m.out")|$at" \
     "$lines|$entry|${first:--}"
done < "$DIR/leaves/rows.tsv"

# THE MODES CHECK IS A CHECK: the same answer for the same input, a different
# one for a perturbed input, and a refusal where its derivation would narrow.
# SAME FOR SAME COMES FIRST. A digest that folds in anything a process seeds
# gives two runs of ONE mode different answers, and then the mode comparison
# above reports a difference that is the instrument's own; that happened in the
# measurement this check replaces. Sixty frames of DEMO1 on the Ruby side are
# seconds; the perturbation adds one to a visplane top cell after the first
# find_plane, so the two plane leaves must differ and nothing else.
echo "== the leaf-modes check agrees with itself, sees a perturbation, and refuses to narrow =="
if have_audit; then
  mkdir -p "$DIR/lm"
  lm() { # name, then the options and arguments
    n=$1; shift
    "$RUBY" "$LM" --audit "$HARNESS_AUDIT_DIR" "$@" < /dev/null > "$DIR/lm/$n.out" 2> "$DIR/lm/$n.err"
    echo "$?" > "$DIR/lm/$n.rc"
    grep '^leaf ' "$DIR/lm/$n.out" > "$DIR/lm/$n.leaves"
  }
  lm same-a "$WADFILE" DEMO1 60 2 & lm same-b "$WADFILE" DEMO1 60 2 & lm broken --break find_plane:1 "$WADFILE" DEMO1 60 2 &
  wait
  ok "two runs of one mode, in two processes, give the same digests" \
     "$(cat "$DIR/lm/same-a.rc")|$(grep -c . "$DIR/lm/same-a.leaves")|$(cmp -s "$DIR/lm/same-a.leaves" "$DIR/lm/same-b.leaves" && echo same)" \
     "0|$(sed -n 's/.* leaves \([0-9]*\) .*/\1/p' "$DIR/lm/same-a.out")|same"
  ok "a visplane cell perturbed after the first find_plane changes the two plane leaves and no other" \
     "$(diff "$DIR/lm/same-a.leaves" "$DIR/lm/broken.leaves" | sed -n 's/^> leaf \([a-z_]*\) .*/\1/p' | tr '\n' ' ')" \
     "check_plane find_plane "
  # A leaves.rb definition no leaf call reaches, and a field a leaf writes with
  # no slice, built here from the tracked sources and the audit.
  { cat "$LEAVES"; printf 'def dc_orphan(x)\n  x\nend\n'; } > "$DIR/lm/orphan.rb"
  lm orphan --leaves "$DIR/lm/orphan.rb" --check
  ok "a leaf definition no leaf call reaches is refused by name" \
     "$(cat "$DIR/lm/orphan.rc")|$(grep -c 'dc_orphan is defined in leaves.rb and no leaf call in source-port.rb reaches it' "$DIR/lm/orphan.err")" "2|1"
  awk -F"$(printf '\t')" 'BEGIN { OFS = FS } $1 == "Renderer" && $2 == "@viewx" { $11 = $11 ",Renderer#abs_angle" } { print }' \
    "$HARNESS_AUDIT_DIR/state-use.tsv" > "$DIR/lm/state-use.tsv"
  lm unsliced --state-use "$DIR/lm/state-use.tsv" --check
  ok "a written field with no slice is refused by name" \
     "$(cat "$DIR/lm/unsliced.rc")|$(grep -c '@viewx is written by a leaf and has no slice here' "$DIR/lm/unsliced.err")" "2|1"
  lm derived --check
  ok "and the tracked sources derive without a refusal" "$(cat "$DIR/lm/derived.rc")" 0
else
  skipped "the leaf-modes controls" "HARNESS_AUDIT_DIR names no audit; build-artifacts.sh writes one under its directory"
fi

else
  stage1_retired "the renderer leaves beside the original, and the leaf-modes controls"
fi

# THE ONE CLOSURE STILL BUILDS. The cutover reaches render through one native
# entry, so every ported definition must be admitted by the kernel in a single
# closure; build-artifacts.sh builds every fixture entry as one
# (tests/doom-core/one-closure.rb) and records what happened. Admission is
# asserted here with every entry in it, and so is the relocation check: the
# kernel's yes is not the last word. The dense-dispatch copy adds a jump table
# over every entry; its references are to the object's own sections, which the
# check admits by target (object-relocs.rb, the owner's rule of 2026-09-18), as
# it admits the tables the plain closure already has. That the check still
# refuses is shown on the same call: the closure's object beside a planted one
# that branches to a symbol it does not define. The shape line is the series:
# entries, buffers, parameters, object size and kernel seconds, per batch.
echo "== every fixture entry is admitted in one closure =="
if [ -n "${HARNESS_ONE_CLOSURE:-}" ] && [ -f "${HARNESS_ONE_CLOSURE:-}/none/shape.tsv" ]; then
  shape() { sed -n "s/^$2$(printf '\t')//p" "$HARNESS_ONE_CLOSURE/$1/shape.tsv"; }
  ok "the closure holds every fixture entry" \
     "$(shape none entries)" "$(ls "$ROOT"/tests/doom-core/fixtures/source/*.contract | grep -c .)"
  ok "the kernel admits it" "$(shape none kernel | cut -f1)" 0
  ok "and its object holds nothing but branches into its own code" "$(shape none relocs)" ok
  ok "the same closure dispatched on a dense op is admitted by the kernel and by the relocation check: its jump table is the object's own" \
     "$(shape dense kernel | cut -f1)|$(shape dense relocs)" "0|ok"
  oc=${CLANG:-${LLVM_PREFIX:+$LLVM_PREFIX/bin/clang}}
  if [ -n "$oc" ] && [ -f "$HARNESS_ONE_CLOSURE/none/one.o" ]; then
    mkdir -p "$DIR/one"
    printf 'int doom_planted_other(void);\nint doom_planted(void){return doom_planted_other();}\n' > "$DIR/one/planted.c"
    "$oc" -ffreestanding -c "$DIR/one/planted.c" -o "$DIR/one/planted.o" 2> "$DIR/one/planted.err"
    out=$("$RUBY" "$ROOT/tests/doom-core/object-relocs.rb" "$(dirname -- "$oc")" "$HARNESS_ONE_CLOSURE/none/one.o" "$DIR/one/planted.o" 2>&1); rc=$?
    ok "and the check still refuses: in one call the closure's object is ok, and a planted object branching to a symbol it does not define is refused" \
       "$rc|$(printf '%s\n' "$out" | grep -c '^one ok$')|$(printf '%s\n' "$out" | grep -c '^planted refused .* to _\{0,1\}doom_planted_other, which this object does not define$')" "1|1|1"
  else
    skipped "the planted refusal beside the closure's object" "no compiler: set CLANG or LLVM_PREFIX"
  fi
  echo "  one closure: entries $(shape none entries) buffers $(shape none buffers) params $(shape none params)" \
       "object $(shape none bytes) B kernel $(shape none kernel | cut -f2) s"
else
  skipped "the one-closure build" "HARNESS_ONE_CLOSURE names no build; build-artifacts.sh writes one under its directory"
fi

# THE HUD'S MESSAGE OFFSETS ARE CHECKED WHERE FULL PREPARES THEM. hud_text_ofs is
# derived from the same parts as the joined hud_texts, and Resources refuses
# offsets that do not start at 0, go backwards, or end anywhere but the joined
# byte count -- which it measures, and nobody writes down. The session and
# adapter routes above draw with the prepared offsets; this shows the refusals
# refusing, and that the offsets are BYTES, not characters.
echo "== the HUD's message offsets are checked where they are prepared =="
"$RUBY" -e '
  require ARGV[0]
  r = Doom::Core::Resources
  try = lambda do |ofs, total|
    r.check_offsets("hud_text_ofs", ofs, total)
    "ok"
  rescue r::PreparationError => e
    e.message
  end
  puts try.([0, 3, 5], 5), try.([1, 3, 5], 5), try.([0, 5, 3], 5), try.([0, 3, 4], 5)
  parts = Struct.new(:parts).new(["ab", "é", ""])
  puts r::OffsetsOf.new("hud_text_ofs", parts, :parts, nil).offsets.join(",")
' "$ROOT/examples/doom/core/full/resources.rb" > "$DIR/ofs.out" 2>&1
ok "offsets that are sound are accepted" "$(sed -n 1p "$DIR/ofs.out")" ok
ok "a first offset other than 0 is refused" "$(sed -n 2p "$DIR/ofs.out")" "hud_text_ofs[0] is 1, not 0"
ok "an offset below the one before is refused" "$(sed -n 3p "$DIR/ofs.out")" "hud_text_ofs[2] is 3, below hud_text_ofs[1] 5"
ok "a last offset that is not the joined byte count is refused" "$(sed -n 4p "$DIR/ofs.out")" \
   "hud_text_ofs's last offset is 4, the joined bytes are 5"
ok "a two-byte character advances the offset by two" "$(sed -n 5p "$DIR/ofs.out")" "0,2,4,4"

echo "screens: $((pass + fail)) checked, $pass pass, $fail fail, $skip skipped; port demos $PORT_DEMOS"
if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then
  {
    echo "screens.sh: REQUIRE_ALL=1, and $skip check(s) did not run:"
    printf '%s' "$skips"
    echo "screens.sh: the routes differ in what the PORT's side is compiled from, so a"
    echo "  route that did not run is a route whose port was never compared with the"
    echo "  recording. Build the artifacts and set the three names rather than unsetting"
    echo "  REQUIRE_ALL, which turns a check that did not run back into a silent skip."
  } >&2
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1
