#!/bin/sh
# tools/npu/build-iree-m33.sh OUT -- builds IREE's runtime for the Cortex-M33:
# local-sync, static libraries only, no threads.
#
#   IREE_SRC                 the IREE source tree (3.11.0)
#   IREE_HOST_BIN_DIR        the host tools of an IREE build
#   ZEPHYR_SDK_INSTALL_DIR   the Zephyr SDK
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ $# -eq 1 ] || { echo "usage: build-iree-m33.sh OUT" >&2; exit 2; }
cmake -G Ninja -S "$IREE_SRC" -B "$1" -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_TOOLCHAIN_FILE="$HERE/m33.cmake" \
  -DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_TESTS=OFF -DIREE_BUILD_SAMPLES=OFF \
  -DIREE_BUILD_BINDINGS_TFLITE=OFF -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF \
  -DIREE_ENABLE_THREADING=OFF -DIREE_SYNCHRONIZATION_DISABLE_UNSAFE=ON \
  -DIREE_ENABLE_POSITION_INDEPENDENT_CODE=OFF -DIREE_ENABLE_WERROR_FLAG=OFF \
  -DIREE_ENABLE_CPUINFO=OFF -DIREE_HAL_DRIVER_DEFAULTS=OFF -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
  -DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF -DIREE_HAL_EXECUTABLE_PLUGIN_DEFAULTS=OFF \
  -DIREE_HOST_BIN_DIR="$IREE_HOST_BIN_DIR"
cmake --build "$1" --target iree_runtime_unified iree_hal_local_loaders_static_library_loader iree_hal_drivers_local_sync_sync_driver
