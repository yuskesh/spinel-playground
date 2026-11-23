#!/bin/sh
#
# tools/doom/build-reference.sh — build the C reference implementation that the
# DOOM comparison uses as its oracle.
#
#   BUILD_DIR=... tools/doom/build-reference.sh
#
# Clones doomgeneric at a fixed commit into an owned build directory, applies
# the tracked patches in tests/doom/reference/patches/ in order, and builds the
# headless binary.  The clone and every build output stay outside the
# repository; only the patches are tracked.
#
#   BUILD_DIR   where to work.        default <root>/build/doom-reference
#   DG_REPO     doomgeneric remote.   default https://github.com/ozkl/doomgeneric
#   DG_SHA      the commit to use.    default dcb7a8db… (2026-04-12 "boolean fix")
#   MAKE_JOBS   parallelism.          default 4
#   CC          C compiler for the reference.  default $LLVM_PREFIX/bin/clang if
#               that exists, else cc.  Makefile.headless uses CC?=cc, so this is
#               passed on the make command line to win over the default.
#               WHICH compiler built the reference is part of the result: two
#               builds of this source have been observed to differ in two frame
#               hashes, so a run that does not record its compiler cannot be
#               compared with one that does.
#
# It needs nothing but this checkout and the network: not the predecessor, not a
# patch supplied from somewhere else.  Every patch it applies is tracked here and
# is digest-checked against tests/doom/reference/manifest.tsv first, so "which
# patches went in" is answerable from the repository rather than from whoever
# ran it.
#
# **Ownership.** The destructive steps -- `git checkout --detach`, restoring
# tracked files, removing the generated sources a re-run would otherwise leave
# behind -- run only inside a clone this script made itself, marked by a stamp
# file it writes.  A directory that exists, is not empty and has no stamp is
# refused rather than cleaned: decision 0006 forbids resetting or cleaning a
# source checkout the user supplied, and the way to honour that is to be unable
# to.
#
# **Every command's status is checked.**  `set -e` plus explicit checks on the
# ones whose failure would otherwise be swallowed by a pipeline or an `if`.
#
# This builds; it does not run.  The oracle run and the replay comparison are
# macOS-owned in this import: the dump hook's SHA-256 column needs CommonCrypto
# and the headless Makefile is macOS-specific.  On any other host this script
# may still clone and patch, and the build step will say what failed.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tools/doom/sha256.sh"

BUILD_DIR="${BUILD_DIR:-$ROOT/build/doom-reference}"
DG_REPO="${DG_REPO:-https://github.com/ozkl/doomgeneric}"
DG_SHA="${DG_SHA:-dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284}"
MAKE_JOBS="${MAKE_JOBS:-4}"
PATCHES="$ROOT/tests/doom/reference/patches"
MANIFEST="$ROOT/tests/doom/reference/manifest.tsv"
STAMP=".spinel-extended-owned-reference-build"

die() { echo "build-reference: $*" >&2; exit 1; }

# Which compiler built the reference is part of the result, not a detail.  Two
# builds of this exact source have been observed to produce different hashes for
# two frames of DEMO1, so an oracle run whose compiler is unrecorded cannot be
# compared with one whose compiler is known.  The selection is therefore
# explicit, loud, and written down beside the binary.
#
# Earlier this script read neither CC nor LLVM_PREFIX: it took Makefile.headless's
# own `CC?=cc` default, so `LLVM_PREFIX=… build-reference.sh` silently built with
# the system compiler while appearing to select one.  Review caught that.
if [ -n "${CC:-}" ]; then
  CC_SOURCE="CC given explicitly"
elif [ -n "${LLVM_PREFIX:-}" ]; then
  # A set-but-wrong LLVM_PREFIX must not fall back.  Falling back is how the
  # original defect looked from outside: a selected toolchain that was not used.
  if [ ! -x "${LLVM_PREFIX}/bin/clang" ]; then
    die "LLVM_PREFIX=${LLVM_PREFIX} has no executable bin/clang.
    Refusing to fall back to the system compiler: a selected toolchain that is
    silently not used is the defect this check exists for.  Fix LLVM_PREFIX, or
    set CC explicitly to build with something else on purpose."
  fi
  CC="${LLVM_PREFIX}/bin/clang"
  CC_SOURCE="derived from LLVM_PREFIX=${LLVM_PREFIX}"
else
  CC=cc
  CC_SOURCE="fallback: neither CC nor LLVM_PREFIX was set"
fi

command -v git >/dev/null 2>&1 || die "git is not on PATH"
command -v make >/dev/null 2>&1 || die "make is not on PATH"
[ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"
[ -d "$PATCHES" ] || die "no patch directory at $PATCHES"

# 1. The patches are what the manifest says they are, before anything is
#    cloned.  A patch that fails its digest stops the build here rather than
#    producing a reference nobody can account for.
n=0
for p in "$PATCHES"/*.patch; do
  [ -f "$p" ] || die "no patches found in $PATCHES"
  rel="tests/doom/reference/patches/$(basename "$p")"
  want=$(awk -F'\t' -v r="$rel" '!/^#/ && $5 == r { print $7 }' "$MANIFEST")
  [ -n "$want" ] || die "$rel is not declared in the manifest"
  got=$(sp_sha256 "$p")
  [ "$got" = "$want" ] || die "$rel has sha256 $got, the manifest says $want"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no patches to apply"

# Declared but absent is a failure too, so the set is checked in both
# directions rather than only over what happens to be on disk.
declared=$(awk -F'\t' '!/^#/ && $1 == "patch" { print $5 }' "$MANIFEST" | sort)
present=$(cd "$ROOT" && ls tests/doom/reference/patches/*.patch | sort)
[ "$declared" = "$present" ] || die "the patch directory and the manifest disagree:
declared:
$declared
present:
$present"

echo "build-reference: $n patches verified against the manifest (digests by $(sp_sha256_tool))"

# Resolve the compiler to a real executable, and check the STATUS of asking it
# for its version -- not just whether the answer was non-empty.  `$CC --version
# | head -1` reports head's status, so a compiler that fails while printing
# something to stdout would pass a non-empty test.  The status is captured on
# its own, before any pipeline.
CC_PATH=$(command -v "$CC" 2>/dev/null) || CC_PATH=""
if [ -z "$CC_PATH" ]; then
  [ -x "$CC" ] || die "the selected compiler '$CC' is not on PATH and is not an executable file"
  CC_PATH="$CC"
fi
# The assignment is wrapped in `if` rather than written bare: under `set -e` a
# failing command substitution in an assignment exits the script immediately,
# with the compiler's status and no diagnostic at all.  The control for this
# case caught that -- the script exited 3 and said nothing.
if CC_VER_RAW=$("$CC_PATH" --version 2>/dev/null); then
  CC_VER_RC=0
else
  CC_VER_RC=$?
fi
[ "$CC_VER_RC" -eq 0 ] || die "'$CC_PATH' exited $CC_VER_RC for --version; refusing to build with a compiler that cannot identify itself"
CC_VERSION=$(printf '%s\n' "$CC_VER_RAW" | head -1)
[ -n "$CC_VERSION" ] || die "'$CC_PATH' reported an empty version; refusing to build with an unidentified compiler"
echo "build-reference: CC=$CC_PATH"
echo "build-reference:   $CC_VERSION"
echo "build-reference:   ($CC_SOURCE)"
case "$CC_SOURCE" in
  fallback:*)
    echo "build-reference: WARNING -- no toolchain was selected, so the reference is" >&2
    echo "build-reference: being built with whatever 'cc' is.  Frame hashes have been" >&2
    echo "build-reference: observed to differ between builds; record this when comparing." >&2
    ;;
esac

# 2. An owned working directory.
mkdir -p "$BUILD_DIR"
CLONE="$BUILD_DIR/doomgeneric"
if [ -e "$CLONE" ]; then
  if [ ! -f "$CLONE/$STAMP" ]; then
    die "$CLONE exists and was not created by this script.
    It will not be reset, cleaned or checked out, because it may be a checkout
    you supplied.  Remove it yourself, or set BUILD_DIR elsewhere."
  fi
else
  git clone -q "$DG_REPO" "$CLONE" || die "could not clone $DG_REPO"
  : > "$CLONE/$STAMP" || die "could not mark $CLONE as owned"
fi

cd "$CLONE"
[ -f "$STAMP" ] || die "refusing to work in $CLONE: the ownership stamp is gone"

git checkout -q --detach "$DG_SHA" || die "doomgeneric has no commit $DG_SHA"
git checkout -q -- . || die "could not restore tracked files in the owned clone"
# The patches add files that the upstream .gitignore covers, so `git checkout`
# does not remove them and a second run would fail to apply.  Named explicitly
# rather than swept with `git clean`, so this cannot remove anything the patch
# set does not create.
rm -f doomgeneric/doomgeneric_headless.c doomgeneric/Makefile.headless \
      doomgeneric/doomgeneric_dump.c doomgeneric/doomgeneric_e047.c \
      doomgeneric/doomgeneric_e051.c doomgeneric/doomgeneric_e052.c \
      doomgeneric/doomgeneric_e053.c

for p in "$PATCHES"/*.patch; do
  git apply "$p" || die "$(basename "$p") did not apply to doomgeneric $DG_SHA"
  echo "build-reference: applied $(basename "$p")"
done

echo "build-reference: doomgeneric $(git rev-parse HEAD)"

# 3. Build.
cd doomgeneric || die "the patched tree has no doomgeneric/ subdirectory"
# `clean` must succeed.  Swallowing its failure leaves objects from an earlier
# build while CC changes underneath them, which produces a binary built by two
# compilers and no diagnostic -- and the compiler identity is exactly what this
# script exists to pin down.  Makefile.headless, which patch 01 adds, has a
# clean target, so a failure here is real.
if ! make -f Makefile.headless CC="$CC_PATH" clean > "$BUILD_DIR/clean.log" 2>&1; then
  echo "build-reference: make clean failed; last lines of $BUILD_DIR/clean.log:" >&2
  tail -10 "$BUILD_DIR/clean.log" >&2
  die "refusing to build over objects that could not be removed"
fi
# Building doomgeneric builds the reference implementation, an oracle
# (tests/ORACLES.tsv): only the owner's instruction runs it. Everything above
# runs either way, and tests/doom/build-reference-controls.sh checks it.
"$ROOT/tools/oracle/gate" tools/doom/build-reference.sh build || exit 0
if ! make -f Makefile.headless CC="$CC_PATH" -j"$MAKE_JOBS" > "$BUILD_DIR/build.log" 2>&1; then
  echo "build-reference: the reference build failed; last lines of $BUILD_DIR/build.log:" >&2
  tail -20 "$BUILD_DIR/build.log" >&2
  die "make -f Makefile.headless failed.
    This Makefile and the dump hook's SHA-256 column are macOS-specific (the
    hook uses CommonCrypto), so a failure here on another host is expected and
    is not evidence about the reference itself."
fi

BIN="$PWD/doomgeneric_headless"
[ -x "$BIN" ] || die "the build reported success but produced no $BIN"

# Provenance beside the binary, so an oracle run's output can be traced to the
# compiler that produced it without anyone having to remember.
{
  echo "doomgeneric_sha=$DG_SHA"
  echo "doomgeneric_repo=$DG_REPO"
  echo "cc=$CC_PATH"
  echo "cc_version=$CC_VERSION"
  echo "cc_selected_by=$CC_SOURCE"
  echo "patches_verified=$n"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(uname -s) $(uname -m)"
} > "$BUILD_DIR/reference-provenance.txt" || die "could not write the provenance file"

echo "build-reference: built $BIN"
echo "build-reference: provenance in $BUILD_DIR/reference-provenance.txt"
