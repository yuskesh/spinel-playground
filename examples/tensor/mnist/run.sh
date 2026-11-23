#!/bin/sh
# examples/tensor/mnist -- fetches the MNIST test set and classifies it on both devices.
#
#   ./run.sh                     # local-sync and metal, 10000 images
#   ./run.sh local-sync          # one only
#   N=1000 ./run.sh              # a different number of images
#
# The data (~11 MB) is **not in the repository**. It is fetched here, its sha256
# checked, and cached in build/mnist/. It comes from the ossci-datasets mirror, not
# LeCun's site, and the sha256 values match the canonical ones.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build
M=$OUT/mnist
N=${N:-10000}
BATCH=${BATCH:-100}
BASE=https://ossci-datasets.s3.amazonaws.com/mnist

[ -x "$OUT/app" ] || { echo "run $HERE/build.sh first" >&2; exit 1; }
mkdir -p "$M"

fetch() { # fetch <name> <sha256>
  f=$M/$1
  if [ ! -f "$f" ]; then
    [ -f "$f.gz" ] || curl -sSfL -o "$f.gz" "$BASE/$1.gz"
    got=$(shasum -a 256 "$f.gz" | cut -d' ' -f1)
    if [ "$got" != "$2" ]; then
      rm -f "$f.gz"
      echo "mnist: the sha256 of $1.gz differs: $got (expected $2)" >&2
      exit 1
    fi
    gunzip -kf "$f.gz"
  fi
}

fetch t10k-images-idx3-ubyte \
      8d422c7b0a1c1c79245a5bcf07fe86e33eeafee792b84584aec276f5a2dbc4e6
fetch t10k-labels-idx1-ubyte \
      f7ae60f92e00ec6debd23a6088c31dbd2371eca3ffa0defaefb259924204aec6

# The metal device has **a run-time driver only on macOS**
# (compiling works on Linux too: iree-compile's metal-spirv runs).
# Naming the devices explicitly still runs any device as before. The Darwin default is unchanged.
if [ "$(uname -s)" = Darwin ]; then DEFAULT_DEVS="local-sync metal"; else DEFAULT_DEVS="local-sync"; fi
for d in ${*:-$DEFAULT_DEVS}; do
  case $d in
    metal) sfx=metal ;;
    cuda)  sfx=cuda ;;
    *)     sfx=cpu ;;
  esac
  "$OUT/app" "$d" "$OUT/mnist_mlp_$sfx.vmfb" "$OUT/mnist_scale_$sfx.vmfb" \
      "$M/t10k-images-idx3-ubyte" "$M/t10k-labels-idx1-ubyte" "$N" "$BATCH"
  echo
done
