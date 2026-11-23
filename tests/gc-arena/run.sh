#!/bin/sh
# Acceptance checks for the build choice between the collected heap and no
# collector (upstream --gc=none).
#
# Ordinary Ruby programs are built twice, once on the collector and once with
# --gc=none, and compared with each other. The pair is two configurations of
# the same compiler, so it is a routine check. Under ALLOW_ORACLE=1 each is also
# compared with an independent reference interpreter; that section is an oracle
# (tests/ORACLES.tsv) and runs only on the owner's instruction. Everything here
# goes through the product path: the compiler is given --gc=none and nothing
# else.
#
# What a matching pair of outputs does and does not establish: it establishes
# that the configuration did not change that program's result. It does not
# establish that the program is correct, and it says nothing about cases not
# run here.
#
# Every run's exit status is compared, not just its output: a program that
# printed the right answer and then died must not read as agreement. Where the
# compiler's answer differs from the reference interpreter in BOTH
# configurations, the difference is not --gc=none's -- but it is pinned to a
# checked-in file under expected/, byte for byte, so a NEW shared difference
# fails instead of being absorbed as another note.
#
# usage: tests/gc-arena/run.sh
#   CLANG      C compiler for both configurations (default: clang)
#   REF_RUBY   independent reference interpreter (default: ruby), used only
#              by the gated reference section
#   NM         symbol reader (default: nm)
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
fx="$here/fixtures"
SPINEL="$root/vendor/spinel/spinel"
CLANG="${CLANG:-clang}"
REF_RUBY="${REF_RUBY:-ruby}"

[ -x "$SPINEL" ] || { echo "run.sh: no vendor/spinel/spinel; see docs/building.md" >&2; exit 2; }
command -v "$CLANG" >/dev/null 2>&1 || { echo "run.sh: not found: $CLANG" >&2; exit 2; }
NM="${NM:-nm}"

work=$(mktemp -d "${TMPDIR:-/tmp}/spinel-gcarena.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; fail=0; notes=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

# POSIX sh has no local variables, so these names are prefixed to keep them from
# clobbering a caller's loop variable -- which they did, silently, until a test
# name came out as "control_flow.rb.rb".
# Run a program, keeping BOTH its output and its exit status. `|| true` on the
# run line threw the status away, so a crash after correct output passed.
run_capture() { # outfile rcfile command...
  _rc_o=$1; _rc_r=$2; shift 2
  if "$@" > "$_rc_o" 2>&1; then printf '0\n' > "$_rc_r"; else printf '%s\n' "$?" > "$_rc_r"; fi
}

build() { # fixture stem [extra flags...]
  _b_f=$1; _b_s=$2; shift 2
  ( cd "$work" && "$SPINEL" "$fx/$_b_f" "$@" --cc="$CLANG" -o "$work/$_b_s" ) >"$work/$_b_s.build" 2>&1
}

# The reference interpreter's answers are an oracle, asked about once.
if "$root/tools/oracle/gate" tests/gc-arena/run.sh reference; then reference=1; else reference=0; fi
if [ "$reference" = 1 ]; then
  command -v "$REF_RUBY" >/dev/null 2>&1 || { echo "run.sh: not found: $REF_RUBY" >&2; exit 2; }
fi

# ---------------------------------------------------- both configurations ----
for f in workload control_flow; do
  build $f.rb ${f}_gc    && ok "$f builds on the collector"  || bad "$f builds on the collector"  "$(tail -2 "$work/${f}_gc.build")"
  build $f.rb ${f}_ar --gc=none && ok "$f builds under --gc=none" || bad "$f builds under --gc=none" "$(tail -2 "$work/${f}_ar.build")"
  run_capture "$work/$f.gc.out"  "$work/$f.gc.rc"  "$work/${f}_gc"
  run_capture "$work/$f.ar.out"  "$work/$f.ar.rc"  "$work/${f}_ar"
  gcrc=$(cat "$work/$f.gc.rc"); arrc=$(cat "$work/$f.ar.rc")
  if cmp -s "$work/$f.gc.out" "$work/$f.ar.out" && [ "$gcrc" = "$arrc" ]; then
    ok "$f gives the same output and exit status in both configurations"
  else
    bad "$f gives the same output and exit status in both configurations" \
      "gc rc=$gcrc gc=none rc=$arrc; $(diff "$work/$f.gc.out" "$work/$f.ar.out" | head -4 | tr '\n' ' ')"
  fi
  [ "$reference" = 1 ] || continue
  run_capture "$work/$f.ref.out" "$work/$f.ref.rc" "$REF_RUBY" "$fx/$f.rb"
  refrc=$(cat "$work/$f.ref.rc")
  # The reference comparison separates two different things. If the two
  # configurations agree with each other but not with the reference, that is the
  # compiler differing from CRuby and has nothing to do with --gc=none. That is
  # not a licence to absorb any such difference: the exact diff is pinned in
  # expected/$f.ref-diff, so this stays a note only while it is THE SAME
  # difference. A new one, or a changed one, fails.
  pin="$here/expected/$f.ref-diff"
  diff "$work/$f.ref.out" "$work/$f.ar.out" > "$work/$f.refdiff" 2>&1 || true
  printf '%s\n' "$refrc $arrc" > "$work/$f.refrc"
  if cmp -s "$work/$f.ar.out" "$work/$f.ref.out" && [ "$arrc" = "$refrc" ]; then
    if [ -f "$pin" ]; then
      bad "$f under --gc=none agrees with the reference interpreter" \
        "it now AGREES, but expected/$f.ref-diff still records a difference; delete the pin"
    else
      ok "$f under --gc=none agrees with the reference interpreter"
    fi
  elif ! cmp -s "$work/$f.gc.out" "$work/$f.ar.out" || [ "$gcrc" != "$arrc" ]; then
    bad "$f under --gc=none agrees with the reference interpreter" \
      "and the two configurations do not agree either, so this IS --gc=none: $(diff "$work/$f.gc.out" "$work/$f.ar.out" | head -4 | tr '\n' ' ')"
  elif [ ! -f "$pin" ]; then
    bad "$f differs from the reference in both configurations, undeclared" \
      "a shared difference with no expected/$f.ref-diff: $(head -4 "$work/$f.refdiff" | tr '\n' ' ')"
  elif cmp -s "$work/$f.refdiff" "$pin" && [ "$(cat "$pin.rc")" = "$refrc $arrc" ]; then
    notes=$((notes+1))
    printf 'note %s\n' "$f differs from the reference in BOTH configurations, exactly as recorded in expected/$f.ref-diff: a compiler difference, not --gc=none"
  else
    bad "$f differs from the reference in both configurations, but NOT as recorded" \
      "$(diff "$pin" "$work/$f.refdiff" | head -4 | tr '\n' ' ') [rc want $(cat "$pin.rc" 2>/dev/null) got $refrc $arrc]"
  fi
done

# Retention: what the workload keeps for the whole run must still be readable.
grep -q 'row-0' "$work/workload.ar.out" && grep -q 'row-1999' "$work/workload.ar.out" \
  && ok "values retained for the whole run are still readable under --gc=none" \
  || bad "values retained for the whole run are still readable under --gc=none" "$(cat "$work/workload.ar.out")"

# ------------------------------------------- explicit release and at_exit ----
build resources.rb res_gc     && ok "resources builds on the collector" || bad "resources builds on the collector"
build resources.rb res_ar --gc=none && ok "resources builds under --gc=none" || bad "resources builds under --gc=none"
run_capture "$work/res.gc.out" "$work/res.gc.rc" "$work/res_gc"
run_capture "$work/res.ar.out" "$work/res.ar.rc" "$work/res_ar"
if cmp -s "$work/res.gc.out" "$work/res.ar.out" && [ "$(cat "$work/res.gc.rc")" = "$(cat "$work/res.ar.rc")" ]; then
  ok "explicit close and exit processing are unchanged under --gc=none"
else
  bad "explicit close and exit processing are unchanged under --gc=none" \
    "gc rc=$(cat "$work/res.gc.rc") gc=none rc=$(cat "$work/res.ar.rc"); $(diff "$work/res.gc.out" "$work/res.ar.out" | head -4 | tr '\n' ' ')"
fi
[ "$(cat "$work/res.ar.rc")" = "0" ] \
  && ok "the resources fixture exits zero under --gc=none" \
  || bad "the resources fixture exits zero under --gc=none" "rc=$(cat "$work/res.ar.rc")"
grep -q 'at_exit ran' "$work/res.ar.out" && grep -q 'END ran' "$work/res.ar.out" \
  && ok "at_exit and END still run under --gc=none" || bad "at_exit and END still run under --gc=none" "$(cat "$work/res.ar.out")"
grep -q '^true$' "$work/res.ar.out" \
  && ok "an explicitly closed file reports closed under --gc=none" || bad "an explicitly closed file reports closed under --gc=none"

# ------------------------------------------- GC operations and threads ------
# The driver no longer refuses them: under --gc=none GC.start does nothing, and
# a Thread builds. Each is checked here only as far as this suite goes: the
# program builds, runs and prints what the collector's build prints. Nothing
# beyond these two programs is claimed.
pair() { # name fixture: build both ways, run, compare output and status
  _p_n=$1; _p_f=$2
  if build "$_p_f" "${_p_n}_gc" && build "$_p_f" "${_p_n}_none" --gc=none; then
    ok "$_p_n builds on the collector and under --gc=none"
  else
    bad "$_p_n builds on the collector and under --gc=none" \
      "$(tail -2 "$work/${_p_n}_gc.build" 2>/dev/null) $(tail -2 "$work/${_p_n}_none.build" 2>/dev/null)"
    return 0
  fi
  run_capture "$work/$_p_n.gc.out" "$work/$_p_n.gc.rc" "$work/${_p_n}_gc" "$@"
  run_capture "$work/$_p_n.none.out" "$work/$_p_n.none.rc" "$work/${_p_n}_none" "$@"
}
pair use_gc use_gc.rb
if [ "$(cat "$work/use_gc.none.rc")" = 0 ] && cmp -s "$work/use_gc.gc.out" "$work/use_gc.none.out"; then
  ok "GC.start is a no-op under --gc=none: the program runs on, as on the collector"
else
  bad "GC.start is a no-op under --gc=none: the program runs on, as on the collector" \
    "rc=$(cat "$work/use_gc.none.rc") $(head -2 "$work/use_gc.none.out" | tr '\n' ' ')"
fi
pair use_thread use_thread.rb
if [ "$(cat "$work/use_thread.none.rc")" = 0 ] && cmp -s "$work/use_thread.gc.out" "$work/use_thread.none.out"; then
  ok "a Thread builds and runs under --gc=none (checked by this suite only)"
else
  bad "a Thread builds and runs under --gc=none (checked by this suite only)" \
    "rc=$(cat "$work/use_thread.none.rc") $(head -2 "$work/use_thread.none.out" | tr '\n' ' ')"
fi

# -------------------------------------------------------- large allocation --
# There is no limit under --gc=none (SPINEL_MAX_HEAP_MB is not checked). The
# fixture keeps 200 strings of 1 MB alive, so both builds hold the same memory.
pair big big.rb 200
if [ "$(cat "$work/big.none.rc")" = 0 ] && cmp -s "$work/big.gc.out" "$work/big.none.out"; then
  ok "a 200 MB retained allocation runs to the end in both configurations"
else
  bad "a 200 MB retained allocation runs to the end in both configurations" \
    "gc rc=$(cat "$work/big.gc.rc") gc=none rc=$(cat "$work/big.none.rc")"
fi

# --------------------------------------------- collector out of the artifact --
# A failing nm used to print nothing, which grep -c read as 0 -- exactly the
# answer "the collector is absent" wants. Every use goes through here, which
# fails loudly instead of returning a count nm never produced.
nm_syms() { # binary -> defined symbols, or exit 3 if nm failed
  ${NM} --defined-only "$1" > "$work/nm.out" 2>"$work/nm.err" || return 3
  [ -s "$work/nm.out" ] || return 3
  cat "$work/nm.out"
}
gcsyms() {
  if ! nm_syms "$1" > "$work/nm.syms"; then printf 'NM-FAILED\n'; return 0; fi
  grep -cE ' [Tt] sp_gc_collect$' "$work/nm.syms" || true
}
# Compared as strings, not with -gt: gcsyms answers NM-FAILED when the symbol
# reader itself failed, and a numeric test on that is a shell error on the way to
# the right verdict rather than the verdict itself.
n_gc=$(gcsyms "$work/workload_gc"); n_none=$(gcsyms "$work/workload_ar")
case "$n_gc" in
  NM-FAILED|0) bad "sp_gc_collect is present in the default artifact (control)" "saw $n_gc" ;;
  *)           ok  "sp_gc_collect is present in the default artifact (control)" ;;
esac
case "$n_none" in
  0) ok  "sp_gc_collect is absent under --gc=none" ;;
  *) bad "sp_gc_collect is absent under --gc=none" "saw $n_none" ;;
esac
# The symbol reader itself is checked, so a broken nm cannot answer "absent".
if [ "$(gcsyms "$work/no-such-binary-$$")" = "NM-FAILED" ]; then
  ok "a failing nm is reported as a failure, not as zero symbols"
else
  bad "a failing nm is reported as a failure, not as zero symbols" "got $(gcsyms "$work/no-such-binary-$$")"
fi

printf '\n%s\n' "gc/gc=none acceptance: $pass passed, $fail failed, $notes recorded difference(s) not attributable to --gc=none"
printf '%s\n' "matching output means the configuration did not change that program, not that the program is correct"
[ "$fail" -eq 0 ]
