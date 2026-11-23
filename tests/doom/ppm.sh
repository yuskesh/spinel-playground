#!/bin/sh
#
# tests/doom/ppm.sh — DOOM pictures and frames written as PPM images.
#
#   LLVM_PREFIX=... sh tests/doom/ppm.sh
#
#   WAD      the IWAD             default <root>/build/doom-wad/doom1.wad
#   SPINEL   the pinned compiler  default <root>/vendor/spinel/bin/spinel
#   RUBY     default ruby
#
# bin/dump_ppm.rb writes two WAD pictures (TITLEPIC, 320x200, and the status bar
# face STFST00, 24x29 with transparent pixels); bin/sim_demo.rb renders DEMO1
# to tic 399 and dumps that frame's 8-bit screen; bin/frame_ppm.rb writes it.
# Each file must be a valid binary PPM: a P6 header with the picture's own
# width and height and maxval 255, followed by exactly width*height*3 bytes.
# The pictures are for looking at; nothing here compares them with another
# implementation. Exit 0 on success, 1 on a failure, 2 without an IWAD.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPINEL="${SPINEL:-$REPO/vendor/spinel/bin/spinel}"
WAD="${WAD:-$REPO/build/doom-wad/doom1.wad}"
RUBY="${RUBY:-ruby}"
[ -f "$WAD" ] || { echo "---- ppm: SKIP (no IWAD at $WAD; tools/doom/fetch-iwad.sh)"; exit 2; }
[ -x "$SPINEL" ] || { echo "---- ppm: SKIP (build vendor/spinel first)"; exit 2; }
CCARG=""
[ -n "${LLVM_PREFIX:-}" ] && CCARG="--cc=$LLVM_PREFIX/bin/clang"

W=$(mktemp -d "${TMPDIR:-/tmp}/doom-ppm.XXXXXX")
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

for p in dump_ppm frame_ppm sim_demo; do
  # shellcheck disable=SC2086
  if "$SPINEL" "$REPO/examples/doom/bin/$p.rb" $CCARG -o "$W/$p" >"$W/$p.log" 2>&1; then
    ok "bin/$p.rb builds"
  else
    bad "bin/$p.rb builds"; tail -5 "$W/$p.log" | sed 's/^/      /'
  fi
done

# ppm <file> <width> <height>: a P6 header naming exactly this size, then the pixels
ppm() {
  "$RUBY" -e 'd = File.binread(ARGV[0]); w = ARGV[1].to_i; h = ARGV[2].to_i
    m = d.match(/\AP6\s+(\d+)\s+(\d+)\s+(\d+)\s/n) or abort "no P6 header"
    abort "header #{m[1]}x#{m[2]}, expected #{w}x#{h}" unless [m[1].to_i, m[2].to_i] == [w, h]
    abort "maxval #{m[3]}" unless m[3] == "255"
    n = d.bytesize - m[0].bytesize
    abort "#{n} pixel bytes, expected #{w * h * 3}" unless n == w * h * 3' "$1" "$2" "$3"
}

if "$W/dump_ppm" "$WAD" "$W" TITLEPIC STFST00 >"$W/dump.log" 2>&1; then
  ok "dump_ppm writes TITLEPIC and STFST00"
  for c in "TITLEPIC 320 200" "STFST00 24 29"; do
    set -- $c
    if e=$(ppm "$W/$1.ppm" "$2" "$3" 2>&1); then ok "$1.ppm is a valid ${2}x${3} PPM"; else bad "$1.ppm: $e"; fi
  done
else
  bad "dump_ppm"; sed 's/^/      /' "$W/dump.log"
fi

mkdir -p "$W/sim"
if "$W/sim_demo" "$WAD" DEMO1 400 "$W/sim" frame 35 399 >"$W/sim.log" 2>&1 &&
   "$W/frame_ppm" "$WAD" "$W/sim/frame_399.bin" 320 200 "$W/frame.ppm" >"$W/frame.log" 2>&1; then
  ok "sim_demo dumps DEMO1's tic 399 and frame_ppm writes it"
  if e=$(ppm "$W/frame.ppm" 320 200 2>&1); then ok "the frame is a valid 320x200 PPM"; else bad "frame: $e"; fi
else
  bad "the frame"; cat "$W/sim.log" "$W/frame.log" 2>/dev/null | tail -5 | sed 's/^/      /'
fi
head -c 100 "$W/sim/frame_399.bin" > "$W/short.bin" 2>/dev/null
if "$W/frame_ppm" "$WAD" "$W/short.bin" 320 200 "$W/short.ppm" >"$W/short.log" 2>&1; then
  bad "frame_ppm accepted a 100-byte frame as 320x200"
else
  ok "frame_ppm refuses a frame of the wrong size"
fi

echo "---- ppm: $pass passed, $fail failed"
[ "$fail" = 0 ]
