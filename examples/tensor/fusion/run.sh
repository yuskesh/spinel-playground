#!/bin/sh
# examples/tensor/fusion -- runs on both devices. The expected values are in README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build
[ -x "$OUT/app" ] || { echo "run $HERE/build.sh first" >&2; exit 1; }

# The metal device has **a run-time driver only on macOS**
# (compiling works on Linux too: iree-compile's metal-spirv runs).
# Naming the devices explicitly still runs any device as before. The Darwin default is unchanged.
if [ "$(uname -s)" = Darwin ]; then DEFAULT_DEVS="local-sync metal"; else DEFAULT_DEVS="local-sync"; fi
for d in ${*:-$DEFAULT_DEVS}; do
  case $d in
    metal) vmfb=$OUT/fusion_metal.vmfb ;;
    cuda)  vmfb=$OUT/fusion_cuda.vmfb ;;
    *)     vmfb=$OUT/fusion_cpu.vmfb ;;
  esac
  "$OUT/app" "$d" "$vmfb"
  echo
done
