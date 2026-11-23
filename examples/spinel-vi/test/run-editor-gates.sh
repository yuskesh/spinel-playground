#!/usr/bin/env bash
# E102: the normalized fake trace is primary; a real PTY only checks that one
# key reaches the editor and termbox2 restores termios.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd -- "$HERE/.." && pwd)
ROOT=$(cd -- "$APP/../.." && pwd)
BUILD="$APP/build/e102-gates"
mkdir -p "$BUILD"

"$ROOT/vendor/spinel/bin/spinel" "$APP/editor.rb" -o "$BUILD/editor"
"$BUILD/editor" --fake-trace > "$BUILD/fake.out"
actual=$(shasum -a 256 "$BUILD/fake.out" | awk '{print $1}')
expected=$(tr -d '\n' < "$HERE/editor_fake.expected.sha256")
test "$actual" = "$expected"
grep -F $'event\t2\tU+0000\t0\t0\t12\t5' "$BUILD/fake.out" >/dev/null
grep -F $'event\t1\tU+0069\t0\t0\t0\t0' "$BUILD/fake.out" >/dev/null
grep -F $'event\t1\tU+006F\t0\t0\t0\t0' "$BUILD/fake.out" >/dev/null
grep -F 'shutdown' "$BUILD/fake.out" >/dev/null
printf 'PASS\tfake_event_screen_golden\t21 events, resize, modes, h/j/k/l/i/a/o/Esc/x, command line, normalized screen hash\n'

# Fake keeps an explicit deterministic 80x24 initial geometry.  editor.rb
# reads the seam after init rather than constructing a fixed-size Editor.
"$BUILD/editor" --fake-size-trace > "$BUILD/size.out"
grep -F 'initial-size=80x24' "$BUILD/size.out" >/dev/null
printf 'PASS\tinitial_terminal_dimensions\tfake initial 80x24 comes from terminal seam before first frame\n'

perl "$HERE/pty-gate.pl" "$BUILD/real.typescript" "$BUILD/editor" \
  "$BUILD/real.out" basic --event-limit=1 1
grep -a -F 'TERM_RESTORED' "$BUILD/real.out" >/dev/null
printf 'PASS\treal_pty_one_key\ttermbox2 receives one key and restores termios\n'
