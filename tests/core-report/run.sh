#!/bin/sh
#
# tests/core-report/run.sh -- decision 0010 step 1: the loop-bound build report.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/core-report/run.sh
#
# What it establishes, in order:
#
#   1. The kernel's report flags: --report needs --profile and the reverse,
#      only hosted-stage2 is implemented, and an entry the kernel refuses gets
#      no report.
#   2. OBSERVATION CHANGES NOTHING. Every fixture entry is built three times:
#      A plainly with --emit-mlir, B the same with --report, C plainly with
#      neither. A and C must be byte-identical -- otherwise comparing A with B
#      would mean nothing -- and B's object, header and MLIR must equal A's. A
#      build with -O1 appended must differ, which shows the comparison can fail.
#   3. Every report validates against the schema, and says what
#      tests/core-report/expect.tsv says, which was written from the rules and
#      not from a run. The validator is shown to refuse damaged reports.
#   4. Every bound is a bound: tests/core-report/oracle.rb runs the fixtures
#      under CRuby and compares what each loop counted with the bound the
#      report gives for the same arguments.
#   5. The golden reports under tests/core-report/golden/ are reproduced,
#      minus what differs per host. UPDATE_GOLDEN=1 rewrites them instead and
#      counts each as skipped.
#   6. A loop's digest ignores layout and changes with its condition.
#   7. A version 2 report (decision 0014) validates against the version 2
#      schema and is refused by the version 1 schema.
#   8. An unreserved call frame's evidence, with its bytes, validates against
#      the version 1 schema.
#
# KERNEL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select the tools.
# BASELINE_KERNEL, when set, names a kernel built WITHOUT this change; every
# plain object must then equal the one it builds. REQUIRE_ALL=1 turns a skip
# into a failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-report"
FIX="$HERE/fixtures"
SCHEMA="$ROOT/tools/mlir/native/schema/core-report-v1.schema.json"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"

die() { echo "core-report: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build tools/mlir/native first)"
[ -x "$READER" ] || die "no contract reader at $READER (build tools/contract or set SPINEL_TYPEDUMP)"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

# UPDATE_GOLDEN rewrites the very files this run would compare, so its
# comparisons become comparisons with themselves. REQUIRE_ALL is what a gate
# sets. Refusing the combination is what makes a vacuous pass IMPOSSIBLE for a
# gate to see, rather than merely unlikely.
if [ "${UPDATE_GOLDEN:-}" = 1 ] && [ "${REQUIRE_ALL:-}" = 1 ]; then
  die "UPDATE_GOLDEN=1 rewrites the golden reports and the canonical fixture, so their comparisons would compare each with itself; it cannot be combined with REQUIRE_ALL=1"
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/core-report.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
# THREE SKIP SITES, AND UNDER REQUIRE_ALL EXACTLY ONE IS REACHABLE. The other
# two fire only under UPDATE_GOLDEN, which is refused together with
# REQUIRE_ALL before any work, so a gate that reports "1 skipped" can only be
# reporting the baseline comparison. Anyone adding a skip site that a gate CAN
# reach makes that count ambiguous again, and the diagnostic below names what
# did not run precisely because a count alone cannot say which.
skips=""
skipped() {
  echo "  SKIP $1"
  skip=$((skip + 1))
  skips="$skips  - $1
"
}
# The Ruby checks print their own pass/FAIL lines and a summary line; their
# counts are added to this script's.
tally() { # log
  sed '$d' "$1"
  p=$(tail -n 1 "$1" | sed -n 's/^[a-z]*: \([0-9]*\) passed, \([0-9]*\) failed$/\1/p')
  f=$(tail -n 1 "$1" | sed -n 's/^[a-z]*: \([0-9]*\) passed, \([0-9]*\) failed$/\2/p')
  if [ -z "$p" ] || [ -z "$f" ]; then
    echo "  FAIL $(basename "$1") ended without its summary line"; tail -n 3 "$1" | sed 's/^/        /'
    fail=$((fail + 1)); return
  fi
  pass=$((pass + p)); fail=$((fail + f))
}

# kernel CONTRACT ROOT STEM [kernel options] [-- clang options]
kernel() {
  k_contract=$1; k_root=$2; k_stem=$3; shift 3
  "$KERNEL" "$k_contract" --root "$k_root" --typedump "$READER" -o "$k_stem.o" \
    --header "$k_stem.h" --clang "$CC_BIN" "$@" > "$k_stem.log" 2>&1
}
rc_of() { "$@" && echo 0 || echo $?; }

# CORE_REPORT_ENTRIES and CORE_REPORT_INJECT_FAILURE exist for ONE thing: the
# selftest at the end of this file, which needs a run that is red for an
# unrelated reason AND has a skip. That state is what suppressed the
# REQUIRE_ALL diagnostic until today, and once the defect that supplied the
# failure is fixed, nothing produces it any more -- so the branch keeps the
# input, the way canonical-rejected.json keeps the bytes that fail the
# canonical comparison. They are not for ordinary use.
ENTRIES=${CORE_REPORT_ENTRIES:-$(sed -e '/^#/d' -e '/^[[:space:]]*$/d' "$HERE/expect.tsv" | cut -f1 | awk '!seen[$0]++')}
# The injector is reachable only from the selftest below, BY CONSTRUCTION: the
# variable names a token file that the parent run creates in its own temporary
# directory, holding a nonce that parent generated.
#
# WHAT THAT CLOSES, AND WHAT IT DOES NOT, because a claim of unreachability
# with no stated scope is eventually read as covering everything:
#
#   closed: a stray CORE_REPORT_INJECT_FAILURE inherited from a shell, a
#     wrapper or an exported profile -- refused, loudly, since it names no
#     token; and a token left behind by a run that was killed before its trap
#     fired -- refused, since its nonce belongs to that run and not this one.
#   NOT closed: a process of the SAME USER running concurrently, which can
#     read the live token while the selftest window is open. Nothing in a
#     build system closes that, and it does not matter here: such a process
#     can edit this file, which is cheaper and total.
#
# So this stops accidents and stale residue, which are the things that happen.
if [ -n "${CORE_REPORT_INJECT_FAILURE:-}" ]; then
  # The value is a path and a NONCE, and the file must contain that nonce. The
  # path alone would still be reachable by accident in one case: a run killed
  # before its trap fires leaves its temporary directory, and its token, behind
  # -- so a variable naming that stale path would be honoured by a later run.
  # The nonce is fresh per parent and never written anywhere else, so a stale
  # token is refused like any other file.
  inject_path=${CORE_REPORT_INJECT_FAILURE% *}
  inject_nonce=${CORE_REPORT_INJECT_FAILURE##* }
  if [ "$inject_path" = "$CORE_REPORT_INJECT_FAILURE" ] || [ ! -f "$inject_path" ] ||
     [ "$(cat "$inject_path" 2>/dev/null)" != "core-report selftest injector $inject_nonce" ]; then
    die "CORE_REPORT_INJECT_FAILURE belongs to this suite's own selftest and names a token file, with its nonce, that only the parent run writes; it is not a way to add a failure to a run"
  fi
  ok "the injected control failure (CORE_REPORT_INJECT_FAILURE)" injected none
fi
mkdir -p "$W/c" "$W/r" "$W/a" "$W/b" "$W/p" "$W/cli"
# shellcheck disable=SC2086
"$RUBY" "$HERE/contracts.rb" --fixture "$FIX/loops.rb" --root-name loops.rb --out "$W/c" $ENTRIES \
  || die "could not write the fixture contracts"

echo "== the report flags =="
C1="$W/c/lb_lt.contract"
ok "--report without --profile is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/1" --report "$W/cli/1.json")" 2
ok "  and says why, writing nothing" \
   "$(grep -c -- '--report needs --profile' "$W/cli/1.log"):$([ -e "$W/cli/1.json" ] || [ -e "$W/cli/1.o" ] && echo wrote || echo none)" "1:none"
ok "--profile without --report is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/2" --profile hosted-stage2)" 2
# `realtime` became a profile this build accepts with step 2, so the refusal
# is shown with a name no profile has.
ok "an unimplemented profile is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/3" --report "$W/cli/3.json" --profile bare-metal)" 2
ok "  and named as not implemented" "$(grep -c "profile 'bare-metal' is not implemented" "$W/cli/3.log")" 1
ok "--report-revision without --report is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/4" --report-revision abc)" 2
ok "a revision is recorded where the report names the source" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/5" --report "$W/cli/5.json" --profile hosted-stage2 --report-revision 0123abc):$("$RUBY" -rjson -e 'r = JSON.parse(File.read(ARGV[0])); print r["inputs"]["source"]["revision"], " ", r["properties"]["loop_bound"]["evidence"][0]["artifact"]["revision"]' "$W/cli/5.json" 2>/dev/null)" \
   "0:0123abc 0123abc"
# The report is the one flag that could overwrite an artifact, and it digests
# the object before writing, so the overwrite would look like it had worked.
ok "--report over the object is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/7" --report "$W/cli/7.o" --profile hosted-stage2)" 2
ok "--report over the header is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/8" --report "$W/cli/8.h" --profile hosted-stage2)" 2
ok "--report over the MLIR is refused" \
   "$(rc_of kernel "$C1" "$FIX" "$W/cli/9" --emit-mlir "$W/cli/9.mlir" --report "$W/cli/9.mlir" \
      --profile hosted-stage2)" 2
cat > "$W/cli/bad.rb" <<'EOF'
def lb_bad(cnt, n_cnt)
  s = "x"
  0
end
EOF
"$RUBY" "$HERE/contracts.rb" --fixture "$W/cli/bad.rb" --root-name bad.rb --out "$W/cli" lb_bad
ok "an entry the kernel refuses gets no report" \
   "$(rc_of kernel "$W/cli/lb_bad.contract" "$W/cli" "$W/cli/6" --report "$W/cli/6.json" --profile hosted-stage2):$([ -e "$W/cli/6.json" ] && echo wrote || echo none)" \
   "1:none"

echo "== observation changes nothing =="
for e in $ENTRIES; do
  ra=$(rc_of kernel "$W/c/$e.contract" "$FIX" "$W/a/$e" --emit-mlir "$W/a/$e.mlir")
  rb=$(rc_of kernel "$W/c/$e.contract" "$FIX" "$W/b/$e" --emit-mlir "$W/b/$e.mlir" \
         --report "$W/r/$e.json" --profile hosted-stage2)
  rp=$(rc_of kernel "$W/c/$e.contract" "$FIX" "$W/p/$e")
  if [ "$ra$rb$rp" != 000 ]; then
    ok "$e builds three times" "$ra$rb$rp" 000
    sed 's/^/        /' "$W/b/$e.log" | head -5
    continue
  fi
  ok "$e: two plain builds are identical" "$(cmp -s "$W/a/$e.o" "$W/p/$e.o" && echo same || echo differ)" same
  same=same
  for x in o h mlir; do cmp -s "$W/a/$e.$x" "$W/b/$e.$x" || same="$x differs"; done
  [ -s "$W/r/$e.json" ] || same="no report"
  ok "$e: object, header and MLIR identical with the report" "$same" same
done
ok "an -O1 build differs, so the comparison can fail" \
   "$(rc_of kernel "$W/c/lb_nested.contract" "$FIX" "$W/p/sensitivity" -- -O1):$(cmp -s "$W/a/lb_nested.o" "$W/p/sensitivity.o" && echo same || echo differ)" \
   "0:differ"
if [ -n "${BASELINE_KERNEL:-}" ]; then
  # a kernel built without this change: whether this comparison is an oracle
  # is the owner's to classify (tests/ORACLES.tsv), so it is gated until then
  if "$ROOT/tools/oracle/gate" tests/core-report/run.sh baseline-kernel; then
    [ -x "$BASELINE_KERNEL" ] || die "BASELINE_KERNEL is not executable: $BASELINE_KERNEL"
    differ=""
    for e in $ENTRIES; do
      "$BASELINE_KERNEL" "$W/c/$e.contract" --root "$FIX" --typedump "$READER" -o "$W/p/$e.base.o" \
        --clang "$CC_BIN" > "$W/p/$e.base.log" 2>&1 || differ="$differ $e(rc)"
      cmp -s "$W/p/$e.o" "$W/p/$e.base.o" || differ="$differ $e"
    done
    ok "every plain object equals the baseline kernel's" "${differ:-none}" none
  fi
else
  skipped "the baseline kernel comparison (set BASELINE_KERNEL)"
fi

echo "== the reports say what the rules say =="
"$RUBY" "$HERE/check.rb" --schema "$SCHEMA" --expect "$HERE/expect.tsv" --reports "$W/r" > "$W/check.log" 2>&1 || true
tally "$W/check.log"
"$RUBY" "$HERE/check.rb" --schema "$SCHEMA" --selftest "$W/r/lb_nested.json" > "$W/selftest.log" 2>&1 || true
tally "$W/selftest.log"

echo "== every bound is a bound (CRuby) =="
if "$ROOT/tools/oracle/gate" tests/core-report/run.sh bound-oracle; then
  "$RUBY" "$HERE/oracle.rb" --fixture "$FIX/loops.rb" --expect "$HERE/expect.tsv" \
    --grid "$HERE/oracle.tsv" --reports "$W/r" > "$W/oracle.log" 2>&1 || true
  tally "$W/oracle.log"
fi

echo "== the canonical JSON the goldens are written in =="
if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
  # Rewriting the fixture makes its byte comparison vacuous, so this counts as
  # a skip and the run's other lines stay in the log rather than printing
  # checks nothing tallied.
  "$RUBY" "$HERE/check.rb" --json-selftest "$FIX/canonical.json" --update > "$W/canonical.log" 2>&1 || true
  skipped "the canonical JSON fixture (UPDATE_GOLDEN=1 rewrote it)"
else
  "$RUBY" "$HERE/check.rb" --json-selftest "$FIX/canonical.json" > "$W/canonical.log" 2>&1 || true
  tally "$W/canonical.log"
fi

echo "== the golden reports =="
mkdir -p "$W/g"
for g in work:gd_work unknown:gd_unknown none:gd_none; do
  stem=${g%%:*}; entry=${g#*:}
  rc=$(rc_of kernel "$FIX/golden/$stem.contract" "$FIX" "$W/g/$entry" --report "$W/g/$entry.json" --profile hosted-stage2)
  ok "$entry builds with its report" "$rc" 0
  [ "$rc" = 0 ] || continue
  "$RUBY" "$HERE/normalize.rb" "$W/g/$entry.json" > "$W/g/$entry.normal.json"
  if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
    cp "$W/g/$entry.normal.json" "$HERE/golden/$entry.json"
    skipped "$entry compared with its golden (UPDATE_GOLDEN=1 rewrote it)"
  elif [ -f "$HERE/golden/$entry.json" ]; then
    ok "$entry reproduces its golden report" \
       "$(cmp -s "$W/g/$entry.normal.json" "$HERE/golden/$entry.json" && echo same || echo differ)" same
    cmp -s "$W/g/$entry.normal.json" "$HERE/golden/$entry.json" \
      || diff "$HERE/golden/$entry.json" "$W/g/$entry.normal.json" | head -10 | sed 's/^/        /'
  else
    ok "$entry has a golden report" missing present
  fi
done
"$RUBY" "$HERE/check.rb" --schema "$SCHEMA" --validate "$W/g/gd_work.json" "$W/g/gd_unknown.json" \
  "$W/g/gd_none.json" "$HERE/golden/gd_work.json" "$HERE/golden/gd_unknown.json" \
  "$HERE/golden/gd_none.json" > "$W/golden.log" 2>&1 || true
tally "$W/golden.log"

echo "== a version 2 report validates against the version 2 schema =="
# DECISION 0014, Task 4. An application entry's report is version 2: the same
# document plus its `application` object. The fixture is tests/app's write-set
# entry, reported at admission (no object yet), bound to the fixture's
# configuration; tests/app/effects.sh checks what the report SAYS, this only
# that the document is the schema's, and that the version 1 schema refuses it.
SCHEMA2="$ROOT/tools/mlir/native/schema/core-report-v2.schema.json"
APPFIX="$ROOT/tests/app/fixtures/effects"
mkdir -p "$W/v2/e"
cp "$APPFIX/writes.rb" "$APPFIX/writes.contract" "$W/v2/"
for f in "$APPFIX"/e/adc.json "$APPFIX"/e/get.json; do
  sed "s/HOSTTARGET/$("$CC_BIN" -print-target-triple)/" "$f" > "$W/v2/e/$(basename "$f")"
done
if "$KERNEL" "$W/v2/writes.contract" --root "$W/v2" --admit-only --clang "$CC_BIN" --typedump "$READER" \
     --report "$W/v2/writes.json" --profile realtime --config-binding "$(cat "$APPFIX/binding.txt")" \
     > "$W/v2/writes.log" 2>&1; then
  "$RUBY" "$HERE/check.rb" --schema "$SCHEMA2" --validate "$W/v2/writes.json" > "$W/v2.log" 2>&1 || true
  tally "$W/v2.log"
  ok "the version 1 schema refuses the version 2 report" \
     "$("$RUBY" "$HERE/check.rb" --schema "$SCHEMA" --validate "$W/v2/writes.json" > /dev/null 2>&1 && echo accepted || echo refused)" refused
else
  ok "the version 2 fixture reports" "$(tail -1 "$W/v2/writes.log")" reported
fi

echo "== an unreserved call frame validates against the schema =="
# DECISION 0021. The stack measurement adds a call frame codegen did not
# reserve to its function and records it as evidence with its bytes. No entry
# above has one, so the schema refused that key in DOOM's reports while every
# report here validated. fixtures/unreserved.rb pushes six stack arguments on
# x86-64, named as the target so every host builds the same frame. The control
# is the same schema without `bytes`, which must refuse the report.
mkdir -p "$W/uf"
if kernel "$FIX/unreserved.contract" "$FIX" "$W/uf/uf_many" --report "$W/uf/uf_many.json" \
     --profile hosted-stage2 -- --target=x86_64-unknown-linux-gnu; then
  ok "the entry reports an unreserved call frame with its bytes" \
     "$("$RUBY" -rjson -e 'e = JSON.parse(File.read(ARGV[0]))["properties"]["stack_budget"]["evidence"]
       puts e.count { |x| x["subject"].start_with?("unreserved call frame in ") && x["bytes"].is_a?(Integer) }' \
       "$W/uf/uf_many.json")" 1
  "$RUBY" "$HERE/check.rb" --schema "$SCHEMA" --validate "$W/uf/uf_many.json" > "$W/uf.log" 2>&1 || true
  tally "$W/uf.log"
  "$RUBY" -rjson -e 's = JSON.parse(File.read(ARGV[0]))
    s["$defs"]["stackEvidence"]["properties"].delete("bytes") or abort("no bytes in stackEvidence")
    File.write(ARGV[1], JSON.generate(s))' "$SCHEMA" "$W/uf/nobytes.schema.json"
  ok "the schema without bytes refuses it" \
     "$("$RUBY" "$HERE/check.rb" --schema "$W/uf/nobytes.schema.json" --validate "$W/uf/uf_many.json" > /dev/null 2>&1 && echo accepted || echo refused)" refused
else
  ok "the unreserved-frame fixture reports" "$(tail -1 "$W/uf/uf_many.log")" reported
fi

echo "== a digest follows the condition, not the layout =="
mkdir -p "$W/v"
cat > "$W/v/layout.rb" <<'EOF'
# the same loop as lb_lt, laid out differently
def lb_lt(cnt, n_cnt, n)

  i = 0
  while (i <   n)   # parenthesised, spaced and commented
    cnt[0] += 1
    i += 1
  end
  0
end
EOF
cat > "$W/v/changed.rb" <<'EOF'
def lb_lt(cnt, n_cnt, n)
  i = 0
  while i <= n
    cnt[0] += 1
    i += 1
  end
  0
end
EOF
digest_of() { "$RUBY" -rjson -e 'print JSON.parse(File.read(ARGV[0]))["properties"]["loop_bound"]["loops"][0]["digest"]' "$1"; }
for v in layout changed; do
  "$RUBY" "$HERE/contracts.rb" --fixture "$W/v/$v.rb" --root-name "$v.rb" --out "$W/v/$v" lb_lt
  rc=$(rc_of kernel "$W/v/$v/lb_lt.contract" "$W/v" "$W/v/$v" --report "$W/v/$v.json" --profile hosted-stage2)
  ok "the $v variant builds" "$rc" 0
done
base=$(digest_of "$W/r/lb_lt.json")
ok "layout, parentheses and comments leave the digest alone" "$(digest_of "$W/v/layout.json")" "$base"
ok "a changed condition changes the digest" \
   "$([ "$(digest_of "$W/v/changed.json")" = "$base" ] && echo same || echo differ)" differ

# THE STATE THE DIAGNOSTIC WAS SUPPRESSED IN, kept and exercised. A child run
# is given an unrelated failure and no BASELINE_KERNEL, which is red and
# skipped at once; the parent then requires the REQUIRE_ALL diagnostic to be in
# its output. Before the reporting order was fixed, the exit on the failure
# came first and none of it was ever printed. The child is a real run of this
# script, not a stub, because what was wrong was the order of a real run.
if [ -z "${CORE_REPORT_INJECT_FAILURE:-}" ] && [ "${UPDATE_GOLDEN:-}" != 1 ]; then
  echo "== what a run says when it is red AND something did not run =="
  child="$W/red-and-skipped.log"
  # The status is CAPTURED, not left to `set -e`: the child is meant to fail,
  # and an uncaught failure here would kill the parent at the line that exists
  # to check what the child printed.
  token="$W/inject.token"
  # /dev/urandom AND od are REQUIRED, and the requirement is stated rather than
  # worked around. There used to be a fallback to the pid and the clock, which
  # is guessable: a construct that quietly degrades a property is worse than
  # one that refuses, because the run continues and means something weaker
  # than it says. If a fresh nonce cannot be made, this refuses, and under
  # REQUIRE_ALL a gate on such a host fails rather than accepting the weaker
  # construction.
  nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$nonce" ] ||
    die "the injector selftest needs a fresh nonce, which needs /dev/urandom and od; it will not fall back to a guessable one"
  printf 'core-report selftest injector %s' "$nonce" > "$token"
  crc=0
  CORE_REPORT_ENTRIES=lb_lt CORE_REPORT_INJECT_FAILURE="$token $nonce" REQUIRE_ALL=1 BASELINE_KERNEL= \
    sh "$0" > "$child" 2>&1 || crc=$?
  ok "it exits 1" "$crc" 1
  # And the injector cannot be tripped from outside: without the token file the
  # variable names, the run refuses rather than quietly gaining a failure.
  stray=0
  CORE_REPORT_ENTRIES=lb_lt CORE_REPORT_INJECT_FAILURE=1 REQUIRE_ALL=1 BASELINE_KERNEL= \
    sh "$0" > "$W/stray.log" 2>&1 || stray=$?
  ok "  a stray CORE_REPORT_INJECT_FAILURE is refused, not honoured" \
     "$stray:$(grep -c "belongs to this suite's own selftest" "$W/stray.log")" "1:1"
  # And a token left behind by a run that was killed before its trap fired:
  # right path, right marker, WRONG NONCE.
  stale="$W/stale.token"
  printf 'core-report selftest injector %s' "$nonce-stale" > "$stale"
  stalerc=0
  CORE_REPORT_ENTRIES=lb_lt CORE_REPORT_INJECT_FAILURE="$stale $nonce" REQUIRE_ALL=1 BASELINE_KERNEL= \
    sh "$0" > "$W/stale.log" 2>&1 || stalerc=$?
  ok "  a stale token from a killed run is refused too" \
     "$stalerc:$(grep -c "belongs to this suite's own selftest" "$W/stale.log")" "1:1"
  ok "  and reports the unrelated failure" \
     "$(grep -c 'FAIL the injected control failure' "$child")" 1
  ok "  and still names the check that did not run" \
     "$(grep -c 'REQUIRE_ALL=1, and 1 check(s) did not run' "$child")" 1
  # THIS PHRASE IS LOAD-BEARING AND THE GREP IS A CONTRACT ON THE MESSAGE'S
  # MEANING, NOT ON ITS WORDING. It asserts the diagnostic still tells the
  # operator that the baseline is a kernel WITHOUT the change, which is the
  # claim the check exists to protect. Rewording the message is fine and costs
  # one line: carry the claim, then update this grep to whatever phrase now
  # carries it. That price is the point -- a check that could tell an intended
  # rewrite from an accidental deletion is a check that can be talked out of
  # firing, and nothing at the moment of firing can distinguish them.
  ok "  and still says what BASELINE_KERNEL buys" \
     "$(grep -c 'built WITHOUT the report change' "$child")" 1
  ok "  and still says not to unset REQUIRE_ALL" \
     "$(grep -c 'Do not' "$child")" 1
fi

echo "core-report: $pass passed, $fail failed, $skip skipped"
# BOTH DIAGNOSTICS, THEN ONE EXIT. What failed and what did not run are
# independent facts, and the exit used to stand between them: any failure left
# the block below unreachable, so the setting's whole effect was invisible on
# exactly the runs an operator reads most closely, and the missing check was
# discovered only after the failure was fixed and the suite re-run.
if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then
  # A failure that only says "something was skipped" invites the operator to
  # reach for the one fix that makes it go away -- unsetting REQUIRE_ALL --
  # which gives up the property the gate exists to establish. So it says which
  # check, what setting it buys, and what not to do.
  #
  # IT SAYS "for example" ABOUT THE REVISION ON PURPOSE. A frozen fact can be
  # named in a message; a branch-relative one cannot be, without machinery to
  # compute it at runtime. The starting revision of whatever branch this is
  # running on is the second kind, so the text names the KIND of thing to build
  # and leaves the commit to the reader. A sibling message elsewhere names its
  # revision outright because that one is frozen -- the difference is what the
  # script can know, not how carefully either was written.
  {
    echo "core-report: REQUIRE_ALL=1, and $skip check(s) did not run:"
    printf '%s' "$skips"
    case "$skips" in
      *BASELINE_KERNEL*)
        echo "core-report: BASELINE_KERNEL is a PATH TO A BUILT spinel-core-kernel BINARY,"
        echo "  one built WITHOUT the report change -- for example from this branch's starting"
        echo "  revision. docs/building.md, under 'The CORE build report', says how to build"
        echo "  one. Setting it establishes that"
        echo "  every object this kernel writes is byte-identical to the one that kernel"
        echo "  writes -- that OBSERVATION DID NOT CHANGE THE ARTIFACT, which is the central"
        echo "  claim of decision 0010 step 1 and the one thing a reporting change must never"
        echo "  break."
        ;;
    esac
    echo "core-report: a gate runs with REQUIRE_ALL=1 so that every check runs. Do not"
    echo "  unset REQUIRE_ALL to get a green run: that turns a check that did not run back"
    echo "  into a silent skip and gives up what the gate is for."
  } >&2
  incomplete=1
fi
[ "$fail" -eq 0 ] || exit 1
[ -z "${incomplete:-}" ] || exit 1
exit 0
