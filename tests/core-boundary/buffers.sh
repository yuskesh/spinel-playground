#!/bin/sh
#
# tests/core-boundary/buffers.sh — the descriptor, access and refusal cases for
# decision 0007 task 3, written BEFORE the buffer lowering exists.
#
#   BOUNDARY=<spinel-core-boundary> KERNEL=<spinel-core-kernel> \
#     tests/core-boundary/buffers.sh
#
# Four lanes:
#
#   1. the descriptor table is well formed and in bijection with the fixtures,
#      and every shape and status it names is one this file defines;
#   2. every kernel contract is accepted by the boundary tool, which is what
#      binds the table's entry names, buffer modes and count parameters to the
#      Ruby definitions;
#   3. the refusal fixtures are refused for their own declared reason;
#   4. execution. There is no buffer lowering yet, so no case can run; that
#      count is printed, not hidden, and REQUIRE_EXECUTION=1 turns an
#      unexecuted case into a failure. Task 3 sets it.
#
# Nothing here compiles or runs a buffer kernel. Until lane 4 executes, this
# file establishes what the answers must be, not that anything produces them.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-boundary"
FIX="$HERE/fixtures/buffers"
BOUNDARY="${BOUNDARY:-$ROOT/tools/mlir/native/build/bin/spinel-core-boundary}"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"

die() { echo "buffers: $*" >&2; exit 1; }
[ -f "$FIX/descriptors.tsv" ] || die "no descriptor table at $FIX/descriptors.tsv"
[ -x "$BOUNDARY" ] || die "no spinel-core-boundary at $BOUNDARY (build it first)"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build it first)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-buffers.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0

TAB=$(printf '\t')

# The closed sets this file understands. A table naming anything else is a
# failure here rather than a case that quietly does nothing: the shapes are how
# the CALL is built, and a shape with no construction behind it would be a case
# that never ran.
SHAPES="normal count-short count-high-word null-zero null-nonzero misaligned
size-overflow addr-overflow count-not-i64 alias-inout alias-overlap alias-in-in
result-null result-unaligned result-in-buffer"
STATUSES="ok argument arithmetic bounds capacity"

echo "== the descriptor table is well formed =="
rows=$(awk -F"$TAB" '!/^#/ && NF { print }' "$FIX/descriptors.tsv")
[ -n "$rows" ] || die "the descriptor table holds no cases"

# Counted by awk, which sees the fields. `read` does not: with IFS set to a
# tab it puts every extra column into the LAST variable, so a row with ten
# fields read as nine and passed.
n_rows=$(echo "$rows" | awk -F"$TAB" 'END { print NR }')
bad_fields=$(echo "$rows" | awk -F"$TAB" 'NF != 9 { n++ } END { print n + 0 }')
if [ "$bad_fields" -ne 0 ]; then
  echo "  FAIL $bad_fields row(s) do not have nine fields"
  fail=$((fail + 1))
else
  echo "  pass $n_rows case(s), nine fields each"
  pass=$((pass + 1))
fi

dupes=$(echo "$rows" | cut -f1 | sort | uniq -d)
if [ -n "$dupes" ]; then
  echo "  FAIL duplicate case id(s): $(echo "$dupes" | tr '\n' ' ')"
  fail=$((fail + 1))
else
  echo "  pass every case id is distinct"
  pass=$((pass + 1))
fi

unknown=$(echo "$rows" | cut -f3 | sort -u | while read -r s; do
  echo "$SHAPES" | tr ' \n' '\n\n' | grep -qx "$s" || echo "$s"
done)
if [ -n "$unknown" ]; then
  echo "  FAIL shape(s) this file cannot build: $(echo "$unknown" | tr '\n' ' ')"
  fail=$((fail + 1))
else
  echo "  pass every shape named is one this file defines"
  pass=$((pass + 1))
fi

unknown=$(echo "$rows" | cut -f7 | sort -u | while read -r s; do
  echo "$STATUSES" | tr ' ' '\n' | grep -qx "$s" || echo "$s"
done)
if [ -n "$unknown" ]; then
  echo "  FAIL status(es) outside the ABI: $(echo "$unknown" | tr '\n' ' ')"
  fail=$((fail + 1))
else
  echo "  pass every status named is one of the ABI's"
  pass=$((pass + 1))
fi

# Bijection with the fixtures: nothing on disk goes unexercised, and no case
# names a kernel that is not there.
on_disk=$(cd "$FIX/src" && ls *.rb | sed 's/\.rb$//' | sort)
named=$(echo "$rows" | cut -f2 | sort -u)
if [ "$on_disk" = "$named" ]; then
  echo "  pass the table names exactly the $(echo "$on_disk" | wc -l | tr -d ' ') kernel(s) in src/"
  pass=$((pass + 1))
else
  echo "  FAIL src/ holds [$(echo "$on_disk" | tr '\n' ' ')] and the table names [$(echo "$named" | tr '\n' ' ')]"
  fail=$((fail + 1))
fi

# Every kernel must be paired with a contract, and every contract with a kernel.
missing=""
for stem in $on_disk; do
  [ -f "$FIX/src/$stem.contract" ] || missing="$missing $stem"
done
extra=""
for f in "$FIX"/src/*.contract; do
  stem=$(basename "$f" .contract)
  [ -f "$FIX/src/$stem.rb" ] || extra="$extra $stem"
done
if [ -n "$missing" ] || [ -n "$extra" ]; then
  echo "  FAIL kernels without a contract:$missing; contracts without a kernel:$extra"
  fail=$((fail + 1))
else
  echo "  pass every kernel has its own contract and every contract its kernel"
  pass=$((pass + 1))
fi

echo "== every kernel contract is accepted, with the declared buffer shape =="
# This is what binds the table to the definitions: the boundary tool resolves
# the entry in the analysed AST, checks the parameter names and arity against
# it, and checks each buffer's count from both directions.
for f in "$FIX"/src/*.contract; do
  stem=$(basename "$f" .contract)
  if id=$("$BOUNDARY" "$f" --root "$FIX" --identity 2>"$WORK/$stem.err"); then
    echo "  pass $stem: $id"
    pass=$((pass + 1))
  else
    echo "  FAIL $stem was refused:"; sed 's/^/      /' "$WORK/$stem.err" | head -3
    fail=$((fail + 1))
  fi
done

# The control for that lane: a contract whose count parameter does not match
# the definition must be refused, or the lane above would pass whatever it said.
# BOTH the count parameter and the buffer's reference to it, so the contract
# stays internally consistent and the only thing wrong is that the definition
# has no such parameter. Renaming one alone breaks the contract's own
# count binding first and never reaches the definition at all -- measured.
sed -e 's/^param n_src scalar u64$/param n_other scalar u64/' \
    -e 's/count n_src$/count n_other/' \
  "$FIX/src/sum_u8.contract" > "$WORK/wrong-count.contract"
if "$BOUNDARY" "$WORK/wrong-count.contract" --root "$FIX" >/dev/null 2>"$WORK/wrong-count.err"; then
  echo "  FAIL a contract naming a count the definition does not have was accepted"
  fail=$((fail + 1))
elif grep -q ': parameter-name: ' "$WORK/wrong-count.err"; then
  # The DIAGNOSTIC, not just a non-zero exit: the edit renames the parameter,
  # so the refusal has to be about the name not matching the definition. A
  # check that accepted any refusal would pass on an unrelated defect and would
  # go on passing once this one was fixed.
  echo "  pass a mismatched count parameter is refused by name, so the lane above binds"
  pass=$((pass + 1))
else
  echo "  FAIL the mismatched count was refused for another reason:"
  sed 's/^/      /' "$WORK/wrong-count.err" | head -3
  fail=$((fail + 1))
fi

echo "== the refusal fixtures are refused for their own reason =="
# Each fixture declares the category it must eventually carry. Today every
# contract with a buffer parameter is stopped by the `unsupported-boundary`
# gate before the checker looks at the body, so these refusals are PRE-EMPTED:
# they happen, but for a reason that will disappear the moment task 3 lands.
#
# Counting that as a pass would be a check that quietly stops meaning anything.
# It is counted separately instead, printed, and turned into a failure by
# REQUIRE_EXECUTION -- the same treatment the execution lane gets, and for the
# same reason.
preempted=0
refuse_case() { # $1 fixture stem  $2 the category it must eventually carry
  set +e
  "$KERNEL" "$FIX/refuse/$1.contract" --root "$FIX" -o "$WORK/$1.o" \
    --clang "$CC_BIN" > "$WORK/$1.out" 2>&1
  _rc=$?
  set -e
  if [ "$_rc" -eq 0 ]; then
    echo "  FAIL $1 built; it must be refused"
    fail=$((fail + 1))
  elif grep -q ": $2: " "$WORK/$1.out"; then
    echo "  pass $1 is refused ($2)"
    pass=$((pass + 1))
  elif grep -q ': unsupported-boundary: ' "$WORK/$1.out"; then
    echo "  NOT RUN $1 is refused, but by the buffer gate rather than as $2"
    preempted=$((preempted + 1))
  else
    echo "  FAIL $1 refused for a third reason (wanted $2 or the buffer gate):"
    sed 's/^/      /' "$WORK/$1.out" | head -3
    fail=$((fail + 1))
  fi
}
# A store into a buffer the contract declares `in`. The mode is the whole
# promise the caller was given. `readonly-write` does not exist as a category
# yet; naming it here is what task 3 has to satisfy.
refuse_case readonly_write   readonly-write
# `[]` on something that is not a declared buffer parameter. Indexable Ruby
# objects are heap objects, and this one keeps its existing category.
refuse_case index_not_buffer heap-operation
# A buffer parameter names storage the caller lends for the call, and
# rebinding the name drops the borrow while the contract still says the
# argument is there. This is an OWNERSHIP rule and stands on its own: the
# count's bound is a separate matter, settled in the generator and exercised by
# grow_count / shrink_count above, where the assignment is admitted and only
# the BOUND is immutable.
refuse_case buffer_rebound   buffer-rebound
# The two ways a value is nil in this subset, and the pair to src/walk_links.rb.
# The producer's own `nullable_int` analysis answers about hosted Ruby, where
# `buf[i]` off the end is nil; the checked route replaced that nil with
# SPINEL_CORE_BOUNDS, so with facts supplied the derivation answers instead.
# These two are what makes that a narrowing rather than a hole: a value that is
# really nil here is still refused, and by the derivation.
# `implicit-nil` names the nil itself rather than what it makes conflicting
# downstream. It was `type-evidence` while the fixture's `if` was in statement
# position and the refusal came from the broader rule decision 0008 task 4
# narrowed; the fixture now puts the `if` in value position, which is where the
# nil actually is.
refuse_case nil_if_no_else   implicit-nil
refuse_case nil_while_value  type-evidence

echo "== execution =="
# Every case builds its kernel, is called from a generated C driver, and must
# land in exactly one bucket: the declared status, the declared result on
# success, and the declared `inout` content afterwards. The driver is generated
# from the CONTRACT's parameter order, so an arity or a mode is stated once and
# in the fixture.
n_cases=$n_rows
executed=0

for f in "$FIX"/src/*.contract; do
  stem=$(basename "$f" .contract)
  kdir="$WORK/k/$stem"
  mkdir -p "$kdir"
  set +e
  "$KERNEL" "$f" --root "$FIX" -o "$kdir/k.o" --header "$kdir/k.h" \
    --clang "$CC_BIN" > "$kdir/build.out" 2> "$kdir/build.err"
  echo $? > "$kdir/build.rc"
  set -e
done

# The driver. `shape` is how the CALL is built and nothing else; the contents
# and the scalars come in on the command line, so one driver per kernel serves
# every case over it.
build_driver() { # $1 kdir  $2 contract
  _params=$(awk '$1 == "param" { print $2, $3, $4, $5, $6, $7 }' "$2")
  _entry=$(awk '$1 == "entry" { print $2 }' "$2")
  {
    cat <<'HEAD'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "k.h"

/* Allocated to EXACTLY the content, so that a bounds sanitiser has something
 * to work with: a read one element past the count lands in a redzone rather
 * than in the middle of a 4096-byte array where nothing would notice. malloc
 * returns maximally aligned storage, which is what the `misaligned` shapes
 * offset from.
 *
 * The result gets sixteen bytes rather than eight, because `result-unaligned`
 * reads and writes eight bytes starting one past the base and those bytes have
 * to be inside the allocation -- the pointer is wrong for the KERNEL, which is
 * the point, and must still be legal for this program to touch. */
static unsigned char *slab0, *slab1, *rslab;

static int count_of(const char *list) {
  int n = 0;
  if (!list || strcmp(list, "-") == 0) return 0;
  for (const char *p = list; *p; ++p) {
    if (p == list || *p == ',') ++n;
  }
  return n;
}

static int fill(unsigned char *at, const char *list, int width) {
  int n = 0;
  if (!list || strcmp(list, "-") == 0) return 0;
  const char *p = list;
  while (*p) {
    char *end;
    long long v = strtoll(p, &end, 10);
    if (end == p) break;
    if (width == 1) at[n] = (unsigned char)v;
    else if (width == 2) ((uint16_t *)(void *)at)[n] = (uint16_t)v;
    else if (width == 4) ((uint32_t *)(void *)at)[n] = (uint32_t)v;
    else ((uint64_t *)(void *)at)[n] = (uint64_t)v;
    ++n;
    p = (*end == ',') ? end + 1 : end;
  }
  return n;
}
HEAD
    echo "int main(int argc, char **argv) {"
    echo "  if (argc < 4) return 99;"
    echo "  const char *shape = argv[1];"
    echo "  int cap_in = count_of(argv[2]), cap_io = count_of(argv[3]);"
    echo "  slab0 = malloc((size_t)(cap_in ? cap_in : 1) * IN_WIDTH + 8);"
    echo "  slab1 = malloc((size_t)(cap_io ? cap_io : 1) * IO_WIDTH + 8);"
    echo "  rslab = malloc(16);"
    echo "  if (!slab0 || !slab1 || !rslab) return 97;"
    echo "  memset(slab0, 0, (size_t)(cap_in ? cap_in : 1) * IN_WIDTH + 8);"
    echo "  memset(slab1, 0, (size_t)(cap_io ? cap_io : 1) * IO_WIDTH + 8);"
    echo "  memset(rslab, 0, 16);"
    echo "  int n_in = fill(slab0, argv[2], IN_WIDTH);"
    echo "  int n_io = fill(slab1, argv[3], IO_WIDTH);"
    echo "  (void)n_in; (void)n_io;"
  } > "$1/drv.c.head"
}

# Everything above is common; the per-kernel part is assembled in shell because
# only the contract knows the parameter order.
gen_driver() { # $1 kdir  $2 contract
  _entry=$(awk '$1 == "entry" { print $2 }' "$2")
  _result=$(awk '$1 == "result" { print $2 }' "$2")
  # buffers, in contract order: name element mode count
  _bufs=$(awk '$1 == "param" && $3 == "buffer" { print $2, $4, $5, $7 }' "$2")
  _in_width=1; _io_width=1
  _n_buf=0
  _in_slab=""; _io_slab=""
  while read -r bname belem bmode bcount; do
    [ -n "$bname" ] || continue
    _n_buf=$((_n_buf + 1))
    case "$belem" in u8|i8) _w=1 ;; u16|i16) _w=2 ;; i32|u32) _w=4 ;; i64) _w=8 ;; esac
    if [ "$bmode" = inout ]; then _io_width=$_w; else _in_width=$_w; fi
  done <<EOF
$_bufs
EOF
  build_driver "$1" "$2"
  sed -i.bak "s/IN_WIDTH/$_in_width/; s/IO_WIDTH/$_io_width/" "$1/drv.c.head"
  rm -f "$1/drv.c.head.bak"

  # pointers and counts per buffer, adjusted by shape
  {
    cat "$1/drv.c.head"
    _ioseen=0
    _inseen=0
    echo "  unsigned char *p[4]; unsigned long long c[4]; int nb = 0;"
    # One allocation PER BUFFER. Two buffers of the same mode used to share a
    # backing store, which made every pair of them overlap by construction --
    # so a kernel with two `inout` buffers could not be given disjoint ones at
    # all, and the aliasing shapes were testing the default layout rather than
    # themselves. Aliasing is now something a SHAPE does.
    while read -r bname belem bmode bcount; do
      [ -n "$bname" ] || continue
      if [ "$bmode" = inout ]; then
        _ioseen=$((_ioseen + 1))
        if [ "$_ioseen" -eq 1 ]; then
          echo "  p[nb] = slab1; c[nb] = (unsigned long long)n_io; nb++;"
        else
          echo "  p[nb] = malloc((size_t)(cap_io ? cap_io : 1) * IO_WIDTH + 8);"
          echo "  if (!p[nb]) return 97;"
          echo "  memset(p[nb], 0, (size_t)(cap_io ? cap_io : 1) * IO_WIDTH + 8);"
          echo "  fill(p[nb], argv[3], IO_WIDTH);"
          echo "  c[nb] = (unsigned long long)n_io; nb++;"
        fi
      else
        _inseen=$((_inseen + 1))
        if [ "$_inseen" -eq 1 ]; then
          echo "  p[nb] = slab0; c[nb] = (unsigned long long)n_in; nb++;"
        else
          echo "  p[nb] = malloc((size_t)(cap_in ? cap_in : 1) * IN_WIDTH + 8);"
          echo "  if (!p[nb]) return 97;"
          echo "  memset(p[nb], 0, (size_t)(cap_in ? cap_in : 1) * IN_WIDTH + 8);"
          echo "  fill(p[nb], argv[2], IN_WIDTH);"
          echo "  c[nb] = (unsigned long long)n_in; nb++;"
        fi
      fi
    done <<EOF
$_bufs
EOF
    cat <<'SHAPES'
  int64_t *res = (int64_t *)(void *)rslab;
  /* The storage holds one element MORE than the count, so an access one past
   * the count lands on a guard the test can read afterwards rather than on
   * memory nothing is looking at. */
  if (strcmp(shape, "count-short") == 0)    { if (c[0] > 0) c[0] = c[0] - 1; }
  /* A count of 2^32, whose low 32 bits are zero. Truncating it would read as
   * an empty buffer; not truncating it returns 4294967296, and the kernel that
   * uses this shape returns the count without touching the storage -- the only
   * way to tell the two apart without owning four gibibytes.
   *
   * The base is placed well ABOVE the result so that a range this large is
   * still disjoint from it. Synthetic, never dereferenced, and not claimed to
   * be an allocation. */
  else if (strcmp(shape, "count-high-word") == 0) {
    uintptr_t far = (uintptr_t)(void *)rslab + ((uintptr_t)1 << 33);
    p[0] = (unsigned char *)far; c[0] = 0x100000000ULL;
  }
  else if (strcmp(shape, "null-zero") == 0) { p[0] = 0; c[0] = 0; }
  else if (strcmp(shape, "null-nonzero") == 0) { p[0] = 0; c[0] = 4; }
  else if (strcmp(shape, "misaligned") == 0) { p[0] = p[0] + 1; }
  else if (strcmp(shape, "size-overflow") == 0) { c[0] = 0x4000000000000000ULL; }
  /* A base near the top of the address space with a SMALL count, so that
   * base + size is the only thing wrong: non-NULL, aligned for any element
   * type, and a range that cannot contain the result because it has wrapped.
   * Passing a real pointer with a huge count instead was refused on the result
   * overlap, and the wrap was never reached. Nothing dereferences it: entry
   * validation refuses before the body runs. */
  /* Synthetic addresses, built by arithmetic on uintptr_t and cast back. They
   * are NEVER dereferenced -- entry validation refuses before the body runs --
   * and nothing here claims they are real allocations. Computing them as
   * `array + big` would have been arithmetic past the end of a real object. */
  else if (strcmp(shape, "addr-overflow") == 0) {
    uintptr_t top = (uintptr_t)0 - (uintptr_t)16;
    p[0] = (unsigned char *)top; c[0] = 32;
  }
  /* A count with no i64 value, and valid in every other respect: non-NULL,
   * aligned, no size overflow for a one-byte element, and a range that does
   * not wrap. The base is placed ABOVE the result so that a range spanning
   * half the address space still does not contain it -- otherwise the result
   * overlap refuses this first and the entry-scalar check is never reached. */
  else if (strcmp(shape, "count-not-i64") == 0) {
    uintptr_t above = (uintptr_t)(void *)rslab + (uintptr_t)4096;
    p[0] = (unsigned char *)above; c[0] = 0x8000000000000000ULL;
  }
  else if (strcmp(shape, "alias-inout") == 0) { p[1] = p[0]; c[1] = c[0]; }
  /* A PARTIAL overlap, not the same storage: the ranges intersect without
   * either containing the other, which `alias-inout` above does not test. */
  else if (strcmp(shape, "alias-overlap") == 0) { p[1] = p[0] + 1; c[1] = c[0]; }
  else if (strcmp(shape, "alias-in-in") == 0)  { p[1] = p[0]; c[1] = c[0]; }
  else if (strcmp(shape, "result-null") == 0)  { res = 0; }
  else if (strcmp(shape, "result-unaligned") == 0) { res = (int64_t *)(void *)(rslab + 1); }
  else if (strcmp(shape, "result-in-buffer") == 0) { res = (int64_t *)(void *)p[0]; }
  else if (strcmp(shape, "normal") != 0) return 98;
  /* The result's value BEFORE the call, so "untouched" is a fact about the
   * caller's storage rather than something the shell infers from a dash.
   *
   * Written and read back with memcpy, never through the typed pointer. Two of
   * these shapes hand the kernel a result pointer that is deliberately wrong
   * -- `result-unaligned` is misaligned and `result-null` is NULL -- and a
   * typed store through either is undefined in THIS PROGRAM, before the kernel
   * is ever asked to refuse it. memcpy has no alignment requirement; the NULL
   * case is simply not written. */
  const int64_t before = -987654321;
  if (res) memcpy((void *)res, &before, sizeof before);

  /* The baseline for the `inout` buffer, taken HERE: immediately before the
   * call and after everything else has been set up. `result-in-buffer` makes
   * the result alias a buffer, so initialising one writes to the other, and a
   * baseline taken any earlier would describe storage the call never saw. */
  unsigned char *pre1 = malloc((size_t)(cap_io ? cap_io : 1) * IO_WIDTH + 8);
  if (!pre1) return 97;
  memcpy(pre1, slab1, (size_t)(cap_io ? cap_io : 1) * IO_WIDTH + 8);

  /* Isolation, computed rather than argued.
   *
   * A shape that means to exercise ONE descriptor refusal has to be valid in
   * every other respect, and the two shapes below build addresses this driver
   * can check for itself. `addr-overflow` was silently being refused on the
   * result overlap -- a range spanning half the address space contains
   * everything -- so the range is checked here to be one that cannot contain
   * the result, and the count to be one that does not also overflow its size. */
  const char *iso = "-";
  if (strcmp(shape, "addr-overflow") == 0 ||
      strcmp(shape, "count-not-i64") == 0 ||
      strcmp(shape, "count-high-word") == 0) {
    unsigned long long base = (unsigned long long)(uintptr_t)p[0];
    unsigned long long size = c[0] * (unsigned long long)IN_WIDTH;
    unsigned long long limit = base + size;
    unsigned long long r = (unsigned long long)(uintptr_t)res;
    const int wraps = limit < base;
    const int hits = r < limit && base < r + 8;
    const int sizeOverflows = IN_WIDTH > 1 && c[0] > ~0ULL / (unsigned long long)IN_WIDTH;
    const int nulls = base == 0;
    const int unaligned = IN_WIDTH > 1 && (base & (unsigned long long)(IN_WIDTH - 1));
    const int wantWrap = strcmp(shape, "addr-overflow") == 0;
    (void)0;
    iso = (!hits && !sizeOverflows && !nulls && !unaligned &&
           wraps == wantWrap) ? "iso" : "NOT-ISOLATED";
  }
SHAPES
    printf '  int32_t st = spinel_core_%s(' "$_entry"
    _first=1
    _bi=0
    awk '$1 == "param" { print $2, $3, $4, $5, $6, $7 }' "$2" | {
      _argi=4
      while read -r pname pkind rest; do
        [ "$_first" -eq 1 ] || printf ', '
        _first=0
        if [ "$pkind" = buffer ]; then
          case "$(echo "$rest" | awk '{print $1}')" in
            u8) printf '(%s uint8_t *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
            i8) printf '(%s int8_t *)(void *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
            u16) printf '(%s uint16_t *)(void *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
            i16) printf '(%s int16_t *)(void *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
            i32) printf '(%s int32_t *)(void *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
            u32) printf '(%s uint32_t *)(void *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
            i64) printf '(%s int64_t *)(void *)p[%d]' "$(echo "$rest" | awk '{print $2}' | sed 's/^in$/const/; s/^inout$//')" "$_bi" ;;
          esac
          _bi=$((_bi + 1))
        elif echo "$rest" | grep -q '^u64'; then
          # a count: which buffer's, by NAME
          _k=0; _found=-1
          while read -r bn be bm bc; do
            [ -n "$bn" ] || continue
            [ "$bc" = "$pname" ] && _found=$_k
            _k=$((_k + 1))
          done <<BEOF
$_bufs
BEOF
          printf 'c[%d]' "$_found"
        else
          printf 'strtoll(argv[%d], 0, 10)' "$_argi"
          _argi=$((_argi + 1))
        fi
      done
    }
    printf ', res);\n'
    cat <<'TAIL'
  printf("%d", (int)st);
  if (st == 0 && res) {
    int64_t got;
    memcpy(&got, (const void *)res, sizeof got);
    printf(" %lld", (long long)got);
  } else if (res) {
    printf(" %s",
           memcmp((const void *)res, &before, sizeof before) == 0 ? "untouched"
                                                                  : "TOUCHED");
  } else {
    printf(" -");
  }
  printf(" ");
  if (n_io == 0) printf("-");
  else for (int i = 0; i < n_io; ++i)
    printf("%s%llu", i ? "," : "",
           IO_WIDTH == 1 ? (unsigned long long)slab1[i]
           : IO_WIDTH == 2 ? (unsigned long long)((uint16_t *)(void *)slab1)[i]
           : IO_WIDTH == 4 ? (unsigned long long)((uint32_t *)(void *)slab1)[i]
           : (unsigned long long)((uint64_t *)(void *)slab1)[i]);
  printf(" %s", iso);
  /* The pre-call content, so that "untouched" is compared against what the
   * call actually started from rather than against the table's own input
   * column. They differ exactly when something wrote to the buffer during
   * setup, which is the case worth catching. */
  printf(" ");
  if (n_io == 0) printf("-");
  else for (int i = 0; i < n_io; ++i)
    printf("%s%llu", i ? "," : "",
           IO_WIDTH == 1 ? (unsigned long long)pre1[i]
           : IO_WIDTH == 2 ? (unsigned long long)((uint16_t *)(void *)pre1)[i]
           : IO_WIDTH == 4 ? (unsigned long long)((uint32_t *)(void *)pre1)[i]
           : (unsigned long long)((uint64_t *)(void *)pre1)[i]);
  printf("\n");
  return 0;
}
TAIL
  } > "$1/drv.c"
  sed -i.bak "s/IO_WIDTH/$_io_width/g; s/IN_WIDTH/$_in_width/g" "$1/drv.c"; rm -f "$1/drv.c.bak"
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$1" "$1/drv.c" "$1/k.o" -o "$1/drv" 2>"$1/drv.log"
}

while IFS="$TAB" read -r id kernel shape inb inout args status result expect; do
  kdir="$WORK/k/$kernel"
  rc=$(cat "$kdir/build.rc")
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL $id: the kernel did not build:"
    sed 's/^/      /' "$kdir/build.err" | head -3
    fail=$((fail + 1)); continue
  fi
  if [ ! -x "$kdir/drv" ]; then
    if ! gen_driver "$kdir" "$FIX/src/$kernel.contract"; then
      echo "  FAIL $id: the driver did not compile:"
      sed 's/^/      /' "$kdir/drv.log" | head -6
      fail=$((fail + 1)); continue
    fi
  fi
  set +e
  out=$("$kdir/drv" "$shape" "$inb" "$inout" $(echo "$args" | tr ',' ' ' | sed 's/^-$//'))
  drc=$?
  set -e
  if [ "$drc" -ne 0 ]; then
    echo "  FAIL $id: the driver exited $drc"
    fail=$((fail + 1)); continue
  fi
  got_st=$(echo "$out" | cut -d' ' -f1)
  got_res=$(echo "$out" | cut -d' ' -f2)
  got_io=$(echo "$out" | cut -d' ' -f3)
  got_iso=$(echo "$out" | cut -d' ' -f4)
  got_pre=$(echo "$out" | cut -d' ' -f5)
  executed=$((executed + 1))

  # A shape claiming to isolate one refusal must be valid in every other
  # respect, and the driver measures that rather than the table asserting it.
  if [ "$got_iso" = "NOT-ISOLATED" ]; then
    echo "  FAIL $id: the $shape shape is not isolated; another descriptor rule"
    echo "       also refuses it, so this case does not test what it claims"
    fail=$((fail + 1)); continue
  fi
  case "$status" in
    ok) want_st=0 ;; argument) want_st=1 ;; arithmetic) want_st=2 ;;
    bounds) want_st=3 ;; capacity) want_st=4 ;;
    *) echo "  FAIL $id declares status '$status'"; fail=$((fail + 1)); continue ;;
  esac
  want_io=$expect
  # `untouched` means unchanged from what the call STARTED with, which the
  # driver reports, and not from the table's input column: the two differ when
  # something wrote to the buffer during setup.
  [ "$want_io" = untouched ] && want_io=$got_pre
  if [ "$got_st" != "$want_st" ]; then
    echo "  FAIL $id: expected $status ($want_st), got $got_st"
    fail=$((fail + 1))
  elif [ "$status" = ok ] && [ "$got_res" != "$result" ]; then
    echo "  FAIL $id: expected result $result, got $got_res"
    fail=$((fail + 1))
  elif [ "$status" != ok ] && [ "$got_res" = TOUCHED ]; then
    # Decision 0007: the scalar result is published only on success.
    echo "  FAIL $id: failed with status $got_st and still wrote the result"
    fail=$((fail + 1))
  elif [ "$want_io" != "-" ] && [ "$got_io" != "$want_io" ]; then
    echo "  FAIL $id: expected the inout buffer to be [$want_io], it is [$got_io]"
    fail=$((fail + 1))
  else
    if [ "$status" = ok ]; then
      echo "  pass $id = $got_res"
    else
      echo "  pass $id is $status, result $got_res, inout [$got_io]"
    fi
    pass=$((pass + 1))
  fi
done <<EOF
$rows
EOF

NM="${NM:-nm}"
command -v "$NM" >/dev/null 2>&1 || die "no nm at '$NM'"

echo "== sanitisers =="
# Decision 0007 task 3 asks for the available sanitiser runs and for any
# unavailable one to be recorded separately. Availability is PROBED -- built
# and run -- rather than assumed from the compiler's name: a toolchain can
# accept the flag and then fail to link the runtime, and a check that only
# compiled would report a pass for something that never ran.
#
# Both the kernel object and the driver are rebuilt, so the kernel's own
# accesses are instrumented and not just the harness's. The driver allocates
# each buffer to exactly its content, so a read one element past the count
# lands in a redzone.
# `unmeasured` counts sub-lanes that produced no evidence BECAUSE A TOOL WAS
# MISSING. It does not count the UndefinedBehaviorSanitizer note below, which
# is a documented impossibility rather than a gap a machine could close.
san_ran=0; san_skipped=""; unmeasured=0
for san in address undefined; do
  # The probe frees what it allocates, and runs under the SAME options the real
  # runs use. An earlier version leaked its allocation, LeakSanitizer failed
  # it, and address was recorded as unavailable on this machine -- a probe
  # failing for its own reason reads exactly like a missing toolchain.
  cat > "$WORK/sanprobe.c" <<'PEOF'
#include <stdlib.h>
int main(void) {
  volatile int *p = malloc(sizeof(int));
  if (!p) return 1;
  *p = 1;
  int v = *p;
  free((void *)p);
  return v - 1;
}
PEOF
  if ! "$CC_BIN" -fsanitize=$san -O1 "$WORK/sanprobe.c" -o "$WORK/sanprobe" \
       2>"$WORK/sanprobe.$san.log"; then
    san_skipped="$san_skipped $san(build: $(head -1 "$WORK/sanprobe.$san.log" | cut -c1-60))"
    continue
  fi
  if ! ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
       "$WORK/sanprobe" >"$WORK/sanprobe.$san.run" 2>&1; then
    san_skipped="$san_skipped $san(runtime: $(head -1 "$WORK/sanprobe.$san.run" | cut -c1-50))"
    continue
  fi

  bad=0; ran=0
  while IFS="$TAB" read -r id kernel shape inb inout args status result expect; do
    sdir="$WORK/san/$san/$kernel"
    if [ ! -x "$sdir/drv" ]; then
      mkdir -p "$sdir"
      if ! "$KERNEL" "$FIX/src/$kernel.contract" --root "$FIX" -o "$sdir/k.o" \
             --header "$sdir/k.h" --clang "$CC_BIN" -- -fsanitize=$san \
             > "$sdir/build.out" 2>&1; then
        echo "  FAIL $san: the $kernel kernel did not build instrumented:"
        sed 's/^/      /' "$sdir/build.out" | head -3
        fail=$((fail + 1)); bad=$((bad + 1)); continue
      fi
      cp "$WORK/k/$kernel/drv.c" "$sdir/drv.c"
      if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -fsanitize=$san -O1 \
             -I"$sdir" "$sdir/drv.c" "$sdir/k.o" -o "$sdir/drv" 2>"$sdir/drv.log"; then
        echo "  FAIL $san: the $kernel driver did not build instrumented:"
        sed 's/^/      /' "$sdir/drv.log" | head -4
        fail=$((fail + 1)); bad=$((bad + 1)); continue
      fi
    fi
    set +e
    out=$(ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
          "$sdir/drv" "$shape" "$inb" "$inout" \
          $(echo "$args" | tr ',' ' ' | sed 's/^-$//') 2>"$sdir/$id.err")
    drc=$?
    set -e
    ran=$((ran + 1))
    if [ "$drc" -ne 0 ] || [ -s "$sdir/$id.err" ]; then
      echo "  FAIL $san reported on $id (exit $drc):"
      sed 's/^/      /' "$sdir/$id.err" | head -4
      fail=$((fail + 1)); bad=$((bad + 1)); continue
    fi
    got=$(echo "$out" | cut -d' ' -f1)
    case "$status" in
      ok) w=0 ;; argument) w=1 ;; arithmetic) w=2 ;; bounds) w=3 ;; capacity) w=4 ;;
    esac
    if [ "$got" != "$w" ]; then
      echo "  FAIL $san: $id answered $got instrumented and $w plain"
      fail=$((fail + 1)); bad=$((bad + 1))
    fi
  done <<SEOF
$rows
SEOF
  # "No diagnostic" is also what a sanitiser that is not watching reports, so
  # each one has to be shown catching something. Two levels of that, and they
  # establish different things.
  #
  # First, the RUNTIME: a program with the defect this sanitiser exists to find
  # must be reported, by its own diagnostic text and not merely by a non-zero
  # exit. Each sanitiser gets a defect it actually checks -- an out-of-bounds
  # read is address's, a signed overflow is undefined's -- because one control
  # shared between them would establish nothing about the other.
  case "$san" in
    address)
      cat > "$WORK/sancheck.$san.c" <<'PEOF'
#include <stdlib.h>
int main(void) {
  unsigned char *p = malloc(4);
  if (!p) return 1;
  p[0] = 1;
  volatile unsigned char v = p[4];   /* one past the end */
  int out = (int)v;
  free(p);
  return out;
}
PEOF
      want_report='AddressSanitizer'
      ;;
    undefined)
      cat > "$WORK/sancheck.$san.c" <<'PEOF'
#include <limits.h>
int main(void) {
  volatile int x = INT_MAX;
  volatile int y = 1;
  return x + y;                      /* signed overflow */
}
PEOF
      want_report='runtime error'
      ;;
  esac
  if ! "$CC_BIN" -fsanitize=$san -O1 "$WORK/sancheck.$san.c" \
       -o "$WORK/sancheck.$san" 2>"$WORK/sancheck.$san.build"; then
    # A control that does not BUILD is a control that never ran. It used to be
    # skipped here -- the `if` had no `else` and the compiler's stderr went to
    # /dev/null -- so a sanitiser lane could pass with nothing behind it. It
    # did: the embedded C had a newline inside a string literal and had never
    # compiled once.
    echo "  FAIL $san: the runtime control did not build:"
    sed 's/^/      /' "$WORK/sancheck.$san.build" | head -4
    fail=$((fail + 1)); bad=$((bad + 1))
  else
    set +e
    ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
      "$WORK/sancheck.$san" >"$WORK/sancheck.$san.out" 2>&1
    crc=$?
    set -e
    if ! grep -q "$want_report" "$WORK/sancheck.$san.out"; then
      echo "  FAIL $san did not report its own defect (exit $crc, wanted \"$want_report\"):"
      sed 's/^/      /' "$WORK/sancheck.$san.out" | head -4
      fail=$((fail + 1)); bad=$((bad + 1))
    fi
  fi

  # Second, the KERNEL. `address` gets a functional control: a caller that
  # LIES about the count. Decision 0007 is explicit that a raw foreign
  # pointer's actual capacity cannot be established by the compiler, so entry
  # validation accepts a count of n over an allocation of n-1 and the kernel's
  # own in-bounds load then runs off the end. If that is reported, the
  # kernel's loads are instrumented -- which grepping the object for an
  # `__asan_` reference does not show, since an initialisation constructor
  # carries one too.
  #
  # This case exists ONLY here: outside a sanitiser it is undefined behaviour
  # and is not in the descriptor table.
  if [ "$san" = address ]; then
    sdir="$WORK/san/$san/sum_u8"
    if [ ! -x "$sdir/drv" ]; then
      echo "  FAIL $san: no instrumented sum_u8 driver to check the kernel with"
      fail=$((fail + 1)); bad=$((bad + 1))
    else
      cat > "$WORK/liar.c" <<'PEOF'
#include <stdlib.h>
#include <string.h>
#include "k.h"
int main(void) {
  unsigned char *p = malloc(3);        /* three elements ... */
  if (!p) return 1;
  memset(p, 1, 3);
  int64_t r = 0;
  int32_t st = spinel_core_sum_u8(p, 4, &r);   /* ... and a count of four */
  free(p);
  return (int)st;
}
PEOF
      if ! "$CC_BIN" -std=c11 -fsanitize=address -O1 -I"$sdir" "$WORK/liar.c" \
             "$sdir/k.o" -o "$WORK/liar" 2>"$WORK/liar.build"; then
        echo "  FAIL $san: the kernel-instrumentation control did not build:"
        sed 's/^/      /' "$WORK/liar.build" | head -4
        fail=$((fail + 1)); bad=$((bad + 1))
      else
        set +e
        ASAN_OPTIONS=detect_leaks=0 "$WORK/liar" >"$WORK/liar.out" 2>&1
        set -e
        if grep -q 'heap-buffer-overflow' "$WORK/liar.out"; then
          echo "  pass $san sees the KERNEL's own loads (a caller that lies"
          echo "       about the count is caught inside spinel_core_sum_u8)"
          pass=$((pass + 1))
        else
          echo "  FAIL $san did not report the kernel reading past a short"
          echo "       allocation, so its silence on the cases means nothing:"
          sed 's/^/      /' "$WORK/liar.out" | head -4
          fail=$((fail + 1)); bad=$((bad + 1))
        fi
      fi
    fi
  else
    # Stated rather than left implied. UndefinedBehaviorSanitizer's checks are
    # emitted by the FRONTEND while it compiles C; there is no function
    # attribute that makes a pass add them to pre-existing IR, which is what
    # this object is. So `address` reaching the kernel does not mean
    # `undefined` does, and no control here establishes that it does. What is
    # established is that its runtime reports, and that the harness around the
    # kernel is watched.
    echo "  NOT SHOWN $san: its checks are emitted while compiling C, and this"
    echo "            object is already IR -- nothing here watches the kernel"
    echo "            itself. The runtime and the harness are covered."
    echo "            This is a property of the sanitiser, not of this machine:"
    echo "            no toolchain closes it, so REQUIRE_ALL does not fail on it."
  fi

  if [ "$bad" -eq 0 ]; then
    echo "  pass $san: $ran case(s), same statuses and no diagnostic"
    pass=$((pass + 1)); san_ran=$((san_ran + 1))
  fi
done
if [ -n "$san_skipped" ]; then
  # Recorded on its own line rather than folded into a pass: an unavailable
  # sanitiser is a gap in the evidence, not a check that succeeded.
  echo "  NOT RUN sanitiser(s) unavailable:$san_skipped"
  unmeasured=$((unmeasured + 1))
fi
if [ "$san_ran" -eq 0 ]; then
  echo "  NOT RUN no sanitiser ran, so nothing here is sanitiser evidence"
  unmeasured=$((unmeasured + 1))
fi

echo "== the objects are free-standing at the production optimisation level =="
# Decision 0007 keeps version 1's undefined set empty, and warns that loop
# optimisations may introduce memset or memcpy. They do: measured, clear_u8's
# `while` became an undefined `memset` at the shared emitter's -O2, and this
# lane is what found it. The kernel tool now disables loop-idiom recognition
# for this compilation path -- and the decision is explicit that an option
# alone is not proof, which is why the object is read here.
cat > "$WORK/symprobe.c" <<'PEOF'
int spinel_core_symbol_probe(void) { return 0; }
PEOF
"$CC_BIN" -c "$WORK/symprobe.c" -o "$WORK/symprobe.o" 2>"$WORK/symprobe.log" \
  || die "cannot compile the symbol probe: $(head -2 "$WORK/symprobe.log")"
symbols() { # $1 object -> "<type> <name>" per line, non-zero if nm failed
  "$NM" "$1" > "$WORK/nm.out" 2> "$WORK/nm.err" || return 1
  [ -s "$WORK/nm.out" ] || return 2
  awk 'NF >= 2 { print $(NF-1), $NF }' "$WORK/nm.out"
}
probe=$(symbols "$WORK/symprobe.o") || die "nm could not read the probe: $(head -2 "$WORK/nm.err")"
probe_name=$(echo "$probe" | awk '$2 ~ /spinel_core_symbol_probe$/ { print $2; exit }')
[ -n "$probe_name" ] || die "nm did not report the probe symbol"
SYM_PREFIX=${probe_name%spinel_core_symbol_probe}

obj_bad=0; n_obj=0
for f in "$FIX"/src/*.contract; do
  stem=$(basename "$f" .contract)
  [ -f "$WORK/k/$stem/k.o" ] || continue
  n_obj=$((n_obj + 1))
  if ! table=$(symbols "$WORK/k/$stem/k.o"); then
    echo "  FAIL $stem: nm could not read the object: $(head -2 "$WORK/nm.err")"
    fail=$((fail + 1)); obj_bad=$((obj_bad + 1)); continue
  fi
  undef=$(echo "$table" | awk '$1 == "U" { print $2 }' | tr '\n' ' ')
  # Uppercase types only: a lowercase one is local to the object, which is what
  # a constant-pool entry is, and exporting nothing is not the same as defining
  # nothing.
  exported=$(echo "$table" | awk '$1 != "U" && $1 ~ /^[A-Z]$/ { print $2 }' | tr '\n' ' ')
  if [ -n "$undef" ]; then
    echo "  FAIL $stem: the object has undefined symbol(s): $undef"
    fail=$((fail + 1)); obj_bad=$((obj_bad + 1))
  elif [ "$exported" != "${SYM_PREFIX}spinel_core_$stem " ]; then
    echo "  FAIL $stem: the object exports [$exported], not [${SYM_PREFIX}spinel_core_$stem ]"
    fail=$((fail + 1)); obj_bad=$((obj_bad + 1))
  else
    pass=$((pass + 1))
  fi
done
if [ "$n_obj" -eq 0 ]; then
  echo "  FAIL no objects were inspected"; fail=$((fail + 1))
elif [ "$obj_bad" -ne 0 ]; then
  echo "  $((n_obj - obj_bad)) of $n_obj object(s) are clean; $obj_bad are not"
else
  echo "  pass all $n_obj object(s): no undefined symbols, one exported symbol each"
fi

if [ "$executed" -ne "$n_cases" ]; then
  echo "  FAIL only $executed of $n_cases case(s) reached a bucket"
  fail=$((fail + 1))
else
  echo "  pass all $n_cases case(s) landed in a declared bucket"
  pass=$((pass + 1))
fi
if [ "$preempted" -ne 0 ] && [ "${REQUIRE_EXECUTION:-0}" = 1 ]; then
  echo "  FAIL REQUIRE_EXECUTION=1 and $preempted refusal(s) are still pre-empted"
  fail=$((fail + 1))
fi

# REQUIRE_ALL asks for the evidence, not for a report saying where evidence is
# missing. A sanitiser this toolchain does not have is a gap run.sh cannot see,
# because the lane still prints a summary and exits 0. Measured: with the
# sanitiser probe forced to fail to build and REQUIRE_ALL=1 this lane came back
# "112 checked, 112 pass, 0 fail, 0 sanitiser(s) run" and exit 0, which run.sh
# printed as ok.
#
# The UndefinedBehaviorSanitizer note above is NOT counted here. Its checks are
# emitted while compiling C and this object is already IR; no machine closes
# that, so failing on it would make REQUIRE_ALL unsatisfiable rather than
# strict. The counts are not moved either: nothing here failed a check, and a
# count that changed with the environment would stop being comparable between
# machines. What changes is the exit status.
require_all_fail=0
if [ "${REQUIRE_ALL:-0}" = 1 ] && [ "$unmeasured" -ne 0 ]; then
  echo "  REQUIRE_ALL is set and $unmeasured sanitiser sub-lane(s) produced no evidence"
  echo "  for want of a tool. Each is named above. The counts below are unchanged:"
  echo "  this is a refusal of the run, not a failed check."
  require_all_fail=1
fi

echo "buffers: $((pass + fail)) checked, $pass pass, $fail fail," \
     "$executed/$n_cases executed, $preempted refusal(s) pre-empted," \
     "$san_ran sanitiser(s) run"
[ "$fail" -eq 0 ] || exit 1
[ "$require_all_fail" -eq 0 ] || exit 1
