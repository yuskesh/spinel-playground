#!/usr/bin/env bash
# E040's i64 boundaries on a 64-bit host -- e040_wide.rb, the two methods that
# left e040_kern.rb when a 32-bit target stopped accepting a 64-bit body
# (decision 0019, revised 2026-10-21). The device lanes do not build them.
#
#   bash run_wide.sh        # host.tsv in $RES
#
# The kernel is compiled for this host's profile and called from a C driver.
# The expected values are worked by hand, not taken from another
# implementation: 46341 * 46341 = 2147488281, which an :i64 return holds and an
# :i32 one does not; -100000 * 100000 = -10000000000; 3 * 5 = 15; and
# 2**62 * 4 = 2**64 overflows the i64 body itself, trap code 1.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) PROF=$FSDIR/profiles/x86_64-linux-host.yaml ;;
  Darwin-arm64) PROF=$HERE/../e079/arm64-host.yaml ;;
  *) echo "$LANE: run_wide.sh needs a 64-bit host profile for $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac
W=$OUT/wide
fs_fresh_workdir "$W"; mkdir -p "$W/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$W/spinel/"
cp "$HERE/e040_wide.rb" "$W/"
(cd "$W" && "$MLIRGEN" e040_wide.rb --freestanding --profile "$PROF" \
    -o wide.o --emit-header spinel_freestanding.h > build.log 2>&1) ||
  { cat "$W/build.log" >&2; echo "$LANE: e040_wide.rb did not build for the host" >&2; exit 1; }
cat > "$W/drv.c" <<'C'
#include <inttypes.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include "spinel_freestanding.h"
static jmp_buf back;
static int32_t trapped;
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
	(void)a; (void)b; (void)detail;
	trapped = code;
	longjmp(back, 1);
}
#define CASE(name, expr) do { \
	trapped = 0; \
	if (setjmp(back) == 0) printf("%s\t%" PRId64 "\n", name, (int64_t)(expr)); \
	else printf("%s\ttrap:%d\n", name, (int)trapped); \
} while (0)
int main(void)
{
	CASE("mulwide(46341,46341)", spinel_mulwide(46341, 46341));
	CASE("mulwide(-100000,100000)", spinel_mulwide(-100000, 100000));
	CASE("bigmul(3,5)", spinel_bigmul(3, 5));
	CASE("bigmul(4611686018427387904,4)", spinel_bigmul(INT64_C(4611686018427387904), 4));
	return 0;
}
C
"$CLANG" -O1 -I"$W" "$W/drv.c" "$W/wide.o" -o "$W/drv" > "$W/link.log" 2>&1 ||
  { cat "$W/link.log" >&2; echo "$LANE: the host driver did not link" >&2; exit 1; }
"$W/drv" > "$W/rows.tsv"
{
  printf 'case\twant\tgot\tverdict\n'
  while IFS="$(printf '\t')" read -r c want; do
    got=$(awk -F'\t' -v c="$c" '$1 == c { print $2 }' "$W/rows.tsv")
    [ "$got" = "$want" ] && v=PASS || v=FAIL
    printf '%s\t%s\t%s\t%s\n' "$c" "$want" "${got:-none}" "$v"
  done <<'T'
mulwide(46341,46341)	2147488281
mulwide(-100000,100000)	-10000000000
bigmul(3,5)	15
bigmul(4611686018427387904,4)	trap:1
T
} > "$RES/host.tsv"
cat "$RES/host.tsv"
! grep -q 'FAIL' "$RES/host.tsv"
