#!/bin/sh
# tests/oracle/run.sh -- the oracle gate: tools/oracle/gate, its Ruby form, and
# tests/oracle/check.sh, each shown to refuse.
#
#   sh tests/oracle/run.sh
#
#   1. the check passes on this checkout, and on an unmodified copy of the
#      files the list names (the identity control for the planted ones);
#   2. each planted defect fails the check with its own message: a gate call
#      removed, an unlisted CRuby run, a call naming an unlisted section, a
#      gated row removed, an ungated file running a comparison program, a
#      file excluding a program that its row does not name;
#   3. the gate: without ALLOW_ORACLE a listed section is NOT RUN, with it the
#      section runs, and a section the list does not name is refused either
#      way -- in sh and in Ruby.
#
# Runs no oracle: the gates it calls are its own, on rows it plants.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY="${RUBY:-ruby}"
W=$(mktemp -d "${TMPDIR:-/tmp}/oracle-run.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT INT TERM
TAB=$(printf '\t')
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }

echo "== the list and this checkout =="
sh "$ROOT/tests/oracle/check.sh" > "$W/tree.out" 2>&1; rc=$?
tail -1 "$W/tree.out"
ok "the check passes on this checkout" "$rc:$(grep -c '^  FAIL' "$W/tree.out")" "0:0"

# A copy holding the list, the gate, the check and every file the list names.
copy() { # name -> the copy's root
  c="$W/$1"
  mkdir -p "$c/tests" "$c/tools"
  cp -R "$ROOT/tools/oracle" "$c/tools/oracle"
  cp -R "$ROOT/tests/oracle" "$c/tests/oracle"
  cp "$ROOT/tests/ORACLES.tsv" "$c/tests/ORACLES.tsv"
  awk -F"$TAB" '!/^#/ && NF == 4 { print $1 }' "$ROOT/tests/ORACLES.tsv" | sort -u | while IFS= read -r p; do
    mkdir -p "$c/$(dirname "$p")"; cp "$ROOT/$p" "$c/$p"
  done
  echo "$c"
}
check() { # root label -> its output in $W/<label>.out, its status echoed
  sh "$1/tests/oracle/check.sh" "$1" > "$W/$2.out" 2>&1 && echo 0 || echo 1
}
fails_with() { # label root want
  rc=$(check "$2" "$1")
  ok "$1" "$rc:$(grep -cF -- "$3" "$W/$1.out")" "1:1"
}

echo "== the planted defects =="
c=$(copy identity)
ok "control: an unmodified copy passes, so a refusal below is the defect's" "$(check "$c" identity)" 0

c=$(copy unmarked)
sed 's|"$ROOT/tools/oracle/gate" tests/doom-core/borrowed-calls.sh order|true|' \
  "$ROOT/tests/doom-core/borrowed-calls.sh" > "$c/tests/doom-core/borrowed-calls.sh"
ok "the planted copy lost its gate call" \
   "$(grep -c 'oracle/gate' "$c/tests/doom-core/borrowed-calls.sh")" 0
fails_with "a gate call removed is a gated row with no call" "$c" \
  "gates tests/doom-core/borrowed-calls.sh order, and the file has no such call"

c=$(copy unlisted)
mkdir -p "$c/tests/planted"
printf '#!/bin/sh\nok "x" "$("$RUBY" -e '"'"'require_relative ARGV[0]; print 1'"'"' fixture.rb)" 1\n' > "$c/tests/planted/new.sh"
fails_with "an unlisted CRuby run is found" "$c" \
  "tests/planted/new.sh looks like an oracle"

c=$(copy section)
sed 's|tests/doom/run.sh reference-ruby|tests/doom/run.sh reference-rubyx|' "$ROOT/tests/doom/run.sh" > "$c/tests/doom/run.sh"
fails_with "a call naming an unlisted section is refused" "$c" \
  "names tests/doom/run.sh reference-rubyx, which is not a gated row"

c=$(copy row)
grep -v "^tests/gc-arena/run.sh$TAB" "$ROOT/tests/ORACLES.tsv" > "$c/tests/ORACLES.tsv"
fails_with "a gated row removed leaves its call unlisted" "$c" \
  "tests/gc-arena/run.sh: its gate call names tests/gc-arena/run.sh reference, which is not a gated row"

c=$(copy program)
mkdir -p "$c/tests/planted"
printf '#!/bin/sh\n"$RUBY" tools/metal/tests/gpu_compare.rb a b\n' > "$c/tests/planted/runs.sh"
fails_with "an ungated file running a comparison program is refused" "$c" \
  "tests/planted/runs.sh mentions tools/metal/tests/gpu_compare.rb"

# A program's row may name a file that mentions it only to leave it out. The
# allowance names that file, so another file doing the same is still refused.
c=$(copy excludes)
mkdir -p "$c/tests/planted"
printf '#!/bin/sh\nEXCLUDED="test_otlp_semantic_model.rb"\n' > "$c/tests/planted/skips.sh"
fails_with "an exclusion allowance covers only the file it names" "$c" \
  "tests/planted/skips.sh mentions tools/ebpf/tests/spinel_ebpf/test_otlp_semantic_model.rb"

echo "== the gate =="
# A list of one gated row and nothing else, beside a copy of the gate.
g="$W/gate"
mkdir -p "$g/tools" "$g/tests"
cp -R "$ROOT/tools/oracle" "$g/tools/oracle"
printf 'here.sh\tsect\tconfirm\tsomething else\n' > "$g/tests/ORACLES.tsv"
G="$g/tools/oracle/gate"
ok "without ALLOW_ORACLE, a listed section is NOT RUN and says what it compares with" \
   "$(env -u ALLOW_ORACLE "$G" here.sh sect; echo "rc $?")" "NOT RUN (oracle): here.sh sect: something else
rc 1"
ok "ALLOW_ORACLE=0 is not the instruction" \
   "$(ALLOW_ORACLE=0 "$G" here.sh sect > /dev/null; echo $?)" 1
ok "with ALLOW_ORACLE=1 it runs, silently" "$(ALLOW_ORACLE=1 "$G" here.sh sect; echo ":$?")" ":0"
ok "an unlisted section is refused even with ALLOW_ORACLE=1" \
   "$(ALLOW_ORACLE=1 "$G" here.sh other; echo "rc $?")" "NOT RUN (oracle): here.sh other: not a gated section in tests/ORACLES.tsv
rc 1"
printf 'here.sh\t-\texempt\tnot an oracle\n' > "$g/tests/ORACLES.tsv"
ok "and so is a row that is not gated" "$(ALLOW_ORACLE=1 "$G" here.sh - > /dev/null; echo $?)" 1
printf 'here.sh\tsect\tconfirm\tsomething else\n' > "$g/tests/ORACLES.tsv"
rb() { "$RUBY" -e 'require ARGV[0]; print OracleGate.allow?(ARGV[1], ARGV[2])' "$g/tools/oracle/gate.rb" "$@"; }
ok "Ruby: without ALLOW_ORACLE, NOT RUN" "$(env -u ALLOW_ORACLE "$RUBY" -e 'require ARGV[0]; print OracleGate.allow?(ARGV[1], ARGV[2])' "$g/tools/oracle/gate.rb" here.sh sect)" \
   "NOT RUN (oracle): here.sh sect: something else
false"
ok "Ruby: with ALLOW_ORACLE=1, true" "$(ALLOW_ORACLE=1 rb here.sh sect)" true
ok "Ruby: an unlisted section is refused" "$(ALLOW_ORACLE=1 rb here.sh other | tail -1)" false

echo
echo "oracle: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ]
