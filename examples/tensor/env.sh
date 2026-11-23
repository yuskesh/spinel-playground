#!/bin/sh
# examples/tensor/env.sh -- the toolchain the three tensor examples share.
#
# Each example's build.sh reads it with `. "$HERE/../env.sh"`. It decides only
# where things are; what is built is the example's own business.
#
# Required from the caller (absolute paths):
#   IREE_SRC      the IREE runtime source tree
#   IREE_BUILD    its runtime-only build tree
#   IREE_COMPILE  the iree-compile executable, from the same IREE commit
# See docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md.
#
# An unset one fails loudly; no other toolchain is picked up silently. A .vmfb
# is a versioned format, and a compiler and runtime from different commits
# break in a way that shows only at run time.
TENSOR_DIR=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$TENSOR_DIR/../.." && pwd)

SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
# The tensor front: the native importer, then one .vmfb per backend. It stands
# in for spinel-llvm's `spinel-mlirgen --tensor`; see tools/tensor/spinel-tensor.
MLIRGEN=${MLIRGEN:-$ROOT/tools/tensor/spinel-tensor}
SHIM=$ROOT/tools/tensor/sp_tensor_shim.c
SURFACE=$ROOT/tools/tensor/spinel/tensor.rb
CC=${CC:-cc}

# An optional file for local defaults (gitignored): three lines of
# `IREE_SRC=... export IREE_SRC` saves exporting them each time.
[ -f "$TENSOR_DIR/iree.env" ] && . "$TENSOR_DIR/iree.env"

die() { echo "examples/tensor: $*" >&2; exit 1; }

need() {
  eval "v=\$$1"
  [ -n "$v" ] || die "\$$1 is not set; see docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md"
  [ -e "$v" ] || die "\$$1 = $v does not exist"
}

[ -x "$SPINEL" ] || die "spinel is not built: (cd $ROOT/vendor/spinel && make deps && make -j8)"
[ -x "$MLIRGEN" ] || die "no tensor front at $MLIRGEN"

need IREE_SRC
need IREE_BUILD
need IREE_COMPILE

# The IREE build configuration leaks into its headers: the shim TU has to be
# compiled with the same defines as the runtime, or iree_allocator_system() is
# not declared (E030 §1). Metal exists only on macOS, so the Metal flags and
# frameworks are Darwin-only; elsewhere the CPU path links without them.
IREE_METAL_CFLAGS="-DIREE_HAVE_HAL_METAL_DRIVER_MODULE=1"
IREE_CXX_LINK="--link -lc++"
IREE_METAL_LINK="--link -framework --link Metal --link -framework --link Foundation"
if [ "$(uname -s)" != Darwin ]; then
  IREE_METAL_CFLAGS=""
  IREE_METAL_LINK=""
  IREE_CXX_LINK="--link -lstdc++"
fi

IREE_CFLAGS="-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl \
-DIREE_HAVE_HAL_LOCAL_SYNC_DRIVER_MODULE=1 \
-DIREE_HAVE_HAL_LOCAL_TASK_DRIVER_MODULE=1 \
$IREE_METAL_CFLAGS \
-DIREE_HAVE_VMVX_MODULE \
-I$IREE_SRC/runtime/src -I$IREE_BUILD/runtime/src"

# libiree_runtime_unified.a is not link-closed: flatcc and printf live outside it.
IREE_LINK="--link $IREE_BUILD/runtime/src/iree/runtime/libiree_runtime_unified.a \
--link $IREE_BUILD/build_tools/third_party/flatcc/libflatcc_parsing.a \
--link $IREE_BUILD/build_tools/third_party/printf/libprintf_printf.a \
$IREE_METAL_LINK \
$IREE_CXX_LINK"
