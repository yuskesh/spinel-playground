#!/bin/sh
#
# tests/doom-core/source-pack.sh — decision 0008 task 2's packaging checks.
#
# The packer's job is to be boring: the same manifest over the same bytes must
# give the same output, every packed line must be traceable to the unit it came
# from, and anything it cannot vouch for must be refused BY NAME before an
# artifact is replaced. Each check here breaks one of those.
#
# A refusal is checked by its category and its origin, never by the exit
# status: the packer exits 1 for all of them, so an exit status alone would
# pass every control for the wrong reason.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/doom-core/fixtures/source-pack"
PACK="${PACK:-$ROOT/tools/doom/pack-core.rb}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp reader "$READER"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
RUBY="${RUBY:-ruby}"

die() { echo "source-pack: $*" >&2; exit 1; }
[ -x "$READER" ] || die "no reader at $READER (build it first)"
[ -f "$PACK" ] || die "no packer at $PACK"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"

TAB=$(printf "\\t")
W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-pack.XXXXXX")
# AN ABORT IS NOT A RESULT. The handler cleans up AND EXITS: a handler that
# only cleans up leaves the script running with its work directory deleted, so
# the next check cannot find its files, fails, and the suite prints a summary
# with a count as though it had finished. That is an abort dressed as a
# finding, and it is what a Ctrl-C, a CI limit or a `timeout` produces --
# measured on audit.sh, which has the same shape, on 2026-09-18. The exit
# status is what tells an abort from a result.
# tests/doom-core/abort-controls.sh sends each signal and requires no summary.
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
trap 'cleanup; echo "source-pack: interrupted (SIGINT); no summary follows" >&2; exit 130' INT
trap 'cleanup; echo "source-pack: terminated (SIGTERM); no summary follows" >&2; exit 143' TERM
pass=0; fail=0
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | tail -5; fail=$((fail + 1)); fi; }
reject() { if grep -qE "$3" "$2"; then echo "  FAIL $1 (the wrong answer is present)"; fail=$((fail + 1));
           else echo "  pass $1"; pass=$((pass + 1)); fi; }
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }

# A manifest built from the files on disk, so a fixture cannot drift from its
# digests without this noticing.
manifest() { # dir out [names...]
  d=$1; out=$2; shift 2
  : > "$out"
  for n in "$@"; do
    printf '%s%s%s\n' "$n" "$TAB" "$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$d/$n")" >> "$out"
  done
}
pack() { # workdir root manifest -> $W/<workdir>.err, .rb, .map
  mkdir -p "$W/$1"
  "$RUBY" "$PACK" --manifest "$3" --root "$2" --reader "$READER" \
    --output "$W/$1/packed.rb" --map "$W/$1/map.tsv" > "$W/$1.err" 2>&1 && echo 0 > "$W/$1.rc" || echo $? > "$W/$1.rc"
}

echo "== the plan's two units and direct helper =="
manifest "$FIX/ok/src" "$W/ok.mf" first.rb second.rb
pack ok "$FIX/ok/src" "$W/ok.mf"
ok "the pack succeeds" "$(cat "$W/ok.rc")" 0
cat "$FIX/ok/src/first.rb" "$FIX/ok/src/second.rb" > "$W/expect.rb"
if cmp -s "$W/ok/packed.rb" "$W/expect.rb"; then
  echo "  pass the packed bytes are the units and nothing else"; pass=$((pass + 1))
else
  echo "  FAIL the packed bytes are not the concatenation"; fail=$((fail + 1))
fi
want "the map names the first unit's lines"  "$W/ok/map.tsv" "^1${TAB}3${TAB}first\.rb${TAB}[0-9a-f]{64}$"
want "and the second unit's, continuing"     "$W/ok/map.tsv" "^4${TAB}6${TAB}second\.rb${TAB}[0-9a-f]{64}$"
want "the map binds the packed bytes"        "$W/ok/map.tsv" "^# packed${TAB}sha256:[0-9a-f]{64}$"
want "and the manifest it came from"         "$W/ok/map.tsv" "^# manifest${TAB}sha256:[0-9a-f]{64}$"
ok "and it maps every packed line" \
   "$("$RUBY" -e 'n=0; File.foreach(ARGV[0]){|l| next if l.start_with?("#")||l.start_with?("packed_start"); f=l.split("\t"); n+=f[1].to_i-f[0].to_i+1}; print n' "$W/ok/map.tsv")" \
   "$(wc -l < "$W/ok/packed.rb" | tr -d ' ')"

echo "== the same input gives the same bytes =="
pack ok2 "$FIX/ok/src" "$W/ok.mf"
if cmp -s "$W/ok/packed.rb" "$W/ok2/packed.rb" && cmp -s "$W/ok/map.tsv" "$W/ok2/map.tsv"; then
  echo "  pass a second run is byte-identical"; pass=$((pass + 1))
else
  echo "  FAIL a second run differs"; fail=$((fail + 1))
fi

echo "== the order is the manifest's =="
manifest "$FIX/order/src" "$W/fwd.mf" first.rb second.rb
manifest "$FIX/order/src" "$W/rev.mf" second.rb first.rb
pack fwd "$FIX/order/src" "$W/fwd.mf"
pack rev "$FIX/order/src" "$W/rev.mf"
ok "both orders pack" "$(cat "$W/fwd.rc")$(cat "$W/rev.rc")" "00"
if cmp -s "$W/fwd/packed.rb" "$W/rev/packed.rb"; then
  echo "  FAIL reversing the manifest produced the same bytes; the order is not being used"
  fail=$((fail + 1))
else
  echo "  pass reversing the manifest changes the packed bytes"; pass=$((pass + 1))
fi
want "and the map follows it" "$W/rev/map.tsv" "^1${TAB}3${TAB}second\.rb${TAB}"
want "with the other unit after" "$W/rev/map.tsv" "^4${TAB}6${TAB}first\.rb${TAB}"

echo "== what the packer refuses, by category and origin =="
refuse() { # label workdir root manifest pattern
  pack "$2" "$3" "$4"
  want "$1" "$W/$2.err" "$5"
  ok "  and it fails" "$(cat "$W/$2.rc")" 1
}
manifest "$FIX/dup-method/src" "$W/dupm.mf" first.rb second.rb
refuse "two units defining one method" dupm "$FIX/dup-method/src" "$W/dupm.mf" \
  "^pack-core: duplicate-definition: second\.rb: second\.rb defines dc_twice, which first\.rb already defines$"
manifest "$FIX/dup-const/src" "$W/dupc.mf" first.rb second.rb
refuse "two units assigning one constant" dupc "$FIX/dup-const/src" "$W/dupc.mf" \
  "^pack-core: duplicate-definition: second\.rb: second\.rb defines DC_LIMIT, which first\.rb already defines$"
manifest "$FIX/require/src" "$W/req.mf" first.rb second.rb
refuse "a unit that loads a sibling" req "$FIX/require/src" "$W/req.mf" \
  "^pack-core: require-relative: first\.rb: reading it also opened second\.rb;"
manifest "$FIX/toplevel/src" "$W/top.mf" first.rb
refuse "a unit that runs something" top "$FIX/toplevel/src" "$W/top.mf" \
  "^pack-core: top-level-execution: first\.rb: runs a CallNode at the top level"
manifest "$FIX/endmarker/src" "$W/end.mf" first.rb
refuse "a unit with __END__" endm "$FIX/endmarker/src" "$W/end.mf" \
  "^pack-core: end-marker: first\.rb: line 4 is __END__"
manifest "$FIX/syntax/src" "$W/syn.mf" first.rb
refuse "a unit that does not parse" syn "$FIX/syntax/src" "$W/syn.mf" \
  "^pack-core: syntax: first\.rb: the reader could not parse it"
manifest "$FIX/encoding-decl/src" "$W/encd.mf" first.rb
refuse "a unit declaring another coding" encd "$FIX/encoding-decl/src" "$W/encd.mf" \
  "^pack-core: encoding: first\.rb: declares coding euc-jp"
manifest "$FIX/encoding-bytes/src" "$W/encb.mf" first.rb
refuse "a unit that is not UTF-8" encb "$FIX/encoding-bytes/src" "$W/encb.mf" \
  "^pack-core: encoding: first\.rb: is not valid UTF-8"
manifest "$FIX/unlisted/src" "$W/unl.mf" first.rb
refuse "a .rb under the root nobody listed" unl "$FIX/unlisted/src" "$W/unl.mf" \
  "^pack-core: unlisted-unit: 1 \.rb file\(s\) under .*are not in the manifest: second\.rb$"

# Manifest-side refusals, over the good fixture.
good=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$FIX/ok/src/first.rb")
printf 'first.rb%s%s\nabsent.rb%s%s\n' "$TAB" "$good" "$TAB" "$good" > "$W/miss.mf"
refuse "a manifest naming a file that is not there" miss "$FIX/ok/src" "$W/miss.mf" \
  "^pack-core: missing-file: .*:2: absent\.rb is not a file under the root$"
printf 'first.rb%s%s\n' "$TAB" "0000000000000000000000000000000000000000000000000000000000000000" > "$W/bad.mf"
refuse "a manifest with the wrong digest" bad "$FIX/ok/src" "$W/bad.mf" \
  "^pack-core: digest: .*:1: first\.rb is sha256 $good, the manifest says 0{64}$"
printf '../first.rb%s%s\n' "$TAB" "$good" > "$W/trav.mf"
refuse "a path that climbs out" trav "$FIX/ok/src" "$W/trav.mf" \
  "^pack-core: path-traversal: .*:1: \.\./first\.rb climbs out with \.\.$"
printf 'first.rb%s%s\nfirst.rb%s%s\n' "$TAB" "$good" "$TAB" "$good" > "$W/twice.mf"
refuse "a path listed twice" twice "$FIX/ok/src" "$W/twice.mf" \
  "^pack-core: manifest: .*:2: first\.rb is listed twice, at line 1 and here$"

# A path with no `..` in it that still leaves the root, which only resolving it
# can see: the fixture is built here because a symlink out of the tree is not
# something to keep checked in.
mkdir -p "$W/escroot"
cp "$FIX/ok/src/first.rb" "$W/escroot/first.rb"
ln -s "$FIX/ok/src/second.rb" "$W/escroot/second.rb"
manifest "$W/escroot" "$W/esc.mf" first.rb second.rb
refuse "a link that resolves outside the root" esc "$W/escroot" "$W/esc.mf" \
  "^pack-core: outside-root: .*:2: second\.rb resolves to .*, which is outside "

echo "== one Integer width per entry (decision 0022 §2.6) =="
# The good fixture's two units declare nothing; wide.rb declares int64. A
# manifest's `#width` lines give each entry its width, and --entry picks one.
mkdir -p "$W/wroot"
cp "$FIX/ok/src/first.rb" "$FIX/ok/src/second.rb" "$W/wroot/"
manifest "$W/wroot" "$W/w-units.mf" first.rb second.rb
printf '#width\tdc_a\tint64\n#width\tdc_b\ttarget\n' | cat - "$W/w-units.mf" > "$W/w.mf"
pack_entry() { # workdir root manifest entry
  mkdir -p "$W/$1"
  "$RUBY" "$PACK" --manifest "$3" --root "$2" --reader "$READER" --entry "$4" \
    --output "$W/$1/packed.rb" --map "$W/$1/map.tsv" > "$W/$1.err" 2>&1 && echo 0 > "$W/$1.rc" || echo $? > "$W/$1.rc"
}
pack_entry w-a "$W/wroot" "$W/w.mf" dc_a
ok "an int64 entry packs" "$(cat "$W/w-a.rc")" 0
ok "  and its file starts with the declaration none of its units make" "$(head -1 "$W/w-a/packed.rb")" "# spinel: int64"
pack_entry w-b "$W/wroot" "$W/w.mf" dc_b
ok "a target entry packs from the same units" "$(cat "$W/w-b.rc")" 0
ok "  and its file is the units' bytes, with no declaration" \
   "$(cat "$W/wroot/first.rb" "$W/wroot/second.rb" | cmp -s - "$W/w-b/packed.rb" && echo same)" same
cp "$W/wroot/first.rb" "$W/wroot/second.rb" "$W/wroot2/" 2>/dev/null || { mkdir -p "$W/wroot2"; cp "$W/wroot/first.rb" "$W/wroot/second.rb" "$W/wroot2/"; }
{ printf '# spinel: int64\n'; cat "$W/wroot/second.rb"; } > "$W/wroot2/second.rb"
manifest "$W/wroot2" "$W/w2-units.mf" first.rb second.rb
printf '#width\tdc_a\tint64\n#width\tdc_b\ttarget\n' | cat - "$W/w2-units.mf" > "$W/w2.mf"
pack_entry w2-a "$W/wroot2" "$W/w2.mf" dc_a
ok "an int64 entry over a unit that declares it packs" "$(cat "$W/w2-a.rc")" 0
# Where the declaration came from (decision 0019): the map records the width
# line and the declaring units, and tools/doom/packed-place.rb turns the
# kernel's packed places into them. The kernel lines here are planted.
PLACE=$ROOT/tools/doom/packed-place.rb
want "the int64 entry's map records its manifest width line" "$W/w-a/map.tsv" "^# width${TAB}dc_a${TAB}int64${TAB}manifest line 1$"
placed() { # workdir root manifest-name line -> the placed line
  printf '%s\n' "$4" | "$RUBY" "$PLACE" --map "$W/$1/map.tsv" --packed "$W/$1/packed.rb" --units "$2" --manifest "$3"
}
ok "  a refused declaration on packed line 1 is the manifest's width line" \
   "$(placed w-a "$W/wroot" units.tsv "$W/w-a/packed.rb:1: int-width-int64-refused: x")" \
   "units.tsv:1: int-width-int64-refused: x (the manifest's \`#width\` line gives this entry int64)"
ok "  a packed line inside a unit is that unit's own line" \
   "$(placed w-a "$W/wroot" units.tsv "$W/w-a/packed.rb:2: some-code: y")" "$W/wroot/first.rb:1: some-code: y"
ok "  a place in another file is left alone" \
   "$(placed w-a "$W/wroot" units.tsv "$W/other/packed.rb:2: some-code: y")" "$W/other/packed.rb:2: some-code: y"
want "an entry over a unit that declares int64 records the unit" "$W/w2-a/map.tsv" "^# declares int64${TAB}second\.rb$"
ok "  and the placed refusal names it beside the width line" \
   "$(placed w2-a "$W/wroot2" units.tsv "$W/w2-a/packed.rb:1: int-width-int64-refused: x")" \
   "units.tsv:1: int-width-int64-refused: x (the manifest's \`#width\` line gives this entry int64; $W/wroot2/second.rb:1 declares it too)"
# tools/doom/failure-site.rb over a planted build: an entry's stage holds the
# map pack-core wrote and a site table of the kernel's shape, and the planted
# adapter line names site 1, packed line 6 -- the second unit's line 2.
mkdir -p "$W/fsb/stage/dc_a"
cp "$W/w-a/map.tsv" "$W/fsb/stage/dc_a/map.tsv"
printf '# planted\nsite\tfile\tline\tcolumn\tstatus\twhat\n1\t%s\t6\t3\tARITHMETIC\tchecked +\n' "$W/w-a/packed.rb" > "$W/fsb/stage/dc_a/sites.tsv"
ok "failure-site.rb names the unit and line a failed entry stopped at" \
   "$(printf 'noise\nspinel-core: dc_a answered 2 at failure site 1\n' | "$RUBY" "$ROOT/tools/doom/failure-site.rb" --build "$W/fsb" --units "$W/wroot")" \
   "dc_a: $W/wroot/second.rb:2: ARITHMETIC: checked + (failure site 1, column 3)"
ok "  and site 0 as the wrapper's own refusal" \
   "$(printf 'spinel-core: dc_a answered 1 at failure site 0\n' | "$RUBY" "$ROOT/tools/doom/failure-site.rb" --build "$W/fsb")" \
   "dc_a: status 1, no failure site (the wrapper's own argument checks)"
pack_entry w2-b "$W/wroot2" "$W/w2.mf" dc_b
want "a target entry over a unit that still declares int64 is refused, naming it" "$W/w2-b.err" \
  "^pack-core: width: dc_b is packed at the target's width, and second\.rb still declare\(s\) .# spinel: int64.$"
ok "  and it fails" "$(cat "$W/w2-b.rc")" 1
pack_entry w-c "$W/wroot" "$W/w.mf" dc_c
want "an entry the manifest gives no width is refused" "$W/w-c.err" "^pack-core: width: .* gives no width for dc_c$"
pack w-none "$W/wroot" "$W/w.mf"
want "a manifest with width lines and no --entry is refused" "$W/w-none.err" "^pack-core: usage: .* name the entry with --entry$"
pack_entry w-plain "$W/wroot" "$W/w-units.mf" dc_a
want "--entry over a manifest with no width lines is refused" "$W/w-plain.err" "^pack-core: usage: --entry dc_a, and .* names no entry's width$"
printf '#width\tdc_a\tint32\n' | cat - "$W/w-units.mf" > "$W/w-bad.mf"
pack_entry w-bad "$W/wroot" "$W/w-bad.mf" dc_a
want "a width that is neither int64 nor target is refused" "$W/w-bad.err" "^pack-core: manifest: .*:1: width \"int32\" is neither int64 nor target$"

echo "== one entry's units =="
# A `#units` line packs an entry from the units it names, in the manifest's
# order; an entry without one is packed from every unit.
printf '#width\tdc_a\ttarget\n#width\tdc_b\ttarget\n#units\tdc_a\tsecond.rb\n' | cat - "$W/w-units.mf" > "$W/u.mf"
pack_entry u-a "$W/wroot" "$W/u.mf" dc_a
ok "an entry with a units line packs" "$(cat "$W/u-a.rc")" 0
ok "  from the units it names, and no others" "$(cmp -s "$W/wroot/second.rb" "$W/u-a/packed.rb" && echo second-only)" second-only
pack_entry u-b "$W/wroot" "$W/u.mf" dc_b
ok "an entry without one packs every unit" \
   "$(cat "$W/wroot/first.rb" "$W/wroot/second.rb" | cmp -s - "$W/u-b/packed.rb" && echo all)" all
printf '#width\tdc_a\ttarget\n#units\tdc_a\tsecond.rb,first.rb\n' | cat - "$W/w-units.mf" > "$W/u-order.mf"
pack_entry u-order "$W/wroot" "$W/u-order.mf" dc_a
ok "  in the manifest's order, not the line's" \
   "$(cat "$W/wroot/first.rb" "$W/wroot/second.rb" | cmp -s - "$W/u-order/packed.rb" && echo manifest-order)" manifest-order
printf '#width\tdc_a\ttarget\n#units\tdc_a\tthird.rb\n' | cat - "$W/w-units.mf" > "$W/u-bad.mf"
pack_entry u-bad "$W/wroot" "$W/u-bad.mf" dc_a
want "a units line naming a unit the manifest does not list is refused" "$W/u-bad.err" \
  "^pack-core: manifest: dc_a's units name third\.rb, which the manifest does not list$"
printf '#width\tdc_a\ttarget\n#units\tdc_a\tfirst.rb,first.rb\n' | cat - "$W/w-units.mf" > "$W/u-dup.mf"
pack_entry u-dup "$W/wroot" "$W/u-dup.mf" dc_a
want "a units line naming a unit twice is refused" "$W/u-dup.err" "^pack-core: manifest: dc_a's units name a unit twice$"

echo "== a failed run leaves the previous package alone =="
cp "$W/ok/packed.rb" "$W/keep/packed.rb" 2>/dev/null || { mkdir -p "$W/keep"; cp "$W/ok/packed.rb" "$W/keep/packed.rb"; }
cp "$W/ok/map.tsv" "$W/keep/map.tsv"
before_rb=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/keep/packed.rb")
before_map=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/keep/map.tsv")
"$RUBY" "$PACK" --manifest "$W/bad.mf" --root "$FIX/ok/src" --reader "$READER" \
  --output "$W/keep/packed.rb" --map "$W/keep/map.tsv" > "$W/keep.err" 2>&1 || true
after_rb=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/keep/packed.rb")
after_map=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/keep/map.tsv")
ok "the previous packed file is untouched" "$after_rb" "$before_rb"
ok "and so is its map"                      "$after_map" "$before_map"
want "and the run said why"                 "$W/keep.err" '^pack-core: digest:'

echo "== a source edited after capture cannot move that build =="
# The packer reads every unit before it calls the reader once, so the wrapper
# below rewrites a unit strictly after the capture. The output must be what was
# captured, and the packer must say the file moved.
mkdir -p "$W/mutroot"
cp "$FIX/ok/src/first.rb" "$FIX/ok/src/second.rb" "$W/mutroot/"
manifest "$W/mutroot" "$W/mut.mf" first.rb second.rb
cat > "$W/mutreader" <<EOF
#!/bin/sh
"$RUBY" -e 'p = ARGV[0]; t = File.read(p); n = t.sub("a * 2", "a * 9"); exit 0 if n == t; File.write(p, n)' \
  "$W/mutroot/first.rb"
exec "$READER" "\$@"
EOF
chmod +x "$W/mutreader"
mkdir -p "$W/mutout"
"$RUBY" "$PACK" --manifest "$W/mut.mf" --root "$W/mutroot" --reader "$W/mutreader" \
  --output "$W/mutout/packed.rb" --map "$W/mutout/map.tsv" > "$W/mut.err" 2>&1 && echo 0 > "$W/mut.rc" || echo $? > "$W/mut.rc"
ok "the pack still succeeds" "$(cat "$W/mut.rc")" 0
if grep -q 'a \* 9' "$W/mutroot/first.rb"; then
  echo "  pass the control rewrote the unit after capture"; pass=$((pass + 1))
  want   "the packed bytes are the captured ones" "$W/mutout/packed.rb" 'a \* 2'
  reject "not the edit that landed afterwards"    "$W/mutout/packed.rb" 'a \* 9'
  want   "and the packer says the file moved"     "$W/mut.err" 'changed on disk after they were read'
else
  echo "  FAIL the control could not rewrite its own source; it proves nothing"; fail=$((fail + 1))
fi

echo "== the units, the manifest and the README say the same three things =="
# A BIJECTION, not three counts. `src/bspwalk.rb` sat on disk and in the
# manifest for a whole task while the README's table did not list it, and
# nothing here noticed -- because nothing compared the sets. Three sets are
# compared name for name: the .rb files under the packing root, the rows of
# examples/doom/core/sources.tsv, and the `src/NAME` cells of the README's
# unit table. Each of the three comparisons is run in BOTH directions.
SRC="$ROOT/examples/doom/core/src"
( cd "$SRC" && ls *.rb ) | sort > "$W/u.disk"
awk -F"$TAB" '!/^#/ && NF >= 2 { print $1 }' "$ROOT/examples/doom/core/sources.tsv" \
  | sort > "$W/u.manifest"
sed -n 's/^| `src\/\([a-z_]*\.rb\)` |.*/\1/p' "$ROOT/examples/doom/core/README.md" \
  | sort > "$W/u.readme"
sed -n 's/^| `src\/\([a-z_]*\.rb\)` |.*/\1/p' "$ROOT/examples/doom/core/NOTICE.md" \
  | sort > "$W/u.notice"
ok "there are units to compare at all" "$([ -s "$W/u.disk" ] && echo yes)" "yes"
ok "the manifest declares no unit that is not there" "$(comm -13 "$W/u.disk" "$W/u.manifest" | tr '\n' ' ')" ""
ok "and leaves none on disk undeclared"               "$(comm -23 "$W/u.disk" "$W/u.manifest" | tr '\n' ' ')" ""
ok "the README's table lists no unit that is not there" "$(comm -13 "$W/u.disk" "$W/u.readme" | tr '\n' ' ')" ""
ok "and leaves none out of the table"                   "$(comm -23 "$W/u.disk" "$W/u.readme" | tr '\n' ' ')" ""
# The NOTICE table is the attribution, and a unit missing from it is a unit
# redistributed without naming what it was derived from. Same bijection.
ok "the NOTICE names no unit that is not there" "$(comm -13 "$W/u.disk" "$W/u.notice" | tr '\n' ' ')" ""
ok "and every unit has its attribution"         "$(comm -23 "$W/u.disk" "$W/u.notice" | tr '\n' ' ')" ""

# AND THE SAME BIJECTION FOR THE ENTRIES THE FRAME LANE COMPILES. The contracts
# under tests/doom-core/fixtures/source are one set; harness/build-artifacts.sh's
# SENTRIES is the list that decides which of them are built and put through the
# link rule. THE LIST DRIFTED ONE WAY: on 2026-09-18 it held 40 names against 42
# tracked .contract files -- `inputall` and `renderall` on disk and unbuilt,
# while 46 rows of tools/doom/core-migrated.tsv said definitions were "compiled
# through dc_sp_renderall". A contract nothing builds is a claim nothing checks,
# so this compares the two sets in both directions, as the three above do.
( cd "$ROOT/tests/doom-core/fixtures/source" && ls *.contract ) | sed 's/\.contract$//' | sort > "$W/e.disk"
sed -n 's/^SENTRIES="\(.*\)"$/\1/p' "$ROOT/tests/doom-core/harness/build-artifacts.sh" \
  | tr ' ' '\n' | grep -v '^$' | sort > "$W/e.list"
ok "there are entry contracts to compare at all" "$([ -s "$W/e.disk" ] && echo yes)" "yes"
ok "the built-entry list names no contract that is not there" "$(comm -13 "$W/e.disk" "$W/e.list" | tr '\n' ' ')" ""
ok "and leaves no tracked contract unbuilt"                   "$(comm -23 "$W/e.disk" "$W/e.list" | tr '\n' ' ')" ""

# The control: with the README row that was missing removed again, the check
# above must name that unit rather than pass on a count that still matches.
sed '/^| `src\/bspwalk.rb` |/d' "$ROOT/examples/doom/core/README.md" > "$W/readme.short"
sed -n 's/^| `src\/\([a-z_]*\.rb\)` |.*/\1/p' "$W/readme.short" | sort > "$W/u.short"
ok "a unit dropped from the table is named" "$(comm -23 "$W/u.disk" "$W/u.short" | tr '\n' ' ')" "bspwalk.rb "

echo "== the packed source builds and runs =="
# THE KERNEL TOOL. tools/core/spinel-core-build compiles the selected method as
# a core object; the packed file defines and executes nothing, so the driver
# line is appended HERE, by the test, and never by the packer.
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else CC_BIN=""; fi
CORE_BUILD="${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}"
if [ -z "$CC_BIN" ] || [ ! -x "$CC_BIN" ] || [ ! -x "$CORE_BUILD/bin/spinel-core-emit" ]; then
  echo "  SKIP set LLVM_PREFIX (or CLANG) and build tools/mlir/native for the kernel lane" >&2
  echo "source-pack: $((pass + fail)) checked, $pass pass, $fail fail (kernel lane skipped)"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

manifest "$FIX/core/src" "$W/core.mf" first.rb second.rb
pack core "$FIX/core/src" "$W/core.mf"
ok "the core-eligible units pack" "$(cat "$W/core.rc")" 0
cp "$W/core/packed.rb" "$W/app.rb"
printf 'puts dc_pick(7, 3)\n' >> "$W/app.rb"
# The program's library half must be the packed bytes, unchanged.
head -c "$(wc -c < "$W/core/packed.rb")" "$W/app.rb" > "$W/app.prefix"
if cmp -s "$W/app.prefix" "$W/core/packed.rb"; then
  echo "  pass the program's library half is the packed bytes"; pass=$((pass + 1))
else
  echo "  FAIL the program's library half is not the packed bytes"; fail=$((fail + 1))
fi
CLANG="$CC_BIN" SPINEL_CORE_BUILD="$CORE_BUILD" \
  sh "$ROOT/tools/core/spinel-core-build" --source "$W/app.rb" --core dc_pick -o "$W/app" \
  > "$W/build.err" 2>&1 && echo 0 > "$W/build.rc" || echo $? > "$W/build.rc"
ok "it builds with dc_pick as a core object" "$(cat "$W/build.rc")" 0
want "and says which symbol it compiled"     "$W/build.err" 'core spc_[0-9a-f]+_dc_pick'
if [ -x "$W/app" ]; then
  "$W/app" > "$W/app.out" 2>&1 || true
  if "$ROOT/tools/oracle/gate" tests/doom-core/source-pack.sh app; then
    "$RUBY" "$W/app.rb" > "$W/cruby.out" 2>&1 || true
    ok "the native answer is the CRuby answer" "$(cat "$W/app.out")" "$(cat "$W/cruby.out")"
  fi
  ok "and it is 3"                           "$(cat "$W/app.out")" "3"
else
  echo "  FAIL no executable was produced"; fail=$((fail + 1))
fi

echo "== the plan's own helper, and what the checker says about it =="
# The plan names dc_twice/dc_pick and requires the native result to be 7. The
# checker refused both as unproved arithmetic until decision 0015 admitted
# checked + - * / %, so the 7 was measured only through the ordinary hosted
# compiler. It is now measured through both, and the refusal is kept on a copy
# whose helper also holds a String literal, which CORE never admits (it would
# allocate). Since decision 0042 no Integer operator is left unproved.
cp "$W/ok/packed.rb" "$W/seven.rb"
printf 'puts dc_pick(3)\n' >> "$W/seven.rb"
"$SPINEL" "$W/seven.rb" --cc="$CC_BIN" -o "$W/seven" > "$W/seven.build" 2>&1 || true
if [ -x "$W/seven" ]; then
  "$W/seven" > "$W/seven.out" 2>&1 || true
  ok "dc_pick(3) is 7 natively"       "$(cat "$W/seven.out")" "7"
  if "$ROOT/tools/oracle/gate" tests/doom-core/source-pack.sh seven; then
    "$RUBY" "$W/seven.rb" > "$W/seven.cruby" 2>&1 || true
    ok "and CRuby agrees"               "$(cat "$W/seven.cruby")" "$(cat "$W/seven.out")"
  fi
else
  echo "  FAIL the hosted build produced no executable"; sed 's/^/        /' "$W/seven.build" | tail -3
  fail=$((fail + 1))
fi
CLANG="$CC_BIN" SPINEL_CORE_BUILD="$CORE_BUILD" \
  sh "$ROOT/tools/core/spinel-core-build" --source "$W/seven.rb" --core dc_pick -o "$W/seven-core" \
  > "$W/seven.core.err" 2>&1 && echo 0 > "$W/seven.core.rc" || echo $? > "$W/seven.core.rc"
ok "it builds with dc_pick as a core object" "$(cat "$W/seven.core.rc")" 0
if [ -x "$W/seven-core" ]; then
  ok "and the core object's answer is 7" "$("$W/seven-core" 2>&1 || true)" "7"
else
  echo "  FAIL the core build produced no executable"; sed 's/^/        /' "$W/seven.core.err" | tail -3
  fail=$((fail + 1))
fi
# The control: the same two units with a String literal before `a * 2`.
sed 's/^\( *\)a \* 2$/"ab"\na * 2/' "$W/seven.rb" > "$W/str.rb"
ok "the control's helper is the one changed" "$(diff "$W/seven.rb" "$W/str.rb" | grep -c '^> *"ab"$')" 1
CLANG="$CC_BIN" SPINEL_CORE_BUILD="$CORE_BUILD" \
  sh "$ROOT/tools/core/spinel-core-build" --source "$W/str.rb" --core dc_pick -o "$W/str-core" \
  > "$W/str.core.err" 2>&1 || true
want "the checker refuses it by name"     "$W/str.core.err" "'dc_pick' is not eligible for core compilation"
want "and says the String needs the heap" "$W/str.core.err" 'REFUSED.dc_twice.*heap-operation.*StringNode'
ok "and publishes nothing" "$([ -e "$W/str-core" ] && echo published || echo none)" none


echo "== the real core tree packs =="
# examples/doom/core is the tree the entries are compiled from. Packing it here
# means sources.tsv cannot drift from the bytes without this failing.
pack tree "$ROOT/examples/doom/core/src" "$ROOT/examples/doom/core/sources.tsv"
ok "examples/doom/core packs" "$(cat "$W/tree.rc")" 0
want "and the map names the first unit"  "$W/tree/map.tsv" "${TAB}fixed\.rb${TAB}[0-9a-f]{64}$"
want "and the second, continuing from it" "$W/tree/map.tsv" "${TAB}thinkers\.rb${TAB}[0-9a-f]{64}$"
cp "$W/tree/packed.rb" "$W/tree.rb"
cat >> "$W/tree.rb" <<'RB'
puts fixed_to_i32(4294967295)
puts fixed_mul(-196608, 131072)
puts fixed_cdiv(-7, 2)
puts fixed_div(-196608, 131072)
puts fixed_bam(-1)
RB
if [ -n "$CC_BIN" ] && [ -x "$CC_BIN" ]; then
  "$SPINEL" "$W/tree.rb" --cc="$CC_BIN" -o "$W/tree.bin" > "$W/tree.build" 2>&1 || true
  if [ -x "$W/tree.bin" ]; then
    "$W/tree.bin" > "$W/tree.native" 2>&1 || true
    if "$ROOT/tools/oracle/gate" tests/doom-core/source-pack.sh tree; then
      "$RUBY" "$W/tree.rb" > "$W/tree.cruby" 2>&1 || true
      ok "the packed helpers agree with CRuby" "$(cat "$W/tree.native")" "$(cat "$W/tree.cruby")"
    fi
    ok "and give the five recorded answers"  "$(tr '\n' ' ' < "$W/tree.native")" "-1 -393216 -3 -98304 4294967295 "
  else
    echo "  FAIL the packed tree did not build"; sed 's/^/        /' "$W/tree.build" | tail -3; fail=$((fail + 1))
  fi
  # The README says the driver refuses these without a declaration. Measured,
  # not assumed: if that stops being true the README is wrong and this fails.
  cp "$W/tree/packed.rb" "$W/decl.rb"
  printf 'puts fixed_mul(1, 1)\n' >> "$W/decl.rb"
  CLANG="$CC_BIN" SPINEL_CORE_BUILD="$CORE_BUILD" \
    sh "$ROOT/tools/core/spinel-core-build" --source "$W/decl.rb" --core fixed_mul -o "$W/decl" \
    > "$W/decl.err" 2>&1 || true
  want "the driver refuses an undeclared helper" "$W/decl.err" "'fixed_mul' is not eligible for core compilation"
  want "for the packed file's top level" "$W/decl.err" 'binding-environment.*top level supports only definitions'
  ok "and no longer for its arithmetic (decision 0042)" "$(grep -c 'unproved-arithmetic' "$W/decl.err")" 0
  want "the README says so too" "$ROOT/examples/doom/core/README.md" 'every refusal reports .binding-environment.'
fi

echo "source-pack: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
