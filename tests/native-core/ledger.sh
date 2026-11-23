#!/bin/sh
# The input ledger, at the tools rather than at the driver.
#
# The boundary is enforced by the shared loader, so a standalone run of the
# checker or the emitter refuses what the driver would refuse. It is NOT
# conditional on --inputs-out: that flag only selects whether a copy is written
# for the caller.
#
# usage: SPINEL_SEAM=<checkout> tests/native-core/ledger.sh
#
# CLANG is REQUIRED, on every platform, and LLVM_PREFIX (or NM) with it for the
# gate checks elsewhere in this suite. --clang below used to default to the
# Debian path /opt/llvm-23.1.1/bin/clang, so on a machine without it the two
# emitter checks failed as though the emitter had refused their programs; this
# file now refuses to start instead, and says which variable to set. LLVM_PREFIX
# alone is enough -- its bin/clang is taken. See docs/native-core/reproducing.md.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
BUILD="${SPINEL_CORE_BUILD:-$root/tools/mlir/native/build}"
CHECK="$BUILD/bin/spinel-core-check"
EMIT="$BUILD/bin/spinel-core-emit"
READER="${SPINEL_TYPEDUMP:-$root/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$CHECK"
source_stamp kernel "$EMIT"
source_stamp reader "$READER"
SPINEL_SEAM="${SPINEL_SEAM:-$root/vendor/spinel}"
SPINEL="$(CDPATH= cd -- "$SPINEL_SEAM" && pwd)/bin/spinel"
for f in "$CHECK" "$EMIT" "$READER" "$SPINEL"; do
  [ -x "$f" ] || { echo "ledger.sh: missing $f" >&2; exit 2; }
done

# The clang the emitter was configured with; spinel-core-emit hands it IR, and
# a clang from a different LLVM cannot read it. REFUSED rather than guessed.
# The two emitter checks below used to write `${CLANG:-/opt/llvm-23.1.1/bin/clang}`
# inline, so on any machine without that Debian path they failed as though the
# emitter had rejected the program, which is what they are there to observe.
# tools/core/core-artifact-gate refuses the same way rather than falling back.
CLANG="${CLANG:-${LLVM_PREFIX:+$LLVM_PREFIX/bin/clang}}"
if [ -z "${CLANG:-}" ]; then
  echo "ledger.sh: set CLANG to the clang this build used, or LLVM_PREFIX to its prefix" >&2
  exit 2
fi
[ -x "$CLANG" ] || { echo "ledger.sh: no clang at $CLANG" >&2; exit 2; }

w=$(mktemp -d "${TMPDIR:-/tmp}/core-ledger.XXXXXX")
w=$(CDPATH= cd -- "$w" && pwd -P)
trap 'rm -rf "$w"' EXIT INT TERM
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

B='def pick(a, b)
  a < b ? a : b
end

puts pick(7, 3)
'
: > "$w/empty.rb"
printf '# only a comment\n' > "$w/comment_only.rb"
printf '%s' "$B"                                  > "$w/clean.rb"
printf 'require_relative "empty"\n%s' "$B"        > "$w/r_empty.rb"
printf 'require_relative "comment_only"\n%s' "$B" > "$w/r_comment.rb"
printf 'require "json"\n%s' "$B"                  > "$w/r_pkg.rb"

# ---- the standalone checker, with NO --inputs-out --------------------------
"$CHECK" "$w/clean.rb" --method pick --typedump "$READER" >/dev/null 2>&1 \
  && ok "the standalone checker accepts a single-file program" \
  || bad "the standalone checker accepts a single-file program"
for c in r_empty r_comment; do
  if "$CHECK" "$w/$c.rb" --method pick --typedump "$READER" >"$w/$c.out" 2>&1; then
    bad "the standalone checker refuses $c without --inputs-out" "it accepted it"
  else
    grep -q 'input ledger' "$w/$c.out" \
      && ok "the standalone checker refuses $c without --inputs-out" \
      || bad "the standalone checker refuses $c for the ledger" "$(head -1 "$w/$c.out")"
  fi
done

# Decision 0042 stage 4: a source that calls an intrinsic is read with the
# intrinsics' prelude placed before the program, from a copy. A source that spells
# require_relative gets its copy beside it, since the parser resolves that load
# from the source's own directory; the copy is refused for the ledger as the
# source itself would be, is removed again, and a directory the copy cannot be
# written to is refused by name.
printf 'require_relative "empty"\ndef pick(a, b)\n  core_w32_add(a, b)\nend\n\nputs pick(7, 3)\n' > "$w/r_intr.rb"
if "$CHECK" "$w/r_intr.rb" --method pick --typedump "$READER" >"$w/r_intr.out" 2>&1; then
  bad "the standalone checker refuses r_intr (an intrinsic and require_relative)" "it accepted it"
else
  grep -q 'input ledger' "$w/r_intr.out" \
    && ok "the standalone checker refuses r_intr (an intrinsic and require_relative) for the ledger" \
    || bad "the standalone checker refuses r_intr for the ledger" "$(head -1 "$w/r_intr.out")"
fi
left=$(ls -a "$w" | grep -c '^\.spinel-prelude\.' || true)
[ "$left" = 0 ] \
  && ok "r_intr: no .spinel-prelude.* copy left beside the source" \
  || bad "r_intr: no .spinel-prelude.* copy left beside the source" "$left left"
mkdir "$w/ro"
cp "$w/r_intr.rb" "$w/empty.rb" "$w/ro/"
chmod a-w "$w/ro"
if "$CHECK" "$w/ro/r_intr.rb" --method pick --typedump "$READER" >"$w/ro.out" 2>&1; then
  bad "a directory the copy cannot be written to is refused" "it accepted it"
else
  grep -q 'not writable' "$w/ro.out" \
    && ok "a directory the copy cannot be written to is refused as not writable" \
    || bad "a directory the copy cannot be written to is refused as not writable" "$(head -1 "$w/ro.out")"
fi
chmod u+w "$w/ro"
# The copy is held to the text written to it, as the source is held to its
# snapshot: a reader that edits the file it is handed is refused either way.
# The wrapper changes the call's constant before the real reader runs. For a
# source that calls an intrinsic, the file it is handed is the copy; for one
# that does not, the source itself (the control: the existing check).
cat > "$w/drift" <<'DRIFT'
#!/bin/sh
sed 's/, 1)$/, 2)/; s/a + 1$/a + 2/' "$1" > "$1.drift" && cat "$1.drift" > "$1" && rm -f "$1.drift"
exec "$REAL_READER" "$@"
DRIFT
chmod +x "$w/drift"
printf 'def pick(a)\n  core_w32_add(a, 1)\nend\n\nputs pick(7)\n' > "$w/drift_intr.rb"
printf 'def pick(a)\n  a + 1\nend\n\nputs pick(7)\n' > "$w/drift_plain.rb"
for c in drift_intr:"the reader's copy of" drift_plain:"source changed while obtaining analysis"; do
  n=${c%%:*}; words=${c#*:}
  if REAL_READER="$READER" "$CHECK" "$w/$n.rb" --method pick --typedump "$w/drift" >"$w/$n.out" 2>&1; then
    bad "$n: a reader that edits its input is refused" "it was accepted"
  else
    grep -qF "$words" "$w/$n.out" \
      && ok "$n: a reader that edits its input is refused ($words)" \
      || bad "$n: a reader that edits its input is refused ($words)" "$(head -1 "$w/$n.out")"
  fi
done
# The prelude goes before the program in the copy, after the source's leading
# comment lines, so each source line is further down in the copy. What the
# user reads still names the source's own line: the reader's parse errors,
# which name the copy, and the checker's locations, which come from the
# module. Each source has comment lines and calls an intrinsic; the lines and
# columns are the source's, by hand.
printf '# a comment\n\ndef calc(a)\n  core_u32(7) + a\nend\n\ndef bad(\n  x = ) 1\nend\nputs calc(1)\n' > "$w/l_parse.rb"
"$CHECK" "$w/l_parse.rb" --method calc --typedump "$READER" >"$w/l_parse.out" 2>&1 || true
grep -q 'l_parse\.rb:8:5: expected a default value for the parameter' "$w/l_parse.out" \
  && ok "l_parse: a parse error in a source with the prelude names its own line (8:5)" \
  || bad "l_parse: a parse error in a source with the prelude names its own line (8:5)" "$(grep -m1 'l_parse\.rb:' "$w/l_parse.out")"
printf '# a comment\ndef calc(a)\n  x = core_w32_add(a, 1)\n  [1].size + x\nend\nputs calc(1)\n' > "$w/l_check.rb"
"$CHECK" "$w/l_check.rb" --method calc --typedump "$READER" >"$w/l_check.out" 2>&1 || true
grep -q "^REFUSED	calc	$w/l_check\.rb:4:2	heap-operation	" "$w/l_check.out" \
  && ok "l_check: a refusal in a source with the prelude names its own line (4:2)" \
  || bad "l_check: a refusal in a source with the prelude names its own line (4:2)" "$(grep -m1 '^REFUSED' "$w/l_check.out")"
# A UTF-8 byte order mark stays the copy's first bytes, before the prelude,
# and the parser counts it in line 1's columns: a program that starts on
# line 1 behind it is read, and its line-1 columns and parse errors keep
# the mark's 3 bytes (3 + 13 and 3 + 35, by hand).
printf '\357\273\277def calc(a)\n  core_w32_add(a, 1)\nend\nputs calc(7)\n' > "$w/l_bom.rb"
"$CHECK" "$w/l_bom.rb" --method calc --typedump "$READER" >"$w/l_bom.out" 2>&1 || true
grep -q "^CHECKED	calc	$w/l_bom\.rb	" "$w/l_bom.out" \
  && ok "l_bom: a source behind a byte order mark that calls an intrinsic is checked" \
  || bad "l_bom: a source behind a byte order mark that calls an intrinsic is checked" "$(grep -m1 -E '^(CHECKED|REFUSED|UNKNOWN)|unexpected' "$w/l_bom.out")"
printf '\357\273\277def calc(a); [core_w32_add(a, 1)].size; end\nputs calc(7)\n' > "$w/l_bom_col.rb"
"$CHECK" "$w/l_bom_col.rb" --method calc --typedump "$READER" >"$w/l_bom_col.out" 2>&1 || true
grep -q "^REFUSED	calc	$w/l_bom_col\.rb:1:16	heap-operation	" "$w/l_bom_col.out" \
  && ok "l_bom_col: a refusal on line 1 behind a byte order mark keeps its column (1:16)" \
  || bad "l_bom_col: a refusal on line 1 behind a byte order mark keeps its column (1:16)" "$(grep -m1 '^REFUSED' "$w/l_bom_col.out")"
printf '\357\273\277def calc(a); core_w32_add(a, 1) + ); end\nputs calc(7)\n' > "$w/l_bom_parse.rb"
"$CHECK" "$w/l_bom_parse.rb" --method calc --typedump "$READER" >"$w/l_bom_parse.out" 2>&1 || true
grep -q "l_bom_parse\.rb:1:38: unexpected ')'" "$w/l_bom_parse.out" \
  && ok "l_bom_parse: a parse error on line 1 behind a byte order mark keeps its column (1:38)" \
  || bad "l_bom_parse: a parse error on line 1 behind a byte order mark keeps its column (1:38)" "$(grep -m1 'l_bom_parse\.rb:' "$w/l_bom_parse.out")"

# A packaged require. The reader does not OPEN the package -- so a ledger of
# opened files is honestly silent about it -- but it does RECOGNISE the load and
# replace it with a comment, while the hosted compiler resolves it to a file.
# "I opened one file" and "I analysed everything this program asks to load" are
# different statements, and only the first is something a list of opened files
# can make. So an unsatisfied load refuses the ledger, and the checker refuses
# the program.
printf 'require "thread"\n%s' "$B" > "$w/r_core.rb"
for c in r_pkg r_core; do
  if "$CHECK" "$w/$c.rb" --method pick --typedump "$READER" >"$w/$c.out" 2>&1; then
    bad "the standalone checker refuses $c, an unsatisfied load" "it accepted it"
  else
    grep -q 'load request' "$w/$c.out" \
      && ok "the standalone checker refuses $c: a load it recognised and did not satisfy" \
      || bad "the standalone checker refuses $c for the unsatisfied load" "$(head -1 "$w/$c.out")"
  fi
done
# The two halves are refused by DIFFERENT mechanisms, and the asymmetry is the
# point. The hosted compiler resolves the package to a file, so it has no
# unsatisfied load and its ledger is accurate -- two entries -- and the driver
# refuses it for the path outside the snapshot. The reader never resolves it, so
# its ledger would have been a truthful single entry, and what refuses there is
# the unsatisfied load. Either alone leaves a gap; both are asserted.
"$SPINEL" "$w/r_pkg.rb" --inputs-out="$w/pkg.spinel" -S >/dev/null 2>&1 || true
sn=$(tr -cd '\0' < "$w/pkg.spinel" 2>/dev/null | wc -c | tr -d ' ')
[ "${sn:-0}" -gt 1 ] \
  && ok "the compiler resolves the package to a file and records both ($sn entries)" \
  || bad "the compiler records the package it opened" "$sn entries"
"$READER" "$w/r_pkg.rb" ast --inputs-out="$w/pkg.reader" >"$w/pkg.rout" 2>&1 \
  && bad "the reader refuses the package as an unsatisfied load" "it succeeded" \
  || { grep -q 'load request' "$w/pkg.rout" \
        && ok "the reader refuses it as a load it recognised and did not satisfy" \
        || bad "the reader refuses the package as an unsatisfied load" "$(head -1 "$w/pkg.rout")"; }

# ---- the standalone emitter, with NO --inputs-out --------------------------
"$SPINEL" "$w/clean.rb" --core pick --core-id=z --core-map="$w/clean.map" --no-line-map -S \
  >/dev/null 2>&1 || true
cp "$w/clean.map" "$w/r_empty.map"
"$EMIT" --source "$w/clean.rb" --core-map "$w/clean.map" -o "$w/clean.o" \
  --clang "$CLANG" --typedump "$READER" >/dev/null 2>&1 \
  && ok "the standalone emitter accepts a single-file program" \
  || bad "the standalone emitter accepts a single-file program"
if "$EMIT" --source "$w/r_empty.rb" --core-map "$w/r_empty.map" -o "$w/r_empty.o" \
     --clang "$CLANG" --typedump "$READER" >"$w/e.out" 2>&1; then
  bad "the standalone emitter refuses a dependency without --inputs-out" "it accepted it"
else
  grep -q 'input ledger' "$w/e.out" \
    && ok "the standalone emitter refuses a dependency without --inputs-out" \
    || bad "the standalone emitter refuses a dependency for the ledger" "$(head -1 "$w/e.out")"
fi

# ---- a reader whose LATER faces disagree with its first --------------------
# Four separate processes read the source. That they read the same files is the
# thing being checked, not something the check may assume, so every face is
# asked. This reader is honest on `ast` and reports an outside file afterwards.
cat > "$w/liar" <<'LIAR'
#!/bin/sh
real="$REAL_READER"; out=""; face=""
for a in "$@"; do case "$a" in --inputs-out=*) out=${a#--inputs-out=} ;; esac; done
for a in "$@"; do case "$a" in ast|nodes|locals|methods) face=$a ;; esac; done
set -- "$@"
"$real" "$@" || exit $?
if [ -n "$out" ] && [ "$face" != "ast" ]; then
  printf '%s\0/etc/passwd\0' "$LIAR_SOURCE" > "$out"
fi
LIAR
chmod +x "$w/liar"
if REAL_READER="$READER" LIAR_SOURCE="$(cd "$w" && pwd)/clean.rb" \
     "$CHECK" "$w/clean.rb" --method pick --typedump "$w/liar" >"$w/liar.out" 2>&1; then
  bad "a reader whose later faces report an outside input is refused" "it was accepted"
else
  grep -q 'input ledger' "$w/liar.out" \
    && ok "a reader whose later faces report an outside input is refused ($(grep -m1 -o 'ledger ([a-z]*)' "$w/liar.out"))" \
    || bad "a reader whose later faces report an outside input is refused" "$(head -1 "$w/liar.out")"
fi

# A truncated ledger -- a record without its NUL -- is malformed, not a path.
cat > "$w/trunc" <<'TRUNC'
#!/bin/sh
real="$REAL_READER"; out=""
for a in "$@"; do case "$a" in --inputs-out=*) out=${a#--inputs-out=} ;; esac; done
"$real" "$@" || exit $?
[ -n "$out" ] && printf '%s' "$LIAR_SOURCE" > "$out"
exit 0
TRUNC
chmod +x "$w/trunc"
if REAL_READER="$READER" LIAR_SOURCE="$(cd "$w" && pwd)/clean.rb" \
     "$CHECK" "$w/clean.rb" --method pick --typedump "$w/trunc" >"$w/tr.out" 2>&1; then
  bad "a truncated ledger is refused" "it was accepted"
else
  grep -q 'truncated' "$w/tr.out" && ok "a truncated ledger is refused as truncated" \
    || bad "a truncated ledger is refused as truncated" "$(head -1 "$w/tr.out")"
fi

# An empty ledger must not pass as "nothing outside the snapshot".
cat > "$w/blank" <<'BLANK'
#!/bin/sh
real="$REAL_READER"; out=""
for a in "$@"; do case "$a" in --inputs-out=*) out=${a#--inputs-out=} ;; esac; done
"$real" "$@" || exit $?
[ -n "$out" ] && : > "$out"
exit 0
BLANK
chmod +x "$w/blank"
if REAL_READER="$READER" "$CHECK" "$w/clean.rb" --method pick --typedump "$w/blank" \
     >"$w/bl.out" 2>&1; then
  bad "an empty ledger is refused" "it was accepted"
else
  grep -q 'empty ledger' "$w/bl.out" && ok "an empty ledger is refused" \
    || bad "an empty ledger is refused" "$(head -1 "$w/bl.out")"
fi

# ---- the caller's copy is published only once every face passed ------------
# A run that fails on a later face must not have replaced an existing ledger:
# the file on disk would then describe a build that did not happen.
# A leftover staging file is checked after EACH failure, not once at the end: a
# single check at the end cannot say which case left one, and a case that
# cleaned up after a later case had already failed to would look clean.
no_temp() { # label
  [ -z "$(ls "$w"/.spinel-inputs.* 2>/dev/null)" ] \
    && ok "$1: no staging file left behind" \
    || { bad "$1: no staging file left behind" "$(ls "$w"/.spinel-inputs.* 2>/dev/null | head -1)"
         rm -f "$w"/.spinel-inputs.* ; }
}

printf 'PREVIOUS\0' > "$w/out.led"
if REAL_READER="$READER" LIAR_SOURCE="$(cd "$w" && pwd)/clean.rb" \
     "$CHECK" "$w/clean.rb" --method pick --typedump "$w/liar" \
     --inputs-out "$w/out.led" >/dev/null 2>&1; then
  bad "a later-face failure does not publish a ledger" "the run succeeded"
else
  printf 'PREVIOUS\0' > "$w/expect_prev"
  cmp -s "$w/out.led" "$w/expect_prev" \
    && ok "a later-face failure leaves an existing ledger byte-for-byte untouched" \
    || bad "a later-face failure leaves an existing ledger untouched" \
        "it changed: [$(od -c "$w/out.led" 2>/dev/null | head -1)]"
  no_temp "later-face failure"
fi
# A reader that FAILS EARLY: /usr/bin/true writes nothing, so the first face is
# rejected for empty output before any ledger or contract is examined. Kept as
# its own control, and named for what it is -- it does NOT exercise the contract
# stage, which an earlier version of this suite claimed it did.
printf 'PREVIOUS\0' > "$w/out_early.led"
if "$CHECK" "$w/clean.rb" --method pick --typedump /usr/bin/true \
     --inputs-out "$w/out_early.led" >/dev/null 2>&1; then
  bad "a reader that produces nothing fails the run" "it succeeded"
else
  printf 'PREVIOUS\0' > "$w/expect_prev"
  cmp -s "$w/out_early.led" "$w/expect_prev" \
    && ok "an early reader failure leaves an existing ledger byte-for-byte untouched" \
    || bad "an early reader failure leaves an existing ledger untouched" "it changed"
  no_temp "early reader failure"
fi

# The CONTRACT stage. All four faces run for real and write real ledgers, which
# pass their checks; one face then loses a single node definition, so a
# reference to it dangles and readContract rejects the module. This is the
# window the publication change is about: everything before the contract
# succeeded, and the copy must still not have been made.
cat > "$w/corrupt" <<'CORRUPT'
#!/bin/sh
real="$REAL_READER"; face=""
for a in "$@"; do case "$a" in ast|nodes|locals|methods) face=$a ;; esac; done
[ "$face" = "ast" ] || exec "$real" "$@"
t=$(mktemp); "$real" "$@" > "$t" || { rm -f "$t"; exit 1; }
awk -v k="${CORRUPT_NODE:-4}" '/^N /{n++; if (n==k) next} {print}' "$t"
rm -f "$t"
CORRUPT
chmod +x "$w/corrupt"
printf 'PREVIOUS\0' > "$w/out2.led"
if REAL_READER="$READER" CORRUPT_NODE=4 "$CHECK" "$w/clean.rb" --method pick \
     --typedump "$w/corrupt" --inputs-out "$w/out2.led" >"$w/c.out" 2>&1; then
  bad "a contract failure does not publish a ledger" "the run succeeded"
else
  grep -q 'invalid analysis contract' "$w/c.out" \
    && ok "the failure is at the contract stage, after every face and ledger passed" \
    || bad "the failure is at the contract stage" "$(head -2 "$w/c.out" | tr '\n' ' ')"
  grep -q 'input ledger' "$w/c.out" \
    && bad "no face was rejected for its ledger" "$(grep -m1 'input ledger' "$w/c.out")" \
    || ok "no face was rejected for its ledger, so the contract is what failed"
  cmp -s "$w/out2.led" "$w/expect_prev" \
    && ok "a contract failure leaves an existing ledger byte-for-byte untouched" \
    || bad "a contract failure leaves an existing ledger untouched" "it changed"
  no_temp "contract failure"
fi

# And a run that succeeds publishes exactly the canonical content: the resolved
# source path and one NUL. Compared byte for byte against that, not by counting
# terminators -- a count would accept the wrong path.
# The success case starts from the SAME sentinel the failures start from, so
# "unchanged" above is a property of the failure rather than of a path nothing
# ever writes.
printf 'PREVIOUS\0' > "$w/out3.led"
"$CHECK" "$w/clean.rb" --method pick --typedump "$READER" \
  --inputs-out "$w/out3.led" >/dev/null 2>&1
cmp -s "$w/out3.led" "$w/expect_prev" \
  && bad "a successful run replaces the sentinel" "the sentinel survived, so nothing was published" \
  || ok "a successful run replaces the sentinel"
printf '%s\0' "$(cd "$w" && pwd)/clean.rb" > "$w/expect_ok"
cmp -s "$w/out3.led" "$w/expect_ok" \
  && ok "a successful run publishes exactly the resolved source path and a NUL" \
  || bad "a successful run publishes the canonical ledger" \
      "got [$(od -c "$w/out3.led" 2>/dev/null | head -2 | tr '\n' ' ')]"
no_temp "successful run"

printf '\ninput ledger: %s passed, %s failed\n' "$pass" "$fail"
printf '%s\n' "an unsatisfied load refuses the ledger: a list of opened files cannot account for a load that resolved to no file"
[ "$fail" -eq 0 ]
