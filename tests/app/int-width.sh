#!/bin/sh
# Decision 0019: body width changes while the state-buffer ABI stays fixed.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "${RUBY:-ruby}" "$HERE/int-width.rb"
