#!/bin/sh
# Decision 0026 steps 1 and 5: SubsetRefusals.cpp and SubsetTables.cpp against
# their pin; no build.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "${RUBY:-ruby}" "$HERE/check.rb"
