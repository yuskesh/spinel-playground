#!/bin/sh
# tests/spinel-mlir/run.sh -- the tests of spinel-mlir's consumer
# (tools/spinel-mlir), from tests/spinel-mlir/tests.tsv.
#
#   sh tests/spinel-mlir/run.sh DIR
#
# DIR is a fresh directory outside the checkout. Two kinds of test:
#   ctest  an add_test of tools/spinel-mlir/CMakeLists.txt, run by ctest;
#   lit    a test/*.test file. lit is Python and is not used: this reads the
#          file's RUN lines (`// RUN:` or `# RUN:`, a trailing `\` joining the
#          next) and runs each with sh -e, after lit's substitutions as
#          spinel-mlir's lit.cfg.py defined them -- %build the build
#          directory, %src and %S the test/ directory, %t a fresh path in DIR
#          -- and with lit's PATH: the build's bin, bpf-mlir's bin, LLVM's
#          bin. A file passes when every RUN line exits 0.
# It checks:
#   0. the list: every ctest name and every test/*.test is in tests.tsv once,
#      and every row names one that is there;
#   1. the routine class of both kinds;
#   2. gated: the confirm class (ctest), whose expectations come from the Go
#      frontend's output; the owner named them oracles (2026-10-27).
# The oracle-records and absent classes read experiment records spinel-mlir
# keeps under docs/, which were not imported; they are not run (tests.tsv).
# sudo on PATH is a stub that records and fails, as in
# tests/spinel-bpf-mlir/run.sh; a recorded call fails the suite.
#
# Requires: tools/spinel-mlir built (tools/spinel-mlir/README.md, or
# SPINEL_MLIR_BUILD), BPF_MLIR_BUILD (the build of the bpf-mlir the consumer was built with), ruby, and
# LLVM_PREFIX (default /opt/llvm-23.1.1).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIST="$ROOT/tests/spinel-mlir/tests.tsv"
SM="$ROOT/tools/spinel-mlir"
[ $# -eq 1 ] || { echo "usage: sh tests/spinel-mlir/run.sh DIR" >&2; exit 2; }
WORK=$1
case $WORK in "$ROOT"|"$ROOT"/*) echo "run: DIR must be outside the checkout" >&2; exit 2 ;; esac
[ ! -e "$WORK" ] || [ -z "$(ls -A "$WORK" 2>/dev/null)" ] || { echo "run: DIR $WORK is not empty" >&2; exit 2; }
BUILD=${SPINEL_MLIR_BUILD:-$SM/build}
: "${BPF_MLIR_BUILD:?set BPF_MLIR_BUILD to the build directory of the bpf-mlir the consumer was built with}"
LLVM_PREFIX=${LLVM_PREFIX:-/opt/llvm-23.1.1}
[ -x "$BUILD/bin/spinel-mlir" ] || { echo "run: no $BUILD/bin/spinel-mlir (build tools/spinel-mlir first)" >&2; exit 2; }
# The tests reach bpf-mlir's tools at %build/bpf-mlir/bin, where spinel-mlir's
# build.sh builds them; here they are BPF_MLIR_BUILD, linked there (the build
# directory is ignored).
if [ -L "$BUILD/bpf-mlir" ] || [ -e "$BUILD/bpf-mlir" ]; then
  [ "$(cd "$BUILD/bpf-mlir" && pwd -P)" = "$(cd "$BPF_MLIR_BUILD" && pwd -P)" ] || { echo "run: $BUILD/bpf-mlir is not BPF_MLIR_BUILD" >&2; exit 2; }
else
  ln -s "$BPF_MLIR_BUILD" "$BUILD/bpf-mlir" || exit 2
fi
mkdir -p "$WORK/nosudo" "$WORK/tmp" || exit 2
cat > "$WORK/nosudo/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >> "$WORK/sudo-calls"
echo "tests/spinel-mlir/run.sh: sudo is refused here" >&2
exit 1
EOF
chmod +x "$WORK/nosudo/sudo"
PATH="$WORK/nosudo:$BUILD/bin:$BPF_MLIR_BUILD/bin:$LLVM_PREFIX/bin:$PATH"
export PATH TMPDIR="$WORK/tmp"
fail=0
t_all=$(date +%s)

# 0. the list
{ ctest --test-dir "$BUILD" -N | sed -n 's/^ *Test *#[0-9]*: \(.*\)$/ctest\t\1/p'
  (cd "$SM/test" && ls *.test) | sed 's/\.test$//; s/^/lit\t/'
} | LC_ALL=C sort > "$WORK/found.s"
awk -F'\t' '!/^#/ && NF >= 3 { print $1 "\t" $2 }' "$LIST" | LC_ALL=C sort > "$WORK/rows.s"
dups=$(uniq -d "$WORK/rows.s" | wc -l)
missing=$(LC_ALL=C comm -23 "$WORK/found.s" "$WORK/rows.s")
extra=$(LC_ALL=C comm -13 "$WORK/found.s" "$WORK/rows.s")
if [ "$dups" -ne 0 ] || [ -n "$missing" ] || [ -n "$extra" ]; then
  echo "FAIL list: $dups duplicate row(s)"
  [ -n "$missing" ] && echo "$missing" | sed 's/^/  not in tests.tsv: /'
  [ -n "$extra" ] && echo "$extra" | sed 's/^/  in tests.tsv, not found: /'
  fail=$((fail + 1))
else
  echo "ok list: $(wc -l < "$WORK/rows.s") tests ($(grep -c '^ctest' "$WORK/rows.s") ctest, $(grep -c '^lit' "$WORK/rows.s") lit), each in tests.tsv once"
fi

# 1a. routine ctest
# ctest names here are letters, digits, - and _ only (the list check holds the
# names to ctest's), so they go into the regex as they are.
names=$(awk -F'\t' '!/^#/ && $1 == "ctest" && $3 == "routine" { print $2 }' "$LIST" | paste -sd'|' -)
case $names in *[!A-Za-z0-9_\|-]*) echo "run: a ctest name outside [A-Za-z0-9_-]" >&2; exit 2 ;; esac
want=$(awk -F'\t' '!/^#/ && $1 == "ctest" && $3 == "routine"' "$LIST" | wc -l)
t0=$(date +%s)
ctest --test-dir "$BUILD" -j4 --timeout 600 -R "^($names)\$" > "$WORK/ctest.log" 2>&1
rc=$?
np=$(grep -cE '^ *[0-9]+/[0-9]+ Test +#[0-9]+: .* Passed' "$WORK/ctest.log")
nf=$(grep -cE '^ *[0-9]+/[0-9]+ Test +#[0-9]+: .*(Failed|Timeout|Not Run|Exception)' "$WORK/ctest.log")
echo "routine ctest: $np pass, $nf fail of $want (rc $rc, $(( $(date +%s) - t0 )) s, $WORK/ctest.log)"
[ "$rc" -eq 0 ] && [ "$np" -eq "$want" ] || fail=$((fail + 1))

# 1b. routine lit: the RUN lines, as lit would substitute them
t0=$(date +%s); lp=0; lf=0
for n in $(awk -F'\t' '!/^#/ && $1 == "lit" && $3 == "routine" { print $2 }' "$LIST"); do
  f="$SM/test/$n.test"; d="$WORK/lit/$n"; mkdir -p "$d"
  sed -n 's,^[[:space:]]*\(//\|#\)[[:space:]]*RUN:[[:space:]]*,,p' "$f" |
    awk '{ if (sub(/\\$/, "")) { acc = acc $0 " "; next } print acc $0; acc = "" }' > "$d/run-lines"
  if [ ! -s "$d/run-lines" ]; then echo "  FAIL lit $n: no RUN line"; lf=$((lf + 1)); continue; fi
  ok=1; i=0
  while IFS= read -r line; do
    i=$((i + 1))
    cmd=$(printf '%s\n' "$line" | sed "s|%build|$BUILD|g; s|%src|$SM/test|g; s|%S|$SM/test|g; s|%t|$d/t$i|g")
    printf '%s\n' "$cmd" > "$d/cmd$i"
    (cd "$d" && sh -e -c "$cmd") > "$d/out$i" 2>&1 || { r=$?; ok=0; echo "  FAIL lit $n: RUN line $i exited $r ($d/out$i)"; break; }
  done < "$d/run-lines"
  if [ "$ok" -eq 1 ]; then lp=$((lp + 1)); else lf=$((lf + 1)); fi
done
want=$(awk -F'\t' '!/^#/ && $1 == "lit" && $3 == "routine"' "$LIST" | wc -l)
echo "routine lit: $lp pass, $lf fail of $want ($(( $(date +%s) - t0 )) s, $WORK/lit)"
[ "$lf" -eq 0 ] && [ "$lp" -eq "$want" ] || fail=$((fail + 1))

# 2. gated: confirm
if "$ROOT/tools/oracle/gate" tests/spinel-mlir/run.sh confirm; then
  names=$(awk -F'\t' '!/^#/ && $1 == "ctest" && $3 == "confirm" { print $2 }' "$LIST" | paste -sd'|' -)
  case $names in *[!A-Za-z0-9_\|-]*) echo "run: a ctest name outside [A-Za-z0-9_-]" >&2; exit 2 ;; esac
  want=$(awk -F'\t' '!/^#/ && $1 == "ctest" && $3 == "confirm"' "$LIST" | wc -l)
  ctest --test-dir "$BUILD" -j4 --timeout 600 -R "^($names)\$" > "$WORK/confirm.log" 2>&1
  rc=$?
  np=$(grep -cE '^ *[0-9]+/[0-9]+ Test +#[0-9]+: .* Passed' "$WORK/confirm.log")
  echo "confirm ctest: $np pass of $want (rc $rc, $WORK/confirm.log)"
  [ "$rc" -eq 0 ] && [ "$np" -eq "$want" ] || fail=$((fail + 1))
fi

if [ -s "$WORK/sudo-calls" ]; then
  echo "FAIL sudo: a test reached sudo ($(wc -l < "$WORK/sudo-calls") call(s), $WORK/sudo-calls)"
  fail=$((fail + 1))
fi
echo "spinel-mlir: $fail failure(s), $(( $(date +%s) - t_all )) s"
[ "$fail" -eq 0 ]
