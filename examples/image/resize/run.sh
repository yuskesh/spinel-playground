#!/bin/sh
# examples/image/resize -- the 3 shrinks on both devices. The expected values are in README.md.
#
#   ./run.sh                # local-sync and metal
#   ./run.sh local-sync     # one only
#
# The 3 output sizes are 3 regimes as they are:
#
#   1920x1080  exactly half of 4K. Every weight is 0.5 = a 2x2 box average, exact.
#              The **real work**, and the regime with the most ties. It runs on 4 images
#              because the share of ties depends on the **image**, not the resolution.
#   1620x911   ratios that do not divide (2.370... and 2.371...). **Only here** does the
#              output differ from the reference, and it checks the difference is explained by contraction (FMA).
#   1280x720   exactly 1/3. The weights degenerate to (1.0, 0.0), so it is bilinear but in
#              effect point sampling, and exact again. A control showing it is not "safe for
#              integer ratios" but **"safe when the weights are exact in f32"**.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"
OUT=$HERE/build
[ -x "$OUT/app" ] || { echo "run $HERE/build.sh first" >&2; exit 1; }

TAB=$(printf '\t')

# Metal only on macOS, as the tensor examples choose
if [ "$(uname -s)" = Darwin ]; then DEFAULT_DEVS="local-sync metal"; else DEFAULT_DEVS="local-sync"; fi
for d in ${*:-$DEFAULT_DEVS}; do
  case $d in
    metal) vmfb=$OUT/resize_metal.vmfb ;;
    cuda)  vmfb=$OUT/resize_cuda.vmfb ;;
    *)     vmfb=$OUT/resize_cpu.vmfb ;;
  esac
  echo "### $d -- 4K -> 1080p (dyadic, 4 images)"
  "$OUT/app" "$d" "$vmfb" 1080 1920 "$OUT" \
      "$IMG/uhd.pgm" "$IMG/uhd_r005.pgm" "$IMG/uhd_ramp.pgm" "$IMG/uhd_flat.pgm" \
      | column -t -s"$TAB"
  echo
  echo "### $d -- 4K -> 1620x911 (not dyadic) and 4K -> 720p (1/3, degenerate weights)"
  "$OUT/app" "$d" "$vmfb" 911 1620 "$OUT" "$IMG/uhd.pgm" | column -t -s"$TAB"
  "$OUT/app" "$d" "$vmfb" 720 1280 "$OUT" "$IMG/uhd.pgm" | column -t -s"$TAB"
  echo
done
