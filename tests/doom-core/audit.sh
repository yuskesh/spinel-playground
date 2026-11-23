#!/bin/sh
#
# tests/doom-core/audit.sh — the counter-examples macOS found, as tests.
#
# Each one is a defect that was IN tools/doom/audit-core.rb and was found by
# running it, not by reading it. A test here checks the INTENDED edge or
# diagnostic, never merely that the audit exited nonzero: the audit exits
# nonzero while it is incomplete, so an exit status alone would pass every
# control for the wrong reason.
#
# AUDIT can be overridden to run this suite against a MUTANT of the audit.
# That is how each check here was shown to be load-bearing: removing the NUL
# check, the ledger-existence check, the containment check, the set-equality
# check, or any of the seven structural checks on the wire format makes
# exactly the controls that name it fail, and nothing else.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/doom-core/fixtures/audit"
AUDIT="${AUDIT:-$ROOT/tools/doom/audit-core.rb}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"

die() { echo "audit: $*" >&2; exit 1; }
[ -x "$READER" ] || die "no reader at $READER (build it first)"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"

TAB=$(printf "\\t")
W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-audit.XXXXXX")
# AN ABORT IS NOT A RESULT, and this suite is where that was measured. The
# handler used to clean up and RETURN, so the script resumed with its work
# directory deleted: the next check could not find its file, failed, and the
# run printed "audit: 263 checked, 262 pass, 1 fail" as though it had finished.
# It had been killed by a `timeout` at 2400 s. A Ctrl-C or a CI limit produces
# the same false finding, and nothing in the output says the run was stopped.
# The handler now exits, and the status is what tells an abort from a result.
# tests/doom-core/abort-controls.sh sends each signal and requires no summary.
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
trap 'cleanup; echo "audit: interrupted (SIGINT); no summary follows" >&2; exit 130' INT
trap 'cleanup; echo "audit: terminated (SIGTERM); no summary follows" >&2; exit 143' TERM
pass=0; fail=0

run() { # fixture roots outdir
  mkdir -p "$W/$3"
  "$RUBY" "$AUDIT" --entry "$FIX/$1" --roots "$2" --reader "$READER" --tables "$ROOT/tools/doom" \
    --output "$W/$3" > "$W/$3.err" 2>&1 || true
  grep -v '^#' "$W/$3/closure.tsv" > "$W/$3.tsv" 2>/dev/null || : > "$W/$3.tsv"
}

want() { # label file pattern
  if grep -qE "$3" "$2"; then
    echo "  pass $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1"; sed 's/^/        /' "$2" | head -6; fail=$((fail + 1))
  fi
}
ok() { # label got want
  if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
  else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi
}
reject() { # label file pattern
  if grep -qE "$3" "$2"; then
    echo "  FAIL $1 (the wrong answer is present)"; fail=$((fail + 1))
  else
    echo "  pass $1"; pass=$((pass + 1))
  fi
}
# EVIDENCE BEFORE ABSENCE. `reject` alone passes when the audit never ran: a
# diagnostic is missing from the output of a run that died at startup exactly
# as it is missing from a run that got the right answer. So a positive side
# must first show the audit reached the closure stage -- it counted
# definitions and call sites, it reported what the roots reached, and it
# bound all three faces to their ledgers in the report. None of that is
# produced by a startup or parse failure, and all of it is produced
# alongside the overall INCOMPLETE exit 1.
stage() { # label errfile outdir
  if grep -qE 'definition\(s\), [0-9]+ call site\(s\)' "$2" &&
     grep -qE 'reached [0-9]+ definition\(s\) from [0-9]+ root\(s\)' "$2" &&
     [ "$(grep -c '^# face' "$3/closure.tsv" 2>/dev/null || echo 0)" = 3 ]; then
    echo "  pass $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1 (the audit did not reach the closure stage)"
    sed 's/^/        /' "$2" | head -6; fail=$((fail + 1))
  fi
}

echo "== a call's receiver decides it, not the caller's class =="
run receiver.rb 'Game#g_ticker' rcv
# Other#target and Game#target both exist; `Other.new.target` must reach the
# first. Resolving by the caller's class gave Game#target.
want   "Other.new.target resolves to Other#target" "$W/rcv.tsv" "${TAB}target${TAB}.*${TAB}Other#target$"
reject "it does not resolve to Game#target"        "$W/rcv.tsv" 'Game#target'

echo "== new is an allocation with an initialization edge =="
# `new` was among "operators" by name, which erased the allocation AND
# everything Other#initialize reaches.
want "Other.new emits an initialization edge" "$W/rcv.tsv" "${TAB}initialization${TAB}Other[.]new${TAB}.*${TAB}Other#initialize$"
want "and the walk follows it to setup_hidden" "$W/rcv.tsv" "^Other#initialize${TAB}call${TAB}setup_hidden${TAB}.*${TAB}Other#setup_hidden$"

echo "== one candidate is not a resolution =="
run orphan.rb 'Game#g_ticker' orph
# Only Other#orphan exists and the call is bare. Confirming it by counting
# candidates reported it resolved, with nothing unresolved.
want   "a bare call with no receiver evidence stays unresolved" "$W/orph.tsv" 'UNRESOLVED-NO-RECEIVER-EVIDENCE:Other#orphan'
reject "it is not confirmed as Other#orphan"                    "$W/orph.tsv" "${TAB}Other#orphan$"
want   "and the run says so"                                    "$W/orph.err" 'unresolved=1'

echo "== the audit itself reads every element of an A line =="
# An earlier control parsed the ast with its own inline Ruby, so it stayed
# green when the AUDIT's CSV decode was broken: appending `.take(1)` to that
# one line left the suite at 11 of 11. The check has to depend on what the
# AUDIT produced, and on information that lives BEYOND the first element of a
# multi-element A line.
#
# `include` is exactly that. A class body is a StatementsNode whose `body` is
# an A line with one element per statement, and Game's `include` calls are not
# the first of them. Reading only the first element loses the includes, and
# with them every call that resolves through MapMove, Sight, Enemy, Specials,
# Pspr or Inter.
run receiver.rb 'Game#g_ticker' arr
want "the audit finds Other#setup_hidden, which is not the first statement" "$W/arr.tsv" "${TAB}Other#setup_hidden\$"

"$RUBY" "$AUDIT" --entry "$ROOT/examples/doom/lib/doom/game.rb" --roots 'Game#g_ticker' \
  --reader "$READER" --tables "$ROOT/tools/doom" --output "$W/inc" > "$W/inc.err" 2>&1 || true
want "and it reports Game's six includes from the tree" "$W/inc.err" \
  'includes Game<-MapMove,Sight,Enemy,Specials,Pspr,Inter'

# The mutation this control exists to catch, applied to the code that runs.
# The CSV decode now lives in tools/doom/contract_reader.rb, which the audit
# requires relative to itself, so the whole directory is copied and the
# MODULE is mutated there -- mutating a copy of the audit alone would leave
# it requiring the unmutated module and the control would prove nothing.
cp -R "$ROOT/tools/doom" "$W/mutdir"
sed 's/^\( *\)vals = f\[3\]\.to_s\.empty.*$/&.take(1)/' \
  "$ROOT/tools/doom/contract_reader.rb" > "$W/mutdir/contract_reader.rb"
if cmp -s "$ROOT/tools/doom/contract_reader.rb" "$W/mutdir/contract_reader.rb"; then
  echo "  FAIL the A-line mutation did not apply; the control below would be empty"
  fail=$((fail + 1))
else
  mkdir -p "$W/mut"
  "$RUBY" "$W/mutdir/audit-core.rb" --entry "$ROOT/examples/doom/lib/doom/game.rb" --roots 'Game#g_ticker' \
    --reader "$READER" --tables "$ROOT/tools/doom" --output "$W/mut" > "$W/mut.err" 2>&1 || true
  # The mutant has to get as far as the unmutated audit did, or its silence
  # about the includes is just a crash.
  stage  "the mutant still reaches the closure stage" "$W/mut.err" "$W/mut"
  reject "reading only the first element loses them" "$W/mut.err" \
    'includes Game<-MapMove,Sight,Enemy,Specials,Pspr,Inter'
fi

echo "== every face reads the same bytes =="
# macOS swapped the source between the `nodes` read and the `ast` read: the run
# then reported the NEW file's digest while resolving by the OLD one.
#
# The rewrite is Ruby, taking its path in ARGV. An earlier version used
# `sed -i`, which on BSD sed answers "invalid command code f" -- so on macOS
# the source was never rewritten and BOTH assertions passed against an
# unchanged file, with the suite reporting 11 of 11. A control that cannot
# perform its own mutation proves nothing, so the mutation is verified here
# before the audit's answer is looked at: the file's digest must change, and
# the wrapper must have been called at least twice.
cp "$FIX/receiver.rb" "$W/mutable.rb"
before=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/mutable.rb")
cat > "$W/slowreader" <<EOF
#!/bin/sh
n=\$(cat "$W/calls" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$W/calls"
if [ "\$n" = 1 ]; then
  "$RUBY" -e 'p = ARGV[0]; t = File.read(p); n = t.sub("Other.new", "Game.new"); abort("no change") if n == t; File.write(p, n)' "$W/mutable.rb" || exit 97
fi
exec "$READER" "\$@"
EOF
chmod +x "$W/slowreader"
echo 0 > "$W/calls"
mkdir -p "$W/swap"
"$RUBY" "$AUDIT" --entry "$W/mutable.rb" --roots 'Game#g_ticker' --reader "$W/slowreader" --tables "$ROOT/tools/doom" \
  --output "$W/swap" > "$W/swap.err" 2>&1 || true
after=$("$RUBY" -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$W/mutable.rb")
ncalls=$(cat "$W/calls")
grep -v '^#' "$W/swap/closure.tsv" > "$W/swap.tsv" 2>/dev/null || : > "$W/swap.tsv"

if [ "$before" = "$after" ]; then
  echo "  FAIL the control could not rewrite its own source ($before unchanged); it proves nothing"
  fail=$((fail + 1))
elif [ "$ncalls" -lt 2 ]; then
  echo "  FAIL the wrapper reader ran $ncalls time(s); the swap could not have happened mid-run"
  fail=$((fail + 1))
else
  echo "  pass the control rewrote its source ($ncalls reader calls, digest changed)"
  pass=$((pass + 1))
  want   "a source edited mid-run does not change what was read" "$W/swap.tsv" "${TAB}Other#target\$"
  reject "and the swapped-in Game.new is not resolved"           "$W/swap.tsv" "Game#target"
fi

echo "== the snapshot cannot be escaped =="
# macOS's probe: require_relative climbs ../ to the root and then names the
# ORIGINAL dependency by absolute path minus its leading slash. It normalises
# back to the original and the pin accepts it, so a snapshot of two files has
# the snapshot's own entry reading the original second file. Two against two,
# which a length comparison cannot see.
ESC="$FIX/escape"
UP=$("$RUBY" -e 'print "../" * 32')
REL=$("$RUBY" -e 'print File.expand_path(ARGV[0]).sub(%r{\A/}, "").sub(/\.rb\z/, "")' "$ESC/dep.rb")
printf 'require_relative "%s%s"\nmodule Doom\n  class Game\n    def g_ticker\n      Other.new.target\n    end\n  end\nend\n' "$UP" "$REL" > "$W/escmain.rb"
mkdir -p "$W/esc"
"$RUBY" "$AUDIT" --entry "$W/escmain.rb" --roots 'Game#g_ticker' --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/esc" > "$W/esc.err" 2>&1 || true
want "a require that leaves the snapshot is refused by name" "$W/esc.err" 'from OUTSIDE the snapshot'
# Named IN THAT DIAGNOSTIC, not merely somewhere in the output: the set
# comparison below it also prints the path, so grepping the whole file would
# pass with the containment check removed.
grep -A3 "input(s) from OUTSIDE the snapshot" "$W/esc.err" > "$W/esc.outside" 2>/dev/null || : > "$W/esc.outside"
want "and the offending path is named in that diagnostic" "$W/esc.outside" escape/dep.rb
# The pair: an ordinary require_relative closure inside the tree is accepted,
# so the check refuses escaping and not requiring.
mkdir -p "$W/ok"
"$RUBY" "$AUDIT" --entry "$ROOT/examples/doom/bin/doom.rb" --roots 'Game#g_ticker' --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/ok" > "$W/ok.err" 2>&1 || true
stage  "an ordinary require_relative closure is audited to the end" "$W/ok.err" "$W/ok"
reject "and it is not refused"                                      "$W/ok.err" 'OUTSIDE the snapshot|different set than was frozen'

echo "== the temporary directory is not always its own realpath =="
# macOS's trap, reproduced HERE with a symlink rather than described. The
# snapshot is made with Dir.mktmpdir, which answers $TMPDIR's own spelling; on
# macOS that resolves elsewhere (/var -> /private/var), and so does any TMPDIR
# reached through a link. Everything downstream compares the snapshot's paths
# with their realpaths -- the entry's file id above all -- so the two spellings
# made the entry unfindable on that host and only there. It cost a whole run to
# find, because what it reached was an ORPHAN: the fallback for "no file is the
# entry" read a variable bb5ea6f had deleted, so the failure was a NameError
# naming nothing about paths.
LINKTMP="$W/tmplink"
mkdir -p "$W/tmpreal"
ln -sfn "$W/tmpreal" "$LINKTMP"
[ "$(cd "$LINKTMP" && pwd -P)" = "$W/tmpreal" ] || die "the planted TMPDIR does not resolve elsewhere"
mkdir -p "$W/link"
TMPDIR="$LINKTMP" "$RUBY" "$AUDIT" --entry "$FIX/receiver.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/link" > "$W/link.err" 2>&1 || true
stage  "a TMPDIR that resolves elsewhere is audited to the end" "$W/link.err" "$W/link"
reject "and no orphan is reached on that path"                   "$W/link.err" 'NameError|undefined local variable'
# THE CONTROL IS A MUTANT THAT UNRESOLVES THE SNAPSHOT, because the fix is one
# call and a control that cannot remove it proves nothing about it. The mutant
# must refuse BY NAME, naming both spellings it compared -- not crash, which is
# what the orphan did.
cp -R "$ROOT/tools/doom" "$W/linkdir"
sed 's/^SNAP = File\.realpath(Dir\.mktmpdir("audit-core-snap"))$/SNAP = Dir.mktmpdir("audit-core-snap")/' \
  "$ROOT/tools/doom/audit-core.rb" > "$W/linkdir/audit-core.rb"
if cmp -s "$ROOT/tools/doom/audit-core.rb" "$W/linkdir/audit-core.rb"; then
  echo "  FAIL the unresolved-snapshot mutation did not apply; the control below would be empty"
  fail=$((fail + 1))
else
  mkdir -p "$W/linkmut"
  TMPDIR="$LINKTMP" "$RUBY" "$W/linkdir/audit-core.rb" --entry "$FIX/receiver.rb" --roots 'Game#g_ticker' \
    --reader "$READER" --tables "$ROOT/tools/doom" --output "$W/linkmut" > "$W/linkmut.err" 2>&1 || true
  want   "an unresolved snapshot is refused by name, not by a NameError" "$W/linkmut.err" \
         'no file of the ast face is the entry'
  reject "and the refusal is not a crash"                                "$W/linkmut.err" \
         'NameError|undefined local variable'
fi

echo "== every face accounts for its own inputs, and is checked before the next =="
# `--inputs-out` is accepted in EVERY mode -- spinel_typedump.c:452-501 -- and
# Input.cpp:104-128 already requires and checks one per face. An earlier
# revision of the audit checked only `ast`, on the mistaken ground that the
# other faces emit no FILE table; the FILE table is what a face REPORTS, the
# ledger is what the frontend OPENED. So each production face now carries its
# own ledger, and each of the four ways a ledger can fail to describe its run
# is put to each of the three faces below. A control that only proved "some
# face somewhere complained" would not show that the failing face is named.
#
# The wrapper only mangles a PRODUCTION ledger (the audit names them
# production.<face>.inputs); discovery runs `ast` too, and mangling that would
# test the discovery stage while claiming to test the production one.
mangler() { # face mangle -> $W/reader-<face>-<mangle>
  cat > "$W/reader-$1-$2" <<EOF
#!/bin/sh
L=""
for a in "\$@"; do case "\$a" in --inputs-out=*) L=\${a#--inputs-out=} ;; esac; done
M=""
for a in "\$@"; do M=\$a; done
"$READER" "\$@" || exit \$?
case "\$L" in */production.$1.inputs) ;; *) exit 0 ;; esac
[ "\$M" = "$1" ] || exit 0
"$RUBY" "$W/mangle.rb" "\$L" "$2" "$FIX/closure/dep.rb" || exit 97
exit 0
EOF
  chmod +x "$W/reader-$1-$2"
}
cat > "$W/mangle.rb" <<'EOF'
l, how, outside = ARGV
case how
when "missing"  then File.delete(l)
when "truncate" then b = File.binread(l); File.binwrite(l, b[0...-1])
when "outside"  then File.open(l, "ab") { |io| io.write(File.realpath(outside) + "\0") }
when "swap"
  # A path of the SAME LENGTH, in the SAME directory, that was not frozen:
  # inside the snapshot and equal in count, so only comparing the set by name
  # can see it.
  recs = File.binread(l).split("\0", -1); recs.pop
  i = recs.index { |r| !r.end_with?("main.rb") } or abort("mangle: no non-entry record")
  b = File.basename(recs[i])
  recs[i] = File.join(File.dirname(recs[i]), (b[0] == "x" ? "d" : "x") + b[1..])
  File.binwrite(l, recs.map { |r| r + "\0" }.join)
else abort("mangle: unknown #{how}")
end
EOF

for face in nodes ast methods; do
  for m in missing truncate outside swap; do
    mangler "$face" "$m"
    mkdir -p "$W/lg-$face-$m"
    "$RUBY" "$AUDIT" --entry "$FIX/closure/main.rb" --roots 'Game#g_ticker' \
      --reader "$W/reader-$face-$m" --tables "$ROOT/tools/doom" --output "$W/lg-$face-$m" > "$W/lg-$face-$m.err" 2>&1 || true
    case $m in
      missing)  pat="input ledger \\($face\\): the reader wrote no ledger" ;;
      truncate) pat="input ledger \\($face\\): the ledger does not end in a NUL" ;;
      outside)  pat="input ledger \\($face\\): 1 input\\(s\\) from OUTSIDE the snapshot" ;;
      swap)     pat="input ledger \\($face\\): a different set than was frozen" ;;
    esac
    want "$face: a $m ledger is refused, naming the face" "$W/lg-$face-$m.err" "$pat"
  done
done

# The pair. An ordinary two-file closure must run all the way through with
# every ledger accepted -- otherwise the twelve refusals above would also be
# satisfied by an audit that refuses everything.
mkdir -p "$W/lgok"
"$RUBY" "$AUDIT" --entry "$FIX/closure/main.rb" --roots 'Game#g_ticker' --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/lgok" > "$W/lgok.err" 2>&1 || true
stage "a normal multi-file closure is accepted and audited" "$W/lgok.err" "$W/lgok"
want "  both files are in every face's ledger" "$W/lgok.err" '2 file\(s\) opened'
want "  and each face is bound to its own ledger" "$W/lgok/closure.tsv" \
  "^# face${TAB}ast${TAB}output=[0-9a-f]{16}${TAB}ledger=[0-9a-f]{16}${TAB}inputs=2\$"
grep -v '^#' "$W/lgok/closure.tsv" > "$W/lgok.tsv"
want "  the cross-file call resolves" "$W/lgok.tsv" "${TAB}Other#target\$"

echo "== a malformed dump is refused, not read as whatever to_i returns =="
# The subset of Reader.cpp's wire format this audit reads is validated rather
# than assumed: known tags only, each node declared once, each field key set
# once per node, no field on an undeclared node, every R (other than -1) and
# every A element naming a declared node, and a uniform column count in the
# tabular faces. An earlier revision merely DOCUMENTED that it made none of
# these checks. Each check gets the corruption it exists for.
cat > "$W/mangle-out.rb" <<'EOF'
path, how = ARGV
t = File.read(path)
case how
when "dupnode"
  l = t.each_line.find { |x| x.start_with?("N ") } or abort("mangle: no N line")
  print t.sub(l) { l + l }
when "dupkey"
  l = t.each_line.find { |x| x.start_with?("R ") } or abort("mangle: no R line")
  print t.sub(l) { l + l }
when "dangling"
  l = t.each_line.find { |x| x.start_with?("R ") && !x.chomp.end_with?(" -1") } or
    abort("mangle: no linking R line")
  f = l.chomp.split(" ", 4)
  print t.sub(l) { "R #{f[1]} #{f[2]} 999999\n" }
when "unknowntag" then print "ZZ 1 x\n" + t
when "orphanfield" then print t + "I 999999 node_file 0\n"
when "widerow"
  ls = t.lines
  ls[1] = ls[1].chomp + "\textra\n"
  print ls.join
when "dupid"
  ls = t.lines
  print (ls[0, 2] + [ls[1]] + ls[2..]).join
else abort("mangle: unknown #{how}")
end
EOF
outmangler() { # face mangle -> $W/rdr-<face>-<mangle>
  cat > "$W/rdr-$1-$2" <<EOF
#!/bin/sh
L=""
for a in "\$@"; do case "\$a" in --inputs-out=*) L=\${a#--inputs-out=} ;; esac; done
M=""
for a in "\$@"; do M=\$a; done
R="\$L.out"
"$READER" "\$@" > "\$R" || exit \$?
case "\$L" in */production.$1.inputs) ;; *) cat "\$R"; exit 0 ;; esac
[ "\$M" = "$1" ] || { cat "\$R"; exit 0; }
"$RUBY" "$W/mangle-out.rb" "\$R" "$2" || exit 97
EOF
  chmod +x "$W/rdr-$1-$2"
}
wire() { # face mangle pattern label
  outmangler "$1" "$2"
  mkdir -p "$W/wr-$1-$2"
  "$RUBY" "$AUDIT" --entry "$FIX/closure/main.rb" --roots 'Game#g_ticker' \
    --reader "$W/rdr-$1-$2" --tables "$ROOT/tools/doom" --output "$W/wr-$1-$2" > "$W/wr-$1-$2.err" 2>&1 || true
  want "$4" "$W/wr-$1-$2.err" "$3"
}
wire ast dupnode     'ast line [0-9]+: node [0-9]+ is declared twice'                  "a node declared twice is refused"
wire ast dupkey      'ast line [0-9]+: node [0-9]+ sets [a-z_]+ twice'                 "a field key set twice is refused"
wire ast dangling    'ast line [0-9]+: node [0-9]+.s [a-z_]+ links to 999999, which is no declared node' \
                                                                                       "a link to an absent node is refused"
wire ast unknowntag  'ast line 1: unknown record tag "ZZ"'                             "an unknown record tag is refused"
wire ast orphanfield 'sets fields on 1 undeclared node\(s\), the first being 999999'   "a field on an undeclared node is refused"
wire nodes widerow   'nodes line 2: 9 column\(s\), the header declares 8'              "a nodes row of the wrong width is refused"
wire nodes dupid     'the nodes face declares node [0-9]+ twice'                       "a nodes id declared twice is refused"
wire methods widerow 'methods line 2: [0-9]+ column\(s\), the header declares [0-9]+'  "a methods row of the wrong width is refused"

echo "== one definition reported twice is one definition =="
# The reader lists an included module's method under the module (with the ast
# tree) AND once per including class (with that class's resolved types and no
# ast node). Counting the two entries as two candidates called 58 of DOOM's
# call sites ambiguous; matching the twin by name alone picked an unrelated
# class that shares the name and lost the receiver for twelve more.
INST="$FIX/instantiated/main.rb"
mkdir -p "$W/inst"
"$RUBY" "$AUDIT" --entry "$INST" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/inst" > "$W/inst.err" 2>&1 || true
stage  "the instantiation fixture is audited to the end" "$W/inst.err" "$W/inst"
grep -v '^#' "$W/inst/closure.tsv" > "$W/inst.tsv" 2>/dev/null || : > "$W/inst.tsv"
want   "an implicit call to an included method resolves to the instantiation" "$W/inst.tsv" \
  "${TAB}helper${TAB}.*${TAB}Game#helper\$"
reject "it is not ambiguous between the module and the class"                 "$W/inst.tsv" 'AMBIGUOUS'
reject "and not the unrelated class that shares the name"                     "$W/inst.tsv" 'Elsewhere#helper'
want   "a method only the module defines resolves too"                        "$W/inst.tsv" \
  "${TAB}only_in_module${TAB}.*${TAB}Game#only_in_module\$"
want   "and the run says the instantiated node found its ast twin"            "$W/inst.err" \
  'via-ast-twin=[1-9][0-9]* without=0'

echo "== the builtin catalog is a closed list, not a way to silence a count =="
# `builtin` means only "no definition in this tree". Whether CORE can reach it
# is answered per entry in tools/doom/core-builtins.tsv, and an entry that is
# not there stays unresolved.
CAT="$ROOT/tools/doom/core-builtins.tsv"
mkdir -p "$W/bi"
"$RUBY" "$AUDIT" --entry "$FIX/builtin.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --builtins "$CAT" --output "$W/bi" > "$W/bi.err" 2>&1 || true
grep -v '^#' "$W/bi/closure.tsv" > "$W/bi.tsv" 2>/dev/null || : > "$W/bi.tsv"
want "a catalogued builtin carries its verdict" "$W/bi.tsv" "${TAB}abs${TAB}.*${TAB}int${TAB}.*${TAB}BUILTIN-CORE\$"
want "and is counted as one"                    "$W/bi.err" 'builtins core=1 '

grep -v "^int${TAB}abs${TAB}" "$CAT" > "$W/cat-noabs.tsv"
if cmp -s "$CAT" "$W/cat-noabs.tsv"; then
  echo "  FAIL removing the int/abs row changed nothing; the control below would be empty"
  fail=$((fail + 1))
else
  mkdir -p "$W/bi2"
  "$RUBY" "$AUDIT" --entry "$FIX/builtin.rb" --roots 'Game#g_ticker' --reader "$READER" \
    --tables "$ROOT/tools/doom" --builtins "$W/cat-noabs.tsv" --output "$W/bi2" > "$W/bi2.err" 2>&1 || true
  grep -v '^#' "$W/bi2/closure.tsv" > "$W/bi2.tsv" 2>/dev/null || : > "$W/bi2.tsv"
  stage "the audit still runs without that row"                   "$W/bi2.err" "$W/bi2"
  want  "but the uncatalogued builtin is unresolved, not allowed" "$W/bi2.tsv" "${TAB}abs${TAB}.*${TAB}UNRESOLVED\$"
  want  "and the run counts it"                                   "$W/bi2.err" 'unresolved=1'
fi

# A catalog that cannot be trusted is refused rather than partly read.
badcat() { # label row pattern
  printf '%s\n' "$2" > "$W/cat-bad.tsv"
  mkdir -p "$W/bc"
  "$RUBY" "$AUDIT" --entry "$FIX/builtin.rb" --roots 'Game#g_ticker' --reader "$READER" \
    --tables "$ROOT/tools/doom" --builtins "$W/cat-bad.tsv" --output "$W/bc" > "$W/bc.err" 2>&1 || true
  want "$1" "$W/bc.err" "$3"
}
badcat "an unknown verdict is refused"          "int${TAB}abs${TAB}maybe${TAB}reason"     'verdict "maybe" is not one of'
badcat "a poly receiver cannot carry a verdict" "poly${TAB}abs${TAB}core${TAB}reason"     '`poly` is not a receiver a verdict can rest on'
badcat "a verdict with no reason is refused"    "int${TAB}abs${TAB}core${TAB}"            'a verdict needs a reason'
badcat "a row of the wrong width is refused"    "int${TAB}abs${TAB}core"                  '3 column\(s\), want 4'
printf 'int%sabs%score%sone\nint%sabs%score%stwo\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" > "$W/cat-dup.tsv"
mkdir -p "$W/bd"
"$RUBY" "$AUDIT" --entry "$FIX/builtin.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --builtins "$W/cat-dup.tsv" --output "$W/bd" > "$W/bd.err" 2>&1 || true
want "a duplicated entry is refused" "$W/bd.err" 'int abs is listed twice'

echo "== the whole audit, on DOOM =="
# The audit's own acceptance. Everything below it is a control on one piece;
# this is the measurement the pieces exist to make trustworthy.
mkdir -p "$W/doom"
"$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/doom" > "$W/doom.err" 2>&1 && doomrc=0 || doomrc=$?
if [ "$doomrc" -eq 0 ]; then
  echo "  pass the DOOM audit completes (exit 0)"; pass=$((pass + 1))
else
  echo "  FAIL the DOOM audit did not complete (exit $doomrc)"; sed 's/^/        /' "$W/doom.err" | tail -4
  fail=$((fail + 1))
fi
for f in closure.tsv state-use.tsv cycles.tsv configurations.tsv; do
  if [ -s "$W/doom/$f" ]; then
    echo "  pass it wrote $f"; pass=$((pass + 1))
  else
    echo "  FAIL it did not write $f"; fail=$((fail + 1))
  fi
done
want "every entry has roots"            "$W/doom.err" 'reached [0-9]+ definition\(s\) from 22 root\(s\)'
want "the four recursive components"    "$W/doom.err" '4 recursive component\(s\), largest 62'
want "the configuration table is whole" "$W/doom.err" '20 configuration\(s\)'
want "nothing is left unresolved"       "$W/doom.err" 'ambiguous=0 unresolved=0'
want "and every block edge is disposed" "$W/doom.err" 'block-edges=0\+12disposed'
want "the BSP recursion is anchored"        "$W/doom/cycles.tsv" "${TAB}Renderer#render_bsp_node${TAB}bsp${TAB}"
want "the sound propagation is anchored"    "$W/doom/cycles.tsv" "${TAB}Game#recursive_sound${TAB}sound${TAB}"
want "the action knot is anchored"          "$W/doom/cycles.tsv" "${TAB}Game#dispatch_action${TAB}action${TAB}"
want "storage shared by two entries exists" "$W/doom/state-use.tsv" "^StatusBar${TAB}.*${TAB}shared${TAB}"
want "and storage Full owns is read-only"   "$W/doom/state-use.tsv" "^Wad${TAB}.*${TAB}resource${TAB}full${TAB}"

echo "== a shrinking closure fails instead of passing quietly =="
# THE REMOVED EDGE. 3838 of DOOM's call sites get their receiver from the ast
# twin of the instantiated scope they are in. Removing that lookup removes
# those edges -- and the audit must fail, not report a smaller closure it is
# equally happy with. The receiver catalog notices too: its rows then match no
# call site.
# The audit requires tools/doom/contract_reader.rb beside itself, so the
# whole directory is copied and the mutation applied inside the copy. A lone
# copy of the audit would die at `require_relative` and the control would be
# measuring a missing file.
cp -R "$ROOT/tools/doom" "$W/noedgedir"
"$RUBY" -e 'src = File.read(ARGV[0]); k = "twin_node[i] = c.first if c.length == 1";
            abort("no anchor") unless src.include?(k);
            File.write(ARGV[1], src.sub(k) { "# edge removed" })' \
  "$AUDIT" "$W/noedgedir/audit-core.rb" || die "could not build the removed-edge mutant"
mkdir -p "$W/noedge"
"$RUBY" "$W/noedgedir/audit-core.rb" --entry "$ROOT/examples/doom/bin/doom.rb" \
  --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/noedge" > "$W/noedge.err" 2>&1 && nrc=0 || nrc=$?
if [ "$nrc" -eq 0 ]; then
  echo "  FAIL removing 3838 edges still completed"; fail=$((fail + 1))
else
  echo "  pass removing the twin lookup fails the audit"; pass=$((pass + 1))
  want "and it says what went unresolved"   "$W/noedge.err" 'unresolved call site\(s\)'
  want "and the receiver catalog goes dead" "$W/noedge.err" 'matching no call site'
fi

echo "== an unclassified ivar fails =="
# Ownership is declared per class. Drop the class that holds 245 of DOOM's
# variables and the audit must name them, not carry on with 405.
grep -v "^Game${TAB}" "$ROOT/tools/doom/core-state.tsv" > "$W/state-nogame.tsv"
if cmp -s "$ROOT/tools/doom/core-state.tsv" "$W/state-nogame.tsv"; then
  echo "  FAIL dropping the Game row changed nothing"; fail=$((fail + 1))
else
  mkdir -p "$W/nostate"
  "$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
    --state "$W/state-nogame.tsv" --output "$W/nostate" > "$W/nostate.err" 2>&1 || true
  want "the audit names the unowned storage" "$W/nostate.err" \
    'instance variable\(s\) with no owner: Game@'
  want "and says which table is missing it"  "$W/nostate.err" 'state-nogame\.tsv'
fi

echo "== an added reachable helper fails =="
# A helper reachable from a root, calling something no catalog covers, must
# make the audit fail rather than be absorbed into the closure.
mkdir -p "$W/helper"
"$RUBY" "$AUDIT" --entry "$FIX/helper.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --roots-complete \
  --output "$W/helper" > "$W/helper.err" 2>&1 || true
grep -v '^#' "$W/helper/closure.tsv" > "$W/helper.tsv" 2>/dev/null || : > "$W/helper.tsv"
want "the helper is in the closure"          "$W/helper.tsv" "^Game#g_ticker${TAB}call${TAB}helper${TAB}"
want "and the audit fails on what it calls"  "$W/helper.err" 'unresolved call site\(s\)'
reject "it is not absorbed silently"         "$W/helper.err" 'audit-core: COMPLETE'

echo "== the scope document's numbers are the audit's numbers =="
# Stage 1's lesson: a figure that appears anywhere in a document is not
# checked. Each number below is matched inside its own table row, so changing
# it in either place breaks the pair.
DOC="$ROOT/docs/core/doom-stage2-scope.md"
[ -f "$DOC" ] || die "no scope document at $DOC"
docrow() { # label row-label pattern
  grep -E "^\| $2 \|" "$DOC" > "$W/docrow" 2>/dev/null || : > "$W/docrow"
  want "$1" "$W/docrow" "$3"
}
docrow "files opened"        'files the reader opened from .*' '\| 36 \|'
docrow "definitions"         'definitions'                     '\| 1670 \|'
docrow "call sites"          'call sites'                      '\| 19650 \|'
docrow "roots"               'roots'                           '\| 22 \|'
docrow "definitions reached" 'definitions reached'             '\| 372 \|'
docrow "ambiguous"           'ambiguous call sites'            '\| 0 \|'
docrow "unresolved"          'unresolved call sites'           '\| 0 \|'
docrow "recursive"           'recursive components'            '\| 4 \|'
docrow "state"               'instance variables the closure touches' '\| 713 \|'
docrow "configurations"      'configurations'                  '\| 20 \|'
docrow "core builtins"       'core'                            '\| 78 \|'
docrow "obligations"         'obligation'                      '\| 91 \|'
docrow "full-boundary"       'full-boundary'                   '\| 1 \|'
docrow "resource storage"    'resource'                        '\| 235 \|'
docrow "persistent storage"  'persistent'                      '\| 367 \|'
# And the same numbers, from the run above rather than from this file.
# 19635 call sites, re-measured 2026-10-18 at both the old pin 573aa44 and the
# new one: the 19632 recorded here was already stale before the pin move.
# 19636 since 888a00f: Renderer#draw_column reads its source byte as
# `use_zone_window ? @zonewin.getbyte(i) : buf.getbyte(i)`, one getbyte more
# (the call it replaced, buf.getbyte, is still there).
# 19634 since d2f91c4: render_gpu.rb no longer writes the screen's first byte
# back to itself, `scr.setbyte(0, scr.getbyte(0))`, two call sites fewer.
# 1670 and 19635 since 0dfc2f7: JobExecutor keeps its Jobs owner and reads the
# ring through the new Jobs#zone_byte, one definition more; its two calls,
# `@jobs.zone_byte` in JobExecutor#exec_masked and `@zonebuf.getbyte` in
# zone_byte, replace the one `jobs.zonebuf` in JobExecutor#initialize.
# Jobs#zone_byte is reached from the render entry: 372 reached, render=150.
# 19637 since fe94c61: NativeSession#get sign-extends 0018's i8 and i16 too,
# `e == 5 || e == 7`, two call sites more; the closure is unchanged.
# 1669 since de13af3 and bd56ed3 (decision 0021), call sites unchanged:
# de13af3 removed NativePrep.p_hud_data and NativePrep.p_status_bar_data
# (full/nativeprep.rb; one copy of the WAD's data), two definitions and 23
# call sites fewer; bd56ed3 added NativeSession's bind_resource
# (full/native_session.rb), one definition and 23 call sites more.
# 1670 and 19638 since the input entry moved to 32 bits (decision 0022): NativeSession
# gains the reader result32, one definition, and allocates it in initialize,
# one call site (full/native_session.rb).
# 19650 since 4616036 (step and render at 32 bits, decision 0022), definitions
# unchanged: the generated full/nativeprep.rb's three i32-bits preparers
# (p_game_mobj_angle, p_level_seg_angle, p_renderer_xtoviewangle) test each
# word's range and write its signed pattern, four call sites more each; of the
# audit's 36 input files nativeprep.rb is the only one that changed.
want "the run agrees on the closure"   "$W/doom.err" '1670 definition\(s\), 19650 call site\(s\)'
want "the run agrees on what is reached" "$W/doom.err" 'reached 372 definition\(s\) from 22 root\(s\)'
want "the run agrees per entry"        "$W/doom.err" 'input=6 step=240 render=150'
# persistent 369 -> 371 and resource 233 -> 231 on 2026-09-17: Level@@line_flags
# (written through a local alias) and Game@@pl_maxammo (written through index
# operator writes) were resources only because the audit could not see those
# writes; the kernel's read-only borrow check found both.
want "the run agrees on storage"       "$W/doom.err" 'output=99 persistent=371 resource=231 scratch=12'
# core 76, re-measured 2026-10-18; the 75 recorded here held at neither pin.
# 72 at the old pin 573aa44, where Game#cdiv's abs (game.rb:385, x2) and
# Wad#lump's @lumps.length (wad.rb:65, x2) were unresolved; the new pin types
# cdiv's receiver, which makes 74; reading obj_array as an array resolves
# @lumps.length as core, which makes 76. 888a00f's @zonewin.getbyte in
# Renderer#draw_column (a getbyte on a string, as buf.getbyte is) makes 77.
# 0dfc2f7's @zonebuf.getbyte in Jobs#zone_byte makes 78; the getbyte it took
# over in JobExecutor#exec_masked is still there, on @waddata.
want "the run agrees on the builtins"  "$W/doom.err" 'core=78 obligation=91 full-boundary=1'

echo "== every field the closure touches has a disposition =="
# 0008: every ivar reachable from the roots is a stored field, an immutable
# prepared value, an eliminated reference-only trace field, or a Full-only
# value with a reason. Most of that is derived from the reader's own type for
# the storage; the fields it types `poly` are the ones a human had to decide,
# and a `poly` field with no row must fail rather than default.
want "the run classifies every one"  "$W/doom.err" 'state 713 variable\(s\)'
want "and none is unclassified"      "$W/doom/state-use.tsv" "${TAB}stored${TAB}"
reject "no field is left UNCLASSIFIED" "$W/doom/state-use.tsv" 'UNCLASSIFIED'
# The eight eliminated are Random's reference-only trace (core-fields.tsv):
# seven were stored and one, @trace, prepared, before they were classified.
# 216 prepared and 14 full-only since 0dfc2f7: JobExecutor@@zonebuf, prepared
# from its core-acquired.tsv row, is gone, and JobExecutor@@jobs, an obj_Jobs
# reference, is full-only by derivation, as every object reference is.
ok "475 stored, 216 prepared, 14 full-only, 8 eliminated (the same two fields)" \
   "$(awk -F"$TAB" 'NR>3{print $6}' "$W/doom/state-use.tsv" | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')" \
   "eliminated:8 full-only:14 prepared:216 stored:475 "
# The scope document's disposition table says the same four numbers. It had no
# row here until 2026-10-19, and kept 44d774a's 478/222/13/0 from 2026-09-13.
docrow "stored dispositions"     'stored'     '\| 475 \|'
docrow "prepared dispositions"   'prepared'   '\| 216 \|'
docrow "full-only dispositions"  'full-only'  '\| 14 \|'
docrow "eliminated dispositions" 'eliminated' '\| 8 \|'

# The dropped row must be one the reader still types poly, or nothing needs
# it. Game@@tmx was; since the pin move the reader types it int, which the
# derivation classifies on its own. Game@@bottomslope is poly at both pins.
grep -v "^Game@@bottomslope${TAB}" "$ROOT/tools/doom/core-fields.tsv" > "$W/fields-short.tsv"
if cmp -s "$ROOT/tools/doom/core-fields.tsv" "$W/fields-short.tsv"; then
  echo "  FAIL dropping the Game@@bottomslope row changed nothing"; fail=$((fail + 1))
else
  mkdir -p "$W/nofield"
  "$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
    --fields "$W/fields-short.tsv" --output "$W/nofield" > "$W/nofield.err" 2>&1 || true
  want "a poly field with no row is named" "$W/nofield.err" \
    'instance variable\(s\) with no disposition: Game@@bottomslope \(the reader types it poly'
  reject "and the run does not complete"   "$W/nofield.err" 'audit-core: COMPLETE'
fi

echo "== a buffer handed to a method that stores into it is written by the call =="
# `@wad.zone_window(lnum, off, @zonewin)` stores nothing itself: the stores are
# `out.setbyte` inside Wad#zone_window_into, on its parameter. Counting only a
# store whose receiver is the ivar made the direct zone window and the job ring
# -- rewritten every masked column -- read-only resources of the render entry.
# The audit follows a written parameter back to the argument at each call in
# the closure, and names what it cannot follow.
ok "every write through an argument, and nothing it could not follow" \
   "$(grep -v '^#' "$W/doom/argument-writes.tsv" | tr "$TAB" ' ' | tr '\n' '|')$(grep '^#complete' "$W/doom/argument-writes.tsv" | tr "$TAB" ' ')" \
   "field writer callee|Jobs@@zonebuf Renderer#draw_masked_column Wad#zone_window_into|Renderer@@screen Renderer#draw_jobs_cpu JobExecutor#run|Renderer@@screen Renderer#render_player_view JobExecutor#run|Renderer@@zonewin Renderer#draw_masked_column Wad#zone_window|StatusBar@@backing StatusBar#refresh_background StatusBar#draw_patch|#complete writes=5 unresolved=0"
want "so the direct zone window is storage the render entry writes" "$W/doom/state-use.tsv" \
  "^Renderer${TAB}@zonewin${TAB}persistent${TAB}render${TAB}string${TAB}stored${TAB}u8${TAB}fixed:128${TAB}0${TAB}render${TAB}Renderer#draw_masked_column${TAB}"
want "and so is the job ring, through the reader Jobs#zonebuf" "$W/doom/state-use.tsv" \
  "^Jobs${TAB}@zonebuf${TAB}persistent${TAB}render${TAB}string${TAB}stored${TAB}u8${TAB}limit:jobzonecells${TAB}0${TAB}render${TAB}Renderer#draw_masked_column${TAB}"
# AND WHAT IT CANNOT FOLLOW FAILS THE RUN, named: on one copy the window passes
# through a local first; on another the parameter is rebound before the stores.
cp -R "$ROOT/examples/doom" "$W/aw-local"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "            @wad.zone_window(lnum, p + 3 - lpos, @zonewin)\n"
  s.scan(a).length == 1 or abort("no zone_window anchor")
  s.sub!(a, "            w = @zonewin\n            @wad.zone_window(lnum, p + 3 - lpos, w)\n")
  File.write(f, s)' "$W/aw-local/lib/doom/render.rb"
cp -R "$ROOT/examples/doom" "$W/aw-rebound"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "    def zone_window_into(lumpnum, off, out, base)\n"
  s.scan(a).length == 1 or abort("no zone_window_into anchor")
  s.sub!(a, a + "      out = out\n")
  File.write(f, s)' "$W/aw-rebound/lib/doom/wad.rb"
ok "the two copies differ from the tree in three lines and one" \
   "$(diff -r "$ROOT/examples/doom" "$W/aw-local" | grep -c '^[<>]') $(diff -r "$ROOT/examples/doom" "$W/aw-rebound" | grep -c '^[<>]')" "3 1"
for c in local rebound; do
  mkdir -p "$W/aw-$c-out"
  "$RUBY" "$AUDIT" --entry "$W/aw-$c/bin/doom.rb" --reader "$READER" \
    --tables "$ROOT/tools/doom" --output "$W/aw-$c-out" > "$W/aw-$c.err" 2>&1 || true
done
want "a window passed through a local is named, not guessed" "$W/aw-local-out/argument-writes.tsv" \
  "^#unresolved${TAB}argument 2 of Renderer#draw_masked_column -> Wad#zone_window \(lib/doom/render.rb:[0-9]+\) is a LocalVariableReadNode$"
want "and fails the run" "$W/aw-local.err" 'write\(s\) through an argument that could not be followed'
reject "which is not complete" "$W/aw-local.err" 'audit-core: COMPLETE'
want "a rebound parameter is named" "$W/aw-rebound-out/argument-writes.tsv" \
  "^#unresolved${TAB}setbyte into parameter out of Wad#zone_window_into, which is rebound or beside optional parameters"
reject "and that run is not complete either" "$W/aw-rebound.err" 'audit-core: COMPLETE'

echo "== storage reached through an accessor is still storage =="
# 0008: no field may disappear from migration through an unlisted accessor.
# `lv.sector_floorheight` reads Level's storage inside the accessor
# `attr_reader` generated -- a definition with no body, which the walk never
# enters -- so counting only the ivar nodes it can see lost all of Level's
# geometry, and Lump's three fields with it.
want "Level's geometry is in the inventory" "$W/doom/state-use.tsv" "^Level${TAB}@sector_floorheight${TAB}"
want "and the lump fields it reaches"       "$W/doom/state-use.tsv" "^Lump${TAB}@pos${TAB}"
ok   "713 variables, not the 650 the ivar nodes alone showed" \
     "$(grep -vc '^#' "$W/doom/state-use.tsv")" "714"

echo "== an initial is derived from an allocation, or it is not derived =="
# `(field_fill[...] || "0")` wrote a zero for every field with no allocation
# site. 375 of 713 rows took it, and nothing distinguished those from a zero
# an `Array.new(n, 0)` actually specifies -- so the schema could not tell a
# measured initial from an assumed one, and 0008 task 5 is about the state
# just before the FIRST TICK, which is neither an allocation fill nor a first
# assignment.
# PINNED TO THE WORDING THE RUN ACTUALLY PRINTS. This matched "338 derived
# from an allocation", and when that line was corrected to say it counts
# ALLOCATIONS READ rather than answers -- with the breakdown that makes the
# difference visible -- this check was left behind and went red. It stayed red
# for two commits because I ran only state.sh for those reports.
# 338/375 until allocations were matched to their own class. 17 fields had been
# reading another class's allocation of the same ivar name: 15 now read none
# (8 of them had taken its COUNT as well), and the two `sector_validcount`s read
# only their own and stop being "varies".
want "the run says what it read off an allocation, and what it did not" \
  "$W/doom.err" \
  'initials 323 read off an allocation \(literal 315, varies 1, other 7\), 390 UNDERIVED'
# BY NAME. `Random@@mcount` is one counter; `Jobs@@mcount` is a per-column
# array, and the scalar used to be declared screen:screenwidth from it.
want "an allocation in another class is not this field's" "$W/doom/state-use.tsv" \
  "^Random${TAB}@mcount${TAB}.*${TAB}fixed:1${TAB}UNDERIVED${TAB}"
want "and a same-named ivar in another class keeps its own count" "$W/doom/state-use.tsv" \
  "^Jobs${TAB}@mcount${TAB}.*${TAB}screen:screenwidth${TAB}0${TAB}"
# Two classes, two allocations, two different fills -- no longer one "varies".
want "Level's validcount opens at its own fill" "$W/doom/state-use.tsv" \
  "^Level${TAB}@sector_validcount${TAB}.*${TAB}level:numsectors${TAB}0${TAB}"
want "and Renderer's at its own" "$W/doom/state-use.tsv" \
  "^Renderer${TAB}@sector_validcount${TAB}.*${TAB}level:numsectors${TAB}-1${TAB}"
# WHAT THIS ARITHMETIC IS AND IS NOT. It checks that the constants written
# into the expected line above are consistent with each other -- a breakdown
# cannot drift from the total it describes. It does NOT verify the
# classification: that 327 fields really are literal fills, or that 375 really
# have no allocation, is what the audit measures, and this only pins the shape
# of what it reports.
ok   "and the breakdown adds up to the allocations read" \
     "$("$RUBY" -e 'print ARGV.map { |v| Integer(v, 10) }.sum' 315 1 7)" "323"
ok   "and the two account for every variable" \
     "$("$RUBY" -e 'print ARGV.map { |v| Integer(v, 10) }.sum' 323 390)" \
     "$(grep -vc '^#' "$W/doom/state-use.tsv" | "$RUBY" -e 'print Integer(STDIN.read.strip, 10) - 1')"
# THE TWO KINDS, BY NAME. A fill the allocation specifies is kept as measured;
# a field with no allocation says so instead of saying zero.
# BY COLUMN, not by "the row contains this somewhere". The first version of
# the check below was `reject ... "@bombdamage.*${TAB}0${TAB}"`, which matched
# the row's WRITES-OUTSIDE count and failed while the initial said UNDERIVED
# exactly as intended. A row has fourteen columns and most of them can be 0.
initial_of() { # class ivar
  awk -F"$TAB" -v c="$1" -v v="$2" '$1 == c && $2 == v { print $9 }' "$W/doom/state-use.tsv"
}
ok "a fill the allocation specifies is the measured value" \
   "$(initial_of Game @activeplats)" "-1"
ok "and a scalar with no allocation says it is underived, not zero" \
   "$(initial_of Game @bombdamage)" "UNDERIVED"
ok "a scratch scalar says the same: its declared 0 was never derived" \
   "$(initial_of Game @sightzstart)" "UNDERIVED"

echo "== every stored array's size was read off its allocation =="
# The reader says `int_array`, not how many elements. The allocation
# EXPRESSION is rendered from the tree and tools/doom/core-counts.tsv maps
# each (method, expression) pair to a catalog name -- keyed by the pair,
# because `n` means MAXMOBJS in one method and a lump's element count in
# another.
want "a level array takes a level count"   "$W/doom/state-use.tsv" \
  "^Level${TAB}@sector_floorheight${TAB}.*${TAB}level:numsectors${TAB}"
want "a screen array takes a screen count" "$W/doom/state-use.tsv" \
  "^Renderer${TAB}@floorclip${TAB}.*${TAB}screen:screenwidth${TAB}"
want "a slot bank takes a limit"           "$W/doom/state-use.tsv" \
  "^Game${TAB}@mobj_x${TAB}.*${TAB}limit:maxmobjs${TAB}"
reject "and no stored array is left unsized" "$W/doom.err" 'whose count nobody reviewed'

# Drop one row and the audit must name the array and the expression, not carry
# on with a guess.
grep -v "^Game#init_mobjs${TAB}n${TAB}" "$ROOT/tools/doom/core-counts.tsv" > "$W/counts-short.tsv"
if cmp -s "$ROOT/tools/doom/core-counts.tsv" "$W/counts-short.tsv"; then
  echo "  FAIL dropping the Game#init_mobjs row changed nothing"; fail=$((fail + 1))
else
  mkdir -p "$W/nocount"
  "$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
    --counts "$W/counts-short.tsv" --output "$W/nocount" > "$W/nocount.err" 2>&1 || true
  want "an unmapped allocation is named with its expression" "$W/nocount.err" \
    'whose count nobody reviewed: Game@@[a-z_]+ is allocated at Game#init_mobjs with "n"'
  reject "and the run does not complete" "$W/nocount.err" 'audit-core: COMPLETE'
fi
# A row matching no allocation anywhere is a row describing nothing.
{ cat "$ROOT/tools/doom/core-counts.tsv"; printf 'No#such\tnothing\tfixed:1\tinvented\n'; } > "$W/counts-dead.tsv"
mkdir -p "$W/deadcount"
"$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
  --counts "$W/counts-dead.tsv" --output "$W/deadcount" > "$W/deadcount.err" 2>&1 || true
want "a row matching no allocation is named" "$W/deadcount.err" \
  'matching no allocation: No#such "nothing"'
# ...and it is named ONCE. A dead row has no allocation to evaluate, so the
# `fixed:` value check must not report the same row a second time as one it
# could not evaluate.
reject "and not a second time as unevaluated" "$W/deadcount.err" \
  'row\(s\) in core-counts\.tsv the tree cannot evaluate'

echo "== the number in a fixed: row is the number the tree allocates =="
# The catalog's NAME carries a count and nothing ever compared it with the
# allocation, so three rows were simply wrong: fixed:128 against MAXINTERCEPTS
# (189), fixed:8 against MAXSPECHIT (20), fixed:64 against MAXPLATS (30). The
# first two had copied a PROCESSING limit -- `@ic_n >= 128`, `@numspechit >= 8`
# -- into the place that says how long the array is. Those limits are DOOM's
# and are not touched; what was wrong was the length.
mkdir -p "$W/counts"
"$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/counts" > "$W/counts.err" 2>&1 || true
# THE DECLARED SET AND THE JUDGED SET, name by name -- not two numbers that
# happen to match. Mac review of a9d36ef made the audit judge one row out of
# thirty; it answered `agree 1` and every check in this section passed, because
# the run's number went in as a regex and the "all 29" beside it was counting
# rows in the catalog FILE. So the audit writes a verdict per row now, and what
# is compared is the SET.
want "every fixed: row is evaluated from the tree, and none is skipped" \
  "$W/counts.err" 'fixed counts 30 declared, 30 evaluated \(agree 30 contradict 0 unevaluated 0\), 0 matching no allocation'
grep -vE '^#|^verdict' "$W/counts/fixed-counts.tsv" | cut -f2,3 | sort > "$W/judged.txt"
grep -E "${TAB}fixed:" "$ROOT/tools/doom/core-counts.tsv" | cut -f1,2 | sort > "$W/declared.txt"
ok   "the rows the catalog declares are the rows the audit judged" \
     "$(comm -3 "$W/declared.txt" "$W/judged.txt" | wc -l | tr -d ' ')" "0"
ok   "and there are 30 of them, judged one by one" \
     "$(wc -l < "$W/judged.txt" | tr -d ' ')" "30"
ok   "every one of which agrees with the tree" \
     "$(grep -vE '^#|^verdict' "$W/counts/fixed-counts.tsv" | cut -f1 | sort -u | tr '\n' ' ')" "agree "
want "the intercept bank is 189, not the 128 that guards it" \
  "$ROOT/tools/doom/core-counts.tsv" "^MapMove#init_map_state${TAB}MAXINTERCEPTS${TAB}fixed:189${TAB}"
want "the spechit bank is 20, not the 8 that guards it" \
  "$ROOT/tools/doom/core-counts.tsv" "^MapMove#init_map_state${TAB}MAXSPECHIT${TAB}fixed:20${TAB}"
want "the active-platform list is 30, shorter than the 64 plat slots beside it" \
  "$ROOT/tools/doom/core-counts.tsv" "^Specials#spawn_specials${TAB}MAXPLATS${TAB}fixed:30${TAB}"
# THE LIMITS THEMSELVES STAY. Widening an array is not the fix here; the
# refusals at 128 and at 8 are real processing limits and the catalog was
# describing the wrong thing.
want "the intercept limit is still 128" "$ROOT/examples/doom/lib/doom/mapmove.rb" '@ic_n >= 128'
want "the spechit limit is still 8"     "$ROOT/examples/doom/lib/doom/mapmove.rb" '@numspechit >= 8'

# One digit in one row: the check must name that row, with both numbers.
sed "s|^MapMove#init_map_state${TAB}MAXSPECHIT${TAB}fixed:20${TAB}|MapMove#init_map_state${TAB}MAXSPECHIT${TAB}fixed:8${TAB}|" \
  "$ROOT/tools/doom/core-counts.tsv" > "$W/counts-lied.tsv"
if cmp -s "$ROOT/tools/doom/core-counts.tsv" "$W/counts-lied.tsv"; then
  echo "  FAIL putting fixed:8 back changed nothing"; fail=$((fail + 1))
else
  ok "the mutation is one line" \
     "$(diff "$ROOT/tools/doom/core-counts.tsv" "$W/counts-lied.tsv" | grep -c '^[<>]')" "2"
  mkdir -p "$W/lied"
  "$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
    --counts "$W/counts-lied.tsv" --output "$W/lied" > "$W/lied.err" 2>&1 || true
  want "a wrong count is named with both numbers" "$W/lied.err" \
    'MapMove#init_map_state "MAXSPECHIT" is fixed:8, and the tree says 20'
  want "and it is counted as a contradiction" "$W/lied.err" \
    'fixed counts 30 declared, 30 evaluated \(agree 29 contradict 1 unevaluated 0\)'
  reject "and the run does not complete" "$W/lied.err" 'audit-core: COMPLETE'
fi

echo "== an array literal is an allocation, and an empty one is not =="
# `@fuzzoffset = [1, -1, 1, ...]` sizes 50 cells as plainly as `Array.new(50)`
# does, and it was missed for being a literal rather than a call. The FILL
# tells the two readings apart: a literal of mixed values is `varies`, which
# `Array.new(n, 0)` never is.
want "a literal sizes the field it is assigned to" "$W/doom/state-use.tsv" \
  "^Renderer${TAB}@fuzzoffset${TAB}.*${TAB}fixed:50${TAB}varies${TAB}"
# The job executor is HANDED that table (`@fuzzoffset = fuzzoffset`) and
# allocates nothing. It used to match this row too, through the bare ivar name,
# and read Renderer's literal as its own allocation. Its count now comes from
# core-acquired.tsv and it has no fill of its own to read.
want "and the executor that is handed the same table has its count, not its fill" "$W/doom/state-use.tsv" \
  "^JobExecutor${TAB}@fuzzoffset${TAB}.*${TAB}fixed:50${TAB}UNDERIVED${TAB}"
# AN EMPTY LITERAL IS NOT AN ALLOCATION. `@lumps = []` says nothing about how
# long @lumps ends up -- it is grown afterwards and its length is a fact about
# the WAD. Calling that `fixed:0` would be the invented default this file has
# been removing, in a new place. The two checks above are the evidence that
# the audit reached this stage, so the rejection below is not passing by
# absence.
reject "an empty literal does not become a count of zero" "$W/doom/state-use.tsv" \
  "^Wad${TAB}@lumps${TAB}.*${TAB}fixed:0${TAB}"
reject "nor does the growable texture column list" "$W/doom/state-use.tsv" \
  "^Textures${TAB}@collump${TAB}.*${TAB}fixed:0${TAB}"
# And the 50 is READ, not asserted: one digit off in the row is named.
sed "s|^Renderer#initialize${TAB}\[50 element(s)\]${TAB}fixed:50${TAB}|Renderer#initialize${TAB}[50 element(s)]${TAB}fixed:49${TAB}|" \
  "$ROOT/tools/doom/core-counts.tsv" > "$W/counts-lit.tsv"
if cmp -s "$ROOT/tools/doom/core-counts.tsv" "$W/counts-lit.tsv"; then
  echo "  FAIL changing the literal row to fixed:49 changed nothing"; fail=$((fail + 1))
else
  ok "the mutation is one line" \
     "$(diff "$ROOT/tools/doom/core-counts.tsv" "$W/counts-lit.tsv" | grep -c '^[<>]')" "2"
  mkdir -p "$W/lit"
  "$RUBY" "$AUDIT" --reader "$READER" --tables "$ROOT/tools/doom" \
    --counts "$W/counts-lit.tsv" --output "$W/lit" > "$W/lit.err" 2>&1 || true
  want "the literal's own length is what the row is checked against" "$W/lit.err" \
    'Renderer#initialize "\[50 element\(s\)\]" is fixed:49, and the tree says 50'
fi

echo "== a count is only evaluated when the binding is shown to reach it =="
# What the fixtures really do is measured under CRuby, on the owner's instruction.
if "$ROOT/tools/oracle/gate" tests/doom-core/audit.sh cruby-fixtures; then cruby=1; else cruby=0; fi
# Three fixtures, one method each, differing in ONE line. What they really do
# was measured with ruby before any of this was asserted: 64, 65, and a
# TypeError, in that order. A rule that counts plain writes answers 64 to all
# three.
CF="$FIX/counts"
cf() { # variant outdir
  mkdir -p "$W/$2"
  "$RUBY" "$AUDIT" --entry "$CF/$1.rb" --roots 'Game#g_ticker' --reader "$READER" \
    --tables "$ROOT/tools/doom" --counts "$CF/counts.tsv" --output "$W/$2" > "$W/$2.err" 2>&1 || true
}
ok "the fixtures differ in one line" \
   "$("$RUBY" -e 'a, b = ARGV.map { |f| File.readlines(f) }
                  print (a - b).length + (b - a).length' "$CF/plain.rb" "$CF/update.rb")" "2"
ok "and so do the other two" \
   "$("$RUBY" -e 'a, b = ARGV.map { |f| File.readlines(f) }
                  print (a - b).length + (b - a).length' "$CF/plain.rb" "$CF/guarded.rb")" "2"
# What the three actually do, run rather than assumed.
if [ "$cruby" = 1 ]; then
  ok "unconditional binds 64"       "$("$RUBY" -e 'require_relative ARGV[0]
     g = Doom::Game.allocate; g.init_bank; print g.instance_variable_get(:@bank).length' "$CF/plain.rb")" "64"
fi
cf plain cf-plain
want "so the row is evaluated and agrees" "$W/cf-plain.err" \
  'fixed counts 1 declared, 1 evaluated \(agree 1 contradict 0 unevaluated 0\)'

# `n = 64; n += 1` -- one plain write, two binders, and an array of 65.
if [ "$cruby" = 1 ]; then
  ok "an update makes it 65"        "$("$RUBY" -e 'require_relative ARGV[0]
     g = Doom::Game.allocate; g.init_bank; print g.instance_variable_get(:@bank).length' "$CF/update.rb")" "65"
fi
cf update cf-update
want "so the row is refused, not answered with the pre-update value" "$W/cf-update.err" \
  'Game#init_bank "n" is fixed:64, and the tree gives no single value for that allocation'
want "and it is counted as unevaluated" "$W/cf-update.err" \
  'fixed counts 1 declared, 1 evaluated \(agree 0 contradict 0 unevaluated 1\)'

# `n = 64 if false` -- one plain write, one binder, and the method raises.
if [ "$cruby" = 1 ]; then
  ok "a guarded binding does not run at all" "$("$RUBY" -e 'require_relative ARGV[0]
     g = Doom::Game.allocate
     begin; g.init_bank; print "no error"; rescue TypeError; print "TypeError"; end' "$CF/guarded.rb")" "TypeError"
fi
cf guarded cf-guarded
want "so it is refused too, though nothing else binds the name" "$W/cf-guarded.err" \
  'Game#init_bank "n" is fixed:64, and the tree gives no single value for that allocation'
want "and it is counted as unevaluated" "$W/cf-guarded.err" \
  'fixed counts 1 declared, 1 evaluated \(agree 0 contradict 0 unevaluated 1\)'

echo "== a constant is resolved in the reading scope, or not at all =="
# "The only definition of that bare name in the tree" is not a conservative
# rule, it is an unsound one. `Doom::Other::N` is unique, unconditional and
# earlier than the read, and `Doom::Game` still cannot see it. What CRuby does
# is measured first, in both directions.
ok "the fixtures differ in one line" \
   "$("$RUBY" -e 'a, b = ARGV.map { |f| File.readlines(f) }
                  print (a - b).length + (b - a).length' \
      "$CF/scope-bare.rb" "$CF/scope-qualified.rb")" "2"
if [ "$cruby" = 1 ]; then
  ok "a bare name defined in another module is not in scope" \
     "$("$RUBY" -e 'require_relative ARGV[0]
        g = Doom::Game.allocate
        begin; g.init_bank; print "no error"; rescue NameError; print "NameError"; end' \
        "$CF/scope-bare.rb")" "NameError"
fi
if [ "$cruby" = 1 ]; then
  ok "and naming the module reaches it"     "$("$RUBY" -e 'require_relative ARGV[0]
     g = Doom::Game.allocate; g.init_bank; print g.instance_variable_get(:@bank).length' \
     "$CF/scope-qualified.rb")" "64"
fi
mkdir -p "$W/cf-sbare" "$W/cf-squal"
"$RUBY" "$AUDIT" --entry "$CF/scope-bare.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --counts "$CF/counts-bare.tsv" --output "$W/cf-sbare" \
  > "$W/cf-sbare.err" 2>&1 || true
want "so the audit refuses it rather than taking the one definition there is" \
  "$W/cf-sbare.err" 'Game#init_bank "N" is fixed:64, and the tree gives no single value for that allocation'
want "and counts it as unevaluated" "$W/cf-sbare.err" \
  'fixed counts 1 declared, 1 evaluated \(agree 0 contradict 0 unevaluated 1\)'
"$RUBY" "$AUDIT" --entry "$CF/scope-qualified.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --counts "$CF/counts-qualified.tsv" --output "$W/cf-squal" \
  > "$W/cf-squal.err" 2>&1 || true
want "while the qualified one is evaluated and agrees" "$W/cf-squal.err" \
  'fixed counts 1 declared, 1 evaluated \(agree 1 contradict 0 unevaluated 0\)'
# AND IT IS RENDERED AS AN EXPRESSION. `Other::N` used to come out as the
# string "ConstantPathNode" -- the fallback that names the node kind -- so a
# qualified constant would have gone into the catalog under a key that is not
# an expression at all.
reject "a qualified constant is not keyed by its node kind" "$W/cf-squal/fixed-counts.tsv" \
  'ConstantPathNode'
want "it is keyed by what is written" "$W/cf-squal/fixed-counts.tsv" \
  "^agree${TAB}Game#init_bank${TAB}Other::N${TAB}"
# AND THE INNERMOST BINDING DECIDES EVEN WHEN IT IS THE WRONG KIND OF THING.
# `Other = 1` inside `Game`, beside the `Doom::Other` module: CRuby answers
# `1 is not a class/module`. Searching only for SCOPES walks straight past the
# 1 to the module outside and confirms 64, which is what this did.
if [ "$cruby" = 1 ]; then
  ok "an inner constant of the same name is a TypeError, not a fallback" \
     "$("$RUBY" -e 'require_relative ARGV[0]
        g = Doom::Game.allocate
        begin; g.init_bank; print "no error"; rescue TypeError; print "TypeError"; end' \
        "$CF/scope-shadow.rb")" "TypeError"
fi
ok "and it is one line away from the case that works" \
   "$("$RUBY" -e 'a, b = ARGV.map { |f| File.readlines(f) }
                  print (a - b).length + (b - a).length' \
      "$CF/scope-qualified.rb" "$CF/scope-shadow.rb")" "3"
mkdir -p "$W/cf-shadow"
"$RUBY" "$AUDIT" --entry "$CF/scope-shadow.rb" --roots 'Game#g_ticker' --reader "$READER" \
  --tables "$ROOT/tools/doom" --counts "$CF/counts-qualified.tsv" --output "$W/cf-shadow" \
  > "$W/cf-shadow.err" 2>&1 || true
want "so the qualifier resolves to nothing and the row is refused" "$W/cf-shadow.err" \
  'fixed counts 1 declared, 1 evaluated \(agree 0 contradict 0 unevaluated 1\)'
reject "rather than reaching the module outside it" "$W/cf-shadow/fixed-counts.tsv" \
  "^agree${TAB}"

# AND A RUN THAT JUDGED ONE ROW MUST BE VISIBLE AS ONE. This is the audit
# mutation Mac review of a9d36ef used -- skip every `fixed:` row but
# MAXSPECHIT. It answered `agree 1` and COMPLETE, and every check in this
# section passed it, which is why the section now compares the declared SET
# with the judged SET instead of two numbers.
# THE WHOLE DIRECTORY, as the two mutants above do: a lone copy of the audit
# dies at `require_relative "contract_reader"` and the control would be
# measuring a missing file rather than a skipped row. (It did, the first time.)
cp -R "$ROOT/tools/doom" "$W/skipdir"
sed 's|^  next unless name.start_with?("fixed:")$|  next unless name.start_with?("fixed:") \&\& expr == "MAXSPECHIT"|' \
  "$AUDIT" > "$W/skipdir/audit-core.rb"
if cmp -s "$AUDIT" "$W/skipdir/audit-core.rb"; then
  echo "  FAIL the skip mutation changed nothing"; fail=$((fail + 1))
else
  ok "the skip mutation is one line" \
     "$(diff "$AUDIT" "$W/skipdir/audit-core.rb" | grep -c '^[<>]')" "2"
  mkdir -p "$W/skip"
  "$RUBY" "$W/skipdir/audit-core.rb" --entry "$ROOT/examples/doom/bin/doom.rb" --reader "$READER" \
    --tables "$ROOT/tools/doom" --output "$W/skip" > "$W/skip.err" 2>&1 || true
  # EVIDENCE BEFORE ABSENCE: the mutant has to have RUN, or the two set checks
  # below would read an empty file and pass for the wrong reason.
  want "the mutant reached the closure stage" "$W/skip.err" 'reached [0-9]+ definition\(s\)'
  want "the run says how many of the declared rows it judged" "$W/skip.err" \
    'fixed counts 30 declared, 1 evaluated'
  ok   "and the judged set is one row, not thirty" \
       "$(grep -vcE '^#|^verdict' "$W/skip/fixed-counts.tsv")" "1"
  # The check that was passing this before, run against the mutant, to show
  # which one catches it now.
  grep -vE '^#|^verdict' "$W/skip/fixed-counts.tsv" | cut -f2,3 | sort > "$W/skip-judged.txt"
  ok   "so the declared set and the judged set no longer agree" \
       "$(comm -3 "$W/declared.txt" "$W/skip-judged.txt" | grep -c .)" "29"
fi

echo "== an acquired row may convert entries to bytes, and nothing else =="
# A row in core-acquired.tsv answers for a field the tree does not allocate.
# It may also override an ALLOCATED field's count, for exactly one reason: the
# reader types the field `str_array`, the schema stores it as bytes, and the
# encoder joins the strings, so the allocation's count of ENTRIES is not the
# field's length in BYTES. `Textures@@texdata` is 125 entries and 1379328
# bytes.
#
# The first version of that override was unconstrained -- any row could resize
# any allocated field and the run merely said that it had, which is a way to
# put any number on any field.
# 73 rows: Lump@@pos and Lump@@size joined Lump@@name when the three
# singletons became per-entry arrays (docs/core/doom-lump-directory.md); 80
# with JobExecutor's seven handed-in arrays; 82 with the two source aliases,
# `Renderer@@dc_srcbuf` and `Renderer@@ds_source`, each one selector wide.
# 81 since 0dfc2f7, which removed the JobExecutor@@zonebuf row with the alias.
want "the two byte-count conversions are named as what they are" "$W/doom.err" \
  'acquired counts 81 declared, 81 used \(2 converting entries to joined bytes: Textures@@flatdata, Textures@@texdata\)'
# AND A ROW ON AN ORDINARY NUMERIC ARRAY IS REFUSED BY NAME. `Game@@mobj_x` is
# `int_array` stored as i64; no row may resize it.
{ cat "$ROOT/tools/doom/core-acquired.tsv"
  printf 'Game@@mobj_x\tfixed:1\tDoom::Game @mobj_x\tan override that must be refused\n'
} > "$W/acq-bad.tsv"
mkdir -p "$W/acqbad"
"$RUBY" "$AUDIT" --acquired "$W/acq-bad.tsv" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/acqbad" > "$W/acqbad.err" 2>&1 || true
want "a row on an allocated numeric array is refused, with the reason" "$W/acqbad.err" \
  'Game@@mobj_x is allocated and is int_array stored as i64; only a str_array stored as bytes may take its count'
want "and the run does not complete" "$W/acqbad.err" 'INCOMPLETE'
# THE POSITIVE SIDE, so this is not a rule that refuses everything: the two
# real conversions still take effect in the same run.
want "while the two real conversions still apply" "$W/acqbad.err" \
  '2 converting entries to joined bytes: Textures@@flatdata, Textures@@texdata'

echo "== what Full's setup writes before the first tick =="
# The walk from bin/doom.rb's calls before its loop decides which stored fills
# stand (emit-schema.rb carries every field it lists). A write it misses would
# let a fill claim a value setup overwrites, so it has to follow every call,
# and it has to be DOOM's setup that it walks.
want "the setup walk followed every call" "$W/doom.err" \
  '^audit-core: setup reached [0-9]+ definition\(s\) from 19 root\(s\), writes [0-9]+ field\(s\), 0 gap\(s\)$'
# `@th_alloc = 1` in init_thinkers and the add_thinker calls that follow it.
want "a field setup writes after allocating is listed with its sites" "$W/doom/setup-writes.tsv" \
  "^Game@@th_alloc${TAB}Game#add_thinker@lib/doom/game.rb:[0-9]+,Game#init_thinkers@lib/doom/game.rb:[0-9]+$"
# `@mobj_x = Array.new(n, 0)` is at game.rb:169; that allocation is where the
# fill comes from, not a write that changes it -- spawn_mobj's is.
want "an allocation is not a setup write, a later store is" "$W/doom/setup-writes.tsv" \
  "^Game@@mobj_x${TAB}.*Game#spawn_mobj@lib/doom/game.rb:[0-9]+"
reject "and the allocation's own line is not among its writers" "$W/doom/setup-writes.tsv" \
  "^Game@@mobj_x${TAB}.*game.rb:169"
# THE ROOTS ARE bin/doom.rb's, checked against it: every object it constructs
# before the loop is a root's class, except the two named here -- Demo (demo
# playback, not the compared configuration) and Video (SDL, Full's) -- and the
# calls it makes on them in between are roots too.
awk '/while !quit/ { exit } { print }' "$ROOT/examples/doom/bin/doom.rb" \
  | grep -o 'Doom::[A-Za-z]*\.new' | sed 's/Doom::\(.*\)\.new/\1/' | sort -u \
  | grep -vx 'Demo\|Video' > "$W/setup-built.txt"
sed -n 's/^#root\t\([A-Za-z]*\)#initialize$/\1/p' "$W/doom/setup-writes.tsv" | sort -u > "$W/setup-rootcls.txt"
ok "every object doom.rb builds before its loop is a setup root, and no other" \
   "$(comm -3 "$W/setup-built.txt" "$W/setup-rootcls.txt" | tr -d '\t' | tr '\n' ' ')" ""
ok "and there are fifteen of them" "$(grep -c . "$W/setup-rootcls.txt")" "15"
for call in 'rnd.clear:Random#clear' 'sb.start(:StatusBar#start' 'r.job_mode = :Renderer#job_mode=' 'wad.bytes_by_name(:Wad#bytes_by_name'; do
  src=${call%%:*}; root=${call#*:}
  ok "doom.rb calls $src before its loop, and $root is a root" \
     "$(awk '/while !quit/ { exit } { print }' "$ROOT/examples/doom/bin/doom.rb" | grep -cF "$src" | awk '{print ($1 > 0)}') $(grep -cx "#root${TAB}$root" "$W/doom/setup-writes.tsv")" "1 1"
done
# AND A GAP IS SEEN. The one exemption -- a call whose every candidate is a
# generated reader, its result not stored into -- removed, on a copy.
#
# THE CALL IT EXEMPTS IS PLANTED, not borrowed from DOOM. This control used to
# run the mutant on DOOM itself and expect its 19 untyped Lump reads
# (`l.pos` and the like) as gaps. Re-measured on 2026-10-18, the reader types
# those receivers obj_Lump at both the old pin 573aa44 and the new one, so DOOM
# has no call the exemption covers: the mutant reported 0 gaps and the control
# failed with nothing wrong in the audit. A control that reads silence as a
# value needs its own failing input. The plant is one untyped call to a name
# whose only tree definition is a generated reader, its result unused:
# `setup_probe_r = [0, "x"].first; setup_probe_r.pos` in Game#initialize.
# Measured: the real audit gives it no gap (0 in all), the mutant names it
# (1 in all).
cp -R "$ROOT/examples/doom" "$W/probe-treer"
sed 's|^      @skill = skill$|      @skill = skill; setup_probe_r = [0, "x"].first; setup_probe_r.pos|' \
  "$ROOT/examples/doom/lib/doom/game.rb" > "$W/probe-treer/lib/doom/game.rb"
ok "the reader-call probe is one line" \
   "$(diff "$ROOT/examples/doom/lib/doom/game.rb" "$W/probe-treer/lib/doom/game.rb" | grep -c '^[<>]')" "2"
cp -R "$ROOT/tools/doom" "$W/gapdir"
sed 's|^      if how == "unnarrowed" \&\& readers_only$|      if false|' "$AUDIT" > "$W/gapdir/audit-core.rb"
ok "the gap mutation is one line" "$(diff "$AUDIT" "$W/gapdir/audit-core.rb" | grep -c '^[<>]')" "2"
mkdir -p "$W/probe-r" "$W/gap"
"$RUBY" "$AUDIT" --entry "$W/probe-treer/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/probe-r" > "$W/probe-r.err" 2>&1 || true
want "with the exemption, the planted reader call is no gap" "$W/probe-r/setup-writes.tsv" \
  "^#complete${TAB}roots=19${TAB}.*${TAB}gaps=0$"
"$RUBY" "$W/gapdir/audit-core.rb" --entry "$W/probe-treer/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/gap" > "$W/gap.err" 2>&1 || true
want "without it, the planted reader call is a gap, named" "$W/gap/setup-writes.tsv" \
  "^#gap${TAB}no receiver evidence, candidates Lump#pos: Game#initialize -> pos \(lib/doom/game.rb:[0-9]+\)$"
want "and the run says how many" "$W/gap.err" \
  '^audit-core: setup reached [0-9]+ definition\(s\) from 19 root\(s\), writes [0-9]+ field\(s\), 1 gap\(s\)$'

# A BUILTIN IS NOT A NO-WRITE. Mac review of 39e4392 put
# `@setup_probe = Array.new(1, 0); @setup_probe.fill(7)` in Game#initialize and
# the walk -- which skipped every call with no tree definition -- listed nothing
# and reported no gap. Now each builtin's effect comes from
# tools/doom/core-builtin-effects.tsv, and a mutating one is attributed to the
# field its receiver is: directly, through a local, and through a parameter.
# On a COPY of the tree, with three probe fields in Game#initialize.
cp -R "$ROOT/examples/doom" "$W/probe-tree"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "      @skill = skill\n"
  s.scan(a).length == 1 or abort("no @skill anchor")
  s.sub!(a, a + "      @setup_probe_a = Array.new(1, 0); @setup_probe_a.fill(7)\n" \
               "      @setup_probe_b = Array.new(1, 0); probe = @setup_probe_b; probe.fill(7)\n" \
               "      @setup_probe_c = Array.new(1, 0); setup_probe_fill(@setup_probe_c)\n" \
               "      @setup_probe_e = Array.new(1, 0); @setup_probe_f = @setup_probe_e; @setup_probe_f.fill(7)\n")
  b = "    def initialize(wad, level, skill, rnd, textures)\n"
  s.scan(b).length == 1 or abort("no initialize anchor")
  s.sub!(b, "    def setup_probe_fill(a)\n      a.fill(7)\n    end\n\n" + b)
  File.write(f, s)' "$W/probe-tree/lib/doom/game.rb"
ok "the probe adds eight lines to game.rb and nothing else" \
   "$(diff -r "$ROOT/examples/doom" "$W/probe-tree" | grep -c '^[<>]')" "8"
mkdir -p "$W/probe"
"$RUBY" "$AUDIT" --entry "$W/probe-tree/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/probe" > "$W/probe.err" 2>&1 || true
want "fill on an ivar is setup's write to that field" "$W/probe/setup-writes.tsv" \
  "^Game@@setup_probe_a${TAB}Game#initialize@lib/doom/game.rb:[0-9]+$"
want "and through a local that holds it" "$W/probe/setup-writes.tsv" \
  "^Game@@setup_probe_b${TAB}Game#initialize@lib/doom/game.rb:[0-9]+$"
want "and through a parameter it is passed as, at the callee" "$W/probe/setup-writes.tsv" \
  "^Game@@setup_probe_c${TAB}Game#setup_probe_fill@lib/doom/game.rb:[0-9]+$"
# SHARED STORAGE: `@f = @e` makes one array of two fields, so a store through
# @f is a store into @e. Mac review of 1e61b37 showed the walk listing @f
# alone while CRuby held the 7 in @e too.
want "and a store through a field that shares another's array writes both" "$W/probe/setup-writes.tsv" \
  "^Game@@setup_probe_e${TAB}Game#initialize@lib/doom/game.rb:[0-9]+\(through Game@@setup_probe_f\)$"
want "  the one written through" "$W/probe/setup-writes.tsv" \
  "^Game@@setup_probe_f${TAB}Game#initialize@lib/doom/game.rb:[0-9]+$"
want "with no gap" "$W/probe/setup-writes.tsv" "^#complete${TAB}roots=19${TAB}.*${TAB}gaps=0$"
# AND A BUILTIN THE TABLE DOES NOT LIST IS A GAP, named, not a no-write.
cp -R "$ROOT/examples/doom" "$W/probe-tree2"
sed 's|^      @skill = skill$|      @skill = skill; @setup_probe_d = Array.new(1, 0); @setup_probe_d.frobnicate(7); @setup_probe_g = Array.new(1, 0).each { \|x\| x }|' \
  "$ROOT/examples/doom/lib/doom/game.rb" > "$W/probe-tree2/lib/doom/game.rb"
ok "the second probe is one line" \
   "$(diff "$ROOT/examples/doom/lib/doom/game.rb" "$W/probe-tree2/lib/doom/game.rb" | grep -c '^[<>]')" "2"
mkdir -p "$W/probe2"
"$RUBY" "$AUDIT" --entry "$W/probe-tree2/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/probe2" > "$W/probe2.err" 2>&1 || true
want "an unlisted builtin on a field is a gap, with its name and site" "$W/probe2/setup-writes.tsv" \
  "^#gap${TAB}no effect listed for frobnicate on int_array: Game#initialize -> frobnicate \(lib/doom/game.rb:[0-9]+\)$"
# AND A FIELD BOUND TO STORAGE THE WALK CANNOT NAME is a gap: it might share
# that storage with a field nobody lists. (`each` also has no effect row.)
want "a field bound to storage the walk cannot name is a gap" "$W/probe2/setup-writes.tsv" \
  "^#gap${TAB}Game@@setup_probe_g may share storage it is bound to: storage returned by each \(lib/doom/game.rb:[0-9]+\): Game#initialize@lib/doom/game.rb:[0-9]+$"
want "and the walk counts all three" "$W/probe2/setup-writes.tsv" "^#complete${TAB}roots=19${TAB}.*${TAB}gaps=3$"
# A CALL WHOSE RESULT MAY BE ITS RECEIVER IS NOT FRESH. String#to_s returns the
# string itself, so `@t.to_s.setbyte(0, 7)` writes @t (Mac review of b8446d1).
# It was on the fresh-call list. Alone, on its own copy: a store into @t or a
# gap naming it, never nothing.
#
# Since upstream 06430db8b the analysis itself rewrites this: in the table the
# nodes face reads, setbyte's receiver becomes @t and the `to_s` call becomes a
# NilNode at the same id. The audit takes links from the ast and kinds from the
# nodes face, so it saw a nil receiver and recorded NOTHING -- the outcome this
# probe exists to forbid. It now refuses a parse whose faces disagree on a
# node's kind, as the C++ contract reader does, so the probe's audit aborts by
# name. The walk's own to_s rule is no longer reached by this probe; nothing
# in DOOM reaches the rewrite either (0 kind mismatches at both pins).
cp -R "$ROOT/examples/doom" "$W/probe-tree3"
sed 's|^      @skill = skill$|      @skill = skill; @setup_probe_t = Bytes.buffer(1, 0); @setup_probe_t.to_s.setbyte(0, 7)|' \
  "$ROOT/examples/doom/lib/doom/game.rb" > "$W/probe-tree3/lib/doom/game.rb"
ok "the to_s probe is one line" \
   "$(diff "$ROOT/examples/doom/lib/doom/game.rb" "$W/probe-tree3/lib/doom/game.rb" | grep -c '^[<>]')" "2"
mkdir -p "$W/probe3"
"$RUBY" "$AUDIT" --entry "$W/probe-tree3/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/probe3" > "$W/probe3.err" 2>&1 || true
want "a store through to_s is refused, not read as nothing" "$W/probe3.err" \
  "^audit-core: kind-mismatch: node [0-9]+ ast 'CallNode' nodes 'NilNode'$"
reject "and no walk is written from that parse" "$W/probe3/setup-writes.tsv" '^#complete'

echo "== a scratch field is written before it is read, inside the call =="
# 0008 leaves scratch out of the snapshot and checks it through its access
# invariant: no read inside an entry sees a value from before the call. The
# audit shows that per read -- an unconditional write earlier in the same
# definition, or every self-call into the definition made after one, through
# recursion (cross_bsp_node calls itself) -- and says which reads it cannot.
want "every scratch field is shown" "$W/doom.err" '^audit-core: scratch written before read: 12 of 12 shown$'
for f in bombdamage bombsource bombspot crushchange nofit sightzstart strace_dx strace_dy strace_x strace_y t2x t2y; do
  want "Game@@$f is written before each read" "$W/doom/scratch-defined.tsv" "^Game@@${f}${TAB}written-before-read${TAB}[0-9]+${TAB}$"
done
# AND IT CAN FAIL. On a copy: one write moved after the call whose callee reads
# it, and one write made conditional.
cp -R "$ROOT/examples/doom" "$W/scr-tree"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "      @t2y = @mobj_y[t2]\n"; b = "      cross_bsp_node(lv.num_nodes - 1)\n"
  s.scan(a).length == 1 && s.scan(b).length == 1 or abort("no sight anchors")
  s.sub!(a, ""); s.sub!(b, b + a)
  File.write(f, s)' "$W/scr-tree/lib/doom/sight.rb"
sed 's|^      @bombdamage = damage$|      @bombdamage = damage if damage > 0|' \
  "$ROOT/examples/doom/lib/doom/specials.rb" > "$W/scr-tree/lib/doom/specials.rb"
ok "the two changes are four lines" "$(diff -r "$ROOT/examples/doom" "$W/scr-tree" | grep -c '^[<>]')" "4"
mkdir -p "$W/scr"
"$RUBY" "$AUDIT" --entry "$W/scr-tree/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/scr" > "$W/scr.err" 2>&1 || true
want "a write after the call is not shown, with the read it misses" "$W/scr/scratch-defined.tsv" \
  "^Game@@t2y${TAB}not-shown${TAB}[0-9]+${TAB}.*Game#cross_(subsector|bsp_node)@lib/doom/sight.rb:[0-9]+"
want "a conditional write is not shown" "$W/scr/scratch-defined.tsv" \
  "^Game@@bombdamage${TAB}not-shown${TAB}[0-9]+${TAB}Game#pit_radius_attack@lib/doom/specials.rb:[0-9]+"
want "while the fields beside them still are" "$W/scr/scratch-defined.tsv" \
  "^Game@@t2x${TAB}written-before-read${TAB}"
want "and the run counts ten of twelve" "$W/scr.err" '^audit-core: scratch written before read: 10 of 12 shown$'
# A WRITE HAPPENS WHEN ITS VALUE IS DONE, not where it starts. Mac review of
# 7e42637 split `@bombdamage = damage` into `@bombdamage =` and, on the next
# line, `@bombdamage + damage`: the read is inside the write's own value and
# runs before it, and the start-line rule called it written first. Alone, on
# its own copy, so nothing else can be what makes it fail.
cp -R "$ROOT/examples/doom" "$W/scr-tree3"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "      @bombdamage = damage\n"
  s.scan(a).length == 1 or abort("no bombdamage anchor")
  s.sub!(a, "      @bombdamage =\n        @bombdamage + damage\n")
  File.write(f, s)' "$W/scr-tree3/lib/doom/specials.rb"
ok "the split write is three lines of diff" "$(diff -r "$ROOT/examples/doom" "$W/scr-tree3" | grep -c '^[<>]')" "3"
mkdir -p "$W/scr3"
"$RUBY" "$AUDIT" --entry "$W/scr-tree3/bin/doom.rb" --reader "$READER" \
  --tables "$ROOT/tools/doom" --output "$W/scr3" > "$W/scr3.err" 2>&1 || true
want "a read inside the write's own value is not after the write" "$W/scr3/scratch-defined.tsv" \
  "^Game@@bombdamage${TAB}not-shown${TAB}[0-9]+${TAB}Game#radius_attack@lib/doom/specials.rb:[0-9]+"
want "and the other eleven stay shown" "$W/scr3.err" '^audit-core: scratch written before read: 11 of 12 shown$'

echo "== every CORE output has a CORE writer =="
# The owner's rule of 2026-09-17: an output or persistent field step or render
# code writes needs a migrated writer on a path a shipped program runs, unless
# tools/doom/core-unreached.tsv names it. Its failing input is the table with
# one row dropped -- and the row that matters is a span_* one: map_plane is
# migrated BY NAME and writes span_* only under `if @trace`, so only the gate
# evaluation makes that input fail.
want "the full run finds no unlisted field" "$W/doom.err" \
  'CORE writers: 106 field\(s\) declared unreached, 4 of them reset on a shipped path and read on none \(renderer_column_n, renderer_span_n, renderer_visit_n, renderer_wall_n\), 0 written by step or render code with no CORE writer$'
grep -v "^renderer_span_x1${TAB}" "$ROOT/tools/doom/core-unreached.tsv" > "$W/unreached-drop.tsv"
ok "the failing input drops one row" "$(diff "$ROOT/tools/doom/core-unreached.tsv" "$W/unreached-drop.tsv" | grep -c '^<')" "1"
mkdir -p "$W/wr-drop"
"$RUBY" "$AUDIT" --entry "$ROOT/examples/doom/bin/doom.rb" --reader "$READER" --tables "$ROOT/tools/doom" \
  --unreached "$W/unreached-drop.tsv" --output "$W/wr-drop" > "$W/wr-drop.err" 2>&1 || true
want "a dropped span_* row fails the run by name" "$W/wr-drop.err" \
  'INCOMPLETE -- 1 field\(s\) written by step or render code with no CORE writer and no row in unreached-drop.tsv: renderer_span_x1 \(Renderer#map_plane\)'
# A LISTED FIELD WRITTEN ON A SHIPPED PATH must say RESET ONLY, and be one.
sed "s/^\(renderer_span_n${TAB}trace${TAB}\)RESET ONLY: /\1/" "$ROOT/tools/doom/core-unreached.tsv" > "$W/unreached-noreset.tsv"
ok "the reset control changes one row" "$(diff "$ROOT/tools/doom/core-unreached.tsv" "$W/unreached-noreset.tsv" | grep -c '^<')" "1"
mkdir -p "$W/wr-noreset"
"$RUBY" "$AUDIT" --entry "$ROOT/examples/doom/bin/doom.rb" --reader "$READER" --tables "$ROOT/tools/doom" \
  --unreached "$W/unreached-noreset.tsv" --output "$W/wr-noreset" > "$W/wr-noreset.err" 2>&1 || true
want "a reset counter whose row does not say so fails by name" "$W/wr-noreset.err" \
  'declared unreached and written on a shipped path other than as a reset nothing shipped reads: renderer_span_n \(reason says RESET ONLY: false'
# AND ONE A SHIPPED PATH READS is a contradiction however its row reads.
cp -R "$ROOT/examples/doom" "$W/rd-tree"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "      @span_n = 0\n      @phase = 0\n"
  s.scan(a).length == 1 or abort("no span_n anchor")
  s.sub!(a, "      @span_n = 0\n      @phase = @span_n\n")
  File.write(f, s)' "$W/rd-tree/lib/doom/render.rb"
ok "the planted read is one line of diff each way" "$(diff -r "$ROOT/examples/doom" "$W/rd-tree" | grep -c '^[<>]')" "2"
mkdir -p "$W/wr-read"
"$RUBY" "$AUDIT" --entry "$W/rd-tree/bin/doom.rb" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/wr-read" > "$W/wr-read.err" 2>&1 || true
want "a reset counter a shipped path reads fails by name" "$W/wr-read.err" \
  'renderer_span_n \(reason says RESET ONLY: true, every shipped write a literal 0: true, shipped reads: Renderer#render_player_view\)'
# WITHOUT THE GATE EVALUATION the same input passes: the rule would be its name.
cp -R "$ROOT/tools/doom" "$W/nogatedir"
sed 's|^  next false unless defs\[def_key\] && GATE_CLASSES.include?(defs\[def_key\]\["cls"\])$|  next false|' \
  "$AUDIT" > "$W/nogatedir/audit-core.rb"
if cmp -s "$AUDIT" "$W/nogatedir/audit-core.rb"; then
  echo "  FAIL the gate mutation changed nothing"; fail=$((fail + 1))
else
  ok "the gate mutation is one line" "$(diff "$AUDIT" "$W/nogatedir/audit-core.rb" | grep -c '^[<>]')" "2"
  mkdir -p "$W/wr-nogate"
  "$RUBY" "$W/nogatedir/audit-core.rb" --entry "$ROOT/examples/doom/bin/doom.rb" --reader "$READER" \
    --tables "$W/nogatedir" --unreached "$W/unreached-drop.tsv" --output "$W/wr-nogate" \
    > "$W/wr-nogate.err" 2>&1 || true
  want "the gateless mutant reached the rule" "$W/wr-nogate.err" 'CORE writers: 105 field\(s\) declared unreached'
  reject "and passes the dropped row, which is why the gates are evaluated" "$W/wr-nogate.err" \
    'no CORE writer and no row'
fi

# AND A NON-ZERO RESET is not a reset: the third control, a shipped write of
# another literal into a RESET ONLY field.
cp -R "$ROOT/examples/doom" "$W/nz-tree"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "      @span_n = 0\n      @phase = 0\n"
  s.scan(a).length == 1 or abort("no span_n anchor")
  s.sub!(a, "      @span_n = 7\n      @phase = 0\n")
  File.write(f, s)' "$W/nz-tree/lib/doom/render.rb"
ok "the planted write is one line of diff each way" "$(diff -r "$ROOT/examples/doom" "$W/nz-tree" | grep -c '^[<>]')" "2"
mkdir -p "$W/wr-nonzero"
"$RUBY" "$AUDIT" --entry "$W/nz-tree/bin/doom.rb" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/wr-nonzero" > "$W/wr-nonzero.err" 2>&1 || true
want "a reset counter written with a non-zero literal fails by name" "$W/wr-nonzero.err" \
  'renderer_span_n \(reason says RESET ONLY: true, every shipped write a literal 0: false'

echo "== a write through a local alias is a write =="
# Renderer#store_wall_range writes the line flags as `flags = lv.line_flags;
# flags[linedef] = ...`. The kernel found it (the render entry wrote a buffer its
# manifest gave only `in`); the audit now follows the local.
# Six since 888a00f, which made two direct writes go through a local:
# Renderer#clear_screen (`screen = @screen; screen.setbyte(i, 0)`) and
# StatusBar#refresh_background (`backing = @backing; backing.setbyte(i, 0)`),
# so Renderer@@screen and StatusBar@@backing gain a row each. No field is new:
# both were stored already through their direct writes.
want "the full run follows every local store" "$W/doom/local-writes.tsv" "^#complete${TAB}writes=6${TAB}unresolved=0$"
want "  and the line flags are written by store_wall_range" "$W/doom/local-writes.tsv" \
  "^Level@@line_flags${TAB}Renderer#store_wall_range$"
want "  which makes them persistent, not a resource" "$W/doom/state-use.tsv" \
  "^Level${TAB}@line_flags${TAB}persistent${TAB}shared${TAB}int_array${TAB}stored${TAB}"
# AN INDEX OPERATOR WRITE is a store as well: `@pl_maxammo[i] *= 2` has no
# `[]=` edge, and the kernel refused the step entry's backpack before this did.
want "index operator writes are counted" "$W/doom.err" '^audit-core: 62 index operator write\(s\) counted as element stores$'
want "  and the ammo limits are written by the backpack and the ammo use" "$W/doom/state-use.tsv" \
  "^Game${TAB}@pl_maxammo${TAB}persistent${TAB}step${TAB}int_array${TAB}stored${TAB}i64${TAB}fixed:4${TAB}[^${TAB}]*${TAB}step${TAB}Game#decrease_ammo,Game#give_backpack${TAB}"
cp -R "$ROOT/tools/doom" "$W/noopdir"
sed 's|^  next unless INDEX_WRITE_KINDS.include?(kind\[id\])$|  next|' "$AUDIT" > "$W/noopdir/audit-core.rb"
ok "the operator-write mutation is one line" "$(diff "$AUDIT" "$W/noopdir/audit-core.rb" | grep -c '^[<>]')" "2"
mkdir -p "$W/noop"
"$RUBY" "$W/noopdir/audit-core.rb" --entry "$ROOT/examples/doom/bin/doom.rb" --reader "$READER" \
  --tables "$W/noopdir" --output "$W/noop" > "$W/noop.err" 2>&1 || true
want "  without it the ammo limits read as a resource" "$W/noop/state-use.tsv" \
  "^Game${TAB}@pl_maxammo${TAB}resource${TAB}"
# WITHOUT THE RULE the field is a resource again, and nothing else notices.
cp -R "$ROOT/tools/doom" "$W/nolocaldir"
sed 's|^  next unless kind\[r\] == "LocalVariableReadNode"$|  next|' \
  "$AUDIT" > "$W/nolocaldir/audit-core.rb"
ok "the local mutation is one line" "$(diff "$AUDIT" "$W/nolocaldir/audit-core.rb" | grep -c '^[<>]')" "2"
mkdir -p "$W/nolocal"
"$RUBY" "$W/nolocaldir/audit-core.rb" --entry "$ROOT/examples/doom/bin/doom.rb" --reader "$READER" \
  --tables "$W/nolocaldir" --output "$W/nolocal" > "$W/nolocal.err" 2>&1 || true
want "  without it the line flags read as a resource" "$W/nolocal/state-use.tsv" \
  "^Level${TAB}@line_flags${TAB}resource${TAB}"
# A LOCAL THIS DOES NOT FOLLOW fails the run by name: bound a second way.
cp -R "$ROOT/examples/doom" "$W/lb-tree"
"$RUBY" -e '
  f = ARGV[0]; s = File.read(f)
  a = "      flags = lv.line_flags\n"
  s.scan(a).length == 1 or abort("no flags anchor")
  s.sub!(a, "      flags = lv.line_flags\n      flags ||= lv.line_flags\n")
  File.write(f, s)' "$W/lb-tree/lib/doom/render.rb"
ok "the second binding is one line of diff" "$(diff -r "$ROOT/examples/doom" "$W/lb-tree" | grep -c '^[<>]')" "1"
mkdir -p "$W/lb"
"$RUBY" "$AUDIT" --entry "$W/lb-tree/bin/doom.rb" --reader "$READER" --tables "$ROOT/tools/doom" \
  --output "$W/lb" > "$W/lb.err" 2>&1 || true
want "a local bound twice fails the run by name" "$W/lb.err" \
  'INCOMPLETE.*write\(s\) through a local that could not be followed: \[\]= into local flags of Renderer#store_wall_range \(lib/doom/render.rb:[0-9]+\), which is bound other than by plain writes'

echo "== the audit refuses a drifted root =="
run receiver.rb 'Game#no_such_root' drift
want "a root that is not defined stops the run" "$W/drift.err" 'roots have drifted'

echo "audit: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
