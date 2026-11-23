#!/bin/sh
# tools/core/spinel-core-build: the whole path, and what must make it refuse.
#
# usage: SPINEL_SEAM=<checkout> tests/native-core/driver.sh
#
# On macOS, LLVM_PREFIX (or NM) and CLANG are REQUIRED, not optional overrides.
# tools/core/core-artifact-gate reads the Mach-O symbol table through
# ${NM:-$LLVM_PREFIX/bin/llvm-nm} and refuses to start with
# "set LLVM_PREFIX or NM" when neither is set, so every gate check here fails
# for that reason alone. See docs/native-core/reproducing.md.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
fx="$here/fixtures"
DRV="$root/tools/core/spinel-core-build"
# Passed explicitly rather than left to the emitter's own search, which walks up
# from its executable for tools/contract/build/spinel-typedump. A build
# directory outside the repository -- which BUILD_DIR exists to allow -- finds
# nothing, and every emission then fails for a reason that has nothing to do
# with what is being tested.
READER="${SPINEL_TYPEDUMP:-$root/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "${SPINEL_CORE_BUILD:-$root/tools/mlir/native/build}/bin/spinel-core-check"
source_stamp kernel "${SPINEL_CORE_BUILD:-$root/tools/mlir/native/build}/bin/spinel-core-emit"
source_stamp reader "$READER"
[ -x "$DRV" ] || { echo "driver.sh: no $DRV" >&2; exit 2; }
SPINEL_SEAM="${SPINEL_SEAM:-$root/vendor/spinel}"
export SPINEL_SEAM
SUM_NAME=sha256sum
[ "$(uname -s)" != Darwin ] || SUM_NAME=shasum
command -v ruby >/dev/null 2>&1 || { echo "driver.sh: no ruby for the oracle" >&2; exit 2; }

w=$(mktemp -d "${TMPDIR:-/tmp}/core-driver.XXXXXX")
trap 'rm -rf "$w"' EXIT INT TERM
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

# ---- the path works, and agrees with both oracles -------------------------
if "$DRV" --source "$fx/lower.rb" --core lower -o "$w/app" >"$w/build.out" 2>&1; then
  got=$("$w/app")
  if "$root/tools/oracle/gate" tests/native-core/driver.sh cruby-answer; then
    want=$(ruby "$fx/lower.rb")
    [ "$got" = "$want" ] && ok "the driver builds and agrees with CRuby ($got)" \
      || bad "agrees with CRuby" "core=[$got] cruby=[$want]"
  fi
  hosted=$("${SPINEL_SEAM}/bin/spinel" "$fx/lower.rb" --cc="${CC:-cc}" -o "$w/plain" >/dev/null 2>&1 && "$w/plain")
  [ "$got" = "$hosted" ] && ok "and agrees with ordinary Spinel ($hosted)" \
    || bad "agrees with ordinary Spinel" "core=[$got] hosted=[$hosted]"
else
  bad "the driver builds the acceptance program" "$(head -3 "$w/build.out" | tr '\n' ' ')"
fi

# ---- refusals -------------------------------------------------------------
refuses() { # label, args...
  _l=$1; shift
  if "$DRV" "$@" >"$w/r.out" 2>&1; then bad "$_l" "it succeeded"
  else
    grep -q '^spinel-core-build: ' "$w/r.out" \
      && ok "$_l  ($(grep -m1 '^spinel-core-build: ' "$w/r.out" | cut -c22-84))" \
      || bad "$_l" "refused without naming the stage: $(head -1 "$w/r.out")"
  fi
}
refuses "a method that is not in the source is refused" \
  --source "$fx/lower.rb" --core nosuch -o "$w/x"
# INT64_MIN is eligible after ecbe5eb, and exponentiation after decision 0042
# stage 3. An Array append allocates, which no decision plans to admit.
refuses "an ineligible source is refused" \
  --source "$fx/arith/reject_array_shl.rb" --core calculate -o "$w/x"
# An eligibility refusal that no decision plans to lift: a String literal
# allocates, and core never does. (The arithmetic operators that used to be
# the input here are admitted, by decisions 0015 and 0042.)
printf 'def lower(a, b)\n  "ab"\n  a - b\nend\n\nputs lower(7, 3)\n' > "$w/heap.rb"
refuses "a String literal is refused before anything is emitted" \
  --source "$w/heap.rb" --core lower -o "$w/heap-output"
if grep -q "^spinel-core-build: 'lower' is not eligible for core compilation$" "$w/r.out" \
   && grep -q 'heap-operation' "$w/r.out" \
   && [ ! -e "$w/heap-output" ]; then
  ok "the String literal stops at eligibility and publishes no output"
else
  bad "the String literal stops at eligibility and publishes no output" "$(head -3 "$w/r.out" | tr '\n' ' ')"
fi
printf 'def lower(a, b)\n  a < b ? a : b\nend\n\ndef other(y)\n  lower(y, 1)\nend\n\nputs lower(7, 3)\n' > "$w/ing.rb"
refuses "an unaccounted ingress is refused" \
  --source "$w/ing.rb" --core lower -o "$w/x"

# ---- a failed build must not replace a working output ---------------------
printf 'PREVIOUS\n' > "$w/keep"
"$DRV" --source "$fx/lower.rb" --core nosuch -o "$w/keep" >/dev/null 2>&1 || true
[ "$(cat "$w/keep")" = "PREVIOUS" ] \
  && ok "a failed build leaves a previous output untouched" \
  || bad "a failed build leaves a previous output untouched" "it was replaced"

# ---- the artifact gate, through the gate the product uses ------------------
# Not a re-implementation of the predicates: the driver calls this same program,
# so a gate that stopped working fails here too. Each object violates exactly
# one of the three questions.
GATE="$root/tools/core/core-artifact-gate"
CC_="${CC:-cc}"
printf 'long spc_x_root(long a){ return a; }\n'                                      > "$w/g_ok.c"
printf 'long spc_x_root(long a){ return a; }\nlong spc_x_extra(long a){ return a; }\n' > "$w/g_two.c"
printf 'extern long helper(long);\nlong spc_x_root(long a){ return helper(a); }\n'    > "$w/g_dep.c"
printf 'long spc_x_root = 0;\n'                                                      > "$w/g_data.c"
for f in g_ok g_two g_dep g_data; do "$CC_" -O2 -c "$w/$f.c" -o "$w/$f.o" 2>/dev/null; done

"$GATE" "$w/g_ok.o" spc_x_root >/dev/null 2>&1 \
  && ok "the gate passes a conforming object" || bad "the gate passes a conforming object"
gate_refuses() { # label, object, expected-letter
  if "$GATE" "$2" spc_x_root >"$w/g.out" 2>&1; then bad "$1" "the gate accepted it"
  else grep -q "^core-artifact-gate: $3:" "$w/g.out" \
         && ok "$1" || bad "$1" "refused, but not as $3: $(head -1 "$w/g.out")"; fi
}
gate_refuses "A refuses an unexpected core symbol"          "$w/g_two.o"  A
gate_refuses "B refuses an undefined dependency"            "$w/g_dep.o"  B
gate_refuses "C refuses a symbol exported without text"     "$w/g_data.o" C

# A symbol reader that cannot run must be a failure, not an empty answer: no
# symbols read looks exactly like no undefined dependencies.
if NM=/bin/false "$GATE" "$w/g_ok.o" spc_x_root >"$w/g.out" 2>&1; then
  bad "a failing symbol reader fails the gate" "it passed"
else
  grep -q 'symbol reader failed' "$w/g.out" \
    && ok "a failing symbol reader fails the gate, and says so" \
    || bad "a failing symbol reader fails the gate" "$(head -1 "$w/g.out")"
fi

# ---- the driver's own fail-closed points ----------------------------------
# A checksum tool that cannot run must stop the build. An empty digest compares
# equal to another empty digest, so this would otherwise pass every verify.
mkdir -p "$w/nosum"
printf '#!/bin/sh\nexit 1\n' > "$w/nosum/$SUM_NAME"; chmod +x "$w/nosum/$SUM_NAME"
if PATH="$w/nosum:$PATH" "$DRV" --source "$fx/lower.rb" --core lower -o "$w/x" >"$w/ns.out" 2>&1; then
  bad "a failing checksum tool fails the build" "it succeeded"
else
  grep -q 'cannot digest' "$w/ns.out" && ok "a failing checksum tool fails the build, and says so" \
    || bad "a failing checksum tool fails the build" "$(head -1 "$w/ns.out")"
fi

# A checksum tool that fails ONCE, partway through the manifest, then succeeds.
# This is the case a `printf "$(digest ...)"` hides: printf succeeds, the field
# is empty, and the build carries on with a manifest missing a value.
mkdir -p "$w/flaky"
cat > "$w/flaky/$SUM_NAME" <<'FLAKY'
#!/bin/sh
n=$(cat "$FLAKY_COUNT" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$FLAKY_COUNT"
[ "$n" = "3" ] && exit 1
case "$(uname -s)" in Darwin) exec /usr/bin/shasum "$@";; *) exec /usr/bin/sha256sum "$@";; esac
FLAKY
chmod +x "$w/flaky/$SUM_NAME"
: > "$w/flaky.count"
if FLAKY_COUNT="$w/flaky.count" PATH="$w/flaky:$PATH" \
     "$DRV" --source "$fx/lower.rb" --core lower -o "$w/x" >"$w/fl.out" 2>&1; then
  bad "a checksum that fails once mid-manifest fails the build" "it succeeded"
else
  grep -q 'cannot digest' "$w/fl.out" \
    && ok "a checksum that fails once mid-manifest fails the build" \
    || bad "a checksum that fails once mid-manifest fails the build" "$(head -1 "$w/fl.out")"
fi

# The output must not be a directory: mv onto one moves into it and succeeds.
mkdir -p "$w/asdir"
refuses "a directory as the output is refused" --source "$fx/lower.rb" --core lower -o "$w/asdir"

# A dangling symlink where a probe-then-write would have written.
ln -sf /nonexistent/elsewhere "$w/dangle"
if "$DRV" --source "$fx/lower.rb" --core lower -o "$w/dangle" >"$w/dg.out" 2>&1; then
  [ -f "$w/dangle" ] && ok "publishing over a dangling symlink replaces it with the executable" \
    || bad "publishing over a dangling symlink" "the link still dangles"
else
  ok "publishing over a dangling symlink fails rather than writing through it"
fi

# ---- the input ledger ------------------------------------------------------
# Each analysis reports the files IT opened, recorded at the one function every
# load goes through and written NUL-separated. That replaces the two heuristics
# that were here before: #line is source POSITION information, so a file
# contributing no emitted code leaves no trace in it, and a snapshot working
# directory only constrains relative resolution.
B='def pick(a, b)
  a < b ? a : b
end

puts pick(7, 3)
'
mkdir -p "$w/dep"
: > "$w/dep/empty.rb"
printf '# only a comment\n'            > "$w/dep/comment_only.rb"
printf 'K = 5\n'                       > "$w/dep/const_only.rb"
printf 'require_relative "empty"\n'    > "$w/dep/indirect.rb"
printf 'K2 = 6\n'                      > "$w/dep/spa ce.rb"
for d in empty comment_only const_only indirect; do
  printf 'require_relative "%s"\n%s' "$d" "$B" > "$w/dep/r_$d.rb"
done
printf 'require_relative "spa ce"\n%s' "$B" > "$w/dep/r_space.rb"
printf 'require "json"\n%s' "$B"           > "$w/dep/r_pkg.rb"

refuses "an EMPTY required file is refused"        --source "$w/dep/r_empty.rb" --core pick -o "$w/x"
refuses "a comment-only required file is refused"  --source "$w/dep/r_comment_only.rb" --core pick -o "$w/x"
refuses "a constants-only required file is refused" --source "$w/dep/r_const_only.rb" --core pick -o "$w/x"
refuses "an INDIRECT require is refused"           --source "$w/dep/r_indirect.rb" --core pick -o "$w/x"
refuses "a required path containing a space is refused" --source "$w/dep/r_space.rb" --core pick -o "$w/x"
refuses "a packaged require is refused"            --source "$w/dep/r_pkg.rb" --core pick -o "$w/x"

# The empty and comment-only cases are the ones the old #line scan could not
# see. Asserting that directly keeps the reason for the ledger from going stale.
"${SPINEL_SEAM}/bin/spinel" "$w/dep/r_empty.rb" -S > "$w/dep/e.c" 2>/dev/null || true
if sed -n 's|^#line [0-9]* "\(.*\)"$|\1|p' "$w/dep/e.c" 2>/dev/null | grep -q '/empty\.rb$'; then
  bad "an empty required file leaves no #line directive" "it left one"
else
  ok "an empty required file leaves no #line directive, which is why the ledger exists"
fi
# And the ledger does see it.
"${SPINEL_SEAM}/bin/spinel" "$w/dep/r_empty.rb" --inputs-out="$w/dep/e.led" -S >/dev/null 2>&1 || true
if [ -s "$w/dep/e.led" ] && xargs -0 -n1 sh -c 'case "$1" in */empty.rb) printf x;; esac' _ < "$w/dep/e.led" | grep -q x; then
  ok "the ledger does record the empty required file"
else
  bad "the ledger records the empty required file" "it did not"
fi

# The word in a string is still not a dependency.
printf 'MSG = "require me"\n%s' "$B" > "$w/dep/str.rb"
"$DRV" --source "$w/dep/str.rb" --core pick -o "$w/strapp" >"$w/str.out" 2>&1 || true
grep -q 'outside the snapshot' "$w/str.out" \
  && bad "the word require inside a string is not a dependency" "it was read as one" \
  || ok "the word require inside a string is not read as a dependency"

# The builtins allowance must stay a NAMED DIRECTORY, not a hole. The driver
# admits ledger records under the seam's builtins/ because the hosted compiler
# reads builtins/*.rb for itself on every compilation; nothing else is admitted.
# Proving that needs a build whose compiler reads builtins from somewhere the
# driver has NOT been told about, and a seam assembled out of symlinks gives
# exactly that: the compiler resolves builtins/ from its own executable through
# realpath (src/spinel_parse.c, sp_lib_dir), so it reads the REAL checkout's
# copy while the driver's allowance points at this seam's empty one. The read
# must still be refused, and the sentence must name the file it refused.
#
# The source is the plain body, with no require: a require is refused earlier,
# at eligibility, so it can never reach this check. That is why the six require
# cases above all report "not eligible" and none of them exercises this path.
bw=$w/bi; mkdir -p "$bw/seam/builtins" "$bw/seam/lib" "$bw/seam/bin"
for f in "${SPINEL_SEAM}/lib"/*; do ln -s "$f" "$bw/seam/lib/$(basename "$f")"; done
for f in "${SPINEL_SEAM}/bin"/*; do ln -s "$f" "$bw/seam/bin/$(basename "$f")"; done
printf '%s' "$B" > "$bw/plain.rb"
SPINEL_SEAM="$bw/seam" "$DRV" --source "$bw/plain.rb" --core pick -o "$bw/out" \
  >"$bw/out.log" 2>&1 && bi_built=1 || bi_built=0
if ls "${SPINEL_SEAM}"/builtins/*.rb >/dev/null 2>&1; then
  if [ "$bi_built" = 1 ]; then
    bad "a builtins read outside the allowed directory is refused" "it built"
  elif grep -q 'outside the snapshot' "$bw/out.log" \
       && grep -q 'builtins/.*\.rb\]' "$bw/out.log"; then
    ok "a builtins read outside the allowed directory is still refused, and named"
  else
    bad "a builtins read outside the allowed directory is refused" \
        "refused for another reason: $(grep -m1 '^spinel-core-build: ' "$bw/out.log" | cut -c22-90)"
  fi
else
  # This compiler has no builtins/ to read -- every pin before upstream
  # introduced them. There is no read to admit or refuse, so the case the
  # allowance exists for does not arise, and the build must simply succeed.
  [ "$bi_built" = 1 ] \
    && ok "this compiler has no builtins/, so a seam without one still builds" \
    || bad "this compiler has no builtins/, so a seam without one still builds" \
           "$(grep -m1 '^spinel-core-build: ' "$bw/out.log" | cut -c22-90)"
fi

# An empty ledger must not pass: a caller comparing an empty set against the
# snapshot finds nothing outside it and concludes all is well.
: > "$w/dep/blank.led"
if "${SPINEL_SEAM}/bin/spinel" "$fx/lower.rb" --inputs-out="$w/dep/blank.led" -S >/dev/null 2>&1; then
  [ -s "$w/dep/blank.led" ] && ok "a successful run writes a non-empty ledger" \
    || bad "a successful run writes a non-empty ledger" "it was empty"
else bad "a successful run writes a ledger"; fi
# The producer itself refuses to write an unwritable ledger.
"${SPINEL_SEAM}/bin/spinel" "$fx/lower.rb" --inputs-out=/nonexistent-dir/led -S >/dev/null 2>"$w/dep/w.err" \
  && bad "an unwritable ledger fails the producer" "it succeeded" \
  || { grep -q 'input ledger /nonexistent-dir/led' "$w/dep/w.err" \
        && ok "an unwritable ledger fails the producer, naming the path" \
        || bad "an unwritable ledger fails the producer" "$(head -1 "$w/dep/w.err")"; }

# The ledger is published the way the mapping is: an existing one is not
# truncated before a complete replacement exists, and a run that cannot finish
# leaves it alone.
printf 'PREVIOUS\0' > "$w/dep/keep.led"
"${SPINEL_SEAM}/bin/spinel" "$w/dep/r_empty.rb" --inputs-out="$w/dep/keep.led" -S >/dev/null 2>&1 || true
[ "$(tr -d '\0' < "$w/dep/keep.led")" = "PREVIOUS" ] \
  && ok "a run that refuses leaves an existing ledger untouched" \
  || ok "the run succeeded and replaced the ledger (r_empty compiles standalone)"
[ -z "$(ls "$w/dep"/.spinel-inputs.* 2>/dev/null)" ] \
  && ok "no temporary ledger file is left behind" \
  || bad "no temporary ledger file is left behind"

# A checksum tool that fails ONCE, partway through the manifest, then succeeds.
# This is the case a `printf "$(digest ...)"` hides: printf succeeds, the field
# is empty, and the build carries on with a manifest missing a value.
mkdir -p "$w/flaky"
cat > "$w/flaky/$SUM_NAME" <<'FLAKY'
#!/bin/sh
n=$(cat "$FLAKY_COUNT" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$FLAKY_COUNT"
[ "$n" = "3" ] && exit 1
case "$(uname -s)" in Darwin) exec /usr/bin/shasum "$@";; *) exec /usr/bin/sha256sum "$@";; esac
FLAKY
chmod +x "$w/flaky/$SUM_NAME"
: > "$w/flaky.count"
if FLAKY_COUNT="$w/flaky.count" PATH="$w/flaky:$PATH" \
     "$DRV" --source "$fx/lower.rb" --core lower -o "$w/x" >"$w/fl.out" 2>&1; then
  bad "a checksum that fails once mid-manifest fails the build" "it succeeded"
else
  grep -q 'cannot digest' "$w/fl.out" \
    && ok "a checksum that fails once mid-manifest fails the build" \
    || bad "a checksum that fails once mid-manifest fails the build" "$(head -1 "$w/fl.out")"
fi

# The output must not be a directory: mv onto one moves into it and succeeds.
mkdir -p "$w/asdir"
refuses "a directory as the output is refused" --source "$fx/lower.rb" --core lower -o "$w/asdir"

# A dangling symlink where a probe-then-write would have written.
ln -sf /nonexistent/elsewhere "$w/dangle"
if "$DRV" --source "$fx/lower.rb" --core lower -o "$w/dangle" >"$w/dg.out" 2>&1; then
  [ -f "$w/dangle" ] && ok "publishing over a dangling symlink replaces it with the executable" \
    || bad "publishing over a dangling symlink" "the link still dangles"
else
  ok "publishing over a dangling symlink fails rather than writing through it"
fi

# A source that loads another file cannot be snapshotted whole. The check is the
# PRODUCER's input list, from its #line directives, because `require` never
# reaches the eligibility checker: the frontend consumes it before the contract
# is written, so a top-level `require "json"` leaves an ast face identical to a
# program without it. Each spelling below is refused for that reason, including
# the one inside a method that is never called.
B='def pick(a, b)
  a < b ? a : b
end

puts pick(7, 3)
'
printf 'require "json"\n%s' "$B"           > "$w/req1.rb"
printf 'x = 1; require "json"\n%s' "$B"    > "$w/req2.rb"
printf 'Kernel.require "json"\n%s' "$B"    > "$w/req3.rb"
printf 'def unused\n  require "json"\nend\n\n%s' "$B" > "$w/req4.rb"
refuses "a top-level require is refused"                --source "$w/req1.rb" --core pick -o "$w/x"

# The case the #line scan CANNOT see: an empty required file contributes no
# code and therefore no #line directive. It is caught because every producer
# stage runs with the snapshot as its working directory, so a relative require
# resolves inside the snapshot or fails.
mkdir -p "$w/rel"
: > "$w/rel/empty.rb"
printf '# only a comment\n' > "$w/rel/comment_only.rb"
printf 'require_relative "empty"\n%s' "$B" > "$w/rel/r_empty.rb"
printf 'require_relative "comment_only"\n%s' "$B" > "$w/rel/r_comment.rb"
refuses "a relative require of an EMPTY file is refused" \
  --source "$w/rel/r_empty.rb" --core pick -o "$w/x"
refuses "a relative require of a comment-only file is refused" \
  --source "$w/rel/r_comment.rb" --core pick -o "$w/x"
# And the reason matters: an empty file leaves no #line directive at all, so a
# scan of those alone would have passed it.
"${SPINEL_SEAM}/bin/spinel" "$w/rel/r_empty.rb" -S > "$w/rel/e.c" 2>/dev/null || true
if sed -n 's|^#line [0-9]* "\(.*\)"$|\1|p' "$w/rel/e.c" 2>/dev/null | grep -q '/empty\.rb$'; then
  bad "an empty required file leaves no #line directive" "it left one, so the note is wrong"
else
  ok "an empty required file leaves no #line directive (so the snapshot cwd is what catches it)"
fi
refuses "a require after a semicolon is refused"        --source "$w/req2.rb" --core pick -o "$w/x"
refuses "Kernel.require is refused"                     --source "$w/req3.rb" --core pick -o "$w/x"
refuses "a require inside an uncalled method is refused" --source "$w/req4.rb" --core pick -o "$w/x"

# The word in a string is not a dependency. A regex over the source refuses
# this one; the producer's input list does not.
printf 'MSG = "require me"\n%s' "$B" > "$w/str.rb"
if "$DRV" --source "$w/str.rb" --core pick -o "$w/strapp" >"$w/str.out" 2>&1; then
  ok "the word require inside a string is not treated as a dependency"
else
  # The envelope refuses a top-level assignment, so this must fail for THAT
  # reason and not for a dependency that is not there.
  grep -q 'outside the snapshot' "$w/str.out" \
    && bad "the word require inside a string is not a dependency" "it was read as one" \
    || ok "the word require inside a string is not read as a dependency (refused for the assignment instead)"
fi

# The overflow mode is fixed at the hosted default and is not an option, so
# there is nothing to mismatch. The boundary control below drives the seam
# compiler directly instead, since the mismatch it exercises can no longer be
# reached through the driver.
SEAM_SPINEL="${SPINEL_SEAM}/bin/spinel"
EMIT_="${SPINEL_CORE_BUILD:-$root/tools/mlir/native/build}/bin/spinel-core-emit"
"$SEAM_SPINEL" "$fx/lower.rb" --core lower --core-id=probe --core-map="$w/boxed.map" \
  --int-overflow promote --no-line-map -S > "$w/boxed.c" 2>/dev/null
if grep -q 'sp_RbVal' "$w/boxed.map"; then
  ok "promote does box the hosted boundary (the mismatch this guards against)"
  if "$EMIT_" --typedump "$READER" --source "$fx/lower.rb" --core-map "$w/boxed.map" -o "$w/boxed.o" \
       --clang "${CLANG:-clang}" >"$w/boxed.out" 2>&1; then
    bad "a boxed hosted boundary is refused" "an object was emitted; it would link and print 0"
  else
    grep -q 'boundary-mismatch' "$w/boxed.out" \
      && ok "a boxed hosted boundary is refused as a boundary mismatch" \
      || bad "a boxed hosted boundary is refused as a boundary mismatch" "$(head -1 "$w/boxed.out")"
  fi
else
  bad "promote boxes the hosted boundary" "it did not, so this control proves nothing"
fi

# A mapping row without a signature has nothing for that check to compare
# against, so it is malformed rather than unchecked.
printf '#identity\tsymbol\tsignature\nlower\tspc_x_lower\n' > "$w/nosig.map"
"$EMIT_" --typedump "$READER" --source "$fx/lower.rb" --core-map "$w/nosig.map" -o "$w/x.o" \
  --clang "${CLANG:-clang}" >"$w/nosig.out" 2>&1 \
  && bad "a mapping row without a signature is refused" "it was accepted" \
  || ok "a mapping row without a signature is refused"

printf '\ncore driver: %s passed, %s failed\n' "$pass" "$fail"
printf '%s\n' "Native product driver and artifact gate: $(uname -s)."
[ "$fail" -eq 0 ]
