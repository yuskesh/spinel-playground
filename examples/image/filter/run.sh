#!/bin/sh
# examples/image/filter -- runs 4K on both devices x 2 tails. The expected values are in README.md.
#
#   ./run.sh                # local-sync and metal, thr and gain
#   ./run.sh local-sync     # one device only
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
OUT=$HERE/build
[ -x "$OUT/app" ] || { echo "run $HERE/build.sh first" >&2; exit 1; }

IN=${IN:-$IMG/uhd.pgm}
[ -f "$IN" ] || { echo "$IN is missing; $HERE/build.sh runs mkimages.rb to make it" >&2; exit 1; }

# Metal only on macOS, as the tensor examples choose
if [ "$(uname -s)" = Darwin ]; then DEFAULT_DEVS="local-sync metal"; else DEFAULT_DEVS="local-sync"; fi
for d in ${*:-$DEFAULT_DEVS}; do
  case $d in
    metal) vmfb=$OUT/filter_metal.vmfb ;;
    cuda)  vmfb=$OUT/filter_cuda.vmfb ;;
    *)     vmfb=$OUT/filter_cpu.vmfb ;;
  esac
  "$OUT/app" "$d" "$vmfb" "$IN" thr  50.0 "$OUT/out_thr_$d.pgm"
  echo
  "$OUT/app" "$d" "$vmfb" "$IN" gain 0.25 "$OUT/out_gain_$d.pgm"
  echo
done
