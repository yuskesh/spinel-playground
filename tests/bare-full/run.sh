#!/bin/sh
#
# tests/bare-full/run.sh -- full, the hosted runtime with its collector, on a
# Cortex-M33 with no RTOS, under QEMU's mps2-an521.
#
#   sh tests/bare-full/run.sh
#
# The build, its programs and this lane live in spinel-modular, which this
# repository pins as the submodule vendor/spinel-modular. This file runs that
# repository's lane (vendor/spinel-modular/tests/bare-full/run.sh, which says
# what it checks and what it needs) with this repository's Spinel: SPINEL_DIR
# is set to vendor/spinel here unless the caller gave one, so that one Spinel
# checkout is built and both repositories' pins of it must name one commit.
#
# Exit status is the lane's: 0 passed, 1 failed, 2 skipped. Exit 2 also when
# the submodule is not checked out or the two pins of Spinel differ.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MOD="$REPO/vendor/spinel-modular"
if [ ! -f "$MOD/tests/bare-full/run.sh" ]; then
  echo "SKIP  bare-full: vendor/spinel-modular is not checked out (git submodule update --init vendor/spinel-modular)"
  exit 2
fi
if [ -z "${SPINEL_DIR:-}" ]; then
  ours=$(git -C "$REPO" ls-tree HEAD vendor/spinel | awk '{print $3}')
  theirs=$(git -C "$MOD" ls-tree HEAD vendor/spinel | awk '{print $3}')
  if [ -z "$ours" ] || [ "$ours" != "$theirs" ]; then
    echo "SKIP  bare-full: vendor/spinel is pinned at ${ours:-nothing} here and at ${theirs:-nothing} in vendor/spinel-modular; move the pins together"
    exit 2
  fi
  SPINEL_DIR="$REPO/vendor/spinel"
  export SPINEL_DIR
fi
exec sh "$MOD/tests/bare-full/run.sh"
