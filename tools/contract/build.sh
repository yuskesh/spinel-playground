#!/bin/sh
# Build tools/contract/spinel-typedump. [E041]
#
# EXTERNAL build: it does not touch vendor/spinel's Makefile and writes nothing
# inside vendor/. It links the objects the vendor build already produces
# (build/csrc/*.o minus main.o -- main.o has its own main(); sp_parse_lib.o, the
# Prism walk, already lives in that directory) plus libprism.a, exactly as
# spinel-ebpf's tools/stage2_verify.sh does. vendor/spinel stays byte-for-byte
# unmodified.
#
# usage: tools/contract/build.sh [-o OUT]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SP="${SPINEL_DIR:-$root/vendor/spinel}"
OUT="$here/build/spinel-typedump"
CC_="${CC:-cc}"

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    *)  echo "usage: $0 [-o OUT]" >&2; exit 2 ;;
  esac
done

[ -d "$SP/src" ] || { echo "build.sh: no vendor spinel at $SP" >&2; exit 1; }

# The vendor objects. `make` in vendor/spinel produces them; we only build if
# they are missing, so a normal run never rewrites anything under vendor/.
if [ ! -f "$SP/build/csrc/compiler.o" ] || [ ! -f "$SP/build/csrc/sp_parse_lib.o" ] \
   || [ ! -f "$SP/build/libprism.a" ]; then
  echo "build.sh: vendor objects missing -- running 'make -j8' in $SP" >&2
  ( cd "$SP" && make -j8 >/dev/null )
fi

OBJ=$(ls "$SP"/build/csrc/*.o | grep -v '/main\.o$' | tr '\n' ' ')
# E188: upstream (2026-09) links the regexp engine into the compiler so a
# literal is compiled at build time (src/re_lit_check.c + build/regexp/*.o).
# The pinned tree has no re_lit_check.o (its regexp objects are runtime-only and
# would drag runtime symbols in); take the engine only when the seam exists.
if [ -f "$SP/build/csrc/re_lit_check.o" ] && ls "$SP"/build/regexp/*.o >/dev/null 2>&1; then
  OBJ="$OBJ $(ls "$SP"/build/regexp/*.o | tr '\n' ' ')"
fi

# Upstream (2026-10) links the RBS parser into the compiler objects themselves
# (src/rbs_map.c, the inline-RBS reader in src/spinel_parse.c). The pinned tree
# builds librbs.a but its compiler objects do not reference it, so it is linked
# only when present and the link is unchanged for a tree that does not need it.
RBS=
if [ -f "$SP/build/librbs.a" ]; then
  RBS="$SP/build/librbs.a"
fi

# The input ledger (sp_inputs_*) is a fork patch of the pinned tree. Built in
# only when the vendor source defines it; without it --inputs-out refuses.
LEDGER=
if grep -q '^void sp_inputs_enable' "$SP/src/spinel_parse.c" 2>/dev/null; then
  LEDGER=-DSPINEL_HAVE_INPUTS_LEDGER
fi
# The prune of unnamed methods keeps the --core identities (a fork patch). Only
# when the vendor prune reads that list can --keep-method add to it.
if grep -q 'g_core_roots\[i\]' "$SP/src/analyze_desugar.c" 2>/dev/null; then
  LEDGER="$LEDGER -DSPINEL_HAVE_CORE_ROOTS"
fi

mkdir -p "$(dirname "$OUT")"
# -D_DEFAULT_SOURCE: spinel_contract.h calls setenv(3) (POSIX, not C11), and
# glibc's stdlib.h only declares it under a feature-test macro. gcc >= 14
# makes the resulting implicit declaration a hard error under -std=c11.
# On non-glibc (Apple SDK) the macro is simply unused.
# shellcheck disable=SC2086
"$CC_" -O2 -std=c11 -D_DEFAULT_SOURCE $LEDGER -Wall -Wextra -Wno-unused-parameter \
   -I "$SP/src" -I "$here" \
   "$here/spinel_typedump.c" $OBJ "$SP/build/libprism.a" $RBS -lm \
   -o "$OUT"

# The source stamp: what this build compiled and the vendor sources it linked,
# which a lane compares with its tree before it uses the reader
# (tools/test/source-stamp.rb).
"${RUBY:-ruby}" "$root/tools/test/source-stamp.rb" write reader "$OUT" --vendor "$SP"

echo "$OUT"
