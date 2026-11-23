#!/bin/sh
#
# tests/core-boundary/capabilities.sh — the DOOM preparation capabilities of
# decision 0007 task 5. This file covers the first of them: the fixed-point
# helpers.
#
#   KERNEL=<spinel-core-kernel> tests/core-boundary/capabilities.sh
#
# Three lanes:
#
#   1. provenance. Each extracted helper records the original it came from,
#      and the original's digest is checked, so the two drifting apart is a
#      failure rather than something noticed later.
#   2. the adaptation. The extracted Ruby and the ORIGINAL Ruby must agree on
#      every case, under CRuby, before any compiler is involved. That is what
#      makes an adaptation a spelling change rather than a semantic one.
#   3. the kernel. Each helper is built as a CORE object, called from C, and
#      must answer what the original answered.
#
# The expectations are not written down. They are whatever the original Full
# helper says, because the question here is whether the extraction still
# agrees with it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-boundary"
FIX="$HERE/fixtures/capabilities"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
RUBY="${RUBY:-ruby}"

die() { echo "capabilities: $*" >&2; exit 1; }
[ -f "$FIX/cases.tsv" ] || die "no case table at $FIX/cases.tsv"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build it first)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
"$RUBY" -e 'exit 0' >/dev/null 2>&1 || die "'$RUBY' does not run"
# The floor is checked HERE rather than met halfway through, where a ruby that
# does not understand the fixture becomes a non-zero exit some later check
# would read as a refusal it asked for. Same reasoning as oracle.rb, which
# states the same floor, and as closure.sh, which states its prism requirement
# here rather than inside its census.
"$RUBY" -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7.0") ? 0 : 1)' \
  >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' is $("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null), below the 2.7 floor
       this suite declares (tests/core-boundary/oracle.rb states it, and
       docs/building.md records that macOS's default 2.6 is not a selected
       reference); set RUBY=<a newer ruby>."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-capabilities.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0
TAB=$(printf '\t')

sha256_of() {
  case "$(uname -s)" in
    Darwin) /usr/bin/shasum -a 256 "$1" ;;
    *)      sha256sum "$1" ;;
  esac | awk '{ print $1 }'
}

echo "== provenance =="
# Every extracted helper names the original it came from, and every original
# named is there. A recorded path that does not exist would make the record a
# claim about nothing.
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
  # The extraction has to SAY where it came from, in the file itself: a record
  # kept only in a side table is one a reader of the source never sees.
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

# Everything extracted is recorded, not only everything recorded extracted.
for f in "$FIX"/src/*.rb; do
  stem=$(basename "$f" .rb)
  if ! grep -q "^$stem$TAB" "$FIX/provenance.tsv"; then
    echo "  FAIL $stem is extracted with no recorded origin"
    fail=$((fail + 1))
  fi
done

# The adaptation and the kernels' answers read what CRuby running the original
# produced, so they run only on the owner's instruction (tools/oracle/gate).
# The kernels and the harness are built either way.
if "$ROOT/tools/oracle/gate" tests/core-boundary/capabilities.sh original; then oracle=1; else oracle=0; fi

if [ "$oracle" = 1 ]; then
  echo "== the adaptation preserves the original's answers =="
  # Under CRuby, before any compiler. The oracle loads the original unmodified
  # and the extraction beside it and compares every case; a disagreement is a
  # semantic change dressed as a spelling one.
  if "$RUBY" "$FIX/oracle.rb" "$ROOT" > "$WORK/expected.tsv" 2> "$WORK/oracle.err"; then
    echo "  pass $(grep -c . "$WORK/expected.tsv") case(s) agree with the original"
    pass=$((pass + 1))
  else
    echo "  FAIL the extraction and the original disagree:"
    sed 's/^/      /' "$WORK/oracle.err" | head -8
    fail=$((fail + 1))
  fi
  [ -s "$WORK/expected.tsv" ] || die "the oracle produced no expectations"
fi

echo "== the CORE kernels answer what the original answers =="
for f in "$FIX"/src/*.contract; do
  stem=$(basename "$f" .contract)
  "$KERNEL" "$f" --root "$FIX" -o "$WORK/$stem.o" \
    --header "$WORK/spinel_core_$stem.h" --clang "$CC_BIN" > "$WORK/$stem.build" 2>&1 \
    || { echo "  FAIL $stem did not build:"; sed 's/^/      /' "$WORK/$stem.build" | head -4
         fail=$((fail + 1)); continue; }
done
objs=$(ls "$WORK"/*.o 2>/dev/null | tr '\n' ' ')
[ -n "$objs" ] || die "no kernels were built"
if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$FIX/harness.c" $objs \
     -o "$WORK/harness" 2>"$WORK/harness.log"; then
  echo "  FAIL the harness did not compile:"
  sed 's/^/      /' "$WORK/harness.log" | head -6
  fail=$((fail + 1))
elif [ "$oracle" = 1 ]; then
  ran=0
  while IFS="$TAB" read -r id helper args; do
    case "$id" in \#*|"") continue ;; esac
    want=$(awk -F"$TAB" -v k="$id" '$1 == k { print $2 }' "$WORK/expected.tsv")
    if [ -z "$want" ]; then
      echo "  FAIL $id has no expectation from the original"
      fail=$((fail + 1)); continue
    fi
    set +e
    got=$("$WORK/harness" "$helper" $(echo "$args" | tr ',' ' '))
    rc=$?
    set -e
    ran=$((ran + 1))
    if [ "$rc" -ne 0 ]; then
      echo "  FAIL $id: the harness exited $rc"; fail=$((fail + 1)); continue
    fi
    if [ "$got" != "$want" ]; then
      echo "  FAIL $id: the original says $want, the kernel says $got"
      fail=$((fail + 1)); continue
    fi
    echo "  pass $id = $got"
    pass=$((pass + 1))
  done < "$FIX/cases.tsv"
  n_cases=$(awk -F"$TAB" '!/^#/ && NF == 3' "$FIX/cases.tsv" | wc -l | tr -d ' ')
  if [ "$ran" -ne "$n_cases" ]; then
    echo "  FAIL only $ran of $n_cases case(s) ran"; fail=$((fail + 1))
  fi
fi

echo "capabilities: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
