#!/bin/sh
#
# examples/doom/build.sh — build the interactive DOOM binary.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 examples/doom/build.sh
#
# Compiles bin/doom.rb with the pinned Spinel, compiles the two C pieces it
# needs with the SAME compiler, and links them into one executable.
#
#   LLVM_PREFIX  selects the C compiler as $LLVM_PREFIX/bin/clang.  Set but
#                missing bin/clang is a refusal, not a fallback.
#   CC           overrides LLVM_PREFIX.
#   BUILD_DIR    default <root>/build/doom.  Staging lives under it.
#   OUT          default $BUILD_DIR/doom
#   SDL2_CFLAGS  explicit flags, if pkg-config cannot be used
#   SDL2_LIBS    likewise
#   SPINEL       default <root>/vendor/spinel/bin/spinel
#   SPINEL_LIB   the pinned runtime's headers and libspinel_rt.a,
#                default <root>/vendor/spinel/lib
#   CORE_DIR     decision 0008's entries: a directory holding the kernel's
#                doom_core_*.o and, under adapter/obj/, the generated adapter's
#                objects (tests/doom-core/harness/artifacts.sh dc_core_entries
#                and dc_route_adapter write that layout). With it, `-core`
#                plays through the entries; without it, native/sp_core_stub.c
#                is linked and `-core` refuses at session open.
#   RASTER_GPU   1 links the GPU raster path (tools/raster/sp_raster_gpu.c and
#                sp_raster_shim.c, the IREE runtime, and on macOS Metal) in place of
#                native/sp_rg_stub.c, so `-gpu` draws the 3D view on the GPU.
#                Needs IREE_SRC and IREE_BUILD (docs/toolchains/iree-3.11.0/
#                INSTALLATION-RECORD.md). Unset, nothing here changes.
#
# The C pieces:
#
#   native/sp_sdl_shim.c  the SDL2 interface lib/doom/video.rb declares
#   native/sp_core_stub.c the adapter operations core/full/nativeprep.rb
#                         declares, when CORE_DIR is not given
#   native/sp_rg_stub.c   the nine sp_rg_* symbols lib/doom/render_gpu.rb
#                         declares.  A no-device stub: no IREE, no GPU kernels,
#                         no MLIR.  sp_rg_available() answers 0 and the renderer
#                         takes its CPU path.
#
# **Nothing is reused across runs.** The staging directory is removed and
# recreated every time, so an object built by a different compiler or from
# different source cannot survive into a link.  That is cheap here -- two small
# C files -- and the alternative is a binary assembled from two toolchains with
# no diagnostic, which is exactly the class of defect the reference builder was
# just fixed for.
#
# The executable is published by rename from staging, so an interrupted build
# leaves no half-written file at OUT for someone to run.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/examples/doom"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/doom}"
OUT="${OUT:-$BUILD_DIR/doom}"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
SPINEL_LIB="${SPINEL_LIB:-$ROOT/vendor/spinel/lib}"

die() { echo "doom-build: $*" >&2; exit 1; }

# ---- where we are asked to write, checked FIRST -----------------------------
# Before the compiler, before SDL, before anything that needs a toolchain: this
# is a question about the arguments, and answering it first means the refusal
# can be controlled on a host with neither.  The control for it was not
# self-contained while this sat further down -- it needed an LLVM to reach the
# check it was named after, and macOS measured that.
[ -d "$OUT" ] && die "OUT=$OUT is a directory; it must be the path of the executable to write"
OUT_DIR=$(CDPATH= cd -- "$(dirname -- "$OUT")" 2>/dev/null && pwd) || {
  mkdir -p "$(dirname "$OUT")" || die "could not create $(dirname "$OUT")"
  OUT_DIR=$(CDPATH= cd -- "$(dirname -- "$OUT")" && pwd)
}

# ---- the compiler, selected explicitly and identified -----------------------
if [ -n "${CC:-}" ]; then
  CC_SOURCE="CC given explicitly"
elif [ -n "${LLVM_PREFIX:-}" ]; then
  [ -x "${LLVM_PREFIX}/bin/clang" ] || die "LLVM_PREFIX=${LLVM_PREFIX} has no executable bin/clang.
    Refusing to fall back to the system compiler: a selected toolchain that is
    silently not used is worse than no selection at all."
  CC="${LLVM_PREFIX}/bin/clang"
  CC_SOURCE="derived from LLVM_PREFIX=${LLVM_PREFIX}"
else
  CC=cc
  CC_SOURCE="fallback: neither CC nor LLVM_PREFIX was set"
fi
CC_PATH=$(command -v "$CC" 2>/dev/null) || CC_PATH=""
if [ -z "$CC_PATH" ]; then
  [ -x "$CC" ] || die "the selected compiler '$CC' is not on PATH and is not an executable file"
  CC_PATH="$CC"
fi
if CC_VER_RAW=$("$CC_PATH" --version 2>/dev/null); then CC_VER_RC=0; else CC_VER_RC=$?; fi
[ "$CC_VER_RC" -eq 0 ] || die "'$CC_PATH' exited $CC_VER_RC for --version; refusing to build with a compiler that cannot identify itself"
CC_VERSION=$(printf '%s\n' "$CC_VER_RAW" | head -1)
[ -n "$CC_VERSION" ] || die "'$CC_PATH' reported an empty version"

[ -x "$SPINEL" ] || die "no pinned compiler at $SPINEL (see docs/building.md)"

# ---- SDL2, discovered or given, never guessed -------------------------------
if [ -n "${SDL2_CFLAGS:-}" ] || [ -n "${SDL2_LIBS:-}" ]; then
  : "${SDL2_CFLAGS:=}"
  : "${SDL2_LIBS:?SDL2_CFLAGS was given without SDL2_LIBS; give both or neither}"
  SDL_SOURCE="given explicitly"
else
  command -v pkg-config >/dev/null 2>&1 || die "SDL2 is needed and pkg-config is not installed.
    Install pkg-config and the SDL2 development package, or set SDL2_CFLAGS and
    SDL2_LIBS explicitly."
  pkg-config --exists sdl2 || die "SDL2 development files not found by pkg-config.
    Install them -- 'libsdl2-dev' on Debian, 'sdl2' from Homebrew on macOS --
    or set SDL2_CFLAGS and SDL2_LIBS explicitly.
    No hardcoded prefix is searched: a build that guessed a location would
    succeed or fail for reasons nobody could read off the command."
  SDL2_CFLAGS=$(pkg-config --cflags sdl2)
  SDL2_LIBS=$(pkg-config --libs sdl2)
  SDL_SOURCE="pkg-config sdl2 $(pkg-config --modversion sdl2)"
fi

echo "doom-build: CC=$CC_PATH"
echo "doom-build:   $CC_VERSION"
echo "doom-build:   ($CC_SOURCE)"
echo "doom-build: SDL2 $SDL_SOURCE"
echo "doom-build:   cflags: ${SDL2_CFLAGS:-<none>}"
echo "doom-build:   libs:   $SDL2_LIBS"

# ---- staging ---------------------------------------------------------------
# The staging directory is created by mktemp IN THE OUT PARENT, for two reasons.
#
# It is this build's own, so two builds running at once do not delete each
# other's work.  A fixed $BUILD_DIR/stage removed with rm -rf at the start is
# not exclusive: the second build wipes the first one's objects mid-link.
#
# And it is on the same filesystem as OUT, so publishing is a real rename.  OUT
# is caller-settable, so a fixed staging directory under BUILD_DIR could easily
# be on a different filesystem, where `mv` copies -- and a copy is not atomic,
# which is the whole reason for staging.
STAGE=$(mktemp -d "$OUT_DIR/.doom-build.XXXXXX") || die "could not create a staging directory beside $OUT"
cleanup_stage() { [ -n "${STAGE:-}" ] && rm -rf "$STAGE"; }
trap cleanup_stage EXIT INT TERM

# ---- what the runtime needs from the host ----------------------------------
# libcrypt is a separate library on glibc and part of libSystem on macOS, so
# naming it unconditionally is a Linux assumption.  The macOS side hit exactly
# that: `ld: library crypt not found`.  It is probed rather than guessed from
# `uname`, because what matters is whether THIS linker resolves it, not which
# operating system this is.
# Probed inside this build's own staging directory: a fixed name under
# BUILD_DIR is shared, so two builds at once would overwrite each other's probe
# and read back the wrong answer.
CRYPT_LIB=""
probe="$STAGE/crypt-probe"
printf 'int main(void){return 0;}\n' > "$probe.c"
if "$CC_PATH" "$probe.c" -lcrypt -o "$probe.bin" > "$probe.log" 2>&1; then
  CRYPT_LIB="-lcrypt"
  echo "doom-build: libcrypt: linking with -lcrypt"
else
  echo "doom-build: libcrypt: not a separate library here, omitting -lcrypt"
fi
rm -f "$probe.c" "$probe.bin" "$probe.log"

# ---- decision 0008's entries, or their stub ----------------------------------
CORE_OBJS=""
if [ -n "${CORE_DIR:-}" ]; then
  for o in doom_core_input doom_core_step doom_core_render; do
    [ -f "$CORE_DIR/$o.o" ] || die "CORE_DIR=$CORE_DIR has no $o.o"
    CORE_OBJS="$CORE_OBJS $CORE_DIR/$o.o"
  done
  for o in spinel_adapter_registry spinel_adapter_doom_core_input spinel_adapter_doom_core_step spinel_adapter_doom_core_render; do
    [ -f "$CORE_DIR/adapter/obj/$o.o" ] || die "CORE_DIR=$CORE_DIR has no adapter/obj/$o.o"
    CORE_OBJS="$CORE_OBJS $CORE_DIR/adapter/obj/$o.o"
  done
  CORE_OBJS="$CORE_OBJS -lpthread"
  CORE_SOURCE="entries from $CORE_DIR"
  echo "doom-build: -core links the entries from $CORE_DIR"
else
  CORE_SOURCE="stub (no CORE_DIR): -core refuses at session open"
  echo "doom-build: no CORE_DIR: native/sp_core_stub.c, and -core refuses at session open"
fi

# ---- the GPU raster path, or its no-device stub ------------------------------
# tools/raster/sp_raster_gpu.c implements the same nine sp_rg_* symbols as
# native/sp_rg_stub.c, through the IREE runtime. The IREE build configuration
# leaks into its headers, so both files are compiled with the runtime's defines.
RG_OBJS="$STAGE/sp_rg_stub.o"; RG_LIBS=""
if [ "${RASTER_GPU:-}" = 1 ]; then
  : "${IREE_SRC:?RASTER_GPU=1 needs IREE_SRC (docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md)}"
  : "${IREE_BUILD:?RASTER_GPU=1 needs IREE_BUILD}"
  RD="$ROOT/tools/raster"
  IREE_DEFS="-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl \
-DIREE_HAVE_HAL_LOCAL_SYNC_DRIVER_MODULE=1 -DIREE_HAVE_HAL_LOCAL_TASK_DRIVER_MODULE=1 \
-DIREE_HAVE_VMVX_MODULE"
  # Metal exists only on macOS. Elsewhere the runtime's own driver set decides.
  IREE_PLATFORM_LIBS="-lstdc++ -ldl -lm -lpthread"
  if [ "$(uname -s)" = Darwin ]; then
    IREE_DEFS="$IREE_DEFS -DIREE_HAVE_HAL_METAL_DRIVER_MODULE=1"
    IREE_PLATFORM_LIBS="-framework Metal -framework Foundation -lc++"
  fi
  for src in sp_raster_gpu sp_raster_shim; do
    echo "doom-build: compiling tools/raster/$src.c (RASTER_GPU=1)"
    # shellcheck disable=SC2086
    "$CC_PATH" -O2 -Wall $IREE_DEFS -I"$IREE_SRC/runtime/src" -I"$IREE_BUILD/runtime/src" -I"$RD" \
      -c "$RD/$src.c" -o "$STAGE/$src.o" || die "could not compile tools/raster/$src.c"
  done
  RG_OBJS="$STAGE/sp_raster_gpu.o $STAGE/sp_raster_shim.o"
  RG_LIBS="$IREE_BUILD/runtime/src/iree/runtime/libiree_runtime_unified.a \
$IREE_BUILD/build_tools/third_party/flatcc/libflatcc_parsing.a \
$IREE_BUILD/build_tools/third_party/printf/libprintf_printf.a \
$IREE_PLATFORM_LIBS"
  RASTER_SOURCE="GPU (tools/raster, IREE at $IREE_BUILD)"
else
  RASTER_SOURCE="stub (native/sp_rg_stub.c): -gpu falls back to the CPU"
fi
echo "doom-build: raster: $RASTER_SOURCE"

echo "doom-build: generating C from bin/doom.rb"
"$SPINEL" "$HERE/bin/doom.rb" --cc="$CC_PATH" -c --no-line-map -o "$STAGE/doom.c" \
  || die "spinel could not generate C from bin/doom.rb"

STUBS="sp_sdl_shim"
[ "${RASTER_GPU:-}" = 1 ] || STUBS="$STUBS sp_rg_stub"
[ -n "${CORE_DIR:-}" ] || STUBS="$STUBS sp_core_stub"
for src in $STUBS; do
  echo "doom-build: compiling native/$src.c"
  extra=""
  [ "$src" = sp_sdl_shim ] && extra="$SDL2_CFLAGS"
  # shellcheck disable=SC2086
  "$CC_PATH" -O2 -Wall -Wextra -c $extra "$HERE/native/$src.c" -o "$STAGE/$src.o" \
    || die "could not compile native/$src.c"
done

echo "doom-build: compiling and linking the program"
xlibs=$(sed -n 's|^/\* SPINEL_LINK: \(.*\) \*/$|\1|p' "$STAGE/doom.c" | tr '\n' ' ')
# -Wno-all on the GENERATED C only: it is machine-written and its style
# warnings say nothing about this build.  Our own two C files keep -Wall
# -Wextra above, where a warning is a message from a human's code.
# shellcheck disable=SC2086
"$CC_PATH" -O2 -Wno-all -Wno-unknown-warning-option -I"$SPINEL_LIB" "$STAGE/doom.c" \
  "$STAGE/sp_sdl_shim.o" $RG_OBJS $([ -n "${CORE_DIR:-}" ] || echo "$STAGE/sp_core_stub.o") $CORE_OBJS \
  "$SPINEL_LIB/libspinel_rt.a" $xlibs $SDL2_LIBS $RG_LIBS -lm $CRYPT_LIB -o "$STAGE/doom.bin" \
  || die "could not link the program"

[ -x "$STAGE/doom.bin" ] || die "the link reported success but produced no executable"

# Publish by rename within one filesystem, so OUT is either the previous build
# or this one and never a partially written file.
mv "$STAGE/doom.bin" "$OUT" || die "could not publish $OUT"

# BUILD_DIR holds the provenance even when OUT is elsewhere; it was created
# only as OUT's parent, so an OUT outside it published the program and then
# failed here.
mkdir -p "$BUILD_DIR" || die "could not create $BUILD_DIR for the provenance"
{
  echo "cc=$CC_PATH"
  echo "cc_version=$CC_VERSION"
  echo "cc_selected_by=$CC_SOURCE"
  echo "sdl2=$SDL_SOURCE"
  echo "crypt=${CRYPT_LIB:-<not needed>}"
  echo "core=$CORE_SOURCE"
  echo "raster=$RASTER_SOURCE"
  echo "spinel=$("$SPINEL" --cc="$CC_PATH" --version)"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(uname -s) $(uname -m)"
} > "$BUILD_DIR/build-provenance.txt"

echo "doom-build: built $OUT"
echo "doom-build: provenance in $BUILD_DIR/build-provenance.txt"
