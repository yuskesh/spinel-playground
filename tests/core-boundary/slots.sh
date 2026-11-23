#!/bin/sh
#
# tests/core-boundary/slots.sh — the third capability of decision 0007 task 5:
# the fixed-capacity slot and link state the DOOM thinker list and mobj
# allocator keep, with insertion, removal, reuse and exhaustion.
#
#   KERNEL=<spinel-core-kernel> tests/core-boundary/slots.sh
#
# What makes this different from the other two capabilities is the ORACLE.
# There the original Full method is itself an independent answer: it computes
# the same pixels or the same fixed-point value a different way, and a
# disagreement is a real one. Here the extraction is pointer surgery and so is
# the original, so a second spelling of the same surgery agreeing with the
# first would show that the transcription was faithful and nothing more. A
# transposition would be copied across and agree.
#
# So decision 0007 asks for an INDEPENDENT REFERENCE MODEL at this bullet, and
# fixtures/slots/model.rb is one: it keeps an ordered Array and a stack and
# DERIVES what the link fields must contain, never assigning one from another.
# Three worlds run every operation and all three must agree on every cell.
#
# Seven lanes:
#
#   1. provenance. Each extracted kernel names the original it came from, in
#      its own text, every extracted kernel is recorded exactly once, and the
#      ORIGINAL is digested against originals.tsv, so an original drifting
#      under a still-passing extraction is a failure rather than something
#      noticed later.
#   2. the adaptation. Under CRuby, the ORIGINAL Doom::Game methods, the
#      extracted Ruby and the independent model must agree on the status, the
#      result and EVERY CELL after every operation. trace.rb refuses to emit
#      anything otherwise.
#   3. the kernels. The CORE objects, called from C over the same trace, must
#      reproduce the cells the ORIGINAL produced. The C harness models
#      nothing: it parses, calls and compares.
#   4. exhaustion, at the ORIGINAL's own capacity. Everything else runs over
#      short arrays, which the original is happy with because MAXTHINKERS
#      appears in it only in the overflow guard; exhaustion is the one place
#      the two capacities have to be the same number.
#   5. the status ABI. An index outside an array, a bump allocator with
#      nothing left, and a `th_next` chain that closes on itself are where
#      CRuby cannot answer -- a Ruby Array grows or reads nil, and vanilla
#      walks the cycle forever. Each is paired with the case just inside the
#      same edge.
#   6. mutation controls. One point of one extracted source is changed and
#      both comparisons must fail.
#   7. the harness's own guards, and the order control. A trace that never
#      reuses a slot, or never reaches a kernel, or whose ABI checks are all
#      of a kind, must be refused; and the same operations in another order
#      must end in a DIFFERENT state, or reuse order would be a claim about a
#      trace that did not depend on it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/core-boundary/fixtures/slots"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
RUBY="${RUBY:-ruby}"

die() { echo "slots: $*" >&2; exit 1; }
[ -f "$FIX/trace.tsv" ] || die "no trace at $FIX/trace.tsv"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build it first)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
"$RUBY" -e 'exit 0' >/dev/null 2>&1 || die "'$RUBY' does not run"
# The floor is checked HERE rather than met halfway through, where a ruby that
# does not understand the fixture becomes a non-zero exit that the mutation
# controls below would read as a refusal they asked for. Same reasoning as
# oracle.rb, which states the same floor, and as closure.sh, which states its
# prism requirement here rather than inside its census.
"$RUBY" -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7.0") ? 0 : 1)' \
  >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' is $("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null), below the 2.7 floor
       this suite declares (tests/core-boundary/oracle.rb states it, and
       docs/building.md records that macOS's default 2.6 is not a selected
       reference); set RUBY=<a newer ruby>."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-slots.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0
TAB=$(printf '\t')
# The digest tool differs by platform: Debian ships sha256sum, macOS ships
# shasum.  Neither is guaranteed on the other.
sha256_of() {
  case "$(uname -s)" in
    Darwin) /usr/bin/shasum -a 256 "$1" ;;
    *)      sha256sum "$1" ;;
  esac | awk '{ print $1 }'
}


# Replace exactly one literal occurrence of $2 with $3 in $1, writing $4.
# Literal, not a regular expression: the mutation targets hold brackets and
# stars, and a control that silently matched something else would be worse than
# no control. Exits non-zero unless there was exactly one.
replace_once() {
  case "$2$3" in *\\*) return 1 ;; esac
  awk -v old="$2" -v new="$3" '
    { line = $0; out = ""
      while ((i = index(line, old)) > 0) {
        out = out substr(line, 1, i - 1) new
        line = substr(line, i + length(old))
        n = n + 1
      }
      print out line }
    END { exit (n == 1 ? 0 : 1) }
  ' "$1" > "$4"
}

echo "== provenance =="
n_prov=0
while IFS="$TAB" read -r extracted original token upstream; do
  case "$extracted" in \#*|"") continue ;; esac
  n_prov=$((n_prov + 1))
  if [ ! -f "$FIX/src/$extracted.rb" ]; then
    echo "  FAIL $extracted is recorded but not extracted"; fail=$((fail + 1)); continue
  fi
  if [ ! -f "$ROOT/$original" ]; then
    echo "  FAIL $extracted records $original, which is not there"
    fail=$((fail + 1)); continue
  fi
  if ! grep -qF "$original" "$FIX/src/$extracted.rb"; then
    echo "  FAIL $extracted does not name $original in its own text"
    fail=$((fail + 1)); continue
  fi
  if ! grep -qF "$token" "$FIX/src/$extracted.rb"; then
    echo "  FAIL $extracted does not name its upstream ($token) in its own text"
    fail=$((fail + 1)); continue
  fi
  echo "  pass $extracted <- $original ($token; $upstream)"
  pass=$((pass + 1))
done < "$FIX/provenance.tsv"
[ "$n_prov" -gt 0 ] || die "the provenance table is empty"
# The originals themselves, not only their paths. provenance.tsv says WHERE
# each extraction came from; originals.tsv says WHAT it came from, and without
# that an original could change under a still-passing extraction and nothing
# here would say so. Measured: with a line appended to fixed.rb, the
# capabilities lane came back 49 of 49.
[ -f "$FIX/originals.tsv" ] || die "no digest table at $FIX/originals.tsv"
orig_bad=0; n_orig=0
while IFS="$TAB" read -r opath owant; do
  case "$opath" in \#*|"") continue ;; esac
  n_orig=$((n_orig + 1))
  if [ ! -f "$ROOT/$opath" ]; then
    echo "  FAIL the digest table names $opath, which is not there"
    orig_bad=$((orig_bad + 1)); continue
  fi
  ogot=$(sha256_of "$ROOT/$opath")
  if [ "$ogot" != "$owant" ]; then
    echo "  FAIL $opath has drifted from the revision this extraction was taken at:"
    echo "       recorded $owant"
    echo "       found    $ogot"
    orig_bad=$((orig_bad + 1))
  fi
done < "$FIX/originals.tsv"
[ "$n_orig" -gt 0 ] || die "the digest table is empty"
# Both directions, or an original could be dropped from the digest table while
# keeping its row in provenance.tsv with nothing checking it.
for opath in $(awk -F"$TAB" '!/^#/ && NF { print $2 }' "$FIX/provenance.tsv" | sort -u); do
  if ! awk -F"$TAB" -v want="$opath" '!/^#/ && $1 == want { found = 1 } END { exit !found }' \
       "$FIX/originals.tsv"; then
    echo "  FAIL provenance.tsv names $opath, and the digest table does not"
    orig_bad=$((orig_bad + 1))
  fi
done
if [ "$orig_bad" -eq 0 ]; then
  echo "  pass all $n_orig original(s) match the digest recorded for them"
  pass=$((pass + 1))
else
  fail=$((fail + 1))
fi


dup=$(awk -F"$TAB" '!/^#/ && NF { print $1 }' "$FIX/provenance.tsv" | sort | uniq -d)
if [ -n "$dup" ]; then
  echo "  FAIL the provenance table names these more than once: $dup"; fail=$((fail + 1))
fi
for f in "$FIX"/src/*.rb; do
  stem=$(basename "$f" .rb)
  if ! grep -q "^$stem$TAB" "$FIX/provenance.tsv"; then
    echo "  FAIL $stem is extracted with no recorded origin"; fail=$((fail + 1))
  fi
  if [ ! -f "$FIX/src/$stem.contract" ]; then
    echo "  FAIL $stem has no contract"; fail=$((fail + 1))
  fi
done

# The exit status is NOT the check, here or in the mutation controls below.
# trace.rb exits non-zero both when the three worlds disagree AND when it
# could not run at all -- a missing original, a ruby that does not understand
# it, a typo in the file -- and a lane that read only the status would report a
# semantic disagreement where there was a broken tool. Measured: with a syntax
# error appended to the copied trace.rb, every mutation control below reported
# "caught in Ruby", the two model controls rest on nothing else, and the lane
# passed 24 of 24.
#
# So the builder's OWN verdict is what is required, in both directions: its
# summary line when the three agree, and its own per-operation disagreement
# when they do not. Anything else is a broken control and says so.
TRACE_VERDICT='^trace: [0-9]+ operation\(s\) agree across the original, the extraction and the model'
TRACE_DIFFER='^trace: operation [0-9]+ \('
# The harness's own verdict that a kernel no longer reproduces the original's
# cells over the trace. The exhaustion lane has a dozen distinct verdicts and
# no single named one to require, so there it is the `harness:` line itself
# that is required -- a harness that could not start, or that crashed, writes
# none, and would otherwise have been scored a caught mutation.
HARNESS_DIFFER='^harness: (operation [0-9]+ wanted |after operation [0-9]+, )'

# The three worlds, the kernels' cells, the guards and the mutation controls
# read what CRuby running the original produced, so they run only on the
# owner's instruction (tools/oracle/gate). The kernels and the harness are
# built, and the mutation and check tables are checked, either way.
if "$ROOT/tools/oracle/gate" tests/core-boundary/slots.sh original; then oracle=1; else oracle=0; fi

if [ "$oracle" = 1 ]; then
  echo "== the original, the extraction and the model agree on every cell =="
  if "$RUBY" "$FIX/trace.rb" "$ROOT" "$FIX" "$WORK/trace.txt" > "$WORK/trace.out" 2> "$WORK/trace.err"; then
    if ! grep -Eq "$TRACE_VERDICT" "$WORK/trace.err"; then
      echo "  FAIL the trace builder exited 0 without its own verdict, so nothing"
      echo "       was compared:"
      sed 's/^/      /' "$WORK/trace.err" | head -6
      fail=$((fail + 1))
    else
      echo "  pass $(sed 's/^trace: //' "$WORK/trace.err" | tr -d '\n')"
      pass=$((pass + 1))
    fi
  elif grep -Eq "$TRACE_DIFFER" "$WORK/trace.err"; then
    echo "  FAIL the three worlds do not agree:"
    sed 's/^/      /' "$WORK/trace.err" | head -8
    fail=$((fail + 1))
  else
    echo "  FAIL the trace builder never reached a comparison, so this is a broken"
    echo "       control rather than a disagreement between the three worlds:"
    sed 's/^/      /' "$WORK/trace.err" | head -8
    fail=$((fail + 1))
  fi
  [ -s "$WORK/trace.txt" ] || die "the trace builder produced no trace"
fi

echo "== the CORE kernels reproduce the original's cells =="
built=0
for f in "$FIX"/src/*.contract; do
  stem=$(basename "$f" .contract)
  if "$KERNEL" "$f" --root "$FIX" -o "$WORK/$stem.o" \
       --header "$WORK/spinel_core_$stem.h" --clang "$CC_BIN" > "$WORK/$stem.build" 2>&1; then
    built=$((built + 1))
  else
    echo "  FAIL $stem did not build:"; sed 's/^/      /' "$WORK/$stem.build" | head -4
    fail=$((fail + 1))
  fi
done
n_src=$(ls "$FIX"/src/*.contract | wc -l | tr -d ' ')
[ "$built" -eq "$n_src" ] || die "only $built of $n_src kernel(s) built"

if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$FIX/harness.c" "$WORK"/*.o \
     -o "$WORK/harness" 2>"$WORK/harness.log"; then
  echo "  FAIL the harness did not compile:"; sed 's/^/      /' "$WORK/harness.log" | head -8
  fail=$((fail + 1))
elif [ "$oracle" = 1 ]; then
  n_op=$(grep -c "^op$TAB" "$FIX/trace.tsv")
  n_chk=$(grep -c "^check$TAB" "$FIX/trace.tsv")
  lane() { # label mode declared-count
    if out=$("$WORK/harness" "$WORK/trace.txt" "$2" 2>&1); then
      if [ -n "${3:-}" ]; then
        ran=$(printf '%s' "$out" | awk '{ print $2 }')
        if [ "$ran" != "$3" ]; then
          echo "  FAIL the trace declares $3 for $2 and $ran ran"; fail=$((fail + 1)); return
        fi
      fi
      echo "  pass $out"; pass=$((pass + 1))
    else
      echo "  FAIL $1:"; printf '%s\n' "$out" | sed 's/^/      /' | head -6
      fail=$((fail + 1))
    fi
  }
  lane "the kernels and the original disagree" run "$n_op"
  # `run` now names two worlds, so the count is the second word of the first
  # clause; the lane helper compares that against the trace's own op count.

  echo "== exhaustion, at the original's own capacity =="
  lane "exhaustion" exhaust ""

  echo "== the ABI answers what CRuby cannot =="
  lane "the ABI checks" refuse "$n_chk"

  echo "== reuse order is observable =="
  lane "the order control" shuffle ""
fi

echo "== mutation controls =="
n_mut=0
while IFS="$TAB" read -r id file old new stage why; do
  case "$id" in \#*|"") continue ;; esac
  n_mut=$((n_mut + 1))
  M="$WORK/mut-$id"
  rm -rf "$M"; mkdir -p "$M/src"
  cp "$FIX"/trace.tsv "$FIX"/trace.rb "$FIX"/model.rb "$M/"
  cp "$FIX"/src/*.rb "$FIX"/src/*.contract "$M/src/"
  case "$stage" in
    both|ruby) ;;
    *) echo "  FAIL $id: its stage is $stage, not both or ruby"; fail=$((fail + 1)); continue ;;
  esac
  if [ ! -f "$FIX/$file" ]; then
    echo "  FAIL $id: names $file, which is not there"; fail=$((fail + 1)); continue
  fi
  if ! replace_once "$FIX/$file" "$old" "$new" "$M/$file"; then
    echo "  FAIL $id: its target is not in $file exactly once"; fail=$((fail + 1)); continue
  fi
  delta=$(diff "$FIX/$file" "$M/$file" | grep -c '^[<>]' || true)
  if [ "$delta" -ne 2 ]; then
    echo "  FAIL $id: changed $delta line(s) of $file, not one"; fail=$((fail + 1)); continue
  fi
  [ "$oracle" = 1 ] || continue

  # It must stop agreeing BY COMPARING. A non-zero exit alone is not the check:
  # trace.rb exits non-zero when it cannot run at all, and every control would
  # then score a refusal while nothing was compared. So its own per-operation
  # verdict is required, the way arithmetic.sh requires its oracle's.
  if "$RUBY" "$M/trace.rb" "$ROOT" "$M" "$M/trace.txt" >/dev/null 2>"$M/trace.err"; then
    echo "  FAIL $id: the mutated Ruby still agrees with the original ($why)"
    fail=$((fail + 1)); continue
  fi
  if ! grep -Eq "$TRACE_DIFFER" "$M/trace.err"; then
    echo "  FAIL $id: the mutated trace builder never reached a comparison, so this"
    echo "       control shows nothing:"
    sed 's/^/      /' "$M/trace.err" | head -4
    fail=$((fail + 1)); continue
  fi
  if [ "$stage" = "ruby" ]; then
    echo "  pass $id caught in Ruby ($why)"; pass=$((pass + 1)); continue
  fi

  stem=$(basename "$file" .rb)
  if ! "$KERNEL" "$M/src/$stem.contract" --root "$M" -o "$M/$stem.o" \
       --header "$M/spinel_core_$stem.h" --clang "$CC_BIN" > "$M/build.log" 2>&1; then
    echo "  FAIL $id: the mutated kernel did not build:"
    sed 's/^/      /' "$M/build.log" | head -4; fail=$((fail + 1)); continue
  fi
  for other in "$FIX"/src/*.contract; do
    o=$(basename "$other" .contract)
    [ "$o" = "$stem" ] && continue
    cp "$WORK/$o.o" "$M/$o.o"; cp "$WORK/spinel_core_$o.h" "$M/"
  done
  if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$M" "$FIX/harness.c" "$M"/*.o \
       -o "$M/harness" 2>"$M/cc.log"; then
    echo "  FAIL $id: the mutated harness did not compile:"
    sed 's/^/      /' "$M/cc.log" | head -4; fail=$((fail + 1)); continue
  fi
  # Either lane may be the one that sees it. A bound that cuts a well-formed
  # walk short is invisible to a trace shorter than the bound and unmissable
  # when a full list is swept, so the control asks both and says which.
  caught=""
  if ! "$M/harness" "$WORK/trace.txt" run >/dev/null 2>"$M/run.err"; then
    if grep -Eq "$HARNESS_DIFFER" "$M/run.err"; then
      caught="the trace"
    else
      echo "  FAIL $id: the mutated harness failed the trace without comparing a"
      echo "       cell, so this control shows nothing:"
      sed 's/^/      /' "$M/run.err" | head -4
      fail=$((fail + 1)); continue
    fi
  fi
  if [ -z "$caught" ] && ! "$M/harness" "$WORK/trace.txt" exhaust >/dev/null 2>"$M/exhaust.err"; then
    if grep -q '^harness: ' "$M/exhaust.err"; then
      caught="exhaustion"
    else
      echo "  FAIL $id: the mutated harness failed exhaustion without saying why, so"
      echo "       this control shows nothing:"
      sed 's/^/      /' "$M/exhaust.err" | head -4
      fail=$((fail + 1)); continue
    fi
  fi
  if [ -z "$caught" ]; then
    echo "  FAIL $id: the mutated kernel still reproduced the original's cells ($why)"
    fail=$((fail + 1)); continue
  fi
  echo "  pass $id caught in Ruby and in the kernel by $caught ($why)"
  pass=$((pass + 1))
done < "$FIX/mutations.tsv"
[ "$n_mut" -gt 0 ] || die "the mutation table is empty"
n_mut_rows=$(awk -F"$TAB" '!/^#/ && NF { print }' "$FIX/mutations.tsv" | wc -l | tr -d ' ')
[ "$n_mut" -eq "$n_mut_rows" ] || die "$n_mut control(s) ran of $n_mut_rows declared"
dup=$(awk -F"$TAB" '!/^#/ && NF { print $1 }' "$FIX/mutations.tsv" | sort | uniq -d)
if [ -n "$dup" ]; then
  echo "  FAIL the mutation table reuses these ids: $dup"; fail=$((fail + 1))
fi
for f in "$FIX"/src/*.rb; do
  stem=$(basename "$f" .rb)
  if ! awk -F"$TAB" -v want="src/$stem.rb" '!/^#/ && $2 == want { found = 1 } END { exit !found }' \
       "$FIX/mutations.tsv"; then
    echo "  FAIL $stem has no mutation control"; fail=$((fail + 1))
  fi
  # The check table is a declaration set like the other two, so it gets the
  # same treatment: a kernel with no row there is one whose status ABI nothing
  # states. The harness checks that each has both an accepted and a refused
  # row; this checks it has any.
  if ! awk -F"$TAB" -v want="$stem" '!/^#/ && $1 == "check" && $5 == want { found = 1 }
                                     END { exit !found }' "$FIX/trace.tsv"; then
    echo "  FAIL $stem has no ABI check row"; fail=$((fail + 1))
  fi
done

echo "== a trace that would pass for the wrong reason is refused =="
guard() { # id mode awk-program expected-message
  awk "$3" "$WORK/trace.txt" > "$WORK/guard-$1.txt"
  if out=$("$WORK/harness" "$WORK/guard-$1.txt" "$2" 2>&1); then
    echo "  FAIL guard $1: the harness accepted a trace it cannot have checked"
    fail=$((fail + 1))
  elif ! printf '%s' "$out" | grep -qF "$4"; then
    echo "  FAIL guard $1: refused, but not by the guard it aims at:"
    printf '%s\n' "$out" | sed 's/^/      /' | head -3
    fail=$((fail + 1))
  else
    echo "  pass guard $1 refused by the guard it aims at"; pass=$((pass + 1))
  fi
}
if [ "$oracle" != 1 ]; then
  : # the guards perturb the trace the original produced
elif [ -x "$WORK/harness" ]; then
  # a kernel is never called. The operations it drops are renumbered along
  # with the states that describe them, so what is left is a well-formed
  # trace and the harness has to refuse it on its merits.
  guard skips-a-kernel run \
    'BEGIN { n = 0 }
     /^op /{ if ($3 == "tcollect") { dropped[$2] = 1; next }
             map[$2] = n; $2 = n; n = n + 1; print; next }
     /^after /{ if ($2 in dropped) next; $2 = map[$2]; print; next }
     { print }' \
    'the trace does not exercise all five kernels'
  # every ABI check is a refusal, so answering CAPACITY to everything would pass
  guard one-sided-checks refuse '/^check /{ sub(/ [0-9]+ [0-9]+$/, " 4 0") } { print }' \
    'only checks of one kind'
  # nothing is ever handed out twice, so reuse is never observed
  guard never-reuses run '/^op [0-9]+ (tadd|malloc) /{ $6 = 0; $7 = NR } { print }' \
    'no slot is ever handed out twice'
else
  echo "  FAIL the harness did not build, so its guards were not checked"
  fail=$((fail + 1))
fi

echo "slots: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
