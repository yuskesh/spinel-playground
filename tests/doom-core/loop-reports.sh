#!/bin/sh
#
# tests/doom-core/loop-reports.sh -- decision 0010 step 1 over the DOOM CORE
# entries: a build report for every entry, the catalogue of unknown loops, and
# the evidence that reporting changed no object.
#
#   sh tests/doom-core/loop-reports.sh OUTDIR
#
# The entries are every one the DOOM lanes build with spinel-core-kernel, staged
# exactly as those lanes stage them:
#
#   source  the SENTRIES of tests/doom-core/fixtures/source -- however many the
#           list holds; it has been 39, 40 and 42, and a number written here
#           goes stale the way the total below did -- packed
#           from examples/doom/core/src (tick.sh, harness/artifacts.sh)
#   random  pr, mr and cr, packed from random.rb (tick.sh)
#   slots   take and add, packed from thinkers.rb (state.sh)
#
# Each entry is built three times: A plainly with --emit-mlir, B the same with
# --report, P plainly with neither. P must equal A, and B's object, header and
# MLIR must equal A's. One entry built with -O1 must differ, so the comparison
# can fail. BASELINE_KERNEL, when set, names a kernel built without the report
# change, and every plain object must equal the one it builds.
#
# OUTDIR receives, and nothing here is tracked:
#
#   reports/GROUP.NAME.json   the build report of each entry
#   catalogue.tsv, loops.tsv, occurrences.tsv, summary.json
#                             from tests/core-report/catalogue.rb
#   identity.tsv              entry, plain rebuild, report build, per entry
#   run.tsv                   the tools and revision the run used
#
# OUTDIR must be outside every worktree: reports are regenerated evidence
# (decision 0010), not files of the tree they describe.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools. WAD
# is accepted for symmetry with the other DOOM lanes and not read: building an
# entry needs no IWAD. REVISION overrides the source revision recorded in the
# reports, which defaults to this checkout's HEAD.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${1:-}
[ -n "$OUT" ] || { echo "usage: loop-reports.sh OUTDIR" >&2; exit 2; }

die() { echo "loop-reports: $*" >&2; exit 1; }
RUBY="${RUBY:-ruby}"
PACK="${PACK:-$ROOT/tools/doom/pack-core.rb}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
SCHEMA="$ROOT/tools/mlir/native/schema/core-report-v1.schema.json"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
# DORMANT WHEN THE KERNEL PREDATES THE OPTION THIS LANE IS BUILT ON, which is a
# state with a cause rather than a choice, and is reported as one.
#
# The middle of the three builds below passes --report and --profile
# hosted-stage2. Those options were added to the kernel by f65b5a8 (2026-09-16
# 08:17:28) and THIS SUITE LANDED FIFTEEN SECONDS LATER, in e1989a8: the lane
# and the option it needs are one landing. A kernel built before them refuses
# every build with "unknown option --report", and this lane then reports 42 red
# entries that say nothing about the tree -- measured on 2026-09-18 against the
# shared e2f5676 build of 2026-09-15, which every suite is pointed at and which
# predates the feature by about seventeen hours. That run took 7912 s to say
# nothing.
#
# TO REVIVE IT: a kernel built from any revision at or after f65b5a8, which
# includes the current tree -- tools/mlir/native/build.sh, in a worktree of its
# own, about 75 s. Nothing needs designing.
#
# The probe reads the MESSAGE and not the status: the kernel exits 2 for an
# unknown option and for a bad contract path alike.
if "$KERNEL" --report /dev/null 2>&1 | grep -q "unknown option --report"; then
  echo "loop-reports: DORMANT -- $KERNEL does not accept --report, so this lane cannot run."
  echo "loop-reports:   The option was added by f65b5a8 (2026-09-16) and this suite landed with"
  echo "loop-reports:   it, fifteen seconds later, in e1989a8. Revive with a kernel built from"
  echo "loop-reports:   any revision at or after f65b5a8; the current tree has it."
  exit 3
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"

# The same refusal build-artifacts.sh makes, by realpath.
lr_parent=$OUT
while [ ! -d "$lr_parent" ] && [ "$lr_parent" != "/" ] && [ "$lr_parent" != "." ]; do
  lr_parent=$(dirname -- "$lr_parent")
done
lr_here=$(cd -- "$ROOT" && pwd -P)
lr_there=$(cd -- "$lr_parent" && pwd -P)
case "$lr_there" in
  "$lr_here" | "$lr_here"/*) die "$OUT is inside the checkout at $lr_here; reports are evidence kept outside it" ;;
esac
mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd -P)
[ ! -e "$OUT/reports" ] || die "$OUT already holds reports; give a fresh directory"
mkdir -p "$OUT/reports"
W="$OUT/work"
mkdir -p "$W"

REV=${REVISION:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)}
if [ -z "${REVISION:-}" ] && [ -n "$REV" ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  REV="$REV-dirty"
fi

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
rc_of() { "$@" && echo 0 || echo $?; }
pack() { # manifest unit-root output map err
  "$RUBY" "$PACK" --manifest "$1" --root "$2" --reader "$READER" --output "$3" --map "$4" > "$5" 2>&1
}

echo "== staging the entries =="
# source: the recipe tick.sh and build-artifacts.sh use.
SRCFIX="$ROOT/tests/doom-core/fixtures/source"
# THE ENTRY LIST IS NOT COPIED HERE, AND PLEASE DO NOT COPY IT BACK. It is read
# from the lane that owns it and checked against the contracts on disk.
#
# A copy drifts silently, and nothing catches the drift: GIT CANNOT REPORT A
# CONFLICT BETWEEN A LIST AND A DIRECTORY. Measured, the loop+sky merge renamed
# `dplane` to `dplanes`, touched no line of this file, and merged cleanly; a
# copied list would then have failed here as a missing file, or worse, reported
# on one entry fewer than the lane builds. A SILENT UNDERCOUNT IS A GREEN RUN
# THAT CHECKS LESS THAN IT SAYS, which is the one outcome a gate must not have.
SENTRIES=$(sed -n 's/^SENTRIES="\(.*\)"$/\1/p' "$ROOT/tests/doom-core/harness/build-artifacts.sh")
[ -n "$SENTRIES" ] || die "no SENTRIES in tests/doom-core/harness/build-artifacts.sh"
lr_declared=$(ls "$SRCFIX"/*.contract | while read -r c; do basename "$c" .contract; done | sort | tr '\n' ' ')
lr_listed=$(printf '%s\n' $SENTRIES | sort | tr '\n' ' ')
[ "$lr_declared" = "$lr_listed" ] || die "the entries build-artifacts.sh lists and the contracts in
  $SRCFIX disagree, so one of them has moved:
    listed:   $lr_listed
    on disk:  $lr_declared"
CC_BIN_SAVED=$CC_BIN
export ROOT RUBY PACK READER KERNEL CC_BIN SRCFIX SENTRIES
. "$ROOT/tests/doom-core/harness/artifacts.sh"
dc_artifacts_ready || die "a name the staging recipe reads is missing"
dc_entry_units "$W/source" || die "could not copy the source units"
mkdir -p "$W/source/stage/src"
ok "the source units pack" "$(rc_of pack "$W/source/manifest.tsv" "$W/source/unit" \
  "$W/source/stage/src/packed.rb" "$W/source/map.tsv" "$W/source/pack.err")" 0
for e in $SENTRIES; do cp "$SRCFIX/$e.contract" "$W/source/stage/$e.contract"; done

# random: the recipe tick.sh uses.
RND="$ROOT/tests/doom-core/fixtures/random"
mkdir -p "$W/random/unit" "$W/random/stage/src"
cp "$ROOT/examples/doom/core/src/random.rb" "$W/random/unit/random.rb"
cp "$RND/src/entries.rb" "$W/random/unit/entries.rb"
ok "the random units pack" "$(rc_of pack "$RND/manifest.tsv" "$W/random/unit" \
  "$W/random/stage/src/packed.rb" "$W/random/map.tsv" "$W/random/pack.err")" 0
for e in pr mr cr; do cp "$RND/$e.contract" "$W/random/stage/$e.contract"; done

# slots: the recipes state.sh uses; `add` is packed on its own.
SLOTS="$ROOT/tests/doom-core/fixtures/state/slots"
mkdir -p "$W/slots/unit/slots" "$W/slots/stage/slots" "$W/slots-add/unit/slots" "$W/slots-add/stage/slots"
cp "$ROOT/examples/doom/core/src/thinkers.rb" "$W/slots/unit/slots/thinkers.rb"
cp "$SLOTS/entries.rb" "$W/slots/unit/slots/entries.rb"
ok "the take units pack" "$(rc_of pack "$SLOTS/manifest.tsv" "$W/slots/unit" \
  "$W/slots/stage/slots/packed.rb" "$W/slots/map.tsv" "$W/slots/pack.err")" 0
sed 's|root slots/entries.rb|root slots/packed.rb|' "$SLOTS/take.contract" > "$W/slots/stage/take.contract"
cp "$ROOT/examples/doom/core/src/thinkers.rb" "$W/slots-add/unit/slots/thinkers.rb"
cp "$SLOTS/add_entry.rb" "$W/slots-add/unit/slots/add_entry.rb"
ok "the add units pack" "$(rc_of pack "$SLOTS/add-manifest.tsv" "$W/slots-add/unit" \
  "$W/slots-add/stage/slots/packed.rb" "$W/slots-add/map.tsv" "$W/slots-add/pack.err")" 0
sed 's|root slots/add_entry.rb|root slots/packed.rb|' "$SLOTS/add.contract" > "$W/slots-add/stage/add.contract"
[ "$fail" -eq 0 ] || die "staging failed; see the pack.err files under $W"

# group:stage-dir:name, for every entry.
ALL=""
for e in $SENTRIES; do ALL="$ALL source:source:$e"; done
for e in pr mr cr; do ALL="$ALL random:random:$e"; done
ALL="$ALL slots:slots:take slots-add:slots-add:add"

echo "== building every entry three times =="
kernel() { # contract root stem [options]
  k_c=$1; k_r=$2; k_s=$3; shift 3
  "$KERNEL" "$k_c" --root "$k_r" --typedump "$READER" -o "$k_s.o" --header "$k_s.h" \
    --clang "$CC_BIN_SAVED" "$@" > "$k_s.log" 2>&1
}
printf 'entry\tplain_rebuild\treport_build\n' > "$OUT/identity.tsv"
mkdir -p "$W/a" "$W/b" "$W/p"
count=0
for item in $ALL; do
  group=${item%%:*}; rest=${item#*:}; dir=${rest%%:*}; name=${rest#*:}
  stage="$W/$dir/stage"; stem="$group.$name"
  if [ -n "$REV" ]; then set -- --report-revision "$REV"; else set --; fi
  ra=$(rc_of kernel "$stage/$name.contract" "$stage" "$W/a/$stem" --emit-mlir "$W/a/$stem.mlir")
  rb=$(rc_of kernel "$stage/$name.contract" "$stage" "$W/b/$stem" --emit-mlir "$W/b/$stem.mlir" \
         --report "$OUT/reports/$stem.json" --profile hosted-stage2 "$@")
  rp=$(rc_of kernel "$stage/$name.contract" "$stage" "$W/p/$stem")
  if [ "$ra$rb$rp" != 000 ]; then
    ok "$stem builds three times" "$ra$rb$rp" 000
    continue
  fi
  count=$((count + 1))
  plain=$(cmp -s "$W/a/$stem.o" "$W/p/$stem.o" && echo same || echo differ)
  same=same
  for x in o h mlir; do cmp -s "$W/a/$stem.$x" "$W/b/$stem.$x" || same="$x-differs"; done
  [ -s "$OUT/reports/$stem.json" ] || same="no-report"
  printf '%s\t%s\t%s\n' "$stem" "$plain" "$same" >> "$OUT/identity.tsv"
  ok "$stem: two plain builds are identical" "$plain" same
  ok "$stem: object, header and MLIR identical with the report" "$same" same
done
# DERIVED FROM THE LIST, NOT WRITTEN DOWN BESIDE IT. This was the constant 44
# while the list held 45 entries, and the lane that would have said so has been
# dormant since the day it landed (see the probe above), so the drift sat
# unreported: on 2026-09-18 the first run against a current kernel found it, and
# by then the list was 47. A count of a set belongs to the set.
#
# WHAT THIS CHECKS AND WHAT IT CANNOT. It checks the TOTAL against the list this
# loop walks: every entry got through three builds and produced a report. A
# COUNT DERIVED FROM A LIST CAN NEVER CATCH AN INCOMPLETE LIST -- it defines
# correctness as the list agreeing with itself, which is the shape of a
# generator agreeing with itself. THE LIST IS CHECKED ELSEWHERE, in three
# places asking three different questions, none of them redundant:
#
#   * this file's own entries-versus-contracts refusal above, which dies
#     quoting "listed:" and "on disk:" -- and which runs BEFORE this line, so a
#     short list has already stopped the run by the time the total is counted;
#   * screens.sh's "the closure holds every fixture entry";
#   * source-pack.sh's "the built-entry list names no contract that is not
#     there" and "and leaves no tracked contract unbuilt".
#
# AND THE ORDER THEY WERE FIXED IN IS THE TRANSFERABLE PART: the list was
# corrected first (inputall and renderall added to SENTRIES, built and put
# through the link rule), and only then was the count derived. Derive first and
# a short list is frozen as correct.
ok "every entry produced a report" "$count" "$(printf '%s\n' $ALL | wc -l | tr -d ' ')"
ok "an -O1 build differs, so the comparison can fail" \
   "$(rc_of kernel "$W/source/stage/col.contract" "$W/source/stage" "$W/p/sensitivity" -- -O1):$(cmp -s "$W/a/source.col.o" "$W/p/sensitivity.o" && echo same || echo differ)" \
   "0:differ"
if [ -n "${BASELINE_KERNEL:-}" ]; then
  # a kernel built without this change: whether this comparison is an oracle
  # is the owner's to classify (tests/ORACLES.tsv), so it is gated until then
  if "$ROOT/tools/oracle/gate" tests/doom-core/loop-reports.sh baseline-kernel; then
    [ -x "$BASELINE_KERNEL" ] || die "BASELINE_KERNEL is not executable: $BASELINE_KERNEL"
    differ=""
    for item in $ALL; do
      group=${item%%:*}; rest=${item#*:}; dir=${rest%%:*}; name=${rest#*:}
      stage="$W/$dir/stage"; stem="$group.$name"
      "$BASELINE_KERNEL" "$stage/$name.contract" --root "$stage" --typedump "$READER" -o "$W/p/$stem.base.o" \
        --clang "$CC_BIN_SAVED" > "$W/p/$stem.base.log" 2>&1 || differ="$differ $stem(rc)"
      cmp -s "$W/p/$stem.o" "$W/p/$stem.base.o" || differ="$differ $stem"
    done
    ok "every plain object equals the baseline kernel's" "${differ:-none}" none
  fi
else
  echo "  note: BASELINE_KERNEL not set; the objects were not compared with a kernel built without the change"
fi

echo "== the reports =="
"$RUBY" "$ROOT/tests/core-report/check.rb" --schema "$SCHEMA" --validate "$OUT"/reports/*.json > "$W/validate.log" 2>&1 \
  && vrc=0 || vrc=$?
ok "every report validates against the schema" "$vrc:$(grep -c '^  FAIL' "$W/validate.log" || true)" "0:0"
"$RUBY" "$ROOT/tests/core-report/catalogue.rb" --out "$OUT" \
  --map "source=$W/source/map.tsv" --map "random=$W/random/map.tsv" \
  --map "slots=$W/slots/map.tsv" --map "slots-add=$W/slots-add/map.tsv" \
  "$OUT"/reports/*.json > "$W/catalogue.log" 2>&1 && crc=0 || crc=$?
ok "the catalogue is written" "$crc" 0
cat "$W/catalogue.log"

digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}
{
  printf 'key\tvalue\n'
  printf 'revision\t%s\n' "${REV:--}"
  printf 'kernel_sha256\t%s\n' "$(digest "$KERNEL")"
  printf 'reader_sha256\t%s\n' "$(digest "$READER")"
  printf 'clang\t%s\n' "$("$CC_BIN_SAVED" --version | head -n 1)"
  printf 'target\t%s\n' "$("$CC_BIN_SAVED" -print-target-triple)"
  printf 'entries\t%s\n' "$count"
} > "$OUT/run.tsv"

echo "loop-reports: $pass passed, $fail failed; reports and catalogue in $OUT"
[ "$fail" -eq 0 ]
