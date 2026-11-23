#!/bin/sh
#
# tests/core-boundary/schema.sh — the version-1 contract file and its header.
#
#   BOUNDARY=<path to spinel-core-boundary> CC=<clang> tests/core-boundary/schema.sh
#
# Three things, in the order they can fail:
#
#   1. every `bad-*` fixture is refused, and refused for ITS OWN reason.  A
#      refusal with the wrong diagnostic is a failure here: it would pass again
#      the moment the real defect was fixed, and the fixture would then be
#      guarding nothing.
#   2. every `bad-*` fixture is ONE EDIT from an accepted contract.  A fixture
#      three edits away proves nothing about which edit the parser caught.
#   3. the generated header is a real C header: an independent consumer
#      compiles against it, with the declared signature, and a consumer built
#      for a different contract identity is refused.
#   4. the analysis runs on a snapshot this tool owns, and the digest in the
#      header is the digest of the bytes that were analysed.
#   5. a contract whose parameter names are C typedefs still generates a
#      header that compiles -- with the mutation that would break it.
#
# This exercises a parser and a header generator.  Neither executes a kernel;
# nothing here may be described as a working CORE boundary.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-boundary"
BOUNDARY="${BOUNDARY:-$ROOT/tools/mlir/native/build/bin/spinel-core-boundary}"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
FIX="$HERE/fixtures/schema"

die() { echo "schema: $*" >&2; exit 1; }
[ -x "$BOUNDARY" ] || die "no spinel-core-boundary at $BOUNDARY (build it first)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
[ -d "$FIX" ] || die "no fixtures at $FIX"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-schema.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0


# The digest tool differs by platform: Debian ships sha256sum, macOS ships
# shasum.  Neither is guaranteed on the other.
sha256_of() {
  case "$(uname -s)" in
    Darwin) /usr/bin/shasum -a 256 "$1" ;;
    *)      sha256sum "$1" ;;
  esac | awk '{ print $1 }'
}

# The defect each fixture carries.  Declared here rather than derived from the
# tool's output, so the table is a claim the tool must satisfy.
category_for() {
  case "$1" in
    bad-version)          echo unsupported-version ;;
    bad-no-magic)         echo missing-version ;;
    bad-empty)            echo missing-version ;;
    bad-root-unresolved)  echo unresolved-root ;;
    bad-entry-unresolved) echo unresolved-entry ;;
    bad-entry-missing)    echo missing-field ;;
    bad-entry-duplicate)  echo duplicate-field ;;
    bad-result-missing)   echo missing-field ;;
    bad-result-type)      echo bad-type ;;
    bad-scalar-type)      echo bad-type ;;
    bad-buffer-elem)      echo bad-type ;;
    bad-trailing-field)   echo bad-field ;;
    bad-count-missing)    echo bad-field ;;
    bad-unknown-field)    echo unknown-field ;;
    bad-param-missing)    echo parameter-arity ;;
    bad-param-duplicate)  echo duplicate-parameter ;;
    bad-mode-out)         echo unsupported-mode ;;
    bad-mode-unknown)     echo unsupported-mode ;;
    bad-count-unknown)    echo bad-count ;;
    bad-count-not-scalar) echo bad-count ;;
    bad-count-shared)     echo shared-count ;;
    bad-entry-conditional) echo unresolved-entry ;;
    bad-entry-heredoc)    echo unresolved-entry ;;
    bad-entry-in-module)  echo unresolved-entry ;;
    bad-entry-ambiguous)  echo ambiguous-entry ;;
    bad-param-optional)   echo parameter-form ;;
    bad-u64-unbound)      echo unbound-count ;;
    bad-name-keyword)     echo reserved-name ;;
    bad-name-result)      echo reserved-name ;;
    bad-root-multifile)   echo unanalysable-root ;;
    *)                    echo "" ;;
  esac
}

# Which accepted contract each refusal is an edit away from.
base_for() {
  case "$1" in
    bad-mode-*|bad-buffer-elem|bad-count-missing|bad-count-unknown|bad-count-shared|bad-count-not-scalar)
      echo "$FIX/ok-buffer.contract" ;;
    *)
      echo "$FIX/ok-minimal.contract" ;;
  esac
}

echo "== accepted contracts =="
n_ok=0
for f in "$FIX"/ok-*.contract; do
  [ -f "$f" ] || die "no ok-* fixtures found"
  n_ok=$((n_ok + 1))
  name=$(basename "$f" .contract)
  if id=$("$BOUNDARY" "$f" --root "$HERE" --identity 2>"$WORK/$name.err"); then
    echo "  pass $name -> $id"
    pass=$((pass + 1))
  else
    echo "  FAIL $name was refused:"; sed 's/^/      /' "$WORK/$name.err"
    fail=$((fail + 1))
  fi
done
[ "$n_ok" -gt 0 ] || die "no accepted fixtures discovered"

echo "== refusals, each for its own reason =="
n_bad=0
for f in "$FIX"/bad-*.contract; do
  [ -f "$f" ] || die "no bad-* fixtures found"
  n_bad=$((n_bad + 1))
  name=$(basename "$f" .contract)
  want=$(category_for "$name")
  [ -n "$want" ] || { echo "  FAIL $name has no declared category in this runner"; fail=$((fail + 1)); continue; }
  set +e
  "$BOUNDARY" "$f" --root "$HERE" > "$WORK/$name.out" 2> "$WORK/$name.err"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL $name was accepted; it must be refused"; fail=$((fail + 1)); continue
  fi
  if [ -s "$WORK/$name.out" ]; then
    echo "  FAIL $name was refused but still wrote a header"; fail=$((fail + 1)); continue
  fi
  if ! grep -q ": $want: " "$WORK/$name.err"; then
    echo "  FAIL $name refused for the wrong reason (wanted $want):"
    sed 's/^/      /' "$WORK/$name.err" | head -3
    fail=$((fail + 1)); continue
  fi
  echo "  pass $name ($want)"
  pass=$((pass + 1))
done
[ "$n_bad" -gt 0 ] || die "no refusal fixtures discovered"

# The version fixture needs a version this reader does not have. It said
# `core-contract 2` until c757505 made 2 a supported version, and from then
# on it was refused under version 2's rules instead, so the refusal above
# was answering for the wrong check. The control: the same contract at
# version 2 is read as version 2, not refused as an unsupported one.
echo "== version 2 is a version this reader has =="
sed 's/^core-contract 99$/core-contract 2/' "$FIX/bad-version.contract" > "$WORK/version-2.contract"
v2_edits=$(diff "$FIX/bad-version.contract" "$WORK/version-2.contract" | grep -c '^>' || true)
set +e
"$BOUNDARY" "$WORK/version-2.contract" --root "$HERE" > /dev/null 2> "$WORK/version-2.err"
set -e
if [ "$v2_edits" -ne 1 ]; then
  echo "  FAIL the version-2 copy changed $v2_edits line(s); it must change the version line only"
  fail=$((fail + 1))
elif grep -q ': unsupported-version: ' "$WORK/version-2.err"; then
  echo "  FAIL version 2 was refused as an unsupported version:"
  sed 's/^/      /' "$WORK/version-2.err" | head -3
  fail=$((fail + 1))
elif ! grep -q 'a version 2 ' "$WORK/version-2.err"; then
  echo "  FAIL the version-2 copy was not read under version 2's rules:"
  sed 's/^/      /' "$WORK/version-2.err" | head -3
  fail=$((fail + 1))
else
  echo "  pass the same contract at version 2 is read under version 2's rules"
  pass=$((pass + 1))
fi

echo "== each refusal is one edit from an accepted contract =="
for f in "$FIX"/bad-*.contract; do
  name=$(basename "$f" .contract)
  # bad-empty is the one deliberate exception: an empty file is not an edit of
  # anything, and it exists to check the file-level path rather than a field.
  [ "$name" = bad-empty ] && { echo "  pass $name (exempt: the empty file)"; pass=$((pass + 1)); continue; }
  b=$(base_for "$name")
  d=$(diff "$b" "$f" | grep -c '^[<>]' || true)
  if [ "$d" -le 2 ]; then
    echo "  pass $name ($d changed line(s) vs $(basename "$b"))"
    pass=$((pass + 1))
  else
    echo "  FAIL $name is $d changed lines from $(basename "$b"); a refusal fixture must be one edit"
    fail=$((fail + 1))
  fi
done

echo "== an independent C consumer compiles against the generated header =="
"$BOUNDARY" "$FIX/ok-buffer.contract" --root "$HERE" --header "$WORK/accumulate.h" \
  || die "could not generate the header"
ident=$("$BOUNDARY" "$FIX/ok-buffer.contract" --root "$HERE" --identity)
cat > "$WORK/consumer.c" <<CEOF
/* Written against the contract, not against the generated header: the point is
 * that a separately written signature agrees with the generated one. */
#include <stdint.h>
#include <string.h>
#include "accumulate.h"

int32_t spinel_core_accumulate(int32_t *dst, uint64_t n_dst,
                               const uint8_t *src, uint64_t n_src,
                               int64_t *result) {
  (void)dst; (void)n_dst; (void)src; (void)n_src; (void)result;
  return SPINEL_CORE_OK;
}

int main(void) {
  if (strcmp(SPINEL_CORE_ENTRY_ACCUMULATE_IDENTITY, "$ident") != 0) return 1;
  if (SPINEL_CORE_CONTRACT_VERSION != 1) return 2;
  return 0;
}
CEOF
if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$WORK/consumer.c" -o "$WORK/consumer" 2>"$WORK/consumer.log"; then
  if "$WORK/consumer"; then
    echo "  pass an independent consumer compiles and its identity matches"
    pass=$((pass + 1))
  else
    echo "  FAIL the consumer built but its identity check failed"; fail=$((fail + 1))
  fi
else
  echo "  FAIL the consumer did not compile:"; sed 's/^/      /' "$WORK/consumer.log" | head -8
  fail=$((fail + 1))
fi

echo "== a consumer built for a different contract is refused =="
# Same entry name, different signature, and the second contract must itself be
# VALID -- otherwise this would test the parser again rather than the header.
# Widening dst's element type from i32 to i64 does that: still a legal
# contract, different C signature.
sed 's/^param dst buffer i32 inout count n_dst$/param dst buffer i64 inout count n_dst/' \
  "$FIX/ok-buffer.contract" > "$WORK/other.contract"
if "$BOUNDARY" "$WORK/other.contract" --root "$HERE" --header "$WORK/other.h" 2>/dev/null; then
  sed 's/#include "accumulate.h"/#include "other.h"/' "$WORK/consumer.c" > "$WORK/consumer2.c"
  if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$WORK/consumer2.c" -o "$WORK/consumer2" 2>"$WORK/consumer2.log"; then
    echo "  FAIL a consumer for the old signature compiled against the new header"
    fail=$((fail + 1))
  else
    echo "  pass the mismatched signature is refused at compile time"
    pass=$((pass + 1))
  fi
else
  echo "  FAIL could not generate the second header"; fail=$((fail + 1))
fi

echo "== two generated headers in one translation unit =="
# Each header has its own include guard, but they share the status enum.  An
# enum defined twice in one TU is a redefinition error, so the shared part needs
# a guard of its own -- and a single-header test cannot see that.
"$BOUNDARY" "$FIX/ok-minimal.contract" --root "$HERE" --header "$WORK/twice.h" \
  || die "could not generate the second entry's header"
cat > "$WORK/two.c" <<'CEOF'
#include <stdint.h>
#include "accumulate.h"
#include "twice.h"

int32_t spinel_core_accumulate(int32_t *dst, uint64_t n_dst,
                               const uint8_t *src, uint64_t n_src,
                               int64_t *result) {
  (void)dst; (void)n_dst; (void)src; (void)n_src; (void)result;
  return SPINEL_CORE_OK;
}
int32_t spinel_core_twice(int64_t v, int64_t *result) {
  *result = v + v;
  return SPINEL_CORE_OK;
}
int main(void) {
  int64_t r = 0;
  if (spinel_core_twice(21, &r) != SPINEL_CORE_OK) return 1;
  return r == 42 ? 0 : 2;
}
CEOF
if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$WORK/two.c" -o "$WORK/two" 2>"$WORK/two.log"; then
  if "$WORK/two"; then
    echo "  pass two entries' headers coexist in one translation unit"
    pass=$((pass + 1))
  else
    echo "  FAIL the two-header program built but returned non-zero"; fail=$((fail + 1))
  fi
else
  echo "  FAIL two headers in one translation unit did not compile:"
  sed 's/^/      /' "$WORK/two.log" | head -8
  fail=$((fail + 1))
fi

echo "== the analysis runs on a snapshot this tool owns =="
# bad-root-multifile requires a sibling that exists beside the ORIGINAL.  The
# reader is handed the snapshot instead, where that sibling is not, so it
# fails -- and its diagnostic names the path it was actually given.  That path
# is the discriminator: if the tool had analysed the declared path, the
# reader's own message would say so.
[ -f "$FIX/src/sibling.rb" ] || die "the multi-file fixture is missing its sibling"
set +e
"$BOUNDARY" "$FIX/bad-root-multifile.contract" --root "$HERE" >"$WORK/multi.out" 2>"$WORK/multi.err"
rc=$?
set -e
reader_said=$(grep '^spinel: ' "$WORK/multi.err" || true)
if [ "$rc" -eq 0 ]; then
  echo "  FAIL a root that loads a second file was accepted"; fail=$((fail + 1))
elif [ -z "$reader_said" ]; then
  echo "  FAIL the reader produced no diagnostic naming the file it was given:"
  sed 's/^/      /' "$WORK/multi.err" | head -4
  fail=$((fail + 1))
elif echo "$reader_said" | grep -q 'fixtures/schema/src'; then
  echo "  FAIL the reader was given the declared path, not a snapshot: $reader_said"
  fail=$((fail + 1))
elif ! echo "$reader_said" | grep -q 'requires_sibling\.rb'; then
  echo "  FAIL the reader's diagnostic does not name the source at all: $reader_said"
  fail=$((fail + 1))
else
  echo "  pass the reader was given a copy, not the declared path"
  pass=$((pass + 1))
fi

# The snapshot directory must not survive the run -- on the accepting path or
# the refusing one.  A leftover copy of the source is both a leak and a second
# path someone could later mistake for the thing that was analysed.  Scoped to
# a temporary directory of this check's own, so it observes only these two
# runs rather than whatever else is in the system temporary directory.
mkdir "$WORK/tmpscope"
TMPDIR="$WORK/tmpscope" "$BOUNDARY" "$FIX/ok-minimal.contract" --root "$HERE" \
  >/dev/null 2>&1 || die "ok-minimal was refused under a scoped TMPDIR"
set +e
TMPDIR="$WORK/tmpscope" "$BOUNDARY" "$FIX/bad-root-multifile.contract" --root "$HERE" \
  >/dev/null 2>&1
set -e
leaked=$(find "$WORK/tmpscope" -maxdepth 1 -name 'spinel-core-boundary-*' | head -5)
if [ -n "$leaked" ]; then
  echo "  FAIL the snapshot directory was left behind:"; echo "$leaked" | sed 's/^/      /'
  fail=$((fail + 1))
else
  echo "  pass no snapshot directory survives an accepted or a refused run"
  pass=$((pass + 1))
fi

echo "== the header's digest is the digest of the analysed source =="
# Cross-checked between two contracts: each header must carry the digest of
# ITS OWN root and not the other's, so a digest wired to a constant or to the
# wrong file fails here rather than agreeing with itself.
for pair in "ok-minimal:src/scalar.rb" "ok-buffer:src/buffer.rb"; do
  name=${pair%%:*}; src=${pair#*:}
  "$BOUNDARY" "$FIX/$name.contract" --root "$HERE" --header "$WORK/$name.h" \
    || die "could not generate the header for $name"
  want=$(sha256_of "$FIX/$src")
  got=$(sed -n 's/.*_SNAPSHOT "\([0-9a-f]*\)".*/\1/p' "$WORK/$name.h")
  if [ -z "$got" ]; then
    echo "  FAIL $name emitted no snapshot digest"; fail=$((fail + 1)); continue
  fi
  if [ "$got" != "$want" ]; then
    echo "  FAIL $name carries $got; $src is $want"; fail=$((fail + 1)); continue
  fi
  echo "  pass $name carries the digest of $src"
  pass=$((pass + 1))
done
d_min=$(sed -n 's/.*_SNAPSHOT "\([0-9a-f]*\)".*/\1/p' "$WORK/ok-minimal.h")
d_buf=$(sed -n 's/.*_SNAPSHOT "\([0-9a-f]*\)".*/\1/p' "$WORK/ok-buffer.h")
if [ "$d_min" = "$d_buf" ]; then
  echo "  FAIL two contracts over different sources carry the same digest"
  fail=$((fail + 1))
else
  echo "  pass the two digests differ"
  pass=$((pass + 1))
fi

echo "== parameter names that are C typedefs =="
# Measured first: `int32_t f(const uint8_t *uint8_t, const uint8_t *b)` is not
# a warning, it is `unknown type name 'uint8_t'`.  A prototype parameter name
# is a declaration, so it shadows that typedef for the rest of the list.  The
# names that do this are the CONSUMER's typedefs, which a generator cannot
# enumerate -- so the generated prototype uses positional identifiers and puts
# the contract's names in comments.
"$BOUNDARY" "$FIX/ok-typedef-names.contract" --root "$HERE" --header "$WORK/blend.h" \
  || die "could not generate the typedef-name header"
cat > "$WORK/blend.c" <<'CEOF'
#include <stdint.h>
#include "blend.h"

/* Used AFTER the header: if the header had left a parameter name shadowing a
 * typedef, the damage would be inside the prototype, but these also confirm
 * the typedefs are the ones the header's own parameters are written in. */
static uint8_t bytes[4] = {1, 2, 3, 4};
static int64_t out_of_line;

int32_t spinel_core_blend(int32_t base, const uint8_t *src, uint64_t n,
                          int64_t bias, int64_t *result) {
  int64_t total = (int64_t)base + bias;
  uint64_t i;
  for (i = 0; i < n; ++i) total += src[i];
  *result = total;
  return SPINEL_CORE_OK;
}

int main(void) {
  int64_t r = 0;
  if (spinel_core_blend(10, bytes, 4, 100, &r) != SPINEL_CORE_OK) return 1;
  out_of_line = r;
  return out_of_line == 120 ? 0 : 2;
}
CEOF
if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$WORK/blend.c" -o "$WORK/blend" 2>"$WORK/blend.log"; then
  if "$WORK/blend"; then
    echo "  pass a contract named entirely after typedefs generates a usable header"
    pass=$((pass + 1))
  else
    echo "  FAIL the typedef-name program built but returned non-zero"; fail=$((fail + 1))
  fi
else
  echo "  FAIL the typedef-name header did not compile:"
  sed 's/^/      /' "$WORK/blend.log" | head -8
  fail=$((fail + 1))
fi

# The mutation: put the contract's names back where the positional ones are,
# one substitution per parameter, taken from the header's own comments so the
# mutation cannot drift from the fixture.  Nothing else changes.  If this
# still compiles, the check above is vacuous and proves nothing.
awk '{
  if (match($0, /sp_arg[0-9]+/)) {
    id = substr($0, RSTART, RLENGTH)
    if (match($0, /\/\* [A-Za-z_][A-Za-z0-9_]* /)) {
      nm = substr($0, RSTART + 3, RLENGTH - 4)
      sub(id, nm)
    }
  }
  print
}' "$WORK/blend.h" > "$WORK/blend_naive.h"
edits=$(diff "$WORK/blend.h" "$WORK/blend_naive.h" | grep -c '^>' || true)
if [ "$edits" -ne 4 ]; then
  echo "  FAIL the mutation changed $edits parameter line(s); the contract has 4"
  fail=$((fail + 1))
else
  sed 's/#include "blend.h"/#include "blend_naive.h"/' "$WORK/blend.c" > "$WORK/blend_naive.c"
  if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$WORK" "$WORK/blend_naive.c" \
       -o "$WORK/blend_naive" 2>"$WORK/blend_naive.log"; then
    echo "  FAIL the contract's own names compiled too; this check is vacuous"
    fail=$((fail + 1))
  else
    echo "  pass restoring the contract's names ($edits line(s)) breaks the header:"
    grep -m1 'error' "$WORK/blend_naive.log" | sed 's/^/      /'
    pass=$((pass + 1))
  fi
fi

echo "schema: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
