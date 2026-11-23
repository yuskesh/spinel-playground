#!/bin/sh
#
# tests/core-boundary/framebuffer.sh — the second capability of decision 0007
# task 5: the wall column, the plane span and the fuzz column, which are the
# three framebuffer operations the DOOM job executor actually issues.
#
#   KERNEL=<spinel-core-kernel> tests/core-boundary/framebuffer.sh
#
# What makes this different from the fixed-point lane is the shape of the
# answer. A fixed-point helper answers with one number; these answer with a
# SCREEN, so the comparison is every byte of it, including the bytes no job
# should have touched.
#
# Seven lanes:
#
#   1. provenance. Each extracted kernel names the original it came from, in
#      its own text, every extracted kernel is recorded, and the ORIGINAL is
#      digested against originals.tsv, so an original drifting under a still-
#      passing extraction is a failure rather than something noticed later.
#   2. the adaptation. Under CRuby, the ORIGINAL Doom::JobExecutor methods and
#      the extracted Ruby must draw the same screen, byte for byte, over the
#      same schedule. scene.rb refuses to emit anything otherwise.
#   3. the kernels. The CORE objects, called from C over the same schedule,
#      must draw the screen the ORIGINAL produced. The C harness computes
#      nothing: it parses, calls and compares, so there is no C reference
#      whose agreement could stand in for the original's.
#   4. order and neighbouring access. The same jobs run in another order must
#      draw a DIFFERENT screen. Without that, "the schedule order is
#      preserved" would be a claim about a scene whose order did not matter,
#      and the fuzz column's read of what earlier jobs drew would be
#      unobservable.
#   5. the status ABI. Two things CRuby cannot answer for. An index off the
#      end grows a Ruby Array or reads nil, and is SPINEL_CORE_BOUNDS here:
#      EVERY declared buffer face of every kernel has a pair -- the screen
#      written, the screen read above and below by fuzz, the atlas, the flat
#      atlas, the colormap from the wall and from the span, and the fuzz
#      table -- each pair being the exact last index and the one after it. And
#      CRuby integers are arbitrary precision, so the original draws where the
#      kernel's i64 arithmetic overflows and answers SPINEL_CORE_ARITHMETIC; a
#      pair pins where that begins. This is a real Full/CORE divergence and it
#      is recorded rather than avoided. Statuses 1 and 4 cannot arise here;
#      scene.tsv says why.
#   6. mutation controls. One point of one extracted source is changed and
#      both comparisons must fail.
#   7. the harness's own guards. A scene that would make the comparisons true
#      for the wrong reason -- one that draws nothing, one that never reaches
#      a kernel, one whose ABI checks are all of a kind for some kernel, one
#      carrying a field nothing reads -- must be refused rather than passed.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/core-boundary/fixtures/framebuffer"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
RUBY="${RUBY:-ruby}"

die() { echo "framebuffer: $*" >&2; exit 1; }
[ -f "$FIX/scene.tsv" ] || die "no scene at $FIX/scene.tsv"
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-framebuffer.XXXXXX")
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
# Literal, not a regular expression: the mutation targets hold brackets, bars
# and stars, and a control that silently matched something else would be
# worse than no control. Exits non-zero unless there was exactly one.
replace_once() {
  # awk processes escapes in a -v assignment, so a backslash in either string
  # would not be the text it looks like in the table. Refused rather than
  # silently mutated into something else.
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


# Injective as well as surjective. Two rows for one extraction would let a
# second, contradictory origin sit in the table with everything still green.
dup=$(awk -F"$TAB" '!/^#/ && NF { print $1 }' "$FIX/provenance.tsv" | sort | uniq -d)
if [ -n "$dup" ]; then
  echo "  FAIL the provenance table names these more than once: $dup"
  fail=$((fail + 1))
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
# scene.rb exits non-zero both when the two screens differ AND when it could
# not run at all -- a missing original, a ruby that does not understand it, a
# typo in the file -- and a lane that read only the status would report a
# semantic disagreement where there was a broken tool. Measured: with a syntax
# error appended to the copied scene.rb, every mutation control below reported
# "caught in Ruby" and the lane passed 22 of 22.
#
# So the builder's OWN verdict is what is required, in both directions: its
# summary line when it agrees, and its own byte-difference verdict when it does
# not. Anything else is a broken control and says so.
SCENE_VERDICT='^scene: [0-9]+ job\(s\), [0-9]+ screen byte\(s\)'
SCENE_DIFFER='^scene: [0-9]+ byte\(s\) differ between the original and the extraction'
# The harness's own verdicts that a kernel no longer draws what the original
# drew: a byte comparison that failed, or a job that answered with a status
# instead of drawing. Every other `harness:` line is the harness refusing its
# input, which is not what a mutation control is asking about.
KERNEL_DIFFER='^harness: ([0-9]+ of [0-9]+ byte\(s\) differ|job [0-9]+ returned status )'

# The adaptation, the screens, the guards and the mutation controls read what
# CRuby running the original produced, so they run only on the owner's
# instruction (tools/oracle/gate). The kernels and the harness are built, and
# the mutation table is checked, either way.
if "$ROOT/tools/oracle/gate" tests/core-boundary/framebuffer.sh original; then oracle=1; else oracle=0; fi

if [ "$oracle" = 1 ]; then
  echo "== the adaptation draws the original's screen, byte for byte =="
  if "$RUBY" "$FIX/scene.rb" "$ROOT" "$FIX" "$WORK/scene.txt" > "$WORK/scene.out" 2> "$WORK/scene.err"; then
    if ! grep -Eq "$SCENE_VERDICT" "$WORK/scene.err"; then
      echo "  FAIL the scene builder exited 0 without its own verdict, so nothing"
      echo "       was compared:"
      sed 's/^/      /' "$WORK/scene.err" | head -6
      fail=$((fail + 1))
    else
      echo "  pass $(sed 's/^scene: //' "$WORK/scene.err" | tr -d '\n')"
      pass=$((pass + 1))
    fi
  elif grep -Eq "$SCENE_DIFFER" "$WORK/scene.err"; then
    echo "  FAIL the extraction and the original draw different screens:"
    sed 's/^/      /' "$WORK/scene.err" | head -8
    fail=$((fail + 1))
  else
    echo "  FAIL the scene builder never reached its comparison, so this is a broken"
    echo "       control rather than a disagreement about the screen:"
    sed 's/^/      /' "$WORK/scene.err" | head -8
    fail=$((fail + 1))
  fi
  [ -s "$WORK/scene.txt" ] || die "the scene builder produced no scene"
fi

echo "== the CORE kernels draw the screen the original drew =="
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
  n_job=$(grep -c "^job$TAB" "$FIX/scene.tsv")
  n_chk=$(grep -c "^check$TAB" "$FIX/scene.tsv")
  if out=$("$WORK/harness" "$WORK/scene.txt" run 2>&1); then
    # The harness says how many jobs it ran; the scene says how many it
    # declares. A count that is not compared is a number in a report.
    ran=$(printf '%s' "$out" | awk '{ print $2 }')
    if [ "$ran" != "$n_job" ]; then
      echo "  FAIL the scene declares $n_job job(s) and $ran ran"; fail=$((fail + 1))
    else
      echo "  pass $out"; pass=$((pass + 1))
    fi
  else
    echo "  FAIL the kernels drew a different screen:"; echo "$out" | sed 's/^/      /' | head -4
    fail=$((fail + 1))
  fi

  echo "== the ABI answers the off-the-end cases CRuby cannot answer for =="
  if out=$("$WORK/harness" "$WORK/scene.txt" refuse 2>&1); then
    ran=$(printf '%s' "$out" | awk '{ print $2 }')
    if [ "$ran" != "$n_chk" ]; then
      echo "  FAIL the scene declares $n_chk ABI check(s) and $ran ran"; fail=$((fail + 1))
    else
      echo "  pass $out"; pass=$((pass + 1))
    fi
  else
    echo "  FAIL the ABI checks:"; echo "$out" | sed 's/^/      /' | head -8
    fail=$((fail + 1))
  fi

  echo "== the schedule order and the neighbouring read are observable =="
  for mode in reverse fuzzfirst; do
    if out=$("$WORK/harness" "$WORK/scene.txt" "$mode" 2>&1); then
      echo "  pass $out"; pass=$((pass + 1))
    else
      echo "  FAIL control $mode:"; echo "$out" | sed 's/^/      /' | head -4
      fail=$((fail + 1))
    fi
  done
fi

echo "== a scene that would pass for the wrong reason is refused =="
# Each control perturbs the GENERATED scene, not the fixture, so the fixture
# stays the one the lanes above ran. All four must be refused; a harness that
# accepted them would report agreement it had not checked.
# The refusal has to come from the guard the control aims at. A control that
# was refused for some other reason -- a scene it broke by accident -- would
# report that the guard works without ever reaching it.
guard() { # id mode awk-program expected-message
  awk "$3" "$WORK/scene.txt" > "$WORK/guard-$1.txt"
  if out=$("$WORK/harness" "$WORK/guard-$1.txt" "$2" 2>&1); then
    echo "  FAIL guard $1: the harness accepted a scene it cannot have checked"
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
  : # the guards perturb the scene the original drew
elif [ -x "$WORK/harness" ]; then
  # the schedule draws nothing: the expected screen IS the initial screen
  guard draws-nothing run \
    '/^buf screen /{ h = $4 } /^expect /{ print "expect " $2 " " h; next } { print }' \
    'the schedule changes no byte of the screen'
  # a kernel is never called
  guard skips-a-kernel run '!/^job fuzz /' \
    'the schedule does not exercise all three kernels'
  # every ABI check is a refusal, so answering BOUNDS to everything would pass
  guard one-sided-checks refuse '/^check /{ sub(/ [0-9]+$/, " 3") } { print }' \
    'the ABI checks are all of one kind'
  # the scene carries a field nothing reads: a fuzz record is kind, x, yl, yh
  # and fz, and the scene pads the remaining three columns with zeroes.
  # Written with sub() rather than by assigning a field, so no awk has to
  # rebuild the record for the control to mean what it says.
  guard unread-field run '/^job fuzz /{ sub(/ 0 0 0$/, " 7 0 0") } { print }' \
    'a fuzz record carries fields the fuzz kernel does not take'
else
  echo "  FAIL the harness did not build, so its guards were not checked"
  fail=$((fail + 1))
fi

echo "== mutation controls =="
n_mut=0
while IFS="$TAB" read -r id file old new why; do
  case "$id" in \#*|"") continue ;; esac
  n_mut=$((n_mut + 1))
  M="$WORK/mut-$id"
  rm -rf "$M"; mkdir -p "$M/src"
  cp "$FIX"/scene.tsv "$FIX"/scene.rb "$M/"
  cp "$FIX"/src/*.rb "$FIX"/src/*.contract "$M/src/"
  if ! replace_once "$FIX/src/$file" "$old" "$new" "$M/src/$file"; then
    echo "  FAIL $id: its target is not in $file exactly once"; fail=$((fail + 1)); continue
  fi
  # Exactly one line changed, or the control breaks more than it claims.
  delta=$(diff "$FIX/src/$file" "$M/src/$file" | grep -c '^[<>]' || true)
  if [ "$delta" -ne 2 ]; then
    echo "  FAIL $id: changed $delta line(s) of $file, not one"; fail=$((fail + 1)); continue
  fi
  [ "$oracle" = 1 ] || continue

  # (a) the CRuby comparison against the original must stop agreeing -- and it
  # must stop agreeing BY COMPARING. A non-zero exit alone is not the check:
  # scene.rb exits non-zero when it cannot run at all, and every control would
  # then score a refusal while nothing was compared. So its own verdict that
  # the screens differ is required, the way arithmetic.sh requires its oracle's.
  if "$RUBY" "$M/scene.rb" "$ROOT" "$M" "$M/scene.txt" >/dev/null 2>"$M/scene.err"; then
    echo "  FAIL $id: the mutated Ruby still draws the original's screen ($why)"
    fail=$((fail + 1)); continue
  fi
  if ! grep -Eq "$SCENE_DIFFER" "$M/scene.err"; then
    echo "  FAIL $id: the mutated scene builder never reached its comparison, so"
    echo "       this control shows nothing:"
    sed 's/^/      /' "$M/scene.err" | head -4
    fail=$((fail + 1)); continue
  fi

  # (b) the CORE object built from the mutated source must stop agreeing, and
  # it is checked against the GOOD scene: what the original drew does not
  # change because a control was applied to the extraction.
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
  # The same rule on this side. The harness reports every refusal through one
  # `harness:` line and exits 1; a build that could not start, or a crash,
  # produces none, and would otherwise be scored as a caught mutation.
  if "$M/harness" "$WORK/scene.txt" run >/dev/null 2>"$M/harness.err"; then
    echo "  FAIL $id: the mutated kernel still drew the original's screen ($why)"
    fail=$((fail + 1)); continue
  fi
  if ! grep -Eq "$KERNEL_DIFFER" "$M/harness.err"; then
    echo "  FAIL $id: the mutated harness failed without comparing a screen, so"
    echo "       this control shows nothing:"
    sed 's/^/      /' "$M/harness.err" | head -4
    fail=$((fail + 1)); continue
  fi
  echo "  pass $id caught in Ruby and in the kernel ($why)"
  pass=$((pass + 1))
done < "$FIX/mutations.tsv"
[ "$n_mut" -gt 0 ] || die "the mutation table is empty"
n_mut_rows=$(awk -F"$TAB" '!/^#/ && NF { print }' "$FIX/mutations.tsv" | wc -l | tr -d ' ')
[ "$n_mut" -eq "$n_mut_rows" ] || die "$n_mut control(s) ran of $n_mut_rows declared"
dup=$(awk -F"$TAB" '!/^#/ && NF { print $1 }' "$FIX/mutations.tsv" | sort | uniq -d)
if [ -n "$dup" ]; then
  echo "  FAIL the mutation table reuses these ids: $dup"
  fail=$((fail + 1))
fi

# Every extracted kernel is mutated by something. A kernel with no control is
# one whose comparison has never been shown to be able to fail.
for f in "$FIX"/src/*.rb; do
  stem=$(basename "$f" .rb)
  if ! awk -F"$TAB" -v want="$stem.rb" '!/^#/ && $2 == want { found = 1 } END { exit !found }' \
       "$FIX/mutations.tsv"; then
    echo "  FAIL $stem has no mutation control"; fail=$((fail + 1))
  fi
done

echo "framebuffer: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
