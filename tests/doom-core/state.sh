#!/bin/sh
#
# tests/doom-core/state.sh — decision 0008 task 5's state schema.
#
# The schema enumerates every field CORE's resident storage holds, and the
# generator's job is to refuse everything it cannot vouch for before anything
# is allocated. Each refusal is checked by ITS OWN category and origin, never
# by the exit status: the generator exits 1 for all of them.
#
# The generated artifacts are checked for what they have to be, not merely for
# existing: the scalar slots are contiguous indices into one buffer, each array
# keeps its own allocation, and the snapshot is schema-ordered, fixed-width and
# free of scratch.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/doom-core/fixtures/state"
GEN="${GEN:-$ROOT/tools/doom/state-schema.rb}"
RUBY="${RUBY:-ruby}"

die() { echo "state: $*" >&2; exit 1; }
[ -f "$GEN" ] || die "no generator at $GEN"
[ -d "$FIX" ] || die "no fixtures at $FIX"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"

TAB=$(printf "\\t")
W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-state.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skip=0; skips=""
# A RUN STATES WHAT IT COVERED, not only that what it ran passed. A pass count
# is a function of the environment: this suite printed 251 without a compiler
# and 270 with one, and nothing in either said which lanes the smaller run
# left out. Every skipped lane is counted, named in the summary with what would
# enable it, and REQUIRE_ALL=1 turns any of them into a failure.
skipped() { # lane, reason, what enables it
  echo "  SKIP $1: $2 ($3)" >&2
  skip=$((skip + 1))
  skips="$skips
state: skipped $1: $2; enable with $3"
}
summary() {
  echo "state: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped$skips"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then
    echo "state: REQUIRE_ALL=1, and $skip lane(s) did not run" >&2
    exit 1
  fi
  [ "$fail" -eq 0 ] || exit 1
  exit 0
}
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | head -5; fail=$((fail + 1)); fi; }
reject() { if grep -qE "$3" "$2"; then echo "  FAIL $1 (the wrong answer is present)"; fail=$((fail + 1));
           else echo "  pass $1"; pass=$((pass + 1)); fi; }

run() { # stem outdir
  mkdir -p "$W/$2"
  "$RUBY" "$GEN" --schema "$FIX/$1.schema.tsv" --access "$FIX/$1.access.tsv" \
    --catalog "$FIX/catalog.tsv" --output "$W/$2" > "$W/$1.err" 2>&1 \
    && echo 0 > "$W/$1.rc" || echo $? > "$W/$1.rc"
}

echo "== a schema the generator can vouch for =="
run ok out
ok "it generates" "$(cat "$W/ok.rc")" 0
want "and says what it made" "$W/ok.err" '7 field\(s\), 2 scalar slot\(s\), 5 array buffer\(s\)'

echo "== the scalar slots are one buffer, not several =="
# A scalar field is one i64; giving each its own allocation would be one
# allocation per counter. They share `core_state` with generated indices --
# a data layout, not a new object and not a pointer.
want "the slots are generated constants"     "$W/out/slots.rb" '^    PRNDINDEX = 0$'
want "contiguous from zero"                  "$W/out/slots.rb" '^    GAMETIC = 1$'
want "with their own count"                  "$W/out/slots.rb" '^    COUNT = 2$'
want "and one buffer holds them, prepared by Full" "$W/out/buffers.tsv" "^core_state${TAB}persistent${TAB}i64${TAB}2${TAB}prepared:core_state$"
reject "no scalar gets its own allocation"   "$W/out/buffers.tsv" "^prndindex${TAB}"
want "each slot keeps its index, initial and origin" "$W/out/slots.tsv" "^gametic${TAB}1${TAB}0${TAB}Game@gametic$"

echo "== each array keeps its own allocation =="
# 0007 disallows overlap involving an `inout` range, so two arrays sharing one
# allocation would be exactly the thing the gate refuses.
want "the level array is its own buffer"     "$W/out/buffers.tsv" "^sector_floorheight${TAB}persistent${TAB}i64${TAB}512${TAB}0$"
want "so is the framebuffer"                 "$W/out/buffers.tsv" "^framebuffer${TAB}output${TAB}u8${TAB}64000${TAB}0$"
want "and a prepared resource keeps its name" "$W/out/buffers.tsv" "^colormap${TAB}resource${TAB}u8${TAB}8704${TAB}prepared:colormap$"
ok "six allocations for six non-scalar fields plus the slot buffer" \
   "$(grep -vc '^#' "$W/out/buffers.tsv")" "6"

echo "== the snapshot is the game, not the allocator =="
want "it is schema-ordered from zero"        "$W/out/snapshot.tsv" "^colormap${TAB}u8${TAB}8704${TAB}8704${TAB}0$"
want "each offset follows the last"          "$W/out/snapshot.tsv" "^sintable${TAB}i64${TAB}8192${TAB}65536${TAB}8704$"
reject "scratch is not in it"                "$W/out/snapshot.tsv" '^clipbank'
want "and it carries its own total"          "$W/out/snapshot.tsv" "^#total${TAB}-${TAB}-${TAB}142352${TAB}-$"
# Every offset is the running sum of the bytes before it: no padding, and
# nothing skipped. Checked by recomputing rather than by reading the file back.
ok "every offset is the sum of what precedes it" \
   "$("$RUBY" -e '
       off = 0
       bad = 0
       File.foreach(ARGV[0]) do |ln|
         next if ln.start_with?("#")
         f = ln.chomp.split("\t")
         bad += 1 unless f[4].to_i == off
         off += f[3].to_i
       end
       print bad' "$W/out/snapshot.tsv")" "0"

echo "== what it refuses, by category and origin =="
refusal() { # stem pattern label
  run "$1" "bad-$1"
  ok "  $1 is refused" "$(cat "$W/$1.rc")" 1
  want "$3" "$W/$1.err" "$2"
}
refusal dup "duplicate-field: .*dup\.schema\.tsv:6: prndindex is listed twice, at line 5 and here" \
  "a field listed twice"
refusal unknown_count "unknown-count: .*: count .blocks:numsectors. is not fixed:NAME" \
  "a count kind the grammar does not have"
refusal unbound "unbound-count: .*: level:nosuchthing names nothing in the prepared catalog" \
  "a count naming nothing prepared"
refusal overflow "count-overflow: .*: huge is 9223372036854775807 x 8 bytes, which leaves u64" \
  "a count whose byte product leaves u64"
refusal bad_initial "bad-initial: .*: 999 is outside u8" \
  "an initial value outside its element"
refusal prep_len "prepared-length: .*: colormap is 8704 element\(s\) and sintable declares 8192" \
  "prepared data of the wrong length"
refusal res_fill "bad-initial: .*: colormap is a resource; CORE only reads it" \
  "a resource with an initial fill"
refusal bad_role "bad-role: .*: role .invented. is not one of" \
  "a role outside the four"
refusal bad_element "bad-element: .*: element .u7. is not one of" \
  "an element type outside the four"
refusal unknown_buf "unknown-buffer: .*: nosuchbuffer is not a field in the schema" \
  "an access row naming no field"
refusal dup_access "access: .*: doom_core_step lists colormap twice" \
  "a buffer listed twice for one entry"
refusal res_inout "overlap: .*: colormap is a resource and doom_core_step asks for inout" \
  "an entry asking to write a resource"
refusal out_in "overlap: .*: framebuffer is an output and doom_core_render asks for in" \
  "an entry asking to read an output"
# A SCALAR SHARES `core_state`. Both of these used to generate with exit 0 and
# open the slot at 0, the declared initial dropped, because `core_state` was
# one row with fill 0. Each slot's initial now reaches slots.tsv, and Full
# assembles the buffer from it -- tests/doom-core/core-state.rb is what shows
# the values land, and its neighbours stay put.
echo "== a scalar's own initial reaches the slot table =="
run scalar_fill scalar-fill
ok "a scalar slot with a nonzero fill generates" "$(cat "$W/scalar_fill.rc")" 0
want "and its -1 is in the slot table, not dropped" "$W/scalar-fill/slots.tsv" \
  "^prndindex${TAB}0${TAB}-1${TAB}Random@prndindex$"
want "while its neighbour keeps 0" "$W/scalar-fill/slots.tsv" "^gametic${TAB}1${TAB}0${TAB}Game@gametic$"
mkdir -p "$W/scalar-prep"
"$RUBY" "$GEN" --schema "$FIX/scalar_prep.schema.tsv" --access "$FIX/scalar_prep.access.tsv" \
  --catalog "$FIX/scalar_prep.catalog.tsv" --output "$W/scalar-prep" > "$W/scalar_prep.err" 2>&1 \
  && echo 0 > "$W/scalar_prep.rc" || echo $? > "$W/scalar_prep.rc"
ok "a scalar slot with prepared data generates" "$(cat "$W/scalar_prep.rc")" 0
want "and names its prepared data in the slot table" "$W/scalar-prep/slots.tsv" \
  "^gametic${TAB}1${TAB}prepared:gametic_start${TAB}Game@gametic$"
ok "and each fixture is one line away from ok" \
   "$(for s in scalar_fill scalar_prep; do diff "$FIX/ok.schema.tsv" "$FIX/$s.schema.tsv" | grep -c '^[<>]'; done | tr '\n' ' ')" "2 2 "
# `core_state` is the generator's name for the slot buffer; the schema may not take it.
sed 's/^gametic\t/core_state\t/' "$FIX/ok.schema.tsv" > "$W/clash.schema.tsv"
mkdir -p "$W/clash"
"$RUBY" "$GEN" --schema "$W/clash.schema.tsv" --access "$FIX/ok.access.tsv" \
  --catalog "$FIX/catalog.tsv" --output "$W/clash" > "$W/clash.err" 2>&1 || true
want "a field named core_state is refused" "$W/clash.err" \
  'duplicate-field: .*clash\.schema\.tsv:6: core_state uses the name core_state, which is the shared scalar buffer'

echo "== Full assembles core_state, slot by slot =="
"$RUBY" "$ROOT/tests/doom-core/core-state.rb" > "$W/core-state.out" 2>&1 || true
ok   "every slot holds its own initial and every malformed table is refused" \
     "$(tail -1 "$W/core-state.out")" "core-state: all pass"
want "a -1 fill is -1" "$W/core-state.out" '^pass a fill of -1 is -1, not 0$'
want "a prepared scalar is Full's eight bytes" "$W/core-state.out" '^pass a prepared scalar is the eight bytes Full has$'
want "neighbouring slots are untouched" "$W/core-state.out" '^pass and the slots beside them are untouched$'
# THE SESSION ENTRY, not only the generated form: a manifest from anywhere
# whose core_state is not persistent i64 prepared:core_state is refused before
# anything is allocated.
want "a u8 core_state is refused at open, before allocation" "$W/core-state.out" \
  '^pass a u8 core_state is refused before allocation$'
want "and so is the old zero-filled core_state" "$W/core-state.out" \
  '^pass the old zero-filled core_state is refused, not opened with -1 lost$'
want "while the generated form opens" "$W/core-state.out" \
  '^pass the generated form opens, and allocates once$'

echo "== nothing is replaced by a run that refuses =="
# The generator writes through a temporary in the destination and renames, so
# a refusal leaves the previous generation exactly as it was.
before=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/out/buffers.tsv")
"$RUBY" "$GEN" --schema "$FIX/dup.schema.tsv" --access "$FIX/dup.access.tsv" \
  --catalog "$FIX/catalog.tsv" --output "$W/out" > "$W/keep.err" 2>&1 || true
after=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/out/buffers.tsv")
ok "the previous generation is untouched" "$after" "$before"
want "and the run said why"               "$W/keep.err" 'duplicate-field:'

echo "== the same schema gives the same bytes =="
run ok out2
for f in slots.rb buffers.tsv snapshot.tsv; do
  if cmp -s "$W/out/$f" "$W/out2/$f"; then
    echo "  pass $f is byte-identical on a second run"; pass=$((pass + 1))
  else
    echo "  FAIL $f differs between runs"; fail=$((fail + 1))
  fi
done

echo "== the snapshot comparator says WHERE, not how many =="
# A comparator that printed a count of differing bytes would say two runs
# disagree without saying where; a canonical layout exists so that "where" is
# a field and an index rather than an offset into someone's struct.
CMP="$ROOT/tests/doom-core/compare-state.rb"
[ -f "$CMP" ] || die "no comparator at $CMP"
LAY="$W/out/snapshot.tsv"
"$RUBY" -e '
  total = 0
  File.foreach(ARGV[0]) { |ln| next if ln.start_with?("#"); total += ln.chomp.split("\t")[3].to_i }
  a = "\x00".b * total
  File.binwrite(ARGV[1], a)
  b = a.dup
  # sector_floorheight begins at 74240 and is i64; element 3 is 24 bytes in.
  b[74240 + 24, 8] = [42].pack("q<")
  File.binwrite(ARGV[2], b)
  File.binwrite(ARGV[3], a[0, total - 1])
  # An element that differs only in its high bits: a comparator reading the
  # wrong width would miss it.
  c = a.dup
  c[74240 + 24, 8] = [1 << 40].pack("q<")
  File.binwrite(ARGV[4], c)
' "$LAY" "$W/snap-a.bin" "$W/snap-b.bin" "$W/snap-short.bin" "$W/snap-high.bin"

cmp_run() { # label outfile args...
  lbl=$1; outf=$2; shift 2
  "$RUBY" "$CMP" --layout "$LAY" "$@" > "$outf" 2>&1 && echo 0 > "$outf.rc" || echo $? > "$outf.rc"
}
cmp_run equal "$W/cmp-eq.out" --a "$W/snap-a.bin" --b "$W/snap-a.bin"
ok   "two equal snapshots agree" "$(cat "$W/cmp-eq.out.rc")" 0
want "and it says what it compared" "$W/cmp-eq.out" '6 field\(s\), 142352 bytes, a and b agree'

cmp_run diff "$W/cmp-d.out" --a "$W/snap-a.bin" --b "$W/snap-b.bin" --label-a full --label-b core --tic 7
ok   "one differing element fails" "$(cat "$W/cmp-d.out.rc")" 1
want "naming the field, the index and the tic" "$W/cmp-d.out" \
  'value: sector_floorheight\[3\] at tic 7: full has 0 and core has 42 \(i64, byte 74264\)'

cmp_run high "$W/cmp-h.out" --a "$W/snap-a.bin" --b "$W/snap-high.bin"
ok   "a difference in the high bits is found too" "$(cat "$W/cmp-h.out.rc")" 1
want "with the whole i64 value"                   "$W/cmp-h.out" \
  'sector_floorheight\[3\]: a has 0 and b has 1099511627776'

cmp_run short "$W/cmp-s.out" --a "$W/snap-a.bin" --b "$W/snap-short.bin"
ok   "a snapshot of the wrong length is refused" "$(cat "$W/cmp-s.out.rc")" 1
want "by length, not by comparing what it has"    "$W/cmp-s.out" \
  'length: b .* is 142351 bytes and the layout describes 142352'

# A layout with a duplicate record, a gap, or a wrong total is refused before
# any byte is read: a layout with a gap would make every field after it compare
# the wrong bytes and still look plausible.
sed 's|^sintable|sector_floorheight|' "$LAY" > "$W/lay-dup.tsv"
"$RUBY" "$CMP" --layout "$W/lay-dup.tsv" --a "$W/snap-a.bin" --b "$W/snap-a.bin" > "$W/lay-dup.out" 2>&1 || true
want "a layout naming a field twice is refused" "$W/lay-dup.out" \
  'record: .*sector_floorheight appears twice in the layout'
"$RUBY" -e '
  out = []
  File.foreach(ARGV[0]) do |ln|
    if ln.start_with?("sintable\t")
      f = ln.chomp.split("\t"); f[4] = (f[4].to_i + 16).to_s; out << f.join("\t") + "\n"
    else out << ln end
  end
  File.write(ARGV[1], out.join)
' "$LAY" "$W/lay-gap.tsv"
"$RUBY" "$CMP" --layout "$W/lay-gap.tsv" --a "$W/snap-a.bin" --b "$W/snap-a.bin" > "$W/lay-gap.out" 2>&1 || true
want "and one with a gap is refused" "$W/lay-gap.out" \
  'layout: .*sintable begins at 8720 and the fields before it end at 8704'

# The audit produces the inventory the schema is emitted from, so this runs
# it rather than trusting a file someone left behind.
AUDIT="${AUDIT:-$ROOT/tools/doom/audit-core.rb}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp reader "$READER"
mkdir -p "$W/doom"
if [ -x "$READER" ]; then
  "$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
    --output "$W/doom" > "$W/doom.err" 2>&1 || true
fi
if [ ! -s "$W/doom/state-use.tsv" ]; then
  skipped "the emitted-schema lane and every lane after it" "no contract reader at $READER, so no audit" \
    "SPINEL_TYPEDUMP=/path/to/spinel-typedump"
  summary
fi
echo "== the catalog is a measurement of one configuration =="
# examples/doom/core/catalog.tsv is committed; examples/doom/core/full/
# resources.rb is what measures it. If the two ever disagree the committed
# file is stale, and this is what says so -- the numbers are not a table about
# DOOM in general, they are what one map at one resolution actually holds.
# The IWAD comes from WAD or from the checkout, and from nowhere else: a
# path outside the checkout would make these lanes depend on one host.
WADFILE="${WAD:-$ROOT/build/doom-wad/doom1.wad}"
if [ ! -f "$WADFILE" ]; then
  skipped "the catalog measurement" "no IWAD at $WADFILE" "WAD=/path/to/doom1.wad (tools/doom/fetch-iwad.sh gets one)"
else
  "$RUBY" -e '
    require_relative ARGV[0]
    require_relative ARGV[1]
    wad = Doom::Wad.new(ARGV[2])
    # The script is a configuration input like the map and the resolution, so
    # the KeyScript counts are measured from a real one rather than defaulted.
    require "tmpdir"
    sp = File.join(Dir.mktmpdir("cat-script"), "s.txt")
    File.write(sp, "0 10 forward\n")
    c = Doom::Core::Resources.catalog(wad: wad, map: "E1M1", width: 320, height: 200, script: sp)
    have = {}
    File.foreach(ARGV[3]) do |ln|
      next if ln.start_with?("#") || ln.strip.empty?
      f = ln.chomp.split("\t", -1)
      have[f[1]] = Integer(f[2], 10) if f[0] == "count"
    end
    bad = c.reject { |k, v| have[k] == v }
    puts "measured #{c.size}"
    if bad.empty?
      puts "agree yes"
    else
      puts "agree no " + bad.map { |k, v| "#{k}=#{v} committed=#{have[k].inspect}" }.join(" ")
    end
    # BOTH WAYS. This compared every MEASURED name against the committed file
    # and never asked whether the committed file held a name nobody measures.
    # Six did, and four of those numbers disagreed with the objects they
    # describe -- blockmapwords 5322 against 3461, sectorlinetotal 1710
    # against 642, switchnames 40 against 38, demobytes 160013 against
    # 160014 -- which is four of the shape refusals the reference lane
    # reports. They were not mis-mapped rows; they were hand-written numbers
    # that nothing compared with the game.
    puts "unmeasured " + (have.keys - c.keys).sort.join(",")
    puts "uncommitted " + (c.keys - have.keys).sort.join(",")
    # A different resolution must give different numbers, or the catalog is
    # not a function of the configuration at all.
    d = Doom::Core::Resources.catalog(wad: wad, map: "E1M1", width: 640, height: 400, script: sp)
    puts "doubled #{d["screenpixels"]} #{d["openings"]} #{d["numsectors"]}"
    begin
      Doom::Core::Resources.catalog(wad: wad, map: "E1M1", width: 500, height: 200)
      puts "badres NOT REFUSED"
    rescue => e
      puts "badres #{e.message}"
    end
  ' "$ROOT/examples/doom/core/full/resources" "$ROOT/examples/doom/lib/doom/wad" \
    "$WADFILE" "$ROOT/examples/doom/core/catalog.tsv" > "$W/res.out" 2>&1 || true
  res() { grep "^$1 " "$W/res.out" | head -1 | cut -d" " -f2-; }
  want "the committed catalog is what a measurement gives" "$W/res.out" '^agree yes$'
  # 63 until viewheight and viewpixels were measured (2026-09-17).
  ok   "and it measured every count"                       "$(res measured)" "65"
  # A NAME IN ONE AND NOT THE OTHER IS A NUMBER NOBODY CHECKED.
  ok   "every committed count is one the measurement makes" "$(res unmeasured)" ""
  ok   "and every measured count is committed"              "$(res uncommitted)" ""
  ok   "twice the width doubles the screen counts and not the map's" \
       "$(res doubled)" "256000 40960 85"
  want "a resolution DOOM's aspect refuses"                "$W/res.out" \
    '^badres width 500 must be 320\*s with s in 1\.\.8$'
fi

echo "== a session owns every buffer, once =="
# All allocation belongs to Full. A session allocates each declared buffer
# once, hands adapters their registry IDs, and releases each once.
SESS="$ROOT/examples/doom/core/full/session.rb"
[ -f "$SESS" ] || die "no session wrapper at $SESS"
"$RUBY" -e '
  require_relative ARGV[0]
  S = Doom::Core::Session
  rows = [
    {"name"=>"a","role"=>"persistent","element"=>"i64","count"=>4,"initial"=>"0"},
    {"name"=>"fb","role"=>"output","element"=>"u8","count"=>8,"initial"=>"0"},
    {"name"=>"res","role"=>"resource","element"=>"u8","count"=>3,"initial"=>"prepared:res"},
  ]
  say = ->(k, v) { puts "#{k} #{v}" }
  s1 = S.new(rows.map(&:dup), {"res" => "abc".b}, nil)
  s2 = S.new(rows.map(&:dup), {"res" => "abc".b}, nil)
  s1.id(:a).store[0] = 99
  say.("share", "#{s1.id(:a).store[0]} #{s2.id(:a).store[0]}")
  say.("bytes", s1.bytes_total)
  say.("released", s1.close.values.uniq.join(","))
  begin; s1.id(:a); rescue => e; say.("afterclose", e.message); end
  begin; s1.close; rescue => e; say.("doubleclose", e.message); end
  begin; S.new(rows.map(&:dup), {}, nil); rescue => e; say.("noprepared", e.message); end
  begin; S.new(rows.map(&:dup), {"res"=>"ab".b}, nil); rescue => e; say.("badlength", e.message); end
  begin; S.new(rows.map(&:dup), {"res"=>"abc".b}, 10); rescue => e; say.("overlimit", e.message); end
  bad = rows.map(&:dup); bad << bad[0].dup
  begin; S.new(bad, {"res"=>"abc".b}, nil); rescue => e; say.("dupname", e.message); end
  huge = [{"name"=>"h","role"=>"persistent","element"=>"i64",
           "count"=>(1 << 62), "initial"=>"0"}]
  begin; S.new(huge, {}, nil); rescue => e; say.("overflow", e.message); end
' "$SESS" > "$W/sess.out" 2>&1 || true
sess() { grep "^$1 " "$W/sess.out" | head -1 | cut -d" " -f2-; }
ok   "two sessions share no mutable state" "$(sess share)" "99 0"
ok   "the session knows what it allocated" "$(sess bytes)" "43"
ok   "and releases each buffer once"        "$(sess released)" "1"
want "an ID after close is refused"         "$W/sess.out" '^afterclose the session is closed$'
want "a second close is refused"            "$W/sess.out" '^doubleclose the session is already closed$'
want "prepared data that is missing"        "$W/sess.out" '^noprepared res wants prepared:res, which Full did not prepare$'
want "prepared data of the wrong length"    "$W/sess.out" '^badlength prepared:res is 2 bytes and res declares 3$'
want "a session over its byte limit"        "$W/sess.out" '^overlimit the session needs 32 bytes and the limit is 10$'
want "a buffer declared twice"              "$W/sess.out" '^dupname a is declared twice$'
want "and a count whose bytes leave u64"    "$W/sess.out" '^overflow h: 4611686018427387904 x 8 bytes leaves u64$'

echo "== the real schema, emitted from the inventory and generated =="
# examples/doom/core/state.tsv is written FROM the audit's inventory, not by
# hand: 700 rows nobody could check against the code by reading them. Emitting
# it means a field that moves in the source moves here, and the audit is what
# decides whether the move is allowed.
CORE="$ROOT/examples/doom/core"
for f in state.tsv access.tsv catalog.tsv prepared.tsv; do
  [ -s "$CORE/$f" ] || die "no $f in $CORE"
done
cat "$CORE/catalog.tsv" "$CORE/prepared.tsv" > "$W/full-catalog.tsv"
mkdir -p "$W/real"
"$RUBY" "$GEN" --schema "$CORE/state.tsv" --access "$CORE/access.tsv" \
  --catalog "$W/full-catalog.tsv" --output "$W/real" > "$W/real.err" 2>&1 \
  && echo 0 > "$W/real.rc" || echo $? > "$W/real.rc"
ok "the game's own schema generates" "$(cat "$W/real.rc")" 0
# 694 fields, 448 arrays and 740 access rows since decision 0021: hud_data and
# status_bar_data are aliases of renderer_wad_data, the one copy of the WAD.
want "and says what it made" "$W/real.err" '694 field\(s\), 246 scalar slot\(s\), 448 array buffer\(s\), 740 access row\(s\)'

# The fields whose shape the whole migration turns on, checked by name rather
# than by a count that any 700-row file would satisfy.
want "the framebuffer is 64000 bytes"    "$W/real/buffers.tsv" "^renderer_screen${TAB}persistent${TAB}u8${TAB}64000${TAB}0$"
# Both are written by Full's setup after allocation (spawn_mobj, the level
# loader), so both open with Full's data rather than their fill.
want "the mobj slots are the declared capacity" "$W/real/buffers.tsv" "^game_mobj_x${TAB}persistent${TAB}i32${TAB}4096${TAB}prepared:game_mobj_x$"
want "the sector heights are E1M1's 85"  "$W/real/buffers.tsv" "^level_sector_floorheight${TAB}persistent${TAB}i32${TAB}85${TAB}prepared:level_sector_floorheight$"
want "and the scalars share one buffer"  "$W/real/buffers.tsv" "^core_state${TAB}persistent${TAB}i64${TAB}246${TAB}prepared:core_state$"
want "the random index is a slot in it"  "$W/real/slots.rb" '^    RANDOM_PRNDINDEX = [0-9]+$'
reject "and is not its own allocation"   "$W/real/buffers.tsv" "^random_prndindex${TAB}"

# Emitting again from the same inventory must give the same bytes, or the
# schema is not a function of the code.
"$RUBY" "$ROOT/tools/doom/emit-schema.rb" --inventory "$W/doom/state-use.tsv" \
  --setup-writes "$W/doom/setup-writes.tsv" \
  --schema "$W/re-state.tsv" --access "$W/re-access.tsv" \
  --prepared "$W/re-prepared.tsv" --catalog "$CORE/catalog.tsv" > "$W/re.err" 2>&1 || true
for f in state access prepared; do
  if cmp -s "$CORE/$f.tsv" "$W/re-$f.tsv"; then
    echo "  pass $f.tsv is what this inventory emits"; pass=$((pass + 1))
  else
    echo "  FAIL $f.tsv differs from what this inventory emits"
    diff "$CORE/$f.tsv" "$W/re-$f.tsv" | head -4; fail=$((fail + 1))
  fi
done
# FIELDS NO IVAR HOLDS (tools/doom/core-added.tsv) are in the schema with their
# origin, and 0008's command buffer is five i32 cells the input entry writes and
# the step entry reads.
want "the command buffer is an added field" "$CORE/state.tsv" \
  "^core_command${TAB}persistent${TAB}i16${TAB}fixed:5${TAB}0${TAB}added:command${TAB}doom_core_input$"
want "  the input entry writes it" "$CORE/access.tsv" "^doom_core_input${TAB}core_command${TAB}inout$"
want "  and the step entry reads it" "$CORE/access.tsv" "^doom_core_step${TAB}core_command${TAB}in$"
want "a hand-off row says it is one" "$CORE/access.tsv" \
  "^#handoff${TAB}doom_core_render${TAB}game_pl_ammo${TAB}Hand-off, not a closure read"
addedbad() { # label sed-expression pattern
  sed "$2" "$ROOT/tools/doom/core-added.tsv" > "$W/added-bad.tsv"
  rm -f "$W/addedbad-state.tsv"
  "$RUBY" "$ROOT/tools/doom/emit-schema.rb" --inventory "$W/doom/state-use.tsv" \
    --setup-writes "$W/doom/setup-writes.tsv" --added "$W/added-bad.tsv" \
    --schema "$W/addedbad-state.tsv" --access "$W/addedbad-access.tsv" \
    --prepared "$W/addedbad-prepared.tsv" --catalog "$CORE/catalog.tsv" > "$W/addedbad.err" 2>&1 || true
  ok "$1" "$(cmp -s "$ROOT/tools/doom/core-added.tsv" "$W/added-bad.tsv" && echo same || echo changed)|$(grep -c "$3" "$W/addedbad.err")|$([ -f "$W/addedbad-state.tsv" ] && echo present || echo absent)" "changed|1|absent"
}
addedbad "an added field taking an existing field's name is refused" \
  "s/^frame${TAB}core_frame${TAB}/frame${TAB}game_gametic${TAB}/" 'game_gametic is already a field (Game@@gametic)'
addedbad "an added field with a count outside 0008's grammar is refused" \
  "s/${TAB}limit:knotcells${TAB}/${TAB}256*21${TAB}/" 'count "256\*21" is not 0008'"'"'s grammar'
addedbad "a hand-off onto a field an entry already reaches is refused" \
  "s/${TAB}game_pl_ammo${TAB}-${TAB}-${TAB}-${TAB}render:in${TAB}/${TAB}game_pl_ammo${TAB}-${TAB}-${TAB}-${TAB}step:in${TAB}/" \
  'doom_core_step already reaches game_pl_ammo; a hand-off row would hide the measured one'
addedbad "a hand-off of a field the schema does not have is refused" \
  "s/${TAB}game_pl_maxammo${TAB}/${TAB}game_pl_maxammos${TAB}/" 'game_pl_maxammos is handed off, and the schema does not have it'
# AN ALIAS NAMES ONE STORAGE, SO ITS SHAPE IS THE FIELD'S. The emitter refuses
# an alias whose target has another element or count, and one whose target the
# schema does not have, before writing anything.
aliasbad() { # label from to pattern
  sed "s/alias:$2/alias:$3/" "$ROOT/tools/doom/core-representations.tsv" > "$W/reps-alias.tsv"
  rm -f "$W/aliasbad-state.tsv"
  "$RUBY" "$ROOT/tools/doom/emit-schema.rb" --inventory "$W/doom/state-use.tsv" \
    --setup-writes "$W/doom/setup-writes.tsv" --representations "$W/reps-alias.tsv" \
    --schema "$W/aliasbad-state.tsv" --access "$W/aliasbad-access.tsv" \
    --prepared "$W/aliasbad-prepared.tsv" --catalog "$CORE/catalog.tsv" > "$W/aliasbad.err" 2>&1 || true
  ok "$1" "$(diff "$ROOT/tools/doom/core-representations.tsv" "$W/reps-alias.tsv" | grep -c '^[<>]')|$(grep -c "$4" "$W/aliasbad.err")|$([ -f "$W/aliasbad-state.tsv" ] && echo present || echo absent)" "2|1|absent"
}
aliasbad "an alias onto a field of another shape is refused, and writes no schema" jobs_wall renderer_zonewin \
  'JobExecutor@@wall is i64 limit:jobwallfields and its alias target renderer_zonewin is u8 fixed:128; one storage has one shape'
aliasbad "and so is one onto a field the schema does not have" jobs_wall job_executor_wall \
  'JobExecutor@@wall is an alias of job_executor_wall, which the schema does not have'
# THE SETUP WALK DECIDES WHICH FILLS STAND, so the emitter will not run without
# it, will not read one that could not account for a call, and will not take a
# file that is not a whole walk as evidence that nothing was written: an empty,
# header-less, duplicated or truncated file used to read as "setup writes
# nothing", and every fill was kept.
want "the audit's setup walk accounted for every call" "$W/doom.err" \
  '^audit-core: setup reached [0-9]+ definition\(s\) from 19 root\(s\), writes [0-9]+ field\(s\), 0 gap\(s\)$'
want "and says so on its last line" "$W/doom/setup-writes.tsv" \
  "^#complete${TAB}roots=19${TAB}definitions=[0-9]+${TAB}fields=[0-9]+${TAB}gaps=0$"
"$RUBY" "$ROOT/tools/doom/emit-schema.rb" --inventory "$W/doom/state-use.tsv" \
  --schema "$W/nosw-state.tsv" --access "$W/nosw-access.tsv" > "$W/nosw.err" 2>&1 || true
want "the emitter refuses to run without the setup walk" "$W/nosw.err" \
  '^emit-schema: --setup-writes is required$'
SWREAL="$W/doom/setup-writes.tsv"
swbad() { # label file pattern
  rm -f "$W/swbad-state.tsv"
  "$RUBY" "$ROOT/tools/doom/emit-schema.rb" --inventory "$W/doom/state-use.tsv" \
    --setup-writes "$2" --schema "$W/swbad-state.tsv" --access "$W/swbad-access.tsv" > "$W/swbad.err" 2>&1 || true
  want "$1" "$W/swbad.err" "$3"
  ok "  and writes no schema" "$([ -f "$W/swbad-state.tsv" ] && echo present || echo absent)" "absent"
}
: > "$W/sw-empty.tsv"
swbad "an empty setup walk is refused" "$W/sw-empty.tsv" \
  'sw-empty\.tsv: no #complete line: the walk did not finish writing this file'
grep '^#' "$SWREAL" | grep -v '^#complete' > "$W/sw-comments.tsv"
swbad "a comment-only one is refused" "$W/sw-comments.tsv" 'sw-comments\.tsv: no #complete line'
grep -v "^field${TAB}writers$" "$SWREAL" > "$W/sw-nohead.tsv"
swbad "one with no header is refused" "$W/sw-nohead.tsv" \
  'sw-nohead\.tsv:[0-9]+: a row before the `field<TAB>writers` header'
awk -v t="$TAB" 'BEGIN{d=0} !/^#/ && $0 !~ "^field"t"writers$" && !d {print; d=1} {print}' "$SWREAL" > "$W/sw-dup.tsv"
swbad "one listing a field twice is refused" "$W/sw-dup.tsv" 'sw-dup\.tsv:[0-9]+: [A-Za-z]+@@[a-z_0-9]+ is listed twice'
grep -v '^#complete' "$SWREAL" > "$W/sw-trunc.tsv"
swbad "one cut off before #complete is refused" "$W/sw-trunc.tsv" 'sw-trunc\.tsv: no #complete line'
grep -v '^#complete' "$SWREAL" | awk -v t="$TAB" '!/^#/ && $0 !~ "^field"t"writers$" && !d {d=1; next} {print}' > "$W/sw-short.tsv"
grep '^#complete' "$SWREAL" >> "$W/sw-short.tsv"
swbad "one missing a field its #complete counts is refused" "$W/sw-short.tsv" \
  'sw-short\.tsv: #complete says [0-9]+ field\(s\) and the file lists [0-9]+'
grep -v '^#complete' "$SWREAL" > "$W/sw-gap.tsv"
printf '#gap\tno effect listed for frobnicate on int_array: X#g -> frobnicate (x.rb:1)\n' >> "$W/sw-gap.tsv"
grep '^#complete' "$SWREAL" | sed 's/gaps=0$/gaps=1/' >> "$W/sw-gap.tsv"
swbad "and one with a gap is refused" "$W/sw-gap.tsv" \
  'sw-gap\.tsv:[0-9]+: the setup walk has a gap \(no effect listed for frobnicate'
# A KEY STATED TWICE: `fields=99 fields=1` used to collapse to the last one, 1,
# and be accepted if that happened to match.
grep -v '^#complete' "$SWREAL" > "$W/sw-dupkey.tsv"
grep '^#complete' "$SWREAL" | sed "s/${TAB}fields=/${TAB}fields=99${TAB}fields=/" >> "$W/sw-dupkey.tsv"
swbad "one whose #complete states a count twice is refused" "$W/sw-dupkey.tsv" \
  'sw-dupkey\.tsv:[0-9]+: #complete states fields more than once'

echo "== the WAD directory, entry by entry =="
# `Lump@@name/pos/size` are replaced by `wad_lump_name/pos/size`, one value per
# directory entry, built by Full and by the reference separately. A synthetic
# wad generated by the script supplies the two cases doom1.wad has none of --
# a lower-case name, and a name slot with bytes after its NUL -- and the real
# IWAD, when present, supplies the whole directory, a duplicate name, a
# marker's position and the last entry.
"$RUBY" "$ROOT/tests/doom-core/lump-directory.rb" "$WADFILE" > "$W/lumpdir.out" 2>&1 || true
ok   "the directory arrays are right entry by entry, on both sides" \
     "$(tail -1 "$W/lumpdir.out")" "lump-directory: all pass"
want "a name stops at its NUL and is zero-padded, not the raw slot" "$W/lumpdir.out" \
  '^pass a slot with bytes after its NUL stores only the name, zero-padded$'
want "a marker keeps its nonzero position" "$W/lumpdir.out" \
  '^pass a zero-size marker keeps its position, not a zero$'
# A bound stated on the COUNT: `(n * 8) / 8 == n` holds for every Ruby
# integer, so the check written that way refused nothing.
want "a name-byte count one past U64_MAX / 8 is refused before multiplying" "$W/lumpdir.out" \
  '^pass and one more is refused before the product$'

echo "== a produced value is checked against its element before it is packed =="
# `pack` WRAPS rather than refusing: `[-1].pack("C")` is `ff`. `Resources.prepared`
# used to pack straight through while claiming the encoder's rules, so a value
# the reference refuses became a different number on Full's side. Every element
# is checked at its last valid and first invalid value, with the expected bytes
# stated in the script and the reference's own decision used as a cross-check.
# No IWAD is needed; this runs whether or not the reference lane can.
"$RUBY" "$ROOT/tests/doom-core/prepared-domain.rb" > "$W/domain.out" 2>&1 \
  && echo 0 > "$W/domain.rc" || echo $? > "$W/domain.rc"
ok   "every element edge is decided correctly, and as the reference decides" \
     "$(tail -1 "$W/domain.out")" "prepared-domain: 22 checked, 22 pass, 0 fail"
want "a -1 into a u8 is refused rather than wrapped to ff" "$W/domain.out" \
  '^pass -1 as u8x1 +refused +reference agrees$'
want "and 2**63 into an i64 is refused rather than wrapped" "$W/domain.out" \
  '^pass 9223372036854775808 as i64x1 +refused +reference agrees$'
want "an out-of-range ARRAY element takes the same path" "$W/domain.out" \
  '^pass \[1, 256\] as u8x2 +refused'
want "and a nil from a direct producer is an error, not an unsupported field" \
  "$W/domain.out" '^pass nil as i64x1 +refused'

echo "== the angle slots the reference holds as signed patterns (0022 section 2.4) =="
# examples/doom/core/state-repr.tsv: core_state slots whose original word the
# reference converts to the signed i32 pattern the port writes. Each control
# is a copy of the table with one planted fault the reader must name.
REPR="$ROOT/examples/doom/core/state-repr.tsv"
repr() { # table, out
  "$RUBY" -r"$ROOT/examples/doom/core/full/reference" -e '
    names = Doom::Core::Reference.state_repr(ARGV[0])
    puts "slots: #{names.join(" ")}"
    puts "word 2178503144 as slot: #{Doom::Core::Reference.encode(2178503144, "i64", 1, bits32: :slot).unpack1("q<")}"
  ' "$1" > "$2" 2>&1 || true
}
# what step-diff.rb and render-diff.rb hand the port: the same reading, through
# Reference.i32_bits? and Reference.pattern, at the word edges
"$RUBY" -r"$ROOT/examples/doom/core/full/reference" -e '
  r = Doom::Core::Reference
  puts "fields: #{%w[game_mobj_angle renderer_viewangle renderer_clipangle].map { |f| r.i32_bits?(f) }.join(" ")}"
  puts "edges: #{[0, 2**31 - 1, 2**31, 2**32 - 1].map { |v| r.pattern(v) }.join(" ")}"
  [-1, 2**32].each { |v| r.pattern(v) rescue puts "refused: #{$!.message}" }
' > "$W/pattern.out" 2>&1 || true
ok   "an angle buffer and an angle slot are signed patterns, a u32 table is not" \
     "$(sed -n 's/^fields: //p' "$W/pattern.out")" "true true false"
ok   "the words 0, 2**31-1, 2**31 and 2**32-1 as patterns" \
     "$(sed -n 's/^edges: //p' "$W/pattern.out")" "0 2147483647 -2147483648 -1"
ok   "and -1 and 2**32, no words, are refused rather than wrapped" \
     "$(grep -c '^refused: -\{0,1\}[0-9]* is not a 32-bit word$' "$W/pattern.out")" "2"
repr "$REPR" "$W/repr.out"
ok   "the table names the four angle slots" "$(sed -n 's/^slots: //p' "$W/repr.out")" \
     "renderer_viewangle renderer_rw_angle1 renderer_rw_normalangle renderer_rw_centerangle"
ok   "a word past 2**31 in a slot is its signed pattern" \
     "$(sed -n 's/^word 2178503144 as slot: //p' "$W/repr.out")" "-2116464152"
{ cat "$REPR"; grep '^renderer_rw_angle1	' "$REPR"; } > "$W/repr-twice.tsv"
repr "$W/repr-twice.tsv" "$W/repr-twice.out"
want "a slot named twice is refused, naming it" "$W/repr-twice.out" \
  'repr-twice\.tsv:[0-9]+: renderer_rw_angle1 is named twice \(first at line [0-9]+\)'
{ cat "$REPR"; printf 'renderer_clipangle\ti32-bits\t0022-2.4\tplanted: a buffer, no slot\n'; } > "$W/repr-noslot.tsv"
repr "$W/repr-noslot.tsv" "$W/repr-noslot.out"
want "a name that is no slot of an entry is refused, naming it" "$W/repr-noslot.out" \
  'repr-noslot\.tsv:[0-9]+: renderer_clipangle is no slot of an entry'

echo "== the old Full setup and the new prepared state, before the first tick =="
# Both built from the SAME WAD and configuration. What is comparable is what
# the SCHEMA defines -- the stored fields -- because a prepared field's bytes
# are Full's and comparing them against Full would be comparing Full with
# itself.
if [ ! -f "$WADFILE" ]; then
  skipped "the reference lane" "no IWAD at $WADFILE" "WAD=/path/to/doom1.wad"
else
  "$RUBY" "$ROOT/tests/doom-core/build-reference.rb" "$WADFILE" \
    "$W/real/snapshot.tsv" "$CORE/state.tsv" "$W/ref.bin" > "$W/ref.out" 2>&1 || true
  "$RUBY" "$ROOT/tests/doom-core/build-session.rb" "$W/real/buffers.tsv" \
    "$W/real/snapshot.tsv" "$W/sess.bin" > "$W/sess2.out" 2>&1 || true
  rf() { grep "^$1 " "$W/ref.out" | head -1 | cut -d" " -f2-; }

    echo "== one literal write is not an initial value =="
  # 375 fields have no allocation to read a fill from, and a literal
  # assignment in the tree is not their initial: 0008 task 5 asks for the
  # state just before the FIRST TICK, after Full initialisation, and the
  # constructor keeps writing after the literal. Two fields show it, read off
  # a real initialised Game here against the literal the tree holds, so the
  # claim is measured rather than argued.
  "$RUBY" -e '
    $LOAD_PATH.unshift(File.join(ARGV[1], "examples/doom/lib"))
    %w[wad level texnames texture sprites info defs game specials things].each { |f| require "doom/#{f}" }
    wad = Doom::Wad.new(ARGV[0]); tn = Doom::TextureNames.new(wad)
    tx = Doom::Textures.new(wad, tn)
    lv = Doom::Level.new(wad, "E1M1", 1); rnd = Doom::Random.new; rnd.clear
    g = Doom::Game.new(wad, lv, 2, rnd, tx)
    %w[@th_alloc @mobj_alloc @gametic].each do |v|
      puts "#{v} #{g.instance_variable_get(v)}"
    end' "$WADFILE" "$ROOT" > "$W/pretick.out" 2>&1 || true
  pt() { grep "^$1 " "$W/pretick.out" | head -1 | cut -d" " -f2; }
  ok "the tree writes @th_alloc = 1"        "$(grep -c '@th_alloc = 1' "$ROOT/examples/doom/lib/doom/game.rb")" "1"
  ok "and before the first tick it is 97"   "$(pt @th_alloc)" "97"
  ok "the tree writes @mobj_alloc = 0"      "$(grep -c '@mobj_alloc = 0' "$ROOT/examples/doom/lib/doom/game.rb")" "1"
  ok "and before the first tick it is 92"   "$(pt @mobj_alloc)" "92"
  # THE CONTROL FOR THE CONTROL: a field where the literal IS the value, so
  # this is not just "the tree never matches".
  ok "while @gametic really is the 0 the tree writes" "$(pt @gametic)" "0"
  # AND THE TREE DOES SAY THEY ARE UPDATED. An earlier version of this lane
  # reported these three as having one unconditional literal write and nothing
  # to tell them apart. That was a defect in the audit's collector, not a fact
  # about the tree: it gathered `InstanceVariableWriteNode` and missed the 139
  # `InstanceVariableOperatorWriteNode`s, among them `@th_alloc` at
  # game.rb:280, `@mobj_alloc` at 459 and `@gametic` at 896. All three are
  # `updated-in-place` now, with the update site recorded beside the plain one.
  for f in th_alloc mobj_alloc gametic; do
    want "the tree shows Game@@$f is updated after its literal" "$W/doom/initials.tsv" \
      "^updated-in-place${TAB}Game@@$f${TAB}"
  done
  ok "and no field is left claiming a lone unconditional literal" \
     "$(grep -c "^one-literal-unconditional${TAB}" "$W/doom/initials.tsv" || true)" "0"
  # SAME NAME, DIFFERENT CLASS, COUNTED APART. The collector keyed by the bare
  # ivar name, so every class sharing one was merged into a single row's worth
  # of writes. `validcount` is the case: Game's plain assignment is at
  # game.rb:142 and Renderer's at render.rb:364, and they have different write
  # counts, which a merged count cannot show.
  vc() { awk -F"$TAB" -v f="$1" '$2 == f { print $3 }' "$W/doom/initials.tsv"; }
  ok "Game@@validcount is counted on its own"     "$(vc Game@@validcount)" "6"
  ok "Renderer@@validcount is counted on its own" "$(vc Renderer@@validcount)" "2"
  want "and each names its own class's file"      "$W/doom/initials.tsv" \
    "^updated-in-place${TAB}Renderer@@validcount${TAB}2${TAB}plain@lib/doom/render.rb:364,"
  # EVERY SITE IS NAMED, INCLUDING AN INSTANTIATED ONE. A node compiled from
  # an included module carries no `node_file` of its own, and reading that
  # attribute directly produced 221 sites across 80 fields with an empty path
  # (`update@:651`). The audit already maps an instantiated node to its ast
  # twin; the twin is in the module's own file, which is the file a reader
  # wants.
  ok "no site in initials.tsv is missing its file" \
     "$(awk -F"$TAB" 'NR>4 { n = split($4, a, ","); for (i = 1; i <= n; i++) if (a[i] ~ /@:/) c++ }
                      END { print c + 0 }' "$W/doom/initials.tsv")" "0"
  # AND THE INCLUDE-DERIVED ONES ARE THE CASE. `Game@@ic_n` is written in
  # MapMove, which Game includes; the field is Game's and the site is
  # mapmove.rb. A check that only looked at fields written in their own class
  # would have passed while those 221 stayed empty.
  want "an include-derived site names the module's file" "$W/doom/initials.tsv" \
    "^updated-in-place${TAB}Game@@ic_n${TAB}[0-9]+${TAB}plain@lib/doom/mapmove.rb:"
  ok   "and it is not attributed to MapMove" \
       "$(awk -F"$TAB" '$2 == "MapMove@@ic_n"' "$W/doom/initials.tsv" | wc -l | tr -d ' ')" "0"

  # THIS FAILS, AND IT IS MEANT TO. The encoder used to reshape the original --
  # truncating one longer than the schema's count, zero-padding a shorter one --
  # so a field whose declared count is wrong still "agreed". Mac review of
  # 270fa5a measured 166 truncated and 16 zero-padded; reproduced here exactly,
  # and refusing instead of reshaping names all 182.
  #
  # The number is NOT written in as the expected value. Asserting 182 would be
  # recording the difference to make the suite green, which is the thing this
  # lane exists to stop. The schema's counts are wrong for those fields; until
  # they are right this is red, and `shape-errors` below names the count
  # EXPRESSIONS that remain so each run says what the work is.
  ok   "the reference reads every field it can"  "$(rf errors)" "0"
  # AN ALIAS IS CHECKED ON THE ORIGINAL: the schema's `#alias` line says
  # The executor's five banks must be Jobs' banks, not equal-byte copies, and
  # since decision 0021 the status bar's and the HUD's WAD the renderer's.
  # tick.sh separately checks the live ring's owner identity.
  ok   "the executor's banks and schedule columns are the ones Jobs holds, and the status bar's and the HUD's WAD the renderer's, one object each in the original" "$(rf aliases)" "7 identical"
  want "and the shape errors are grouped by count expression" "$W/ref.out" \
    '^shape-errors [0-9]+ across [0-9]+ count expression\(s\)$'
  # ONE LINE PER COUNT EXPRESSION. The group table used to be printed inside
  # the loop over unreachable fields, so it came out once per unreachable
  # field -- three times, every run. Checking the number of GROUPS would have
  # to move whenever the counts improve; checking that no expression is listed
  # twice is the invariant, and it is what caught it.
  ok   "and each count expression is listed once" \
       "$(grep '^S ' "$W/ref.out" | awk '{print $2}' | sort | uniq -d | wc -l | tr -d ' ')" "0"
  sed -n 's/^S /        /p' "$W/ref.out"
  # NOTHING IS UNREADABLE NOW. The three that were -- `Lump@@name/pos/size`,
  # declared as single fields while a Lump is one directory entry per lump --
  # are replaced by per-entry arrays the reference reads off the wad
  # (docs/core/doom-lump-directory.md). This used to pin `Lump=3` and
  # `unreachable 3`; a reader that could not reach the directory would now
  # show up here as a nonzero count rather than as the expected one.
  ok   "and nothing is unreadable" "$(rf byclass)" ""
  want "which it says in so many words"           "$W/ref.out" '^unreachable 0$'
  # THE TWO PERSISTENT FIELDS NO IVAR HOLDS (tools/doom/core-added.tsv) are
  # neither read nor unreachable: they open at their fill on both sides.
  want "and the added fields are named apart" "$W/ref.out" '^added 2 core_command,core_frame$'
  ok   "both snapshots are the layout's length" \
       "$("$RUBY" -e 'print [File.size(ARGV[0]), File.size(ARGV[1])].uniq.length' "$W/ref.bin" "$W/sess.bin")" "1"

  "$RUBY" "$ROOT/tests/doom-core/stored-layout.rb" "$CORE/state.tsv" \
    "$W/real/snapshot.tsv" "$W/stored.tsv" > "$W/stored.out" 2>&1 || true
  "$RUBY" "$ROOT/tests/doom-core/slice-snapshot.rb" "$W/real/snapshot.tsv" "$W/stored.tsv" \
    "$W/sess.bin" "$W/sess-stored.bin"
  "$RUBY" "$ROOT/tests/doom-core/slice-snapshot.rb" "$W/real/snapshot.tsv" "$W/stored.tsv" \
    "$W/ref.bin" "$W/ref-stored.bin"
  # 16875720 over 117 fields until 2026-09-17, when the two added persistent
  # fields (core_command, 5 x i32; core_frame, one i64: 28 bytes) joined.
  # 21855223 until the count catalog was corrected; the five fields that moved
  # are +161 cells (activeplats 64->30, ic_frac/ic_isaline/ic_thing 128->189
  # each, spechit 8->20) and 161 * 8 = 1288, which is exactly the difference.
  # 16875748 until the Jobs counts were corrected to the view the program's
  # Jobs is sized by (render.rb:465): jobs_yx1 and jobs_yx2 51200 -> 43008 and
  # jobs_ycount 200 -> 168 i64 cells, (8192 * 2 + 32) * 8 = 131328 bytes, which
  # is exactly the difference.
  want "the stored subset is what the schema defines" "$W/stored.out" '^stored fields 119 bytes 12853764$'

  # The measured remainder, by name. A field here keeps the fill its ALLOCATION
  # uses, because the audit's setup walk finds no setup code writing it after;
  # a field setup writes is carried by Full instead. That is decided from the
  # tree, never from this comparison -- marking a field `prepared:` BECAUSE it
  # differs here would be fitting the schema to the measurement -- so a
  # difference that appears is reported, not absorbed.
  grep '^SHAPEFIELD ' "$W/ref.out" | cut -d" " -f2 | sort > "$W/shapefields.txt"
  "$RUBY" -e '
    layout, a, b, refused_path = ARGV
    rows = []
    File.foreach(layout) do |ln|
      next if ln.start_with?("#") || ln.strip.empty?
      f = ln.chomp.split("\t", -1)
      rows << [f[0], Integer(f[4], 10), Integer(f[3], 10)]
    end
    refused = File.exist?(refused_path) ? File.readlines(refused_path).map(&:chomp).to_set : Set.new
    x = File.binread(a); y = File.binread(b)
    # A REFUSED FIELD IS NEITHER AGREEING NOR DIFFERING. Its reference bytes
    # are the schema initial, and the session is built from that same initial,
    # so comparing them compares the schema with itself. Counted on its own.
    comparable = rows.reject { |n, _, _| refused.include?(n) }
    unenc = rows.length - comparable.length
    diff = comparable.reject { |_, o, n| x.byteslice(o, n) == y.byteslice(o, n) }
    puts "fields #{rows.length}"
    puts "unencodable #{unenc}"
    puts "differ #{diff.length}"
    puts "agree #{comparable.length - diff.length}"
    puts "names " + diff.first(3).map(&:first).join(",")
  ' "$W/stored.tsv" "$W/sess-stored.bin" "$W/ref-stored.bin" "$W/shapefields.txt" > "$W/diff.out" 2>&1 || true
  df() { grep "^$1 " "$W/diff.out" | head -1 | cut -d" " -f2-; }
  # THREE CATEGORIES, because two would lie. A field the encoder refused is
  # not evidence either way: both sides hold the schema's initial bytes. The
  # counts are printed rather than pinned -- pinning them would make a number
  # the target, and the target is that `unencodable` and `differ` both reach
  # zero against the ORIGINAL, not that they hold today's value.
  ok "every stored field lands in exactly one category" \
     "$("$RUBY" -e 'a,b,c=ARGV.map { |v| Integer(v, 10) }; print a + b + c' \
        "$(df agree)" "$(df differ)" "$(df unencodable)")" "$(grep -c "^[^#]" "$W/stored.tsv")"
  # (An earlier version asserted `unencodable` was NOT zero, which is
  # backwards: it required refused fields to exist and would fail the day the
  # counts are right. What the lane needs is the partition above -- a refused
  # field lands in its own category and so cannot be counted as agreeing --
  # and that holds whether `unencodable` is 182 or 0.)
  echo "        agree $(df agree) / differ $(df differ) / unencodable $(df unencodable)"
  echo "== prepared data carried through the session, and one cell broken =="
  # WHAT THIS SECTION IS EVIDENCE OF, AND WHAT IT IS NOT.
  #
  # The session below is built FROM `ref.bin`: `build-session.rb` slices each
  # prepared field's bytes out of the reference snapshot. So an agreement here
  # is evidence that the bytes SURVIVE the route -- schema order, offsets,
  # lengths, the comparator -- and evidence of nothing else. It is TRANSPORT.
  #
  # It is NOT evidence that the prepared state matches what Full's own
  # preparation produces, because Full's preparation is not in this path at
  # all. `Doom::Core::Resources` measures counts and produces no prepared
  # bytes; until it does, the independent comparison that
  # 0008-doom-core-migration-plan.md:310-313 asks for -- the old Full setup
  # and the new prepared state built from the same WAD and configuration,
  # compared cell by cell -- has no second side to run against.
  #
  # The stored subset above is a DIFFERENT comparison, and worth stating
  # exactly: it compares the original against a session built from THE
  # CURRENT SCHEMA'S INITIAL VALUES. That is a real comparison -- its two
  # sides have different origins, which is why it can differ and does -- but
  # it is not the verification of every defined initial cell. 364 of the
  # schema's initials are the assumed zero rather than a derived one -- the
  # emitter's number, which is what the SCHEMA holds; 375 is the audit
  # inventory's UNDERIVED count and a different measurement of a different
  # file. So what this compares the original against is in part an assumption.
  #
  # Deriving every initial statically is NOT the requirement: Full may
  # initialise correctly and carry the value. The requirement is that every
  # defined initial cell agrees, for the same WAD and configuration.
  # Mac review of 4a8ba23 took the comparison this lane used to run and drove
  # four mutations through it -- a clean run, the corrupt index moved 0 -> 1,
  # two cells broken, and all three snapshots truncated to 6,445,647 bytes --
  # and got the SAME four numbers every time. `byteslice` answers nil past the
  # end and nil == nil is true, so 319 layout fields that were not there at all
  # still "agreed". The inline comparison is gone; this uses the comparator
  # that already refuses on length and names the field and the index.
  #
  # AND THE SET IT COMPARES IS NOT ALL 226. A field the encoder refused, or
  # could not reach, carries the schema's INITIAL on the reference side -- so
  # comparing it compares the schema with itself. The old lane counted all 226
  # as "arrives as the original has it" when most were substitute zeros on
  # both sides.
  #
  # 62 when that was first measured (161 refused for shape, 3 unreachable);
  # 152 once a prepared array's count was recorded from its own allocation,
  # and 154 once an array LITERAL counted as an allocation too -- the two
  # `@fuzzoffset` tables, 50 i64 cells each, which is the 800 bytes the
  # comparator's total gained. The number is INVENTORY and is meant to reach
  # 226. What has to hold at every value is the partition below.
  # EVERY REFUSAL, not only the shape ones. `NOENCODE` names a field the
  # encoder would not speak for whatever the reason -- nil, type, range,
  # shape -- and `UNREACHFIELD` one it could not read at all. Built from
  # SHAPEFIELD alone, this set let a `u8` range refusal through: the field
  # carried the schema's initial on the reference side, the session was built
  # from the same initial, and the comparator called it agreement.
  grep -E '^NOENCODE|^UNREACHFIELD' "$W/ref.out" | awk '{print $2}' | sort -u > "$W/noref.txt"
  # The shape refusals are a SUBSET of the encoder's refusals. If they ever
  # are not, one of the two lists is being built from something other than
  # `errors` and the partition below is measuring the wrong set.
  grep '^SHAPEFIELD ' "$W/ref.out" | awk '{print $2}' | sort -u > "$W/shapeonly.txt"
  grep '^NOENCODE ' "$W/ref.out" | awk '{print $2}' | sort -u > "$W/noencode.txt"
  ok "every shape refusal is one of the encoder's refusals" \
     "$(comm -23 "$W/shapeonly.txt" "$W/noencode.txt" | grep -c .)" "0"
  # NOT "and there are more of them". Today every refusal the encoder makes on
  # this schema IS a shape refusal, so asserting otherwise would assert that a
  # second kind of defect exists -- the backwards shape of check this lane has
  # already been caught making once. The subset relation is the invariant; the
  # control below is what shows `NOENCODE` catches a refusal that is not about
  # shape, by making one.
  ok "which today are the same set, one kind of defect at a time" \
     "$(comm -3 "$W/shapeonly.txt" "$W/noencode.txt" | grep -c .)" "0"
  # AND THE CONTROL IS MAC REVIEW'S: declare a field that holds -1 as a
  # one-element `u8`. -1 does not fit a byte and `encode` refuses it -- but
  # before `NOENCODE` the field appeared in no list, so the reference side
  # carried the schema's initial, the session was built from that same
  # initial, and the comparator counted a placeholder as agreement.
  #
  # The layout is regenerated from the mutated schema, because a layout that
  # still says i64 while the schema says u8 would be measuring a desync rather
  # than a refusal.
  "$RUBY" -e 'n = 0
              out = File.readlines(ARGV[0]).map { |l|
                f = l.chomp.split("\t", -1)
                next l unless f[0] == "status_bar_oldhealth"
                n += 1
                f[2] = "u8"
                f.join("\t") + "\n"
              }
              abort("no status_bar_oldhealth row to mutate") unless n == 1
              File.write(ARGV[1], out.join)' "$CORE/state.tsv" "$W/u8-state.tsv"
  ok "the mutation is one line" \
     "$(diff "$CORE/state.tsv" "$W/u8-state.tsv" | grep -c '^[<>]')" "2"
  ok "and the original really holds -1" \
     "$("$RUBY" -e 'require_relative ARGV[0]
                    require_relative ARGV[1]
                    w = Doom::Wad.new(ARGV[2])
                    sb = Doom::StatusBar.new(w)
                    print sb.instance_variable_get(:@oldhealth)' \
        "$ROOT/examples/doom/lib/doom/wad" "$ROOT/examples/doom/lib/doom/statusbar" "$WADFILE")" "-1"
  mkdir -p "$W/u8"
  "$RUBY" "$GEN" --schema "$W/u8-state.tsv" --access "$CORE/access.tsv" \
    --catalog "$W/full-catalog.tsv" --output "$W/u8" > "$W/u8gen.err" 2>&1 || true
  "$RUBY" "$ROOT/tests/doom-core/build-reference.rb" "$WADFILE" \
    "$W/u8/snapshot.tsv" "$W/u8-state.tsv" "$W/u8-ref.bin" > "$W/u8ref.out" 2>&1 || true
  # ONE MORE REFUSAL THAN THE UNMUTATED RUN, counted rather than read off the
  # `E` lines -- those are the first six only, and this field is not among
  # them. Computed from the base run so it does not need updating when the
  # count defect is fixed.
  ok "a value the element cannot hold is one more refusal" \
     "$(rf errors)" "$("$RUBY" -e 'print Integer(ARGV[0], 10) - 1' \
                       "$(grep '^errors ' "$W/u8ref.out" | head -1 | cut -d" " -f2)")"
  want "and the field is named as one the encoder would not speak for" "$W/u8ref.out" \
    '^NOENCODE status_bar_oldhealth$'
  reject "which the shape list alone never said" "$W/u8ref.out" \
    '^SHAPEFIELD status_bar_oldhealth$'
  "$RUBY" "$ROOT/tests/doom-core/stored-layout.rb" "$CORE/state.tsv" \
    "$W/real/snapshot.tsv" "$W/prep.tsv" prepared "$W/noref.txt" > "$W/prep.out" 2>&1 || true
  # 558 -> 556 fields and 25143720 -> 16751680 bytes, here and below, since
  # decision 0021: hud_data and status_bar_data, 4196020 bytes each, are no
  # longer prepared fields of their own but aliases of renderer_wad_data.
  ok "the prepared fields with the original's own bytes" \
     "$(grep -c '^[^#]' "$W/prep.tsv")" "556"
  # EVERY PREPARED FIELD IS CARRIED OR IS NAMED AS NOT CARRIED, never both and
  # never neither. This is what stops the carried set growing by dropping a
  # field out of the schema rather than by reading it: a field that leaves
  # `noref` has to arrive in `prep.tsv`, and the two together are still 556.
  ok "and the 556 are partitioned, with none in both and none lost" \
     "$("$RUBY" "$ROOT/tests/doom-core/partition.rb" \
        "$W/prep.tsv" "$W/noref.txt" "$CORE/prepared.tsv")" "556 556 0 0 0"
  # AND THE PARTITION CHECK ITSELF IS SHOWN TO SEE BOTH FAULTS. One name put
  # in both sets, and one name in neither, on inputs built here -- because a
  # check whose two interesting columns have read zero on every real run so
  # far has not yet been shown to be able to read anything else.
  printf 'a\t0\t0\t8\t0\nb\t0\t0\t8\t8\n' > "$W/pt-carried.tsv"
  printf 'prepared\ta\t1\nprepared\tb\t1\nprepared\tc\t1\n' > "$W/pt-whole.tsv"
  printf 'b\n' > "$W/pt-noref.txt"
  ok "a field in both the carried set and the refused set is counted" \
     "$("$RUBY" "$ROOT/tests/doom-core/partition.rb" \
        "$W/pt-carried.tsv" "$W/pt-noref.txt" "$W/pt-whole.tsv")" "3 2 1 1 1"
  printf '' > "$W/pt-none.txt"
  ok "and so is a field in neither" \
     "$("$RUBY" "$ROOT/tests/doom-core/partition.rb" \
        "$W/pt-carried.tsv" "$W/pt-none.txt" "$W/pt-whole.tsv")" "3 2 0 0 1"
  "$RUBY" "$ROOT/tests/doom-core/build-session.rb" "$W/real/buffers.tsv" \
    "$W/real/snapshot.tsv" "$W/sess-tp.bin" "$W/ref.bin" > "$W/tp.out" 2>&1 || true
  "$RUBY" "$ROOT/tests/doom-core/build-session.rb" "$W/real/buffers.tsv" \
    "$W/real/snapshot.tsv" "$W/sess-tpc.bin" "$W/ref.bin" \
    level_sector_validcount:0 > "$W/tpc.out" 2>&1 || true
  for s in sess-tp sess-tpc ref; do
    "$RUBY" "$ROOT/tests/doom-core/slice-snapshot.rb" "$W/real/snapshot.tsv" \
      "$W/prep.tsv" "$W/$s.bin" "$W/$s-p.bin"
  done
  cmp_prep() {
    "$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/prep.tsv" \
      --a "$1" --b "$W/ref-p.bin" --label-a session --label-b reference 2>&1 | tail -1
  }
  echo "== and the prepared side produced by Full, not copied (556 fields) =="
  # A PRODUCER COMPARISON, AND NOT THE WHOLE OF PLAN 310-313. Everything above this
  # line fills the prepared fields from `ref.bin`, so both sides come from one
  # snapshot. `build-prepared.rb` produces them from the WAD and the
  # configuration -- constructing the level, the game and the renderer itself
  # -- rather than slicing them out of `ref.bin`. The two sides still have
  # different origins: this one builds from the WAD and the configuration,
  # `build-reference.rb` builds its own objects and reads their ivars.
  #
  # FOR THE PACKED TABLES that is a second read of one constant. FOR A FIELD
  # READ OFF A CONSTRUCTED OBJECT it is the same construction the reference
  # performs, so what agreement shows there is the schema and session route --
  # layout, offsets, lengths, the binding of a prepared name to one field --
  # and not the value. The two are counted apart for that reason.
  #
  # What it does NOT do is pass through `Session.open` and the session's own
  # snapshot: these bytes go straight to the comparator, and the session lane
  # below is still fed from `ref.bin`. So this is evidence that Full's
  # producers and the original agree for the fields it covers, and not yet the
  # comparison plan 310-313 asks for.
  #
  # 40 of the 226 prepared fields, which is what Full can produce today: the
  # packed tables in `Doom::Info` and `Doom::Tables`. The rest are named as
  # skipped with their producer, one line each, rather than left out quietly.
  "$RUBY" "$ROOT/tests/doom-core/build-prepared.rb" "$W/real/snapshot.tsv" \
    "$ROOT/tools/doom/core-acquired.tsv" "$CORE/state.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$WADFILE" E1M1 1 2 10 1 > "$W/fullprep.err" 2>&1 || true
  want "Full produces what it can without a game" "$W/fullprep.err" \
    'build-prepared.rb: 556 field\(s\), 16751680 byte\(s\) produced by Full'
  # EVERY PREPARED FIELD IS IN EXACTLY ONE HALF, BY NAME. `build-prepared.rb`
  # used to report what it skipped as counts keyed by the REASON, and I
  # described that as naming each field. A count by reason cannot be compared
  # with the prepared set, so a field falling out of both halves would not
  # have shown. The two halves are name lists now and this is the check.
  # CLASSIFIED BY WHAT PRODUCED IT. This counted every field with an acquired
  # row as a packed table -- the IWAD, the atlases, the COLORMAP lump among
  # them -- and reported 57 second paths where there are 40. Being named in a
  # table is not evidence of anything; the producer's kind is.
  want "the two kinds of producer are counted apart, by kind" "$W/fullprep.err" \
    'build-prepared.rb: 42 from a packed table \(a second read of one constant\), 514 read off an object Full constructs'
  ok   "and the kinds account for every produced field" \
       "$(awk -F"$TAB" 'NR>2 { c[$1]++ } END { print c["table"] + c["object"] }' \
          "$W/fullprep.tsv.kinds")" "556"
  want "the IWAD is an object read, not a packed table" "$W/fullprep.tsv.kinds" \
    "^object${TAB}wad_data$"
  want "while a mobj table is a packed one" "$W/fullprep.tsv.kinds" \
    "^table${TAB}game_info_damage$"
  want "and names every field it cannot produce" "$W/fullprep.err" \
    'build-prepared.rb: 0 field\(s\) Full cannot produce yet, named in'
  cut -f1 "$W/fullprep.tsv" | grep -v '^#' | sort > "$W/fp-made.txt"
  awk -F"$TAB" 'NR>2 && !/^#/ { print $1 }' "$W/fullprep.tsv.unsupported" | sort > "$W/fp-un.txt"
  awk -F"$TAB" '!/^#/ { print $2 }' "$CORE/prepared.tsv" | sort > "$W/fp-all.txt"
  ok "the two halves are the whole prepared set, with none in both" \
     "$("$RUBY" -e '
        require "set"
        made, un, all = ARGV.map { |f| File.readlines(f).map(&:chomp).reject(&:empty?) }
        print [all.length, made.length, un.length,
               (made.to_set & un.to_set).length,
               (all.to_set - made.to_set - un.to_set).length,
               made.length - made.uniq.length + (un.length - un.uniq.length)].join(" ")' \
        "$W/fp-made.txt" "$W/fp-un.txt" "$W/fp-all.txt")" "556 556 0 0 0 0"
  "$RUBY" "$ROOT/tests/doom-core/slice-snapshot.rb" "$W/real/snapshot.tsv" \
    "$W/fullprep.tsv" "$W/ref.bin" "$W/ref-fullprep.bin"
  ok "and they agree with the original, cell for cell" \
     "$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
        --a "$W/fullprep.bin" --b "$W/ref-fullprep.bin" \
        --label-a full --label-b original 2>&1 | tail -1)" \
     "compare-state: 556 field(s), 16751680 bytes, full and original agree"
  # WHERE EACH OPENING VALUE IS COMPARED, BY NAME. A stored field Full carries --
  # UNDERIVED, or written by Full's setup after allocating it -- is compared in
  # this lane; one kept at its fill is compared in the stored lane. Checked
  # against the audit's own inventory and setup walk, not against either lane.
  IS() { # snapshot stored prepared schema held
    "$RUBY" "$ROOT/tests/doom-core/initial-sets.rb" "$1" "$2" "$3" "$4" \
      "$W/doom/state-use.tsv" "$W/doom/setup-writes.tsv" "$5" "$W/doom.err" "$W/shapefields.txt" "$WADFILE" 2>&1
  }
  HELD="$ROOT/tools/doom/core-initials-held.tsv"
  IS "$W/real/snapshot.tsv" "$W/stored.tsv" "$W/fullprep.tsv" "$CORE/state.tsv" "$HELD" > "$W/sets.out"
  st() { grep "^$1 " "$W/sets.out" | head -1; }
  # 2026-09-17: lanes 675 -> 677 and fills 117 -> 119 are the two added
  # persistent fields; carried 342 -> 344 and setup-only 110 -> 112 are
  # level_line_flags and game_pl_maxammo, stored since the audit saw their
  # writes (a local alias, index operator writes) and written by setup.
  # 677 -> 675 lanes, here and below, since decision 0021: hud_data and
  # status_bar_data are aliases of renderer_wad_data.
  ok "every snapshot field is compared in exactly one lane" \
     "$(st lanes)" "lanes 675 both 0 neither 0 outside 0"
  ok "every field Full should carry is Full's, and still mutable" \
     "$(st carried)" "carried 344 underived 232 setup-only 112 not-prepared 0 stored 0 resource 0"
  ok "and no field kept at its fill is one setup writes" \
     "$(st fills)" "fills 119 setup-written 0 added 2"
  ok "the held fields are exactly the shape refusals and the fields with no count" \
     "$(st held)" "held 0 shape 0 no-count 0 mismatch 0"
  # SCRATCH IS LEFT OUT OF THE SNAPSHOT, and that is only right while the
  # original holds nothing for it before the first tick. Measured on the
  # objects the original constructs for this configuration, not assumed from
  # the role.
  # THE RANDOM TRACE IS ELIMINATED, AND NOTHING ELSE LEAVES WITH IT. 0008's
  # "eliminated reference-only trace field": Random#trace! and sim_demo's
  # rand.tsv oracle are unchanged, the audit's inventory still lists all eight
  # with their origin, and the schema loses exactly those eight -- checked by
  # name, against the inventory, not by a count.
  "$RUBY" -e '
    require "set"
    inv, schema, fields, reps = ARGV
    rep_rows = File.readlines(reps).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t", -1) }
    folds = rep_rows.select { |f| f[1].to_s.start_with?("fold:") }.map(&:first).to_set
    # AN ALIAS has no row of its own either: it IS the storage of a field. The schema
    # says which in an `#alias` line, and that field must be in the schema with
    # the alias target as its origin -- so an alias is accounted for, never
    # silently dropped.
    alias_rows = rep_rows.select { |f| f[1].to_s.start_with?("alias:") }.to_h { |f| [f[0], f[1].delete_prefix("alias:")] }
    schema_lines = File.readlines(schema)
    schema_alias = schema_lines.select { |l| l.start_with?("#alias\t") }.to_h { |l| a = l.chomp.split("\t", -1); [a[1], [a[2], a[3]]] }
    field_origin = schema_lines.reject { |l| l.start_with?("#") }.to_h { |l| a = l.split("\t"); [a[0], a[5]] }
    aliases = alias_rows.keys.to_set
    alias_ok = alias_rows.count { |src, t| schema_alias[src] && schema_alias[src][0] == t && field_origin[t] == schema_alias[src][1] }
    parts = rep_rows.map(&:first).select { |k| k.include?(".") }.to_set
    rows = File.readlines(inv).reject { |l| l.start_with?("#") }.map { |l| l.chomp.split("\t", -1) }
    head = rows.shift; col = head.each_with_index.to_h
    key = ->(f) { "#{f[col["class"]]}@#{f[col["ivar"]]}" }
    elim = rows.select { |f| f[col["disposition"]] == "eliminated" }.map(&key).to_set
    want = %w[log_tic log_before log_after log_value log_site log_n trace tic].map { |i| "Random@@#{i}" }.to_set
    # A FOLDED ivar has no schema row (its fields carry it) and an ADDED part is
    # not an ivar; both are named in core-representations.tsv, and counted.
    kept = rows.select { |f| %w[stored prepared].include?(f[col["disposition"]]) }.map(&key).to_set - folds - aliases
    all_origins = File.readlines(schema).reject { |l| l.start_with?("#") }.map { |l| l.split("\t")[5] }.to_set
    origins = all_origins - parts
    reasons = File.readlines(fields).reject { |l| l.start_with?("#") }.map { |l| l.chomp.split("\t", -1) }
                  .select { |f| f[1] == "eliminated" && !f[3].to_s.strip.empty? }.map(&:first).to_set
    counters = %w[prndindex rndindex pcount mcount].map { |i| "Random@@#{i}" }
    puts "eliminated #{elim.length} unexpected #{(elim ^ want).length} in-schema #{(elim & origins).length} " \
         "with-reason #{(elim & reasons).length}"
    # A FIELD NO IVAR HOLDS is not in the inventory by construction; counted apart.
    added_origins = origins.select { |o| o.to_s.start_with?("added:") }.to_set
    origins -= added_origins
    puts "kept #{kept.length} missing-from-schema #{(kept - origins).length} not-in-inventory #{(origins - kept).length} added #{added_origins.length}"
    puts "counters #{counters.count { |c| kept.include?(c) && origins.include?(c) }}"
    puts "representations folded #{folds.length} added #{parts.length} added-in-schema #{(parts & all_origins).length}"
    puts "aliases #{alias_rows.length} recorded-in-schema #{alias_ok} in-inventory #{(aliases & rows.map(&key).to_set).length} own-row #{(aliases & origins).length}"
  ' "$W/doom/state-use.tsv" "$CORE/state.tsv" "$ROOT/tools/doom/core-fields.tsv" "$ROOT/tools/doom/core-representations.tsv" > "$W/elim.out" 2>&1 || true
  ok "the eliminated fields are exactly the eight trace fields, each with its reason, none in the schema" \
     "$(grep '^eliminated ' "$W/elim.out")" "eliminated 8 unexpected 0 in-schema 0 with-reason 8"
  ok "and every stored or prepared field is still in the schema, and nothing else is" \
     "$(grep '^kept ' "$W/elim.out")" "kept 683 missing-from-schema 0 not-in-inventory 0 added 9"
  ok "the four random counters stay stored" "$(grep '^counters ' "$W/elim.out")" "counters 4"
  # AND A NINTH WOULD SHOW: pcount marked eliminated in a copy of the inventory,
  # its schema row dropped from a copy of the schema.
  sed "s/^\(Random${TAB}@pcount${TAB}[^${TAB}]*${TAB}[^${TAB}]*${TAB}[^${TAB}]*${TAB}\)stored${TAB}/\1eliminated${TAB}/" \
    "$W/doom/state-use.tsv" > "$W/elim-inv.tsv"
  grep -v "${TAB}Random@@pcount${TAB}" "$CORE/state.tsv" > "$W/elim-state.tsv"
  ok "the mutation is one inventory line and one schema line" \
     "$(diff "$W/doom/state-use.tsv" "$W/elim-inv.tsv" | grep -c '^[<>]') $(diff "$CORE/state.tsv" "$W/elim-state.tsv" | grep -c '^[<>]')" "2 1"
  awk '/THE RANDOM TRACE IS ELIMINATED/ {f=1} f && /^  "\$RUBY" -e .$/ {g=1; next} g && /^  . "\$W\/doom\/state-use.tsv"/ {exit} g {print}' \
    "$ROOT/tests/doom-core/state.sh" > "$W/elim.rb"
  ok "a ninth eliminated field is unexpected, and a counter is missing" \
     "$("$RUBY" "$W/elim.rb" "$W/elim-inv.tsv" "$W/elim-state.tsv" "$ROOT/tools/doom/core-fields.tsv" "$ROOT/tools/doom/core-representations.tsv" | grep '^eliminated \|^counters ' | tr '\n' '|')" \
     "eliminated 9 unexpected 1 in-schema 0 with-reason 8|counters 3|"
  ok "no scratch field has a value in the original before the first tick" \
     "$(st scratch)" "scratch 19 in-snapshot 0 defined-before-tick 0 unreachable 0 added 7"
  # EACH OF THOSE CAN FAIL. One change per control, each on a copy.
  grep -v "^game_th_alloc${TAB}" "$W/fullprep.tsv" > "$W/sets-fp-drop.tsv"
  ok "a field dropped from the prepared layout is in neither lane" \
     "$(IS "$W/real/snapshot.tsv" "$W/stored.tsv" "$W/sets-fp-drop.tsv" "$CORE/state.tsv" "$HELD" | sed -n 1p)" \
     "lanes 675 both 0 neither 1 outside 0"
  # A field only SETUP writes -- not UNDERIVED -- put back to its fill.
  sed "s/^\(game_mobj_x${TAB}persistent${TAB}i32${TAB}limit:maxmobjs${TAB}\)prepared:game_mobj_x${TAB}/\10${TAB}/" \
    "$CORE/state.tsv" > "$W/sets-rev.tsv"
  "$RUBY" "$ROOT/tests/doom-core/stored-layout.rb" "$W/sets-rev.tsv" "$W/real/snapshot.tsv" \
    "$W/sets-stored-rev.tsv" > /dev/null 2>&1 || true
  grep -v "^game_mobj_x${TAB}" "$W/fullprep.tsv" > "$W/sets-fp-rev.tsv"
  ok "a setup-written field put back to its fill is found, from both sides" \
     "$(diff "$CORE/state.tsv" "$W/sets-rev.tsv" | grep -c '^[<>]') $(IS "$W/real/snapshot.tsv" "$W/sets-stored-rev.tsv" "$W/sets-fp-rev.tsv" "$W/sets-rev.tsv" "$HELD" | sed -n 2,3p | tr '\n' '|')" \
     "2 carried 344 underived 232 setup-only 112 not-prepared 1 stored 1 resource 0|fills 120 setup-written 1 added 2|"
  { cat "$HELD"; printf 'Game@@gametic\ta row nothing reports\n'; } > "$W/sets-held.tsv"
  ok "a held row that is not a shape refusal or a missing count is a mismatch" \
     "$(IS "$W/real/snapshot.tsv" "$W/stored.tsv" "$W/fullprep.tsv" "$CORE/state.tsv" "$W/sets-held.tsv" | sed -n 4p)" \
     "held 1 shape 0 no-count 0 mismatch 1"
  sed "s/^game_gametic${TAB}persistent${TAB}/game_gametic${TAB}scratch${TAB}/" "$CORE/state.tsv" > "$W/sets-scr.tsv"
  ok "and a field the original defines, declared scratch, is counted" \
     "$(diff "$CORE/state.tsv" "$W/sets-scr.tsv" | grep -c '^[<>]') $(IS "$W/real/snapshot.tsv" "$W/stored.tsv" "$W/fullprep.tsv" "$W/sets-scr.tsv" "$HELD" | sed -n 5p)" \
     "2 scratch 20 in-snapshot 1 defined-before-tick 1 unreachable 0 added 7 game_gametic"
  # AND A LENGTH THAT DISAGREES IS REFUSED BY NAME. The refusal is on a field
  # `build-prepared.rb` actually produces, so this exercises the path rather
  # than a branch nothing reaches: one row of the layout it reads is given a
  # byte count one larger than Full produces.
  "$RUBY" -e '
    n = 0
    out = File.readlines(ARGV[0]).map { |l|
      next l if l.start_with?("#")
      f = l.chomp.split("\t", -1)
      next l unless f[0] == "game_finesine"
      n += 1
      f[3] = (Integer(f[3], 10) + 8).to_s
      f.join("\t") + "\n"
    }
    abort("no game_finesine row") unless n == 1
    File.write(ARGV[1], out.join)' "$W/real/snapshot.tsv" "$W/badlen.tsv"
  ok "the mutation is one line" \
     "$(diff "$W/real/snapshot.tsv" "$W/badlen.tsv" | grep -c '^[<>]')" "2"
  # ALL THREE OUTPUTS, NOT THE BINARY. `build-prepared.rb` writes a layout, a
  # binary and an unsupported list. It used to open the layout for writing and
  # validate each length inside that loop, so a refusal left a TRUNCATED
  # layout beside a binary and a list still holding the previous run's bytes
  # -- and the check here looked only at the binary, which that run had never
  # created, so it passed while a file was being clobbered.
  #
  # Sentinels in all three first, so "unchanged" is something this can see.
  mkdir -p "$W/tx"
  printf 'SENTINEL-LAYOUT\n' > "$W/tx/o.tsv"
  printf 'SENTINEL-BIN'       > "$W/tx/o.bin"
  printf 'SENTINEL-UNSUP\n'   > "$W/tx/o.tsv.unsupported"
  want "a produced field of the wrong length is refused, not padded" /dev/stdin \
    'build-prepared.rb: game_finesine: Full produced 40960 byte\(s\) and the layout declares 40968' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/build-prepared.rb" "$W/badlen.tsv" \
    "$ROOT/tools/doom/core-acquired.tsv" "$CORE/state.tsv" \
    "$W/tx/o.tsv" "$W/tx/o.bin" 2>&1 | tail -1)
EOF
  ok "and all three outputs keep the bytes they had" \
     "$(cat "$W/tx/o.tsv" "$W/tx/o.bin" "$W/tx/o.tsv.unsupported")" \
     "$(printf 'SENTINEL-LAYOUT\nSENTINEL-BINSENTINEL-UNSUP\n')"
  # AND WHERE THERE WAS NOTHING, IT CREATES NOTHING. The sentinel case cannot
  # tell "left alone" from "rewritten with the same bytes"; this one cannot be
  # passed by writing anything at all.
  mkdir -p "$W/tx-empty"
  "$RUBY" "$ROOT/tests/doom-core/build-prepared.rb" "$W/badlen.tsv" \
    "$ROOT/tools/doom/core-acquired.tsv" "$CORE/state.tsv" \
    "$W/tx-empty/o.tsv" "$W/tx-empty/o.bin" > /dev/null 2>&1 || true
  ok "and creates none of them where there were none" \
     "$(ls -A "$W/tx-empty" | wc -l | tr -d ' ')" "0"
  # THE POSITIVE SIDE: the successful run writes all three, so the two checks
  # above are not passing because this never writes anything.
  ok "while a run that succeeds writes all three" \
     "$(ls -A "$W/fullprep.tsv" "$W/fullprep.bin" "$W/fullprep.tsv.unsupported" 2>/dev/null | wc -l | tr -d ' ')" "3"
  # THE CONTROL. One byte of Full's own output, so the agreement above is not
  # two empty files or a comparator that cannot see a difference on this path.
  "$RUBY" -e 'b = File.binread(ARGV[0]); b.setbyte(0, (b.getbyte(0) + 1) & 0xff)
              File.binwrite(ARGV[1], b)' "$W/fullprep.bin" "$W/fullprep-bad.bin"
  ok "one byte changed in Full's output is one byte the comparison sees" \
     "$("$RUBY" -e 'a, b = ARGV.map { |f| File.binread(f) }
                    print a.bytes.zip(b.bytes).count { |x, y| x != y }' \
        "$W/fullprep.bin" "$W/fullprep-bad.bin")" "1"
  want "and it is named with its field and index" /dev/stdin \
    '^compare-state: value: [a-z0-9_]+\[0\]: full has [0-9]+ and original has [0-9]+' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
    --a "$W/fullprep-bad.bin" --b "$W/ref-fullprep.bin" --label-a full --label-b original 2>&1 | head -1)
EOF

  echo "== and through a real session, on a test-only subset =="
  # `Session.open` refuses a prepared name it was given no bytes for, so a
  # session over the PRODUCTION schema cannot be opened until Full produces all
  # 226. This opens one over a TEST-ONLY SUBSET: the fields Full does produce,
  # their buffers selected out of the generated buffers.tsv, their independently
  # produced bytes handed in as prepared data, and the result taken through
  # `Session#snapshot` at the canonical layout.
  #
  # IT IS NOT THE DOOM INITIAL STATE. There are no persistent fields here, no
  # scalar slots, no adapter and no game. The production schema is untouched and
  # its unproduced fields are still named as unproduced, above. A subset opening
  # is not the schema being accepted.
  "$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf.tsv" "$W/ps.bin" \
    > "$W/ps.err" 2>&1 || true
  want "the produced fields open a real session" "$W/ps.err" \
    'partial-session.rb: 556 field\(s\) through a real session, 16751680 byte\(s\)'
  # THE THREE SETS ARE ONE SET. The layout's fields, the buffers selected for
  # them and the prepared names handed over are three lists that could
  # disagree; a session opened over two of them while a third was compared
  # would be measuring something nobody named.
  #
  # A prepared SCALAR is not a buffer of its own: it is a slot in `core_state`,
  # which the manifest carries once. So the carriers are the manifest's buffers
  # other than `core_state`, plus the prepared slots in slots.tsv -- and the
  # last column says `core_state` itself was carried, exactly once.
  ok "the layout, the carriers and the prepared names are the same set" \
     "$("$RUBY" -e '
        require "set"
        rows = ->(p) { File.readlines(p).reject { |l| l.start_with?("#") }.map { |l| l.chomp.split("\t", -1) } }
        lay = rows[ARGV[0]].map { |f| f[0] }.to_set
        man = rows[ARGV[1]]
        buf = man.reject { |f| f[0] == "core_state" }
        slots = rows[ARGV[2]].select { |f| f[2].start_with?("prepared:") }
        carriers = (buf.map { |f| f[0] } + slots.map { |f| f[0] }).to_set
        prep = (buf.map { |f| f[4].sub("prepared:", "") } + slots.map { |f| f[2].sub("prepared:", "") }).to_set
        print [lay.length, (lay ^ carriers).length, (lay ^ prep).length,
               man.count { |f| f[0] == "core_state" }].join(" ")' \
        "$W/fullprep.tsv" "$W/ps-buf.tsv" "$W/real/slots.tsv")" "556 0 0 1"
  ok "and what came out of the session equals the original" \
     "$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
        --a "$W/ps.bin" --b "$W/ref-fullprep.bin" \
        --label-a session --label-b original 2>&1 | tail -1)" \
     "compare-state: 556 field(s), 16751680 bytes, session and original agree"
  # ONE CELL BROKEN BEFORE THE SESSION RECEIVES IT.
  "$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf2.tsv" "$W/ps-bad.bin" \
    wad_data:7 > "$W/ps-bad.err" 2>&1 || true
  want "a cell broken before the session is named with its index" /dev/stdin \
    'value: wad_data\[7\]: session has 255 and original has 0' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
    --a "$W/ps-bad.bin" --b "$W/ref-fullprep.bin" --label-a session --label-b original 2>&1 | head -1)
EOF
  # AND ONE PREPARED NAME WITHHELD: the session's own refusal, which is what
  # stops a missing field becoming substitute zeros.
  want "a prepared name with no bytes is refused by the session" /dev/stdin \
    'wad_data wants prepared:wad_data, which Full did not prepare' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf3.tsv" "$W/ps-drop.bin" "" wad_data 2>&1 | head -1)
EOF

  # A PREPARED SCALAR, carried in `core_state`. `@th_alloc` opens at 97 after
  # Game.new; its low byte flipped is 158. The comparator names the FIELD and
  # its index, not a cell of `core_state`, and nothing else in the snapshot moves.
  "$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf7.tsv" "$W/ps-thalloc.bin" \
    game_th_alloc:0 > /dev/null 2>&1 || true
  want "a prepared scalar broken before the session is named as its field" /dev/stdin \
    'value: game_th_alloc\[0\]: session has 158 and original has 97' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
    --a "$W/ps-thalloc.bin" --b "$W/ref-fullprep.bin" --label-a session --label-b original 2>&1 | head -1)
EOF
  ok "and it is the only byte of the session's snapshot that moved" \
     "$("$RUBY" -e 'a = File.binread(ARGV[0]); b = File.binread(ARGV[1])
                    print a.bytesize == b.bytesize ? a.bytes.zip(b.bytes).count { |x, y| x != y } : "length"' \
        "$W/ps.bin" "$W/ps-thalloc.bin")" "1"
  # AND WITHHELD: Full's assembly of core_state refuses it by field and slot
  # before the session opens, rather than leaving the slot at zero.
  want "a prepared scalar with no bytes is refused when core_state is assembled" /dev/stdin \
    'game_th_alloc \(slot [0-9]+\) wants prepared:game_th_alloc, which Full did not prepare' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf8.tsv" "$W/ps-thdrop.bin" "" game_th_alloc 2>&1 | head -1)
EOF
  ok "and no snapshot was written" \
     "$([ -f "$W/ps-thdrop.bin" ] && echo present || echo absent)" "absent"

  # THE SOURCE ALIASES AS A SELECTOR AND A BASE (docs/core/doom-source-alias.md).
  # `@dc_srcbuf` folds into renderer_dc_srcres/_srcbase and `@ds_source` becomes
  # renderer_ds_srcres/_srcbase; Full and the reference each convert the
  # original's buffer choice. Before the first tick nothing is selected: the
  # four cells are RES_NONE -1 and base 0, read by name out of Full's bytes.
  # Keep the command substitution outside a quoted function argument: bash
  # 3.2 otherwise brace-expands the nested Ruby interpolation and splits it.
  source_cells=$("$RUBY" -e '
        lay = File.readlines(ARGV[0]).reject { |l| l.start_with?("#") }.map { |l| l.split("\t") }
        b = File.binread(ARGV[1])
        print %w[renderer_dc_srcres renderer_dc_srcbase renderer_ds_srcres renderer_ds_srcbase].map { |n|
          f = lay.find { |x| x[0] == n } or next "#{n}=absent"
          "#{n}=#{b.byteslice(Integer(f[4], 10), 8).unpack1("q<")}"
        }.join(" ")' "$W/fullprep.tsv" "$W/fullprep.bin")
  ok "the four source cells Full prepares open at RES_NONE and base 0" \
     "$source_cells" \
     "renderer_dc_srcres=-1 renderer_dc_srcbase=0 renderer_ds_srcres=-1 renderer_ds_srcbase=0"
  ok "and the alias fields themselves are gone from the schema" \
     "$(grep -cE "^renderer_(dc_srcbuf|ds_source)${TAB}" "$CORE/state.tsv" || true)" "0"
  ok "and the representation says what it folded and what it added" \
     "$(grep '^representations ' "$W/elim.out")" "representations folded 1 added 2 added-in-schema 2"
  ok "and the executor's banks and schedule columns are recorded as Jobs' storage, and the status bar's and the HUD's WAD as the renderer's (decision 0021), with no rows of their own" \
     "$(grep '^aliases ' "$W/elim.out")" "aliases 7 recorded-in-schema 7 in-inventory 7 own-row 0"
  # RUNNING: the original renderer over 60 tics of DEMO1, direct CPU path. At
  # every column and span consumer the two conversions agree, nothing is
  # RES_NONE, and reading THROUGH (selector, base) from the declared resources
  # gives the bytes the original reads; at every frame end they agree again.
  # The direct zone draw no longer stores @zonewin in @dc_srcbuf: the retained
  # source at each frame end is WAD, while consumer probes still check all
  # 660 zone-window reads independently.
  SS="$ROOT/tests/doom-core/source-select.rb"
  "$RUBY" "$SS" "$WADFILE" 60 > "$W/ss.out" 2>&1 || true
  ok "before the first tick both conversions select nothing" "$(sed -n 1p "$W/ss.out")" "pre-tick -1 0 -1 0"
  ok "every consumer reads the same bytes through selector and base" \
     "$(sed -n 2,4p "$W/ss.out" | tr '\n' '|')" \
     "tics 60 columns 37049 spans 9837 boundary dc:1=60,ds:3=60|reads dc:0=32851,dc:1=3538,dc:2=660,ds:3=9837|faults disagree 0 res-none-consumer 0 read-mismatch 0 boundary-disagree 0|"
  for m in raw-srcres base-off res-none wrong-res; do
    "$RUBY" "$SS" "$WADFILE" 60 "$m" > "$W/ss-$m.out" 2>&1 || true
  done
  ok "Full reading the original's @dc_srcres as is disagrees before the first tick" \
     "$(sed -n 1p "$W/ss-raw-srcres.out")" "pre-tick 0/-1 0 -1 0"
  ok "  and at the first column" "$(sed -n 5p "$W/ss-raw-srcres.out")" "first disagree tic 0 x 96"
  ok "a base one byte off is a read mismatch, by tic and column" \
     "$(sed -n 4,5p "$W/ss-base-off.out" | tr '\n' '|')" \
     "faults disagree 0 res-none-consumer 0 read-mismatch 46886 boundary-disagree 0|first read-mismatch tic 0 x 261|"
  ok "a consumer reached with nothing selected is reported and not drawn" \
     "$(sed -n 4,5p "$W/ss-res-none.out" | tr '\n' '|')" \
     "faults disagree 0 res-none-consumer 1 read-mismatch 0 boundary-disagree 0|first res-none-consumer tic 0 x 41|"
  ok "a texture column called WAD data disagrees with the reference" \
     "$(sed -n 5p "$W/ss-wrong-res.out")" "first disagree tic 0 x 261"

  # THE WAD DIRECTORY ARRAYS, broken the same ways (docs/core/doom-lump-directory.md).
  # A marker's position: E1M1 at index 6 holds 67500, and its low byte flipped
  # is 67411 -- so a zeroed or skipped marker could not pass this.
  "$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf4.tsv" "$W/ps-lpos.bin" \
    wad_lump_pos:6 > /dev/null 2>&1 || true
  want "a marker's position broken before the session is named with its index" /dev/stdin \
    'value: wad_lump_pos\[6\]: session has 67411 and original has 67500' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
    --a "$W/ps-lpos.bin" --b "$W/ref-fullprep.bin" --label-a session --label-b original 2>&1 | head -1)
EOF
  # The LAST entry's name, F_END, at 8 * 1263: its `F` (70) flipped is 185.
  "$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf5.tsv" "$W/ps-lname.bin" \
    wad_lump_name:10104 > /dev/null 2>&1 || true
  want "the last entry's name broken before the session is named with its index" /dev/stdin \
    'value: wad_lump_name\[10104\]: session has 185 and original has 70' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/fullprep.tsv" \
    --a "$W/ps-lname.bin" --b "$W/ref-fullprep.bin" --label-a session --label-b original 2>&1 | head -1)
EOF
  want "a directory array withheld is refused by the session" /dev/stdin \
    'wad_lump_size wants prepared:wad_lump_size, which Full did not prepare' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/partial-session.rb" "$W/real/buffers.tsv" \
    "$W/fullprep.tsv" "$W/fullprep.bin" "$W/ps-buf6.tsv" "$W/ps-ldrop.bin" "" wad_lump_size 2>&1 | head -1)
EOF
  # A MISSING ENTRY: the same IWAD with one directory entry, DSPISTOL, removed
  # and sixteen zero bytes put back after the directory, so the file -- and
  # `wad_data` -- keep their length and only the directory is one short. The
  # layout still describes this configuration's 1264 entries.
  "$RUBY" -e '
    src = File.binread(ARGV[0]); n, dir = src.byteslice(4, 8).unpack("l<l<")
    k = (0...n).find { |i| src.byteslice(dir + 16 * i + 8, 8) == "DSPISTOL" } or abort("no DSPISTOL")
    out = src.byteslice(0, 4) + [n - 1, dir].pack("l<l<") + src.byteslice(12, dir - 12) +
          src.byteslice(dir, 16 * k) + src.byteslice(dir + 16 * (k + 1), 16 * (n - k - 1)) +
          ("\0".b * 16) + src.byteslice(dir + 16 * n, src.bytesize - dir - 16 * n)
    out.bytesize == src.bytesize or abort("the file changed length")
    File.binwrite(ARGV[1], out)' "$WADFILE" "$W/short-dir.wad"
  want "a directory one entry short is refused by name, not padded" /dev/stdin \
    'build-prepared.rb: wad_lump_name: Full produced 10104 byte\(s\) and the layout declares 10112' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/build-prepared.rb" "$W/real/snapshot.tsv" \
    "$ROOT/tools/doom/core-acquired.tsv" "$CORE/state.tsv" \
    "$W/short-dir.tsv" "$W/short-dir.bin" "$W/short-dir.wad" E1M1 1 2 10 1 2>&1 | tail -1)
EOF
  # A WRONG LENGTH the other way: the real WAD against a layout that gives
  # `wad_lump_pos` one entry fewer than Full produces.
  "$RUBY" -e '
    n = 0
    out = File.readlines(ARGV[0]).map { |l|
      f = l.chomp.split("\t", -1)
      next l unless f[0] == "wad_lump_pos"
      n += 1
      f[2] = (Integer(f[2], 10) - 1).to_s
      f[3] = (Integer(f[3], 10) - 4).to_s
      f.join("\t") + "\n"
    }
    abort("no wad_lump_pos row") unless n == 1
    File.write(ARGV[1], out.join)' "$W/real/snapshot.tsv" "$W/lposlen.tsv"
  ok "the length mutation is one line" \
     "$(diff "$W/real/snapshot.tsv" "$W/lposlen.tsv" | grep -c '^[<>]')" "2"
  want "a directory array of the wrong length is refused by name" /dev/stdin \
    'build-prepared.rb: wad_lump_pos: Full produced 5056 byte\(s\) and the layout declares 5052' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/build-prepared.rb" "$W/lposlen.tsv" \
    "$ROOT/tools/doom/core-acquired.tsv" "$CORE/state.tsv" \
    "$W/lposlen-o.tsv" "$W/lposlen-o.bin" "$WADFILE" E1M1 1 2 10 1 2>&1 | tail -1)
EOF

  ok "carried intact by the route, both sides from the same snapshot" \
     "$(cmp_prep "$W/sess-tp-p.bin")" \
     "compare-state: 556 field(s), 16751680 bytes, session and reference agree"
  # AND THE FULL SNAPSHOT IS CHECKED BEFORE IT IS PROJECTED. Mac review added
  # one byte to the end of a full snapshot and this lane did not move: the
  # projection reads offsets that are all below the end, so an excess tail is
  # invisible to it and to everything downstream. The comparator's length
  # check is on the PROJECTION and cannot see the original.
  cat "$W/sess-tp.bin" > "$W/long.bin"; printf '\0' >> "$W/long.bin"
  ok "the mutation is one byte" \
     "$("$RUBY" -e 'print File.size(ARGV[1]) - File.size(ARGV[0])' "$W/sess-tp.bin" "$W/long.bin")" "1"
  want "a full snapshot of the wrong length is refused before projection" /dev/stdin \
    'slice-snapshot.rb: .*long.bin is [0-9]+ byte\(s\) and .*snapshot.tsv describes [0-9]+' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/slice-snapshot.rb" "$W/real/snapshot.tsv" \
    "$W/prep.tsv" "$W/long.bin" "$W/long-p.bin" 2>&1 || true)
EOF
  ok "and nothing was written" \
     "$([ -f "$W/long-p.bin" ] && echo present || echo absent)" "absent"
  # AND A GAP AND AN OVERLAP THAT CANCEL. The first version of that length
  # check compared the summed field lengths with the layout's end, which is
  # satisfied by a layout that is wrong in two places by the same amount: Mac
  # review's three two-byte fields at 0, 1 and 4 sum to six and end at six,
  # while the second overlaps the first and two bytes in the middle belong to
  # no field at all. It projected `abbcef` out of `abcdef` and exited 0.
  #
  # Four layouts over the same six bytes, so the check is shown to accept the
  # good one as well as refuse the bad ones -- a check that refuses everything
  # would pass three of these.
  SS="$ROOT/tests/doom-core/slice-snapshot.rb"
  printf 'abcdef' > "$W/ss-src.bin"
  printf '#field\telement\tcount\tbytes\toffset\na\tu8\t2\t2\t0\nb\tu8\t2\t2\t2\nc\tu8\t2\t2\t4\n' > "$W/ss-good.tsv"
  printf '#field\telement\tcount\tbytes\toffset\na\tu8\t2\t2\t0\nb\tu8\t2\t2\t3\nc\tu8\t2\t2\t5\n' > "$W/ss-gap.tsv"
  printf '#field\telement\tcount\tbytes\toffset\na\tu8\t2\t2\t0\nb\tu8\t2\t2\t1\nc\tu8\t2\t2\t3\n' > "$W/ss-over.tsv"
  printf '#field\telement\tcount\tbytes\toffset\na\tu8\t2\t2\t0\nb\tu8\t2\t2\t1\nc\tu8\t2\t2\t4\n' > "$W/ss-cancel.tsv"
  rm -f "$W/ss-out.bin"
  "$RUBY" "$SS" "$W/ss-good.tsv" "$W/ss-good.tsv" "$W/ss-src.bin" "$W/ss-out.bin" \
    > "$W/ss-good.err" 2>&1 || true
  ok "a contiguous layout projects every byte" \
     "$([ -f "$W/ss-out.bin" ] && cat "$W/ss-out.bin" || echo NOTHING)" "abcdef"
  for bad in gap over cancel; do
    rm -f "$W/ss-out.bin"
    "$RUBY" "$SS" "$W/ss-$bad.tsv" "$W/ss-good.tsv" "$W/ss-src.bin" "$W/ss-out.bin" \
      > "$W/ss-$bad.err" 2>&1 || true
    want "a layout with a $bad is refused by the running offset" "$W/ss-$bad.err" \
      'slice-snapshot.rb: .*: b begins at [0-9]+ and the fields before it end at 2'
    ok "and the $bad wrote nothing" \
       "$([ -f "$W/ss-out.bin" ] && echo present || echo absent)" "absent"
  done

  # A byte SHORT is refused by the same check, and for the same reason.
  "$RUBY" -e 'File.binwrite(ARGV[1], File.binread(ARGV[0])[0..-2])' "$W/sess-tp.bin" "$W/short.bin"
  want "and so is one that is short" /dev/stdin \
    'slice-snapshot.rb: .*short.bin is [0-9]+ byte\(s\) and .*snapshot.tsv describes [0-9]+' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/slice-snapshot.rb" "$W/real/snapshot.tsv" \
    "$W/prep.tsv" "$W/short.bin" "$W/short-p.bin" 2>&1 || true)
EOF
  # THE CONTROL, and it must name the field AND the index AND both values.
  want "one broken cell is named, with its index" \
    /dev/stdin 'level_sector_validcount\[0\]: session has 255 and reference has 0' \
    <<EOF
$(cmp_prep "$W/sess-tpc-p.bin")
EOF
  # AND A TRUNCATION IS REFUSED BY LENGTH, which is what the old lane could
  # not see: cutting both sides short made every missing field compare equal.
  head -c 200000 "$W/sess-tp-p.bin" > "$W/trunc-a.bin"
  head -c 200000 "$W/ref-p.bin" > "$W/trunc-b.bin"
  want "a truncated snapshot is refused by length" /dev/stdin \
    'length: session .* is 200000 bytes and the layout describes 16751680' \
    <<EOF
$("$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/prep.tsv" \
    --a "$W/trunc-a.bin" --b "$W/trunc-b.bin" --label-a session --label-b reference 2>&1 | tail -1)
EOF

  # The comparator is what reports them, and it names the field and the index.
  "$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/stored.tsv" \
    --a "$W/sess-stored.bin" --b "$W/ref-stored.bin" \
    --label-a schema --label-b reference > "$W/cmpref.out" 2>&1 || true
  # The example has moved three times, and each move was a field leaving the
  # difference list for a reason: `demo_writer_buf` is REFUSED by the encoder
  # (it holds 160014 where the schema declares 160013) and so reaches the
  # comparator with no value at all, and `game_activeplats` now AGREES,
  # because the catalog used to declare it 64 cells long when MAXPLATS is 30.
  # `game_bestslideline` left it in turn, and the example is now
  # `demo_writer_buf` -- which could only reach the comparator once
  # `demobytes` was corrected from the hand-written 160013 to the measured
  # 160014, because until then the field was refused for its shape.
  # What is checked has not moved: the comparator names the FIELD, the INDEX
  # and BOTH values, rather than counting bytes. So the form is checked on its
  # own, and a named field is kept beside it so that a comparator printing one
  # well-formed line about nothing would still fail.
  #
  # THERE ARE NO DIFFERENCES LEFT TO READ IT FROM. Every stored field setup
  # writes is carried by Full now, and the fills that stand all agree -- so the
  # whole stored lane compares equal except the fields the encoder refuses,
  # which are counted on their own and are no evidence either way.
  ok "the fills that stand all agree with the original" \
     "agree $(df agree) / differ $(df differ) / unencodable $(df unencodable)" \
     "agree 119 / differ 0 / unencodable 0"
  # So the comparator's FORM is shown on one byte broken here: the first stored
  # field the encoder does not refuse, its first byte flipped on the schema side.
  "$RUBY" -e '
    layout, bin, refused, out = ARGV
    skip = File.readlines(refused).map(&:strip)
    row = File.readlines(layout).reject { |l| l.start_with?("#") }.map { |l| l.chomp.split("\t") }
              .find { |f| !skip.include?(f[0]) } or abort("no comparable stored field")
    b = File.binread(bin); o = Integer(row[4], 10)
    b.setbyte(o, b.getbyte(o) ^ 0xff)
    File.binwrite(out, b)
    print row[0]' "$W/stored.tsv" "$W/sess-stored.bin" "$W/shapefields.txt" "$W/sess-stored-bad.bin" > "$W/cmpbad.name"
  "$RUBY" "$ROOT/tests/doom-core/compare-state.rb" --layout "$W/stored.tsv" \
    --a "$W/sess-stored-bad.bin" --b "$W/ref-stored.bin" \
    --label-a schema --label-b reference > "$W/cmpbad.out" 2>&1 || true
  want "a difference is named in that form" "$W/cmpbad.out" \
    '^compare-state: value: [a-z0-9_]+\[[0-9]+\]: schema has -?[0-9]+ and reference has -?[0-9]+ \((i64|i32|u32|i16|u16|i8|u8), byte [0-9]+\)$'
  want "with the field it broke, at index 0" "$W/cmpbad.out" \
    "value: $(cat "$W/cmpbad.name")\\[0\\]: schema has "
fi

echo "== the ported slot list answers what the original answers =="
# THE ORIGINAL IS `Doom::Game` ITSELF -- `add_thinker`, `remove_thinker` and
# `run_thinkers`, called on a real instance. It used to be that code with
# `self` replaced by a hash, and the model's own header claimed that made it
# independent; Mac review of 33da4d9 made the same point about the BSP and
# sound models and it applied here too. The port is the CORE source over
# buffers. What is checked is that moving the state did not move the answer.
"$RUBY" "$ROOT/tests/doom-core/slot-model.rb" > "$W/slots.out" 2>&1 || true
sl() { grep "^$1 " "$W/slots.out" | head -1 | cut -d" " -f2-; }
ok "the oracle is game.rb itself"          "$(sl reaches-original)" "true"
ok "fourteen operations, none disagreeing" "$(sl disagree)" "0"
# THE STORE, which the migration row was missing: comparing the live ORDER
# alone would not notice that `th_func`/`th_data` never received anything.
ok "and every slot carries what was passed" "$(sl store-disagree)" "0"
# At the REAL MAXTHINKERS boundary, not a small number chosen to be quick.
# The original raises LevelError; the port answers CAPACITY. Same event.
ok "the arena exhausts where the game's does" "$(sl exhausts-at)" "4095 4095"
ok "and both agree that is the edge"          "$(sl exhaustion-agrees)" "true"
want "the reuse order is LIFO and observable" "$W/slots.out" \
  '^  add	slot 1/1	live 2,4,5,6,7,1 | 2,4,5,6,7,1$'

echo "== and the same answers from a CORE object =="
# The two units are packed by tools/doom/pack-core.rb -- task 2's packer
# feeding task 5's source -- and the entry wrapper is what supplies the counts
# a boundary declares while the helpers take borrowed buffers.
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
source_stamp kernel "$KERNEL"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else CC_BIN=""; fi
if [ ! -x "$KERNEL" ] || [ -z "$CC_BIN" ] || [ ! -x "$CC_BIN" ]; then
  why=""
  [ -x "$KERNEL" ] || why="no kernel at $KERNEL"
  [ -n "$CC_BIN" ] && [ -x "$CC_BIN" ] || why="${why:+$why; }no compiler (${CC_BIN:-neither CLANG nor LLVM_PREFIX is set})"
  skipped "the CORE lane" "$why" \
    "KERNEL=/path/to/spinel-core-kernel and LLVM_PREFIX=/path/to/llvm (or CLANG)"
else
  SLOTS="$ROOT/tests/doom-core/fixtures/state/slots"
  mkdir -p "$W/slotsrc/slots" "$W/slotunit/slots"
  # THE FIXTURE DOES NOT CARRY A COPY of the unit. It stages
  # examples/doom/core/src/thinkers.rb itself beside the entry wrappers, and
  # the fixture manifest pins the SAME sha256 that
  # examples/doom/core/sources.tsv pins -- so editing the unit and forgetting
  # either one fails here instead of compiling a stale twin. It used to be a
  # copy, which is how `dc_store_thinker` could be missing from the real unit
  # while this lane went on passing.
  cp "$ROOT/examples/doom/core/src/thinkers.rb" "$W/slotunit/slots/thinkers.rb"
  cp "$SLOTS/entries.rb" "$W/slotunit/slots/entries.rb"
  ok "the fixture pins the unit's own hash" \
    "$(awk -F"\t" '$1 == "slots/thinkers.rb" { print $2 }' "$SLOTS/manifest.tsv")" \
    "$(awk -F"\t" '$1 == "thinkers.rb" { print $2 }' "$ROOT/examples/doom/core/sources.tsv")"
  "$RUBY" "$ROOT/tools/doom/pack-core.rb" --manifest "$SLOTS/manifest.tsv" \
    --root "$W/slotunit" --reader "$READER" \
    --output "$W/slotsrc/slots/packed.rb" --map "$W/slotsrc/map.tsv" \
    > "$W/pack.err" 2>&1 && echo 0 > "$W/pack.rc" || echo $? > "$W/pack.rc"
  ok   "the two units pack"       "$(cat "$W/pack.rc")" 0
  # 129 lines since 0019 (642fda4): each CORE source starts with "# spinel: int64".
  want "into twelve definitions"  "$W/pack.err" '2 unit\(s\), 129 line\(s\), 12 definition\(s\)'
  sed 's|root slots/entries.rb|root slots/packed.rb|' "$SLOTS/take.contract" > "$W/slotsrc/take.contract"
  "$KERNEL" "$W/slotsrc/take.contract" --root "$W/slotsrc" --typedump "$READER" -o "$W/take.o" \
    --header "$W/take.h" --clang "$CC_BIN" > "$W/take.err" 2>&1 \
    && echo 0 > "$W/take.rc" || echo $? > "$W/take.rc"
  ok "the packed entry compiles as a core object" "$(cat "$W/take.rc")" 0
  cat > "$W/take.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "take.h"
int main(void) {
  int64_t th_free[1] = {-1}, th_prev[8] = {0}, th_alloc[1] = {1};
  int64_t r; int32_t s;
  for (int i = 0; i < 9; i++) {
    r = 999; s = spinel_core_dc_take(th_free, 1, th_prev, 8, th_alloc, 1, 8, &r);
    printf("%lld ", (long long)r); (void)s;
  }
  th_prev[3] = th_free[0]; th_free[0] = 3;
  r = 999; s = spinel_core_dc_take(th_free, 1, th_prev, 8, th_alloc, 1, 8, &r);
  printf("| %lld\n", (long long)r);
  return 0;
}
CEOF
  if "$CC_BIN" -I"$W" "$W/take.c" "$W/take.o" -o "$W/take" > "$W/takelink.err" 2>&1; then
    ok "the native sequence is the Ruby sequence" "$("$W/take")" \
       "1 2 3 4 5 6 7 -1 -1 | 3"
  else
    echo "  FAIL the core object did not link"; sed 's/^/        /' "$W/takelink.err" | head -4
    fail=$((fail + 1))
  fi

  echo "== P_AddThinker as ONE entry, with a public CAPACITY =="
  # Mac review of 33da4d9: mapping `add_thinker` to take+link left out the
  # func/data store (which lived in slot-model.rb) and left overflow as a -1
  # sentinel nobody read. `dc_add_thinker` is the whole operation, and the
  # arena being full is the CAPACITY status, not a magic return value.
  #
  # It is its own unit because the kernel compiles ONE CLOSURE PER FILE, and
  # `dc_take`/`dc_link` call helpers inside this entry's closure -- packed
  # together, the kernel answers `unaccounted-ingress`, correctly.
  mkdir -p "$W/addsrc/slots"
  cp "$ROOT/examples/doom/core/src/thinkers.rb" "$W/addunit/slots/thinkers.rb" 2>/dev/null || {
    mkdir -p "$W/addunit/slots"
    cp "$ROOT/examples/doom/core/src/thinkers.rb" "$W/addunit/slots/thinkers.rb"; }
  cp "$SLOTS/add_entry.rb" "$W/addunit/slots/add_entry.rb"
  "$RUBY" "$ROOT/tools/doom/pack-core.rb" --manifest "$SLOTS/add-manifest.tsv" \
    --root "$W/addunit" --reader "$READER" --output "$W/addsrc/slots/packed.rb" --map "$W/addmap.tsv" \
    > "$W/addpack.err" 2>&1 && echo 0 > "$W/addpack.rc" || echo $? > "$W/addpack.rc"
  ok "the entry packs with the unit" "$(cat "$W/addpack.rc")" 0
  sed 's|root slots/add_entry.rb|root slots/packed.rb|' "$SLOTS/add.contract" \
    > "$W/addsrc/add.contract"
  "$KERNEL" "$W/addsrc/add.contract" --root "$W/addsrc" --typedump "$READER" -o "$W/add.o" \
    --header "$W/add.h" --clang "$CC_BIN" > "$W/add.err" 2>&1 \
    && echo 0 > "$W/add.rc" || echo $? > "$W/add.rc"
  ok "and compiles as a core object" "$(cat "$W/add.rc")" 0
  cat > "$W/add.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "add.h"
#define CAP 8
int main(void) {
  int64_t th_free[1] = {-1}, th_alloc[1] = {1};
  int64_t th_prev[CAP] = {0}, th_next[CAP] = {0};
  int64_t th_func[CAP] = {0}, th_data[CAP] = {0};
  int64_t r; int32_t s;
  for (int i = 0; i < CAP + 1; i++) {
    r = -999;
    s = spinel_core_dc_add_thinker(th_free, 1, th_prev, CAP, th_alloc, 1,
                                   th_func, CAP, th_data, CAP, th_next, CAP,
                                   CAP, 10, 100 + i, &r);
    printf("%d:%d:%lld ", i, (int)s, (long long)r);
  }
  printf("\nstored");
  for (int i = 1; i < CAP; i++)
    printf(" %lld/%lld", (long long)th_func[i], (long long)th_data[i]);
  printf("\n");
  return 0;
}
CEOF
  if "$CC_BIN" -I"$W" "$W/add.c" "$W/add.o" -o "$W/add" > "$W/addlink.err" 2>&1; then
    "$W/add" > "$W/add.out" 2>&1
    ok "seven slots, then CAPACITY with the result untouched" \
      "$(sed -n 1p "$W/add.out")" \
      "0:0:1 1:0:2 2:0:3 3:0:4 4:0:5 5:0:6 6:0:7 7:4:-999 8:4:-999 "
    # The store is the part the migration row was missing. A CAPACITY return
    # writes NOTHING, which is why the result reads back as the caller's -999.
    ok "and every slot carries what was passed" "$(sed -n 2p "$W/add.out")" \
      "stored 10/100 10/101 10/102 10/103 10/104 10/105 10/106"
  else
    echo "  FAIL the add entry did not link"; sed 's/^/        /' "$W/addlink.err" | head -4
    fail=$((fail + 1))
  fi
fi

echo "== the REAL schema, driven natively =="
# Decision 0008 task 5: the session "exposes their IDs to generated adapters".
# Until now every native lane here used a fixture's own invented layout, so
# nothing connected the 700-field schema to a compiled entry -- which is what
# Mac review of 33da4d9 meant by the native registry being unmet.
#
# `registry.h` is generated from the same rows as everything else. The driver
# below takes BOTH the buffer sizes and the two scalar slot indices from it, so
# a C file cannot hold a second opinion about the layout: move a field in the
# schema and this moves with it or fails to build.
#
# The oracle is `Doom::Game` itself over the same sequence -- the native run is
# compared against the original's arrays, not against numbers written here.
if [ -s "$W/real/registry.h" ] && [ -x "$KERNEL" ] && [ -n "$CC_BIN" ] && [ -x "$CC_BIN" ] && [ -f "$W/add.o" ]; then
  want "the registry names the scalar slots" "$W/real/registry.h" \
    '^#define SPINEL_DOOM_SLOT_GAME_TH_FREE [0-9]+$'
  want "and gives every allocation an id"    "$W/real/registry.h" \
    '^  SPINEL_DOOM_BUF_GAME_TH_NEXT = [0-9]+,$'
  want "with the count the schema declares"  "$W/real/registry.h" \
    '\{ "game_th_next", "persistent", "u16", 4096 \}'
  "$RUBY" "$ROOT/tests/doom-core/slot-model.rb" --trace > "$W/trace.out" 2>&1 || true
  tr() { grep "^$1 " "$W/trace.out" | head -1 | cut -d" " -f2-; }
  # THE TWO GENERATED VIEWS OF ONE LAYOUT MUST AGREE. `slots.rb` is what
  # generated Ruby indexes `core_state` with; `registry.h` is what a native
  # caller uses. Nothing above pins them together: measured, shifting EVERY
  # slot index in registry.h by one left this lane at 115/115, because the
  # driver allocates `core_state` itself and only ever uses the indices
  # relative to each other. So the indices are compared directly, which is the
  # check that mutation actually fails.
  "$RUBY" -e '
    require ARGV[0]
    print "#{Doom::CoreSlots::GAME_TH_FREE} #{Doom::CoreSlots::GAME_TH_ALLOC} " \
          "#{Doom::CoreSlots::COUNT}"
  ' "$W/real/slots.rb" > "$W/rbslots.txt" 2>&1 || true
  cat > "$W/reg.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "add.h"
#include "registry.h"

/* The allocation table says how big each buffer is. Nothing here says 4096. */
static int64_t alloc_count(const char *name) {
  size_t i;
  for (i = 0; i < sizeof(spinel_doom_allocs) / sizeof(spinel_doom_allocs[0]); i++)
    if (strcmp(spinel_doom_allocs[i].name, name) == 0)
      return spinel_doom_allocs[i].count;
  fprintf(stderr, "no allocation named %s\n", name);
  exit(2);
}

static void row(const char *label, const int64_t *a, int n) {
  int i;
  printf("%s ", label);
  for (i = 0; i < n; i++) printf("%s%lld", i ? "," : "", (long long)a[i]);
  printf("\n");
}

int main(void) {
  const int64_t cap = alloc_count("game_th_next");
  const int64_t slots = alloc_count("core_state");
  int64_t *state = calloc((size_t)slots, sizeof(int64_t));
  int64_t *next = calloc((size_t)cap, sizeof(int64_t));
  int64_t *prev = calloc((size_t)cap, sizeof(int64_t));
  int64_t *func = calloc((size_t)cap, sizeof(int64_t));
  int64_t *data = calloc((size_t)cap, sizeof(int64_t));
  int64_t r; int32_t s; int i;
  if (!state || !next || !prev || !func || !data) return 2;

  /* The session's initial values, from the schema. `game_th_data` has the
     literal fill -1 and `game_th_next`/`game_th_prev` have 0, which calloc
     already gives.

     `game_th_func` is declared `prepared:maxthinkers` -- NOT a fill of 4096.
     `prepared:` means Full hands the contents over, which is what the emitter
     does with any fill it cannot read as a literal, and `TH_NULL` is a
     constant. So this harness plays Full for that one buffer and fills it the
     way `Doom::Game` does. Reading `prepared:` as "needs no fill" is what made
     this driver disagree with the original at slots 0 and 23 on the first run
     -- the two the port never writes. */
  for (i = 0; i < cap; i++) data[i] = -1;
  for (i = 0; i < cap; i++) func[i] = 10;   /* TH_NULL, as Full prepares it */
  state[SPINEL_DOOM_SLOT_GAME_TH_FREE] = -1;
  state[SPINEL_DOOM_SLOT_GAME_TH_ALLOC] = 1;

  /* TWO DISJOINT ONE-ELEMENT SLICES OF ONE ALLOCATION, which is what the real
     schema forces: both scalars live in core_state. Measured, the boundary
     accepts disjoint slices and answers ARGUMENT (writing nothing) for
     genuinely overlapping inout ranges, so this is the legal shape. */
#define ADD(fn, dt) spinel_core_dc_add_thinker( \
    state + SPINEL_DOOM_SLOT_GAME_TH_FREE, 1, prev, cap, \
    state + SPINEL_DOOM_SLOT_GAME_TH_ALLOC, 1, \
    func, cap, data, cap, next, cap, cap, (fn), (dt), &r)

  for (i = 0; i < 20; i++) { s = ADD(10, 200 + i); if (s) { printf("add %d\n", s); return 1; } }
  { const int rm[3] = {3, 1, 9}; int k;
    for (k = 0; k < 3; k++) {
      /* `remove_thinker` marks and `run_thinkers` unlinks and frees. NEITHER
         IS PORTED YET, so the harness does what they do -- and says so here
         rather than letting a reader think the whole path is native. */
      int64_t tt = rm[k];
      next[prev[tt]] = next[tt];
      prev[next[tt]] = prev[tt];
      func[tt] = 10; data[tt] = -1;
      prev[tt] = state[SPINEL_DOOM_SLOT_GAME_TH_FREE];
      state[SPINEL_DOOM_SLOT_GAME_TH_FREE] = tt;
    } }
  for (i = 0; i < 5; i++) { s = ADD(10, 300 + i); if (s) { printf("add %d\n", s); return 1; } }

  row("trace-next", next, 24);
  row("trace-prev", prev, 24);
  row("trace-func", func, 24);
  row("trace-data", data, 24);
  printf("trace-free %lld\n", (long long)state[SPINEL_DOOM_SLOT_GAME_TH_FREE]);
  printf("trace-alloc %lld\n", (long long)state[SPINEL_DOOM_SLOT_GAME_TH_ALLOC]);
  /* The indices themselves, so `slots.rb` and this header cannot drift. */
  printf("trace-slots %d %d %d\n", SPINEL_DOOM_SLOT_GAME_TH_FREE,
         SPINEL_DOOM_SLOT_GAME_TH_ALLOC, SPINEL_DOOM_SLOT_COUNT);
  return 0;
}
CEOF
  if "$CC_BIN" -I"$W" -I"$W/real" "$W/reg.c" "$W/add.o" -o "$W/reg" > "$W/reglink.err" 2>&1; then
    "$W/reg" > "$W/reg.out" 2>&1
    nt() { grep "^$1 " "$W/reg.out" | head -1 | cut -d" " -f2-; }
    ok "the native link order is the original's"   "$(nt trace-next)"  "$(tr trace-next)"
    ok "and so is the free-list order"             "$(nt trace-prev)"  "$(tr trace-prev)"
    ok "every slot's function code agrees"         "$(nt trace-func)"  "$(tr trace-func)"
    ok "and every slot's data"                     "$(nt trace-data)"  "$(tr trace-data)"
    ok "the free head lands where the game's does" "$(nt trace-free)"  "$(tr trace-free)"
    ok "and so does the high-water mark"           "$(nt trace-alloc)" "$(tr trace-alloc)"
    ok "the header and slots.rb are one layout"    "$(nt trace-slots)" "$(cat "$W/rbslots.txt")"
  else
    echo "  FAIL the registry-driven driver did not build"
    sed 's/^/        /' "$W/reglink.err" | head -5
    fail=$((fail + 1))
  fi
else
  skipped "the real-schema native lane" "no generated registry, kernel, compiler or linked driver" \
    "KERNEL=/path/to/spinel-core-kernel and LLVM_PREFIX=/path/to/llvm (or CLANG)"
fi

summary
