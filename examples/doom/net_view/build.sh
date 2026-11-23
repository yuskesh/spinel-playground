#!/bin/sh
#
# examples/doom/net_view/build.sh -- build the viewer of the board's frames.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh examples/doom/net_view/build.sh OUT
#
# Compiles net_view.rb with the pinned Spinel, compiles its three C pieces with
# the SAME compiler, and links them into the executable OUT. The rules are
# examples/doom/build.sh's:
#
#   LLVM_PREFIX  selects the C compiler as $LLVM_PREFIX/bin/clang; set but
#                missing bin/clang is a refusal, not a fallback
#   CC           overrides LLVM_PREFIX
#   SDL2_CFLAGS  explicit flags, if pkg-config cannot be used
#   SDL2_LIBS    likewise
#   SPINEL       default <root>/vendor/spinel/bin/spinel
#   SPINEL_LIB   the pinned runtime's headers and libspinel_rt.a,
#                default <root>/vendor/spinel/lib
#
# The C pieces:
#
#   ../native/sp_sdl_shim.c  the SDL2 interface ../lib/doom/video.rb declares
#   sp_udp_shim.c            the UDP socket net_view.rb declares
#   sp_focus_shim.c          whether the window has the keyboard (SDL2)
#
# Nothing is reused across runs: the objects are built in a staging directory
# beside OUT, made for this build and removed after it, and OUT is published
# by rename from there, so it is either the previous build or this one.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
HERE="$ROOT/examples/doom/net_view"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
SPINEL_LIB="${SPINEL_LIB:-$ROOT/vendor/spinel/lib}"

die() { echo "net-view-build: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: build.sh OUT (the path of the executable to write)"
TARGET=$1
[ -d "$TARGET" ] && die "$TARGET is a directory; give the path of the executable to write"
mkdir -p "$(dirname "$TARGET")" || die "could not create $(dirname "$TARGET")"
TARGET_DIR=$(CDPATH= cd -- "$(dirname -- "$TARGET")" && pwd)

if [ -n "${CC:-}" ]; then
  CC_SOURCE="CC given explicitly"
elif [ -n "${LLVM_PREFIX:-}" ]; then
  [ -x "${LLVM_PREFIX}/bin/clang" ] || die "LLVM_PREFIX=${LLVM_PREFIX} has no executable bin/clang; refusing to fall back to the system compiler"
  CC="${LLVM_PREFIX}/bin/clang"
  CC_SOURCE="derived from LLVM_PREFIX=${LLVM_PREFIX}"
else
  die "set LLVM_PREFIX or CC: the compiler is selected explicitly"
fi
CC_PATH=$(command -v "$CC" 2>/dev/null) || CC_PATH="$CC"
[ -x "$CC_PATH" ] || die "the selected compiler '$CC' is not on PATH and is not an executable file"
CC_VERSION=$("$CC_PATH" --version 2>/dev/null | head -1) || CC_VERSION=""
[ -n "$CC_VERSION" ] || die "'$CC_PATH' cannot identify itself with --version"
[ -x "$SPINEL" ] || die "no pinned compiler at $SPINEL (see docs/building.md)"

if [ -n "${SDL2_CFLAGS:-}" ] || [ -n "${SDL2_LIBS:-}" ]; then
  : "${SDL2_CFLAGS:=}"
  : "${SDL2_LIBS:?SDL2_CFLAGS was given without SDL2_LIBS; give both or neither}"
  SDL_SOURCE="given explicitly"
else
  command -v pkg-config >/dev/null 2>&1 || die "SDL2 is needed and pkg-config is not installed; install it, or set SDL2_CFLAGS and SDL2_LIBS"
  pkg-config --exists sdl2 || die "SDL2 development files not found by pkg-config ('libsdl2-dev' on Debian, 'sdl2' from Homebrew on macOS), or set SDL2_CFLAGS and SDL2_LIBS"
  SDL2_CFLAGS=$(pkg-config --cflags sdl2)
  SDL2_LIBS=$(pkg-config --libs sdl2)
  SDL_SOURCE="pkg-config sdl2 $(pkg-config --modversion sdl2)"
fi
echo "net-view-build: CC=$CC_PATH ($CC_SOURCE)"
echo "net-view-build:   $CC_VERSION"
echo "net-view-build: SDL2 $SDL_SOURCE"

STAGE=$(mktemp -d "$TARGET_DIR/.net-view-build.XXXXXX") || die "could not create a staging directory beside $TARGET"
trap 'rm -rf "$STAGE"' EXIT INT TERM

# libcrypt is a separate library on glibc and part of libSystem on macOS
CRYPT_LIB=""
printf 'int main(void){return 0;}\n' > "$STAGE/crypt-probe.c"
"$CC_PATH" "$STAGE/crypt-probe.c" -lcrypt -o "$STAGE/crypt-probe" > /dev/null 2>&1 && CRYPT_LIB="-lcrypt"

echo "net-view-build: generating C from net_view.rb"
"$SPINEL" "$HERE/net_view.rb" --cc="$CC_PATH" -c --no-line-map -o "$STAGE/net_view.c" ||
  die "spinel could not generate C from net_view.rb"
# shellcheck disable=SC2086
"$CC_PATH" -O2 -Wall -Wextra -c $SDL2_CFLAGS "$ROOT/examples/doom/native/sp_sdl_shim.c" -o "$STAGE/sp_sdl_shim.o" ||
  die "could not compile native/sp_sdl_shim.c"
"$CC_PATH" -O2 -Wall -Wextra -c "$HERE/sp_udp_shim.c" -o "$STAGE/sp_udp_shim.o" ||
  die "could not compile sp_udp_shim.c"
# shellcheck disable=SC2086
"$CC_PATH" -O2 -Wall -Wextra -c $SDL2_CFLAGS "$HERE/sp_focus_shim.c" -o "$STAGE/sp_focus_shim.o" ||
  die "could not compile sp_focus_shim.c"
xlibs=$(sed -n 's|^/\* SPINEL_LINK: \(.*\) \*/$|\1|p' "$STAGE/net_view.c" | tr '\n' ' ')
# -Wno-all on the generated C only, as examples/doom/build.sh does
# shellcheck disable=SC2086
"$CC_PATH" -O2 -Wno-all -Wno-unknown-warning-option -I"$SPINEL_LIB" "$STAGE/net_view.c" \
  "$STAGE/sp_sdl_shim.o" "$STAGE/sp_udp_shim.o" "$STAGE/sp_focus_shim.o" "$SPINEL_LIB/libspinel_rt.a" $xlibs $SDL2_LIBS -lm $CRYPT_LIB \
  -o "$STAGE/net_view.bin" || die "could not link the viewer"
mv "$STAGE/net_view.bin" "$TARGET" || die "could not publish $TARGET"
echo "net-view-build: built $TARGET"
