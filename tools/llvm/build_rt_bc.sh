#!/usr/bin/env bash
# build_rt_bc.sh -- build ThinLTO bitcode archives of the Spinel runtime.
#
# Compiles every runtime translation unit of vendor/spinel/lib with
# `clang -flto=thin -c` (so each .o is LLVM bitcode, not Mach-O) and packs them
# with llvm-ar into two archives that mirror upstream's pair:
#
#   build/libspinel_rt_lto.a      <- vendor/spinel/lib/libspinel_rt.a
#   build/libspinel_rt_mt_lto.a   <- vendor/spinel/lib/libspinel_rt_mt.a  (-DSP_THREADS)
#
# Compile flags mirror vendor/spinel/Makefile:213-352 (per-member rules) and
# Makefile:375-383 (the mt generic rules), with COPT/SEC_FLAGS from
# vendor/spinel/common.mk. See ../README.md for the full mapping.
#
# Usage: build_rt_bc.sh [-f|--force] [-j N] [-v]      (bash 3.2 compatible)
set -euo pipefail

# spinel-extended: the LLVM is the official release docs/building.md selects
# through LLVM_PREFIX (LLVM= still overrides); there is no Homebrew default.
LLVM=${LLVM:-${LLVM_PREFIX:-}}
[ -n "$LLVM" ] || { echo "$(basename "$0"): set LLVM_PREFIX (or LLVM) to the LLVM release" >&2; exit 1; }
CLANG="$LLVM/bin/clang"
LLVM_AR="$LLVM/bin/llvm-ar"

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
SPINEL_DIR=${SPINEL_DIR:-$REPO/vendor/spinel}
BUILD_DIR=${BUILD_DIR:-$HERE/build}

FORCE=0
VERBOSE=0
JOBS=$( (command -v getconf >/dev/null && getconf _NPROCESSORS_ONLN) 2>/dev/null || echo 4)

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)   FORCE=1; shift ;;
    -j)           JOBS=$2; shift 2 ;;
    -j*)          JOBS=${1#-j}; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "build_rt_bc.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "build_rt_bc.sh: $*" >&2; exit 1; }

[ -x "$CLANG" ]   || die "clang not found at $CLANG (set LLVM=<prefix>)"
[ -x "$LLVM_AR" ] || die "llvm-ar not found at $LLVM_AR (set LLVM=<prefix>)"
[ -d "$SPINEL_DIR/lib" ] || die "vendor/spinel/lib not found at $SPINEL_DIR/lib"

# ---- flags mirrored from upstream -------------------------------------------
# common.mk:15  COPT ?= -O2
# common.mk:49  SEC_FLAGS = -ffunction-sections -fdata-sections
# Makefile:370  MT_DEF = -DSP_THREADS -ftls-model=initial-exec
COPT=(-O2)
SEC_FLAGS=(-ffunction-sections -fdata-sections)
MT_DEF=(-DSP_THREADS -ftls-model=initial-exec)
LTO_FLAGS=(-flto=thin)

# lib/*.c members (Makefile RT_MEMBERS): -Wno-all -Ilib [-Ilib/regexp]
# lib/regexp/*.c (Makefile RE_SRC):      no -Wno-all, -Ilib/regexp[/shim]
# The mt generic rule passes -Ilib -Ilib/regexp -Ilib/regexp/shim to every
# lib/*.c member; we use that superset for both variants -- an extra -I is
# inert for TUs that include nothing from it, and lib/regexp/shim (new
# upstream) is simply absent at older revisions.

# Runtime sources: the Makefile's own RT_MEMBERS and RE_SRC, read from it.
# lib/*.c is not the member list -- upstream e1d92f1e1 also keeps the four
# opt-in C-extension TUs (sp_cext*.c) there, outside libspinel_rt.a.
make_list() {  # make_list <VAR>: the one-line `VAR = ...` assignment's words
  sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$SPINEL_DIR/Makefile" | head -1
}
rt_members=$(make_list RT_MEMBERS)
re_src=$(make_list RE_SRC)
[ -n "$rt_members" ] || die "RT_MEMBERS not found in $SPINEL_DIR/Makefile"
[ -n "$re_src" ]     || die "RE_SRC not found in $SPINEL_DIR/Makefile"
LIB_SRCS=()
for m in $rt_members; do LIB_SRCS+=("$SPINEL_DIR/lib/$m.c"); done
RE_SRCS=()
for f in $re_src; do RE_SRCS+=("$SPINEL_DIR/$f"); done
for f in "${LIB_SRCS[@]}" "${RE_SRCS[@]}"; do [ -f "$f" ] || die "runtime source missing: $f"; done
shopt -s nullglob
HDRS=("$SPINEL_DIR"/lib/*.h "$SPINEL_DIR"/lib/regexp/*.h "$SPINEL_DIR"/lib/regexp/*.inc
      "$SPINEL_DIR"/lib/regexp/shim/*.h "$SPINEL_DIR"/lib/regexp/shim/mruby/*.h)
shopt -u nullglob

[ ${#LIB_SRCS[@]} -gt 0 ] || die "no sources in $SPINEL_DIR/lib"
[ ${#RE_SRCS[@]} -gt 0 ]  || die "no sources in $SPINEL_DIR/lib/regexp"

# Newest header mtime: any header change invalidates every object. Upstream
# tracks per-file header deps; a single global stamp is coarser but never
# under-rebuilds, which is what matters for a cache we own.
newest_hdr=""
for h in ${HDRS[@]+"${HDRS[@]}"}; do
  if [ -z "$newest_hdr" ] || [ "$h" -nt "$newest_hdr" ]; then newest_hdr=$h; fi
done

# up_to_date <obj> <src>
up_to_date() {
  [ "$FORCE" -eq 0 ] || return 1
  [ -f "$1" ] || return 1
  [ "$1" -nt "$2" ] || return 1
  [ -z "$newest_hdr" ] || [ "$1" -nt "$newest_hdr" ] || return 1
  [ "$1" -nt "$0" ] || return 1
  return 0
}

compiled=0
skipped=0
pids=()

wait_slot() {
  while [ "${#pids[@]}" -ge "$JOBS" ]; do
    wait "${pids[0]}" || die "compile failed"
    pids=("${pids[@]:1}")
  done
}

wait_all() {
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || die "compile failed"; done
  pids=()
}

# build_variant <name> <objdir> <archive> [extra flags...]
build_variant() {
  local name=$1 objdir=$2 archive=$3; shift 3
  local extra=("$@")
  mkdir -p "$objdir/regexp"

  local objs=()
  local src obj
  for src in "${LIB_SRCS[@]}"; do
    obj="$objdir/$(basename "${src%.c}").o"
    objs+=("$obj")
    if up_to_date "$obj" "$src"; then skipped=$((skipped + 1)); continue; fi
    compiled=$((compiled + 1))
    [ "$VERBOSE" -eq 0 ] || echo "  CC[$name] $(basename "$src")"
    wait_slot
    "$CLANG" -c "${COPT[@]}" -Wno-all "${SEC_FLAGS[@]}" "${LTO_FLAGS[@]}" ${extra[@]+"${extra[@]}"} \
      -I"$SPINEL_DIR/lib" -I"$SPINEL_DIR/lib/regexp" -I"$SPINEL_DIR/lib/regexp/shim" "$src" -o "$obj" &
    pids+=($!)
  done
  for src in "${RE_SRCS[@]}"; do
    obj="$objdir/regexp/$(basename "${src%.c}").o"
    objs+=("$obj")
    if up_to_date "$obj" "$src"; then skipped=$((skipped + 1)); continue; fi
    compiled=$((compiled + 1))
    [ "$VERBOSE" -eq 0 ] || echo "  CC[$name] regexp/$(basename "$src")"
    wait_slot
    "$CLANG" -c "${COPT[@]}" "${SEC_FLAGS[@]}" "${LTO_FLAGS[@]}" ${extra[@]+"${extra[@]}"} \
      -I"$SPINEL_DIR/lib/regexp" -I"$SPINEL_DIR/lib/regexp/shim" "$src" -o "$obj" &
    pids+=($!)
  done
  wait_all

  # Re-archive when any member is newer than the archive (or it is missing).
  local stale=0
  [ -f "$archive" ] || stale=1
  if [ "$stale" -eq 0 ]; then
    for obj in ${objs[@]+"${objs[@]}"}; do
      if [ "$obj" -nt "$archive" ]; then stale=1; break; fi
    done
  fi
  if [ "$stale" -eq 1 ]; then
    rm -f "$archive"
    "$LLVM_AR" rcs "$archive" ${objs[@]+"${objs[@]}"} || die "llvm-ar failed for $archive"
  fi
}

mkdir -p "$BUILD_DIR"
build_variant plain "$BUILD_DIR/rt-bc/plain" "$BUILD_DIR/libspinel_rt_lto.a"
build_variant mt    "$BUILD_DIR/rt-bc/mt"    "$BUILD_DIR/libspinel_rt_mt_lto.a" "${MT_DEF[@]}"

n_srcs=$(( ${#LIB_SRCS[@]} + ${#RE_SRCS[@]} ))
sz_plain=$(wc -c <"$BUILD_DIR/libspinel_rt_lto.a" | tr -d ' ')
sz_mt=$(wc -c <"$BUILD_DIR/libspinel_rt_mt_lto.a" | tr -d ' ')
printf 'rt bitcode: %d TUs x2 variants (compiled %d, up-to-date %d) -> %s (%s KiB) + %s (%s KiB)\n' \
  "$n_srcs" "$compiled" "$skipped" \
  "libspinel_rt_lto.a" "$((sz_plain / 1024))" \
  "libspinel_rt_mt_lto.a" "$((sz_mt / 1024))"
