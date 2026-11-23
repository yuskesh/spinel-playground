#!/bin/sh
#
# tests/doom-core/session-image.sh — tools/doom/session-image.rb on a session it can be checked against.
#
#   sh tests/doom-core/session-image.sh DIR
#
# Decision 0021's image, from a synthetic session written here: a schema of
# three fields (a resource holding a small IWAD, a writable buffer and a
# core_state slot), the entries' field map naming them, and the snapshot of
# their values. Nothing is built and no WAD is read from disk, so the lane
# runs in seconds; tests/doom-core/bound-resources.sh writes the image of a
# real session and plays DEMO1 over it.
#
# WHAT IT CHECKS
#   * the image's parts: the resource at an offset that is a multiple of 8,
#     the slot first in writable.bin, the writable buffer after it, each
#     file's bytes the snapshot's, and image.sha256 accepted by sha256sum -c
#   * --demo finds the lump through the WAD's own directory and records its
#     offset inside renderer_wad_data and its tics
#   * a lump that breaks examples/doom/lib/doom/demo.rb's rules is refused by
#     name: another version, a second player, no DEMOMARKER; and a lump the
#     WAD does not hold
#   * control: the same lump intact is accepted, so each refusal is its fault
#   * an i64 cell the entries are handed must fit i32: the slot at 2**31-1
#     and -2**31 is accepted, at 2**31 and -2**31-1 refused by name
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: session-image.sh DIR}
RUBY=${RUBY:-ruby}
TOOL=$ROOT/tools/doom/session-image.rb
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
mkdir -p "$DIR" || exit 2

# The session: a WAD of five lumps -- DEMO1 intact (3 tics), and DEMOV, DEMOP
# and DEMOM, each one rule broken -- then a 3-element u16 buffer and a slot.
"$RUBY" -e '
  dir = ARGV[0]
  header = ->(version, players) { [version, 2, 1, 1, 0, 0, 0, 0, 0] + players }
  tics = [[25, 0, 0, 0], [50, 0xf6, 1, 1], [0x81, 3, 0xff, 0]]
  demo = ->(version: 109, players: [1, 0, 0, 0], marker: true) {
    (header.(version, players) + tics.flatten + (marker ? [0x80] : [])).pack("C*")
  }
  lumps = { "DEMO1" => demo.(), "DEMOV" => demo.(version: 108), "DEMOP" => demo.(players: [1, 1, 0, 0]),
            "DEMOM" => demo.(marker: false), "PAD" => "x" * 5 }
  body = +"".b
  entries = lumps.map { |n, d| e = [12 + body.bytesize, d.bytesize, n]; body << d; e }
  wad = ["IWAD", lumps.size, 12 + body.bytesize].pack("a4l<l<") + body
  wad << entries.map { |pos, size, n| [pos, size, n].pack("l<l<a8") }.join
  File.write(File.join(dir, "state.tsv"), <<~TSV)
    #name\trole\telement\tcount\tinitial\torigin\twriters
    game_pad\tpersistent\ti64\tfixed:1\t0\tadded:pad\te
    renderer_wad_data\tresource\tu8\tfixed:#{wad.bytesize}\t0\tRenderer@@wad_data\t-
    some_buffer\tpersistent\tu16\tfixed:3\t0\tadded:buffer\te
  TSV
  File.write(File.join(dir, "fields.tsv"), "#entry\tparam\tfield\telement\tmode\ne\tstate\tcore_state\ti64\tinout\ne\tw\trenderer_wad_data\tu8\tin\ne\tb\tsome_buffer\tu16\tinout\n")
  File.write(File.join(dir, "catalog.tsv"), "")
  File.binwrite(File.join(dir, "snapshot.bin"), [-7].pack("q<") + wad + [1, 2, 3].pack("S<*"))
  File.write(File.join(dir, "demo1.offset"), entries.first[0].to_s)
' "$DIR"
img() { # out [--demo NAME] -> exit status; output in out.out
  o=$1; shift
  rm -rf "$DIR/$o"
  "$RUBY" "$TOOL" --schema "$DIR/state.tsv" --fields "$DIR/fields.tsv" --catalog "$DIR/catalog.tsv" \
    --snapshot "${SNAP:-$DIR/snapshot.bin}" --out "$DIR/$o" "$@" > "$DIR/$o.out" 2>&1
  echo $?
}

echo "== the image's parts =="
ok "the image is written with DEMO1 recorded" "$(img plain --demo DEMO1)" 0
I=$DIR/plain
ok "  image.tsv places each field: the slot, the resource at 0, the buffer after the slot" \
   "$(grep -v '^#' "$I/image.tsv" | cut -f1,5,6 | tr '\t' ':' | tr '\n' ' ')" \
   "game_pad:core_state:0 renderer_wad_data:resource:0 some_buffer:writable:8 "
ok "  writable.bin is the slot's -7 then the buffer's 1, 2, 3" \
   "$("$RUBY" -e 'b = File.binread(ARGV[0]); puts [b[0, 8].unpack1("q<"), *b[8, 6].unpack("S<*")].join(",")' "$I/writable.bin")" "-7,1,2,3"
ok "  resources.bin is the WAD, byte for byte" \
   "$("$RUBY" -e 'w = File.binread(ARGV[0]).byteslice(8, File.size(ARGV[1])); puts w == File.binread(ARGV[1]) ? "same" : "differs"' "$DIR/snapshot.bin" "$I/resources.bin")" same
ok "  sha256sum -c accepts image.sha256" "$(cd "$I" && sha256sum -c image.sha256 2>&1 | grep -c ': OK$')" 3

echo "== an i64 cell past i32 (decisions 0019 and 0022) =="
# the slot, planted: the entries load it at 32 bits on the board
slot() { # value name -> the snapshot with the slot set to value
  "$RUBY" -e 'b = File.binread(ARGV[0]); File.binwrite(ARGV[2], [Integer(ARGV[1])].pack("q<") + b.byteslice(8..))' \
    "$DIR/snapshot.bin" "$1" "$DIR/snap-$2.bin"
  echo "$DIR/snap-$2.bin"
}
ok "a slot of 2147483647 is accepted" "$(SNAP=$(slot 2147483647 hi) img edge-hi)" 0
ok "a slot of -2147483648 is accepted" "$(SNAP=$(slot -2147483648 lo) img edge-lo)" 0
ok "a slot of 2147483648 is refused by name" \
   "$(SNAP=$(slot 2147483648 over) img over):$(grep -c 'game_pad\[0\] is 2147483648, outside i32' "$DIR/over.out")" "1:1"
ok "a slot of -2147483649 is refused by name" \
   "$(SNAP=$(slot -2147483649 under) img under):$(grep -c 'game_pad\[0\] is -2147483649, outside i32' "$DIR/under.out")" "1:1"

echo "== the demo lump =="
ok "DEMO1: its offset inside renderer_wad_data and its 3 tics" \
   "$(grep '^#demo' "$I/image.tsv" | tr '\t' '|')" "#demo|DEMO1|offset $(cat "$DIR/demo1.offset")|tics 3"
ok "control: without --demo there is no #demo line" "$(img nodemo):$(grep -c '^#demo' "$DIR/nodemo/image.tsv")" "0:0"
ok "another version is refused by name" \
   "$(img v --demo DEMOV):$(grep -c 'DEMOV: demo version 108 is not 109 (DOOM 1.9)' "$DIR/v.out")" "1:1"
ok "a second player is refused by name" \
   "$(img p --demo DEMOP):$(grep -c 'DEMOP: only single player demos are supported' "$DIR/p.out")" "1:1"
ok "a lump with no DEMOMARKER is refused by name" \
   "$(img m --demo DEMOM):$(grep -c 'DEMOM: no DEMOMARKER (0x80)' "$DIR/m.out")" "1:1"
ok "a lump the WAD does not hold is refused by name" \
   "$(img n --demo DEMO9):$(grep -c 'demo lump not found: DEMO9' "$DIR/n.out")" "1:1"
ok "and a refused image writes nothing" "$([ -e "$DIR/v/image.tsv" ] && echo written || echo none)" none

echo "session-image: $((pass + fail)) checked, $pass pass, $fail fail; $(( $(date +%s) - T0 )) s"
[ "$fail" -eq 0 ]
