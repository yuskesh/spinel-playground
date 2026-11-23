#!/bin/sh
# tools/npu/stm32mp2/build-iree.sh OUT -- builds IREE's runtime for the
# STM32MP257's Cortex-A35 under Linux: local-sync and static libraries only.
#
#   IREE_SRC             the IREE source tree (3.11.0)
#   IREE_HOST_BIN_DIR    the host tools of an IREE build
#   STM32MP2_CROSS       the cross tools' prefix, ending in the target name and "-"
#   STM32MP2_SYSROOT     the target's sysroot
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ $# -eq 1 ] || { echo "usage: build-iree.sh OUT" >&2; exit 2; }
PATH=$(dirname -- "$STM32MP2_CROSS"):$PATH
export PATH
cmake -G Ninja -S "$IREE_SRC" -B "$1" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$HERE/toolchain.cmake" \
  -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
  -DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_TESTS=OFF -DIREE_BUILD_SAMPLES=OFF \
  -DIREE_BUILD_BINDINGS_TFLITE=OFF -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF \
  -DIREE_ENABLE_WERROR_FLAG=OFF -DIREE_ENABLE_CPUINFO=OFF \
  -DIREE_HAL_DRIVER_DEFAULTS=OFF -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
  -DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF -DIREE_HAL_EXECUTABLE_PLUGIN_DEFAULTS=OFF \
  -DIREE_HOST_BIN_DIR="$IREE_HOST_BIN_DIR"
cmake --build "$1" --target iree_runtime_unified iree_hal_local_loaders_static_library_loader iree_hal_drivers_local_sync_sync_driver
