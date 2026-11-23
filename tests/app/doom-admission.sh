#!/bin/sh
#
# tests/app/doom-admission.sh -- decision 0014: DOOM does not move.
#
#   sh tests/app/doom-admission.sh --baseline-kernel K0 --kernel K1 [--mid-course]
#
# The four DOOM entries measured on 2026-09-21 -- col, renderall, lindex and
# fplane -- are staged exactly as tests/doom-core/loop-reports.sh stages them
# and built with both kernels: plainly, and with a hosted-stage2 report. The
# objects must be byte-identical, and so must the reports, except for the
# kernel's own digest, which differs by construction. Any difference fails,
# naming the entry. The 42-entry comparison is the final verification's.
#
# THE FULL FORM TOOK 1011 s on Debian on 2026-09-22 (renderall 439 s of it),
# past the owner's ten-minute rule for a mid-course check. --mid-course is
# the subset the macOS coordinator settled for Tasks 3-5: col, lindex and fplane,
# plain objects and headers only, the report built and compared for col alone,
# plus the col control: 413 s measured the same day. renderall and every
# other report identity are the final verification's.
#
# The two controls of the 0014 plan run every time, on col alone so that the
# check stays inside its budget:
#   - the baseline given as both kernels passes (its own objects, compared);
#   - a kernel whose emission flag changed fails, naming the object: the
#     baseline wrapped to append -O0 to the codegen line.
#
# K0 is the kernel built from the plan's base, 7a7f453, in a separate worktree;
# the task report records its sha256. SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX)
# and RUBY select the other tools.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# The owner classes this baseline-kernel comparison as an oracle: it runs only
# with ALLOW_ORACLE=1 (tools/oracle/gate).
"$ROOT/tools/oracle/gate" tests/app/doom-admission.sh baseline-kernel || exit 0
BASE=; BRANCH=; MID=
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline-kernel) BASE=$2; shift 2 ;;
    --kernel) BRANCH=$2; shift 2 ;;
    --mid-course) MID=1; shift ;;
    *) echo "usage: doom-admission.sh --baseline-kernel K0 --kernel K1 [--mid-course]" >&2; exit 2 ;;
  esac
done
die() { echo "doom-admission: $*" >&2; exit 1; }
[ -n "$BASE" ] && [ -n "$BRANCH" ] || die "both --baseline-kernel and --kernel are required"
[ -x "$BASE" ] || die "no baseline kernel at $BASE"
[ -x "$BRANCH" ] || die "no kernel at $BRANCH"
RUBY="${RUBY:-ruby}"
PACK="${PACK:-$ROOT/tools/doom/pack-core.rb}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp reader "$READER"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$READER" ] || die "no contract reader at $READER (set SPINEL_TYPEDUMP)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "$MID" ]; then ENTRIES="col lindex fplane"; REPORTS="col"
else ENTRIES="col renderall lindex fplane"; REPORTS=$ENTRIES; fi

W=$(mktemp -d "${TMPDIR:-/tmp}/doom-admission.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
t0=$(date +%s)

# ---- staging, as loop-reports.sh does it -----------------------------------
SRCFIX="$ROOT/tests/doom-core/fixtures/source"
SENTRIES=$(sed -n 's/^SENTRIES="\(.*\)"$/\1/p' "$ROOT/tests/doom-core/harness/build-artifacts.sh")
[ -n "$SENTRIES" ] || die "no SENTRIES in tests/doom-core/harness/build-artifacts.sh"
for e in $ENTRIES; do
  printf '%s\n' $SENTRIES | grep -qx "$e" || die "$e is not a DOOM source entry any more"
done
KERNEL=$BRANCH
export ROOT RUBY PACK READER KERNEL CC_BIN SRCFIX SENTRIES
. "$ROOT/tests/doom-core/harness/artifacts.sh"
dc_artifacts_ready || die "a name the staging recipe reads is missing"
dc_entry_units "$W/source" || die "could not copy the source units"
mkdir -p "$W/source/stage/src"
"$RUBY" "$PACK" --manifest "$W/source/manifest.tsv" --root "$W/source/unit" --reader "$READER" \
  --output "$W/source/stage/src/packed.rb" --map "$W/source/map.tsv" > "$W/source/pack.err" 2>&1 ||
  die "the source units did not pack; see $W/source/pack.err"
STAGE="$W/source/stage"
for e in $ENTRIES; do cp "$SRCFIX/$e.contract" "$STAGE/$e.contract"; done

# with_report ENTRY: whether this run builds and compares the entry's report
with_report() { printf '%s\n' $REPORTS | grep -qx "$1"; }
# build KERNEL ENTRY STEM: the plain object, then the reporting build when
# the entry's report is compared
build() { # kernel entry stem
  "$1" "$STAGE/$2.contract" --root "$STAGE" --typedump "$READER" -o "$3.o" --header "$3.h" \
    --clang "$CC_BIN" > "$3.log" 2>&1 || return 1
  with_report "$2" || return 0
  "$1" "$STAGE/$2.contract" --root "$STAGE" --typedump "$READER" -o "$3.r.o" --header "$3.r.h" \
    --clang "$CC_BIN" --report "$3.json" --profile hosted-stage2 --report-revision admission > "$3.r.log" 2>&1
}
# report STEM: the report with the kernel's own digest fixed, everything else kept
report() {
  "$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); j["tools"]["kernel"]["sha256"] = "-"; puts JSON.generate(j)' "$1.json"
}
compare() { # entry stemA stemB -> "same" or what differs
  d=""
  cmp -s "$2.o" "$3.o" || d="$d object"
  cmp -s "$2.h" "$3.h" || d="$d header"
  if with_report "$1"; then
    [ "$(report "$2")" = "$(report "$3")" ] || d="$d report"
  fi
  echo "${d:-same}" | sed 's/^ //'
}

echo "doom-admission: baseline $BASE"
echo "doom-admission: kernel   $BRANCH"
mkdir -p "$W/base" "$W/branch"
for e in $ENTRIES; do
  s=$(date +%s)
  build "$BASE" "$e" "$W/base/$e" || die "$e did not build with the baseline; see $W/base/$e.log"
  build "$BRANCH" "$e" "$W/branch/$e" || die "$e did not build with the branch kernel; see $W/branch/$e.log"
  what="object and header"; with_report "$e" && what="object, header and report"
  ok "$e: $what unchanged ($(( $(date +%s) - s )) s for both kernels)" \
     "$(compare "$e" "$W/base/$e" "$W/branch/$e")" same
done

echo "doom-admission: controls"
ok "control: the baseline compared with itself passes" "$(compare col "$W/base/col" "$W/base/col")" same
printf '#!/bin/sh\nexec "%s" "$@" -- -O0\n' "$BASE" > "$W/kernel-o0"
chmod +x "$W/kernel-o0"
mkdir -p "$W/o0"
build "$W/kernel-o0" col "$W/o0/col" || die "col did not build with the -O0 wrapper; see $W/o0/col.log"
ok "control: a kernel with a changed emission flag fails, naming the object" \
   "col: $(compare col "$W/base/col" "$W/o0/col")" "col: object report"

echo "doom-admission: $((pass + fail)) checked, $pass pass, $fail fail, $(( $(date +%s) - t0 )) s"
[ "$fail" = 0 ] || exit 1
