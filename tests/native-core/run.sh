#!/bin/sh
# Decision 0005 task 4: lower a checked closure into a core object, link it into
# the hosted program, and run it.
#
# What this establishes: the ordinary Ruby source in fixtures/ -- no
# freestanding_def, no RBS, no hand-written FFI, no inserted inference call --
# becomes an executable whose selected method is defined by an object the MLIR
# path produced, and the answer agrees with CRuby.
#
# What it does NOT establish: anything about a program outside this fixture
# set, and nothing about the hosted runtime being absent from the executable,
# which it is not and is not meant to be. Only the CORE object is
# runtime-independent, and that is checked here at the object.
#
# It runs on native Debian/ELF and on native macOS/Mach-O, and establishes the
# same thing on both. It used to say it established nothing about macOS, and
# that was true of the file rather than of the platform: it linked -lcrypt
# unconditionally and compared a Mach-O symbol against an unprefixed name, so
# eleven of its checks failed for two reasons that have nothing to do with the
# core object. Both differences are now named once, above the checks, the way
# tools/core/spinel-core-build and tools/core/core-artifact-gate name them.
# Recorded on macOS arm64 with clang 23.1.1 and ruby 3.4.1: 18 passed, 0
# failed. Cross compilation is not supported.
#
# The hosted half uses the pinned compiler; SPINEL_SEAM can override it.
#
# usage: SPINEL_SEAM=<checkout> tests/native-core/run.sh
#   SPINEL_CORE_BUILD  build directory holding bin/spinel-core-emit
#   CLANG              the clang that build was configured with
#   CC                 C compiler for the final link (default: cc)
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
fx="$here/fixtures"
CC_="${CC:-cc}"
# The C is generated for one overflow mode and compiled for the same one, from
# one variable. This suite used to generate with the hosted default and compile
# with "$OV_DEFINE" -- generated for one program and compiled
# as another, the same defect the driver was corrected for. `raise` is the
# hosted default and what tools/core/spinel-core-build fixes.
OVERFLOW=raise
OV_DEFINE=-DSP_INT_OVERFLOW_MODE_RAISE
BUILD="${SPINEL_CORE_BUILD:-$root/tools/mlir/native/build}"
SEAM="${SPINEL_SEAM:-$root/vendor/spinel}"

[ -n "$SEAM" ] || { echo "run.sh: set SPINEL_SEAM to a checkout of the --core seam branch" >&2; exit 2; }
SEAM=$(CDPATH= cd -- "$SEAM" && pwd)
SPINEL="$SEAM/bin/spinel"
EMIT="$BUILD/bin/spinel-core-emit"
# Passed explicitly rather than left to the emitter's own search, which walks up
# from its executable for tools/contract/build/spinel-typedump. A build
# directory outside the repository -- which BUILD_DIR exists to allow -- finds
# nothing, and every emission then fails for a reason that has nothing to do
# with what is being tested.
READER="${SPINEL_TYPEDUMP:-$root/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$EMIT"
source_stamp reader "$READER"
[ -x "$SPINEL" ] || { echo "run.sh: no $SPINEL; build the seam checkout" >&2; exit 2; }
[ -x "$EMIT" ]   || { echo "run.sh: no $EMIT; build spinel-core-emit" >&2; exit 2; }
"$SPINEL" --help 2>&1 | grep -q -- '--core' || \
  grep -q 'g_core_root_count' "$SEAM/src/main.c" 2>/dev/null || \
  { echo "run.sh: $SPINEL does not carry the --core seam" >&2; exit 2; }

# The clang the emitter was configured with; spinel-core-emit hands its IR to
# clang, and a clang from a different LLVM cannot read it.
if [ -z "${CLANG:-}" ] && [ -f "$BUILD/CMakeCache.txt" ]; then
  CLANG=$(sed -n 's|^CMAKE_C_COMPILER:[A-Z]*=\(.*\)$|\1|p' "$BUILD/CMakeCache.txt" | head -1)
fi
[ -n "${CLANG:-}" ] && [ -x "$CLANG" ] || { echo "run.sh: set CLANG to the LLVM this build used" >&2; exit 2; }
command -v ruby >/dev/null 2>&1 || { echo "run.sh: no ruby for the oracle" >&2; exit 2; }

# Native ELF and Mach-O differ in two ways this suite touches, and in no other.
# Both are stated here rather than met as eleven failures: Debian links the
# hosted runtime against libcrypt and macOS has no such library, and Mach-O
# adds one ABI underscore to every C identifier. tools/core/spinel-core-build
# makes the first distinction and tools/core/core-artifact-gate the second;
# this file made neither, and on macOS every link failed and the one symbol
# comparison read `_spc_s_lower_lower` against `spc_s_lower_lower`.
case "$(uname -s)" in
  Darwin) CRYPT=; SYM_PREFIX=_ ;;
  Linux)  CRYPT=-lcrypt; SYM_PREFIX= ;;
  *) echo "run.sh: only native Linux and macOS are supported" >&2; exit 2 ;;
esac

# The external symbols an object defines, with the platform prefix taken off
# and nothing else changed. One underscore, not every underscore: the mapped
# names themselves contain them.
exported() {
  nm --defined-only --extern-only "$1" 2>/dev/null \
    | awk -v p="$SYM_PREFIX" '{ s = $NF
        if (p != "" && substr(s, 1, 1) == "_") s = substr(s, 2)
        print s }'
}

w=$(mktemp -d "${TMPDIR:-/tmp}/native-core.XXXXXX")
trap 'rm -rf "$w"' EXIT INT TERM
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

# build <fixture-stem> <snapshot-id> -> $w/<stem>.bin, or non-zero
# Every answer below is compared with CRuby's: an oracle, asked about once.
if "$root/tools/oracle/gate" tests/native-core/run.sh cruby-answers; then cruby=1; else cruby=0; fi

build_one() {
  _f=$1; _id=$2
  "$SPINEL" "$fx/$_f.rb" --core lower --core-id="$_id" \
      --int-overflow "$OVERFLOW" --core-map="$w/$_f.map" --no-line-map -S \
      > "$w/$_f.c" 2>"$w/$_f.hosted.err" || return 1
  "$EMIT" --typedump "$READER" --source "$fx/$_f.rb" --core-map "$w/$_f.map" -o "$w/$_f.o" \
      --clang "$CLANG" --emit-mlir "$w/$_f.mlir" > "$w/$_f.emit.out" 2>&1 || return 1
  $CC_ -O2 "$OV_DEFINE" -I"$SEAM/lib" "$w/$_f.c" "$w/$_f.o" \
      "$SEAM/lib/libspinel_rt.a" -lm $CRYPT -o "$w/$_f.bin" 2>"$w/$_f.link.err" || return 1
  return 0
}

for f in lower lower_reversed lower_equal lower_negative two_call_sites \
         lower_max lower_min_plus_one lower_span; do
  if build_one "$f" "s_$f"; then
    if [ "$cruby" = 1 ]; then
      got=$("$w/$f.bin" 2>&1); want=$(ruby "$fx/$f.rb" 2>&1)
      [ "$got" = "$want" ] && ok "$f: the core-backed executable agrees with CRuby ($got)" \
        || bad "$f: agrees with CRuby" "core=[$got] cruby=[$want]"
    fi
  else
    bad "$f builds end to end" \
      "$(cat "$w/$f.hosted.err" "$w/$f.emit.out" "$w/$f.link.err" 2>/dev/null | head -3 | tr '\n' ' ')"
  fi
done

# The minimum host integer, as a LITERAL operand. It used to be reserved: the
# hosted runtime used INTPTR_MIN as the nil of an Integer slot, and a literal at
# it made the closure bigint. Upstream a07741ff1 moved nil out of band and
# decision 0015 made INT64_MIN an ordinary value, so the admitted domain is the
# whole host range and this builds like the boundary cases above. The expected
# output is written here rather than only compared with CRuby, so the value
# itself is checked.
if build_one lower_sentinel sent; then
  if [ "$cruby" = 1 ]; then
    got=$("$w/lower_sentinel.bin" 2>&1); want=$(ruby "$fx/lower_sentinel.rb" 2>&1)
    [ "$got" = "-9223372036854775808" ] && [ "$got" = "$want" ] \
      && ok "lower_sentinel: the minimum as a literal operand is admitted and prints it ($got)" \
      || bad "lower_sentinel: prints -9223372036854775808 and agrees with CRuby" "core=[$got] cruby=[$want]"
  fi
else
  bad "lower_sentinel builds end to end" \
    "$(cat "$w/lower_sentinel.hosted.err" "$w/lower_sentinel.emit.out" "$w/lower_sentinel.link.err" 2>/dev/null | head -3 | tr '\n' ' ')"
fi

# A helper closure: the root calls a helper, and BOTH are lowered into the one
# object. Its root is pick3, not lower, so it needs its own build line.
if "$SPINEL" "$fx/helper_closure.rb" --core pick3 --core-id=s_helper \
     --int-overflow "$OVERFLOW" --core-map="$w/hc.map" --no-line-map -S \
     > "$w/hc.c" 2>"$w/hc.err" \
   && "$EMIT" --typedump "$READER" --source "$fx/helper_closure.rb" --core-map "$w/hc.map" -o "$w/hc.o" \
        --clang "$CLANG" --emit-mlir "$w/hc.mlir" >>"$w/hc.err" 2>&1 \
   && $CC_ -O2 "$OV_DEFINE" -I"$SEAM/lib" "$w/hc.c" "$w/hc.o" \
        "$SEAM/lib/libspinel_rt.a" -lm $CRYPT -o "$w/hc.bin" 2>>"$w/hc.err"; then
  if [ "$cruby" = 1 ]; then
    got=$("$w/hc.bin" 2>&1); want=$(ruby "$fx/helper_closure.rb" 2>&1)
    [ "$got" = "$want" ] && ok "helper_closure: agrees with CRuby ($got)" \
      || bad "helper_closure agrees with CRuby" "core=[$got] cruby=[$want]"
  fi
  # The helper must be IN the object and not exported: it is part of the
  # closure, not part of the interface.
  hsym=$(awk -F'\t' 'NR==2{print $2}' "$w/hc.map")
  [ "$(exported "$w/hc.o")" = "$hsym" ] \
    && ok "helper_closure: only the root is exported, the helper is not" \
    || bad "helper_closure: only the root is exported" \
        "saw [$(exported "$w/hc.o" | tr '\n' ' ')]"
  [ "$(nm -u "$w/hc.o" | wc -l | tr -d ' ')" = "0" ] \
    && ok "helper_closure: the object has no undefined dependency" \
    || bad "helper_closure: no undefined dependency" "$(nm -u "$w/hc.o" | tr '\n' ' ')"
else
  bad "helper_closure builds end to end" "$(head -3 "$w/hc.err" | tr '\n' ' ')"
fi

# The core object's own boundary. Measured on the object, not on the executable:
# the executable is expected to contain the hosted runtime, and does.
sym=$(awk -F'\t' 'NR==2{print $2}' "$w/lower.map")
[ -n "$sym" ] && ok "the mapping names the symbol ($sym)" || bad "the mapping names the symbol"
ext=$(exported "$w/lower.o")
[ "$ext" = "$sym" ] \
  && ok "the core object exports exactly the mapped symbol" \
  || bad "the core object exports exactly the mapped symbol" "saw [$ext]"
[ "$(nm -u "$w/lower.o" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "the core object has no undefined dependency" \
  || bad "the core object has no undefined dependency" "$(nm -u "$w/lower.o" | tr '\n' ' ')"
grep -q "func.func @$sym" "$w/lower.mlir" \
  && ok "the lowered function carries the mapped name, not the Ruby one" \
  || bad "the lowered function carries the mapped name" "$(grep -m1 'func.func' "$w/lower.mlir")"

# Routing. A stub core must be what runs; if the hosted body were still there
# this would print the right answer and the whole thing would look correct.
printf 'typedef long I;\nI %s(I a, I b){ (void)a; (void)b; return 999; }\n' "$sym" > "$w/stub.c"
$CC_ -O2 -c "$w/stub.c" -o "$w/stub.o"
if $CC_ -O2 "$OV_DEFINE" -I"$SEAM/lib" "$w/lower.c" "$w/stub.o" \
     "$SEAM/lib/libspinel_rt.a" -lm $CRYPT -o "$w/stub.bin" 2>/dev/null; then
  [ "$("$w/stub.bin")" = "999" ] \
    && ok "a stub core object is what runs, so the call routes to the object" \
    || bad "the call routes to the core object" "got [$("$w/stub.bin")]; a hosted body may remain"
else bad "the stub-core control links"; fi

# The emitter refuses what the checker refuses, and says which. The input is
# a String literal, which allocates and which no decision plans to admit in
# core. (The arithmetic operators that used to be the input here are
# admitted, by decisions 0015 and 0042.)
printf 'def lower(a, b)\n  "ab"\n  a - b\nend\n\nputs lower(7, 3)\n' > "$w/arith.rb"
"$SPINEL" "$w/arith.rb" --core lower --core-id=x --core-map="$w/arith.map" \
  --int-overflow "$OVERFLOW" --no-line-map -S \
  > "$w/arith.c" 2>/dev/null || true
if [ -f "$w/arith.map" ] && "$EMIT" --typedump "$READER" --source "$w/arith.rb" --core-map "$w/arith.map" \
     -o "$w/arith.o" --clang "$CLANG" >"$w/arith.err" 2>&1; then
  bad "a String literal is refused by the emitter" "it emitted an object"
elif grep -q 'not-eligible: heap-operation: StringNode requires heap semantics' "$w/arith.err" 2>/dev/null \
     && [ ! -e "$w/arith.o" ]; then
  ok "a String literal is refused, as not eligible, and no object is written"
else
  bad "a String literal is refused, as not eligible, and no object is written" \
    "$(head -1 "$w/arith.err" 2>/dev/null | cut -c1-80)"
fi

printf '\nnative core: %s passed, %s failed\n' "$pass" "$fail"
printf '%s\n' "the executable contains the hosted runtime by design; only the core object is checked for independence"
[ "$fail" -eq 0 ]
