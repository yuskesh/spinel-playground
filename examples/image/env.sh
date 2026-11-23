#!/bin/sh
# examples/image/env.sh -- the toolchain the two image examples share.
#
# The same role and variables as examples/tensor/env.sh, with two differences:
#   * iree.env is looked for in BOTH examples/image/ and examples/tensor/. The
#     prerequisites are identical (the same IREE runtime and iree-compile), so
#     whoever ran the tensor examples first need not write them again.
#   * it names the shared image directory IMG, where mkimages.rb writes. A 4K
#     PGM is 8.3 MB, and both examples use the same ones.
#
# Required from the caller (absolute paths): IREE_SRC, IREE_BUILD and
# IREE_COMPILE, as in docs/toolchains/iree-3.11.0/INSTALLATION-RECORD.md.
IMAGE_DIR=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$IMAGE_DIR/../.." && pwd)

SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
# The tensor front: the native importer, then one .vmfb per backend.
MLIRGEN=${MLIRGEN:-$ROOT/tools/tensor/spinel-tensor}
SHIM=$ROOT/tools/tensor/sp_tensor_shim.c
SURFACE=$ROOT/tools/tensor/spinel/tensor.rb
MKIMAGES=$IMAGE_DIR/mkimages.rb
IMG=${IMG:-$IMAGE_DIR/img}
CC=${CC:-cc}

# Optional local defaults (both gitignored). If the tensor examples already
# run here, examples/tensor/iree.env applies as it is.
[ -f "$IMAGE_DIR/iree.env" ] && . "$IMAGE_DIR/iree.env"
[ -f "$IMAGE_DIR/../tensor/iree.env" ] && . "$IMAGE_DIR/../tensor/iree.env"

die() { echo "examples/image: $*" >&2; exit 1; }

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
# not declared (E030 §1).
# Metal exists only on macOS, as in examples/tensor/env.sh: elsewhere the CPU
# path compiles and links without the Metal driver and frameworks.
IREE_METAL_CFLAGS="-DIREE_HAVE_HAL_METAL_DRIVER_MODULE=1"
IREE_METAL_LINK="--link -framework --link Metal --link -framework --link Foundation"
IREE_CXX_LINK="--link -lc++"
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

# The images are shared by both examples, and the 4K ones are not remade each
# time: mkimages.rb looks at the sizes already there.
mkimages() {
  mkdir -p "$IMG"
  ruby "$MKIMAGES" "$IMG"
}
