#!/bin/sh
# tests/spinel-bpf-mlir/run.sh -- spinel-bpf-mlir's own Go tests that need no
# privilege, from tests/spinel-bpf-mlir/tests.tsv.
#
#   sh tests/spinel-bpf-mlir/run.sh DIR
#
# DIR is a fresh directory outside the checkout. The suite copies the tracked
# files of tools/spinel-bpf-mlir and tools/ebpf/tools into DIR/tree, makes that
# a git work tree of its own (the tests read git: the verified keys, the
# version pins), and runs from it (SPINELBPF_ROOT), because the driver writes a
# build's outputs beside its source. In the copy, third_party/bpf-mlir is
# BPF_MLIR_SRC, third_party/spinel is SPINEL's tree, build/bpf-mlir is
# EBPF_COMPILE's build, and build/bml, build/bml-test are the checkout's archives. Tests
# behind the spinelbpf_mutation build tag are listed and run with the tag.
# It runs:
#   0. the list: every Test function `go test -list` finds is in tests.tsv once,
#      and every row names a function that is there;
#   1. the routine class, per package;
#   2. gated: the oracle-cruby class (TestErrnoConsts runs CRuby).
# The privileged and vm classes are not run. The oracle-committed class needs
# the generated outputs spinel-bpf-mlir committed, which were not imported, so
# it is not run either (tests.tsv says so).
#
# No test here may reach root. sudo on PATH is a stub that records the call and
# fails, the root lock is a file in DIR, SPINELBPF_NO_ROOT=1 makes the tests'
# own helper skip, and a recorded sudo call fails the suite.
#
# Requires: GO (Go 1.27, docs/toolchains/spinel-bpf-mlir-deps), EBPF_COMPILE
# (ebpf-compile built from the bpf-mlir commit of PIN_ROW in third_party/PINS),
# BPF_MLIR_SRC (that bpf-mlir's source: a source release or a clean clone of
# a public release, whose SOURCE_VERSION names the commit, or a checkout
# without SOURCE_VERSION, read at HEAD (decision 0047); in the development
# shape, a checkout with the history back to the public pin, which
# TestReleasePinSameCompilerSource reads), CMAKE (default cmake: the controls
# run tools/spinel-mlir/bpf-mlir-commit.cmake), vendor/spinel built (or
# SPINEL), and bml's archives in
# tools/spinel-bpf-mlir/build/bml and build/bml-test
# (tools/spinel-bpf-mlir/README.md). BPF_MLIR_RELEASE, if set, is a bpf-mlir
# source release without git; the source-commit controls then also require it
# to be at the PINS row public/bpf-mlir.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIST="$ROOT/tests/spinel-bpf-mlir/tests.tsv"
[ $# -eq 1 ] || { echo "usage: sh tests/spinel-bpf-mlir/run.sh DIR" >&2; exit 2; }
WORK=$1
case $WORK in "$ROOT"|"$ROOT"/*) echo "run: DIR must be outside the checkout" >&2; exit 2 ;; esac
[ ! -e "$WORK" ] || [ -z "$(ls -A "$WORK" 2>/dev/null)" ] || { echo "run: DIR $WORK is not empty" >&2; exit 2; }
: "${GO:?set GO to Go 1.27 (docs/toolchains/spinel-bpf-mlir-deps)}"
: "${EBPF_COMPILE:?set EBPF_COMPILE to the ebpf-compile of the bpf-mlir commit third_party/PINS names}"
: "${BPF_MLIR_SRC:?set BPF_MLIR_SRC to the source of the bpf-mlir commit third_party/PINS names}"

# bpf_mlir_commit DIR: the bpf-mlir commit DIR holds, read as
# tools/spinel-mlir/bpf-mlir-commit.cmake reads it (decision 0047):
# SOURCE_VERSION (format=1, one source_commit=<40 hex>, LF line ends) when
# DIR has one -- a source release, or a git clone of a public release, whose
# HEAD is never the source commit; in a git checkout SOURCE_VERSION must be
# tracked and unchanged against HEAD and the work tree free of tracked
# changes. Without SOURCE_VERSION, a checkout's git rev-parse HEAD. Neither
# is refused.
bpf_mlir_commit() {
  if [ -f "$1/SOURCE_VERSION" ]; then
    ! grep -q "$(printf '\r')" "$1/SOURCE_VERSION" ||
      { echo "run: $1/SOURCE_VERSION: has a carriage return" >&2; return 2; }
    { [ "$(grep -c '^format=' "$1/SOURCE_VERSION")" = 1 ] && grep -qx 'format=1' "$1/SOURCE_VERSION" &&
      [ "$(grep -c '^source_commit=' "$1/SOURCE_VERSION")" = 1 ] &&
      v=$(sed -n 's/^source_commit=\([0-9a-f]\{40\}\)$/\1/p' "$1/SOURCE_VERSION") && [ -n "$v" ]; } ||
      { echo "run: $1/SOURCE_VERSION: want format=1 and one source_commit=<40 hex>" >&2; return 2; }
    if [ -e "$1/.git" ]; then
      git --no-optional-locks -C "$1" ls-files --error-unmatch -- SOURCE_VERSION > /dev/null 2>&1 ||
        { echo "run: $1: SOURCE_VERSION is not tracked in the checkout" >&2; return 2; }
      git --no-optional-locks -C "$1" diff --quiet HEAD -- SOURCE_VERSION ||
        { echo "run: $1: SOURCE_VERSION is changed against HEAD" >&2; return 2; }
      s=$(git --no-optional-locks -C "$1" status --porcelain --untracked-files=no) && [ -z "$s" ] ||
        { echo "run: $1: the checkout has tracked changes against HEAD" >&2; return 2; }
    fi
    echo "$v"
  elif [ -e "$1/.git" ]; then
    git --no-optional-locks -C "$1" rev-parse HEAD 2>/dev/null || { echo "run: $1: git rev-parse HEAD failed" >&2; return 2; }
  else
    echo "run: $1 is neither a git checkout nor a bpf-mlir source release (no SOURCE_VERSION)" >&2; return 2
  fi
}
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
B=$ROOT/tools/spinel-bpf-mlir/build
SPINELBPF_LOADER_LIBS=$B/bml/lib
[ -x "$SPINEL" ] || { echo "run: no spinel at $SPINEL (docs/building.md)" >&2; exit 2; }
for a in bml/lib/libbml.a bml-test/lib/libbml.a; do
  [ -f "$B/$a" ] || { echo "run: no $B/$a (tools/spinel-bpf-mlir/README.md)" >&2; exit 2; }
done
# the third_party/PINS row of the build shape's compiler: the public pin here
PIN_ROW=public/bpf-mlir
PIN=$(awk -F'\t' -v r="$PIN_ROW" '$1 == r { print $2 }' "$ROOT/tools/spinel-bpf-mlir/third_party/PINS")
got=$(bpf_mlir_commit "$BPF_MLIR_SRC") || exit 2
[ "$got" = "$PIN" ] || { echo "run: BPF_MLIR_SRC is at bpf-mlir $got, not $PIN" >&2; exit 2; }
mkdir -p "$WORK/nosudo" "$WORK/tmp" || exit 2

# The copy: tracked files only, so nothing the checkout's own builds left is used.
(cd "$ROOT" && git ls-files tools/spinel-bpf-mlir tools/ebpf/tools) > "$WORK/files" || exit 2
mkdir -p "$WORK/tree" || exit 2
(cd "$ROOT" && tar -cf - -T "$WORK/files") | (cd "$WORK/tree" && tar -xf -) || exit 2
G="git -C $WORK/tree -c user.name=run -c user.email=run@localhost -c commit.gpgsign=false"
$G init -q && $G add -A && $G commit -q -m 'tests/spinel-bpf-mlir/run.sh: the tracked files' || exit 2
T="$WORK/tree/tools/spinel-bpf-mlir"
ln -s "$BPF_MLIR_SRC" "$T/third_party/bpf-mlir" || exit 2
# TestReleasePinSameCompilerSource reads third_party/bpf-mlir under the git top
# level, which in the source is the module root and here is the copy's root
mkdir -p "$WORK/tree/third_party" && ln -s "$BPF_MLIR_SRC" "$WORK/tree/third_party/bpf-mlir" || exit 2
mkdir -p "$T/build/tmp" && ln -s "$B/bml" "$T/build/bml" && ln -s "$B/bml-test" "$T/build/bml-test" || exit 2
SPINELBPF_LOADER_LIBS=$T/build/bml/lib
# the tests read Spinel's tree (its runtime and sources, for the verified keys) and
# bpf-mlir's build (ebpf-schema-check) at the source's paths
ln -s "$(dirname "$(dirname "$SPINEL")")" "$T/third_party/spinel" && ln -s "$(dirname "$(dirname "$EBPF_COMPILE")")" "$T/build/bpf-mlir" || exit 2

# sudo, refused and recorded.
cat > "$WORK/nosudo/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >> "$WORK/sudo-calls"
echo "tests/spinel-bpf-mlir/run.sh: sudo is refused here (a privileged test was reached)" >&2
exit 1
EOF
chmod +x "$WORK/nosudo/sudo"
: > "$WORK/root.lock"
PATH="$WORK/nosudo:$PATH"
export PATH SPINEL EBPF_COMPILE SPINELBPF_LOADER_LIBS
export SPINELBPF_ROOT="$T" SPINELBPF_ROOT_LOCK="$WORK/root.lock" SPINELBPF_NO_ROOT=1 SPINELBPF_VERIFIED=off
export GOTOOLCHAIN=local GOFLAGS=-mod=readonly TMPDIR="$WORK/tmp"

fail=0
t_all=$(date +%s)

# The source-commit controls, on planted sources, each read both by
# bpf_mlir_commit and by tools/spinel-mlir/bpf-mlir-commit.cmake, which must
# agree (decision 0047):
#   release    a release at the pin (no git) is read at the pin;
#   other      another SOURCE_VERSION is read as another commit;
#   none       neither form is refused;
#   both       a checkout with a tracked SOURCE_VERSION at the pin is read at
#              the pin, whatever its HEAD (until decision 0047 this was
#              refused, so every git clone of a public release was refused);
#   checkout   a checkout without SOURCE_VERSION is read at its HEAD (new);
#   dirty      a checkout with SOURCE_VERSION and a tracked change is refused
#              (new: a checkout cannot claim a pin it does not hold);
#   edited     a checkout whose SOURCE_VERSION differs from HEAD's is refused
#              (new, the same reason);
#   untracked  a checkout with an untracked SOURCE_VERSION is refused (new,
#              the same reason).
#   crlf       a release whose SOURCE_VERSION has CRLF line ends is refused
#              by both readers (new: file(STRINGS) dropped the CR, so CMake
#              read it while the shell refused it; the review).
# With BPF_MLIR_RELEASE, a real release without git is read at the public pin.
S=$WORK/source-controls
mkdir -p "$S/release" "$S/other" "$S/none" "$S/crlf" || exit 2
printf 'format=1\nsource_commit=%s\n' "$PIN" > "$S/release/SOURCE_VERSION"
printf 'format=1\nsource_commit=%s\n' "$(printf '%s' "$PIN" | tr 0-9a-f 1-9a-f0)" > "$S/other/SOURCE_VERSION"
printf 'format=1\r\nsource_commit=%s\r\n' "$PIN" > "$S/crlf/SOURCE_VERSION"
plant() { # DIR [SOURCE_VERSION]: a checkout with one tracked file, and SOURCE_VERSION tracked when given
  git -c init.defaultBranch=main init -q "$1" && printf 'x\n' > "$1/f" && { [ -z "${2:-}" ] || cp "$2" "$1/SOURCE_VERSION"; } &&
    git -C "$1" add -A && git -C "$1" -c user.name=run -c user.email=run@localhost -c commit.gpgsign=false commit -q -m planted
}
plant "$S/both" "$S/release/SOURCE_VERSION" && plant "$S/checkout" && plant "$S/dirty" "$S/release/SOURCE_VERSION" &&
  plant "$S/edited" "$S/release/SOURCE_VERSION" && plant "$S/untracked" || exit 2
printf 'y\n' > "$S/dirty/f"
cp "$S/other/SOURCE_VERSION" "$S/edited/SOURCE_VERSION"
cp "$S/release/SOURCE_VERSION" "$S/untracked/SOURCE_VERSION"
HEAD_CHECKOUT=$(git -C "$S/checkout" rev-parse HEAD)
CMAKE=${CMAKE:-cmake}
ctl() { # NAME WANT DIR [PIN]: WANT is the commit read, or "refused"
  r=$(bpf_mlir_commit "$3" 2> "$S/err") || r=refused
  [ "$r" = "${4:-$PIN}" ] || [ "$r" = refused ] || r="at $r"
  c=$("$CMAKE" -DBPF_MLIR_SOURCE="$3" -P "$ROOT/tools/spinel-mlir/bpf-mlir-commit.cmake" 2>&1) && c=$(printf '%s\n' "$c" | sed -n 's/^commit //p') || c=refused
  [ "$c" = "${4:-$PIN}" ] || [ "$c" = refused ] || c="at $c"
  if [ "$r" = "$2" ] && [ "$c" = "$2" ]; then nc=$((nc + 1))
  else echo "FAIL source-commit control $1: run.sh got '$r', bpf-mlir-commit.cmake got '$c', want '$2' ($(cat "$S/err"))"; fail=$((fail + 1)); fi
}
nc=0
ctl release "$PIN" "$S/release"
ctl other "at $(sed -n 's/^source_commit=//p' "$S/other/SOURCE_VERSION")" "$S/other"
ctl none refused "$S/none"
ctl both "$PIN" "$S/both"
ctl checkout "at $HEAD_CHECKOUT" "$S/checkout"
ctl dirty refused "$S/dirty"
ctl edited refused "$S/edited"
ctl untracked refused "$S/untracked"
ctl crlf refused "$S/crlf"
want=9
if [ -n "${BPF_MLIR_RELEASE:-}" ]; then
  PUB=$(awk -F'\t' '$1 == "public/bpf-mlir" { print $2 }' "$ROOT/tools/spinel-bpf-mlir/third_party/PINS")
  if [ -e "$BPF_MLIR_RELEASE/.git" ]; then echo "FAIL source-commit control real-release: $BPF_MLIR_RELEASE has git"; fail=$((fail + 1))
  else ctl real-release "$PUB" "$BPF_MLIR_RELEASE" "$PUB"; fi
  want=10
fi
echo "source-commit controls: $nc of $want${BPF_MLIR_RELEASE:+ (with BPF_MLIR_RELEASE)}"
pkgs=$(awk -F'\t' '!/^#/ && NF >= 3 { print $1 }' "$LIST" | LC_ALL=C sort -u)

# 0. the list
: > "$WORK/listed"
: > "$WORK/listed.spinelbpf_mutation"
for p in $pkgs; do
  for tag in '' spinelbpf_mutation; do
    (cd "$T" && "$GO" test ${tag:+-tags $tag} -list '.*' "./$p") > "$WORK/list.out" 2> "$WORK/list.err" || {
      echo "FAIL list: go test ${tag:+-tags $tag }-list ./$p ($WORK/list.err)"; fail=$((fail + 1)); continue; }
    grep '^Test' "$WORK/list.out" | sed "s|^|$p	|" >> "$WORK/listed${tag:+.$tag}"
  done
done
LC_ALL=C sort -u "$WORK/listed" > "$WORK/plain.s"
LC_ALL=C sort -u "$WORK/listed" "$WORK/listed.spinelbpf_mutation" > "$WORK/listed.s"
LC_ALL=C comm -13 "$WORK/plain.s" "$WORK/listed.s" > "$WORK/tagged.s"
awk -F'\t' '!/^#/ && NF >= 3 { print $1 "\t" $2 }' "$LIST" | LC_ALL=C sort > "$WORK/rows.s"
dups=$(uniq -d "$WORK/rows.s" | wc -l)
missing=$(LC_ALL=C comm -23 "$WORK/listed.s" "$WORK/rows.s")
extra=$(LC_ALL=C comm -13 "$WORK/listed.s" "$WORK/rows.s")
if [ "$dups" -ne 0 ] || [ -n "$missing" ] || [ -n "$extra" ]; then
  echo "FAIL list: $dups duplicate row(s)"
  [ -n "$missing" ] && echo "$missing" | sed 's/^/  not in tests.tsv: /'
  [ -n "$extra" ] && echo "$extra" | sed 's/^/  in tests.tsv, not found: /'
  fail=$((fail + 1))
else
  echo "ok list: $(wc -l < "$WORK/rows.s") Test functions, each in tests.tsv once"
fi

# run_class CLASS LABEL [ENV=VAL]: the class's tests per package, each once.
run_class() {
  cls=$1; label=$2; shift 2
  for p in $pkgs; do
  for tag in '' spinelbpf_mutation; do
    names=$(awk -F'\t' -v p="$p" -v c="$cls" '!/^#/ && $1 == p && $3 == c { print $1 "\t" $2 }' "$LIST" | LC_ALL=C sort |
      if [ -n "$tag" ]; then LC_ALL=C comm -12 - "$WORK/tagged.s"; else LC_ALL=C comm -23 - "$WORK/tagged.s"; fi | cut -f2 | paste -sd'|' -)
    [ -n "$names" ] || continue
    log="$WORK/$label-$(echo "$p" | tr / _)${tag:+-$tag}.log"
    t0=$(date +%s)
    (cd "$T" && env "$@" "$GO" test ${tag:+-tags $tag} -count=1 -timeout 30m -v -run "^($names)\$" "./$p") > "$log" 2>&1
    rc=$?
    np=$(grep -c '^--- PASS' "$log"); nf=$(grep -c '^--- FAIL' "$log"); ns=$(grep -c '^--- SKIP' "$log")
    want=$(echo "$names" | tr '|' '\n' | wc -l)
    echo "$label $p${tag:+ (-tags $tag)}: $np pass, $nf fail, $ns skip of $want (rc $rc, $(( $(date +%s) - t0 )) s, $log)"
    if [ "$rc" -ne 0 ] || [ $((np + nf + ns)) -ne "$want" ]; then fail=$((fail + 1)); fi
  done
  done
}

# 1. routine
run_class routine routine

# 2. gated: CRuby
if "$ROOT/tools/oracle/gate" tests/spinel-bpf-mlir/run.sh cruby; then
  run_class oracle-cruby cruby
fi

if [ -s "$WORK/sudo-calls" ]; then
  echo "FAIL sudo: a test reached sudo ($(wc -l < "$WORK/sudo-calls") call(s), $WORK/sudo-calls)"
  fail=$((fail + 1))
fi
echo "spinel-bpf-mlir: $fail failure(s), $(( $(date +%s) - t_all )) s"
[ "$fail" -eq 0 ]
