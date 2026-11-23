#!/bin/sh
#
# tests/affected/run.sh -- tools/test/affected.rb's controls.
#
#   sh tests/affected/run.sh DIR
#
# A throwaway git repository in DIR holds this tree's tables and the CORE
# source files the controls touch, with a planted audit closure (the domain of
# three originals). Each control plants one change on its base commit and
# reads what affected.rb selects:
#
#   1. a line inside dc_st_g_ticker (Game#g_ticker, step): the board check,
#      capacity and the step entry's comparisons excluded; not the render's;
#   2. a line inside dc_rv_render_player_view (render): the render entry's
#      comparisons excluded, no capacity;
#   3. a line inside dc_hud_i16, which no core-migrated.tsv row names: every
#      entry, and the reason says so;
#   4. a line outside every definition: every entry;
#   5. a known non-source file (tools/doom/nor-image.rb): the board check,
#      and verify-sources.sh because the manifest pins it; nothing excluded;
#   6. an excluded suite (tests/doom-core/verify.sh): named under excluded,
#      never under run;
#   7. a selected suite with an oracle section (tests/doom-core/audit.sh): its
#      cruby-fixtures section listed as excluded from tests/ORACLES.tsv;
#   8. a file no row matches, beside a known one: listed as unmapped, exit 1;
#      both select tests/imports/run.sh and tests/oracle/check.sh, as every
#      changed file does;
#   9. a table row naming a test tests.tsv does not list: exit 2;
#  10. files deep under a `/**` row (docs/core/a/b.md, a fixture three
#      levels down): matched, not unmapped;
#  11. a file tests/doom/manifest.tsv pins (examples/doom/bin/doom.rb):
#      verify-sources.sh is selected, besides its row's tests; a new file in
#      tools/doom selects it too, and a new .sh there does not;
#  12. --scope: every tracked file of the 32-bit work's trees in THIS tree
#      matches a row (exit 0), and a tracked file no row knows is listed
#      (exit 1).
#  13. a test with a row in known.tsv: its known failure is printed under it.
#  14. a change under tools/ebpf only, whose rows name no oracle-check (its
#      README, and a tool): tests/oracle/check.sh is selected for each, and
#      why.
#  15. tools/ebpf, its Go path and the Go examples reach their suites: a file
#      in tools/ebpf/src and one in tools/ebpf/tests select tests/ebpf, one in
#      tools/ebpf/go and one in examples/ebpf-go select tests/ebpf-go (and the
#      go/ file not tests/ebpf). Of the hand-run harnesses' row, only the two
#      that tests/ebpf/run.sh runs select it: run_otlp_endpoint.sh does,
#      run_otlp_grpc.sh does not. The README selects its own row's docs check
#      and not tests/ebpf, which does not read it. Sensitivity: with the five
#      rows taken out of the table, as before them, the src, tests, go/ and
#      example files are unmapped and neither suite is selected.
#  16. a file tools/dist/manifest.json rewrites (pinned by sha256) selects the
#      real export, tests/dist/export.sh, and says why; so does the manifest
#      itself; a file it does not pin does not. Sensitivity: with the rule
#      turned off in affected.rb, the pinned file selects no export. The
#      export leaves tools/dist out, and with it the manifest and this rule's
#      test: in an exported tree, control 16 is skipped by name.
#  17. the vendor/spinel gitlink alone (a planted pin move): every run, board
#      and long suite of tests.tsv but the export tool's two, nothing
#      unmapped. The expectation is counted from the planted tests.tsv, so a
#      suite added there without the row fails too. Sensitivity: with the
#      vendor/spinel row taken out, the gitlink is unmapped and no suite of
#      that row is selected. The row itself names exactly those suites, by
#      name, so a suite added to tests.tsv and not to the row fails here,
#      naming it; a planted suite in tests.tsv is the failing input. The
#      export drops the two dist suites from both tables, so it holds there.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: run.sh DIR}
RUBY=${RUBY:-ruby}
pass=0; fail=0; skipped=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
mkdir -p "$DIR" || exit 2
R=$DIR/repo
[ -e "$R" ] && { echo "affected: $R exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$R"
for f in tools/test/affected.rb tools/test/affected.tsv tools/test/tests.tsv tools/test/known.tsv tests/ORACLES.tsv tools/doom/core-migrated.tsv \
         examples/doom/core/entries/units.tsv examples/doom/core/src/stepknot.rb examples/doom/core/src/rview.rb \
         examples/doom/core/src/hud.rb tools/doom/nor-image.rb tests/doom-core/verify.sh tests/doom-core/audit.sh \
         tests/doom/manifest.tsv examples/doom/bin/doom.rb; do
  mkdir -p "$R/$(dirname "$f")" && cp "$ROOT/$f" "$R/$f" || exit 2
done
# the export's manifest, when this tree has one (an exported tree does not)
if [ -f "$ROOT/tools/dist/manifest.json" ]; then
  mkdir -p "$R/tools/dist" && cp "$ROOT/tools/dist/manifest.json" "$R/tools/dist/manifest.json" || exit 2
fi
printf 'from\tedge\tcallee\tfile\tline\torigin\treceiver\tdomain\tresolution\n' > "$DIR/closure.tsv"
printf 'Game#g_ticker\tcall\tx\tgame.rb\t1\tast\tint\tstep\tdef\n' >> "$DIR/closure.tsv"
printf 'Renderer#render_player_view\tcall\tx\trender.rb\t1\tast\tint\trender\tdef\n' >> "$DIR/closure.tsv"
g() { git -C "$R" -c user.name=affected -c user.email=affected@invalid "$@"; }
g init -q && g add -A && g commit -qm base || exit 2
reset() { g checkout -q -- . && g clean -qfd; }
# plant FILE DEF: a comment line after DEF's `def` line (or at the top with -)
plant() {
  "$RUBY" -e 'f, d = ARGV; l = File.readlines(f)
    i = d == "-" ? 0 : (l.index { |x| x.start_with?("def #{d}(") } or abort "no def #{d}") + 1
    l.insert(i, "  # planted\n"); File.write(f, l.join)' "$R/$1" "$2"
}
run() { "$RUBY" "$R/tools/test/affected.rb" --base HEAD --root "$R" --closure "$DIR/closure.tsv" > "$DIR/out.txt" 2> "$DIR/err.txt"; echo $?; }
section() { awk -v s="$1:" '$0 == s { on = 1; next } /^[a-z]+:$/ { on = 0 } on' "$DIR/out.txt"; }

echo "affected: 1. a step definition"
plant examples/doom/core/src/stepknot.rb dc_st_g_ticker
ok "exit 0" "$(run)" 0
ok "the board check over 500 tics is selected" "$(section board | grep -c 'TICS=500 sh tests/doom-core/rt1186.sh')" 1
ok "the reason names the def and its entry" "$(section board | grep -c 'def dc_st_g_ticker replaces Game#g_ticker, reached from step')" 1
ok "host-frames.sh is selected for the step entry" "$(section run | grep -c 'sh tests/doom-core/host-frames.sh')" 1
ok "capacity is selected for the step entry, as a long test" "$(section long | grep -c 'capacity.sh')" 1
ok "the step entry's comparison is excluded, by name" "$(section excluded | grep -c 'step-diff.rb')" 1
ok "the render entry's is not" "$(section excluded | grep -c 'render-diff.rb')" 0
reset

echo "affected: 2. a render definition"
plant examples/doom/core/src/rview.rb dc_rv_render_player_view
ok "exit 0" "$(run)" 0
ok "the render entry's comparisons are excluded" "$(section excluded | grep -cE 'render-diff.rb|route.s screens')" 2
ok "capacity is not selected" "$(section run | grep -c 'capacity.sh')" 0
reset

echo "affected: 3. a definition no migration row names"
plant examples/doom/core/src/hud.rb dc_hud_i16
ok "exit 0" "$(run)" 0
ok "every entry, and why" "$(section board | grep -c 'def dc_hud_i16: no row in core-migrated.tsv, so every entry')" 1
ok "all three entries' comparisons are excluded" "$(section excluded | grep -cE 'input-diff|step-diff|render-diff')" 3
reset

echo "affected: 4. a line outside every definition"
plant examples/doom/core/src/hud.rb -
ok "exit 0" "$(run)" 0
ok "every entry, and why" "$(section board | grep -c 'lines outside every definition, so every entry'):$(section excluded | grep -cE 'input-diff|step-diff|render-diff')" "1:3"
reset

echo "affected: 5. a known non-source file"
printf '# planted\n' >> "$R/tools/doom/nor-image.rb"
ok "exit 0" "$(run)" 0
ok "the board check, and to run besides only verify-sources.sh (the manifest pins the file), the import register's check and the oracle list's" \
   "$(section board | grep -c 'rt1186.sh'):$(section run | grep '^  [a-zA-Z]' | tr -d ' ' | tr '\n' ' ')" "1:shtools/doom/verify-sources.sh shtests/imports/run.shDIR shtests/oracle/check.sh "
ok "nothing excluded" "$(section excluded | tr -d ' ')" "(none)"
reset

echo "affected: 6. an excluded suite"
printf '# planted\n' >> "$R/tests/doom-core/verify.sh"
ok "exit 0" "$(run)" 0
ok "named under excluded" "$(section excluded | grep -c '^  doom-verify: CRuby')" 1
ok "never under run" "$(section run | grep -c '^  [a-zA-Z].*tests/doom-core/verify.sh')" 0
reset

echo "affected: 7. a selected suite's oracle section"
printf '# planted\n' >> "$R/tests/doom-core/audit.sh"
ok "exit 0" "$(run)" 0
ok "audit.sh is selected, as a long test" "$(section long | grep -c 'sh tests/doom-core/audit.sh')" 1
ok "its cruby-fixtures section is listed as excluded" "$(section excluded | grep -c 'tests/doom-core/audit.sh cruby-fixtures (ORACLES.tsv, owner)')" 1
reset

echo "affected: 8. a file no row matches"
printf '# planted\n' >> "$R/tools/doom/nor-image.rb"
printf 'x\n' > "$R/notes.txt"
ok "exit 1" "$(run)" 1
ok "the file is listed as unmapped" "$(section unmapped | grep -c 'notes.txt')" 1
ok "and the known one is still answered" "$(section board | grep -c 'rt1186.sh')" 1
ok "every changed file, the unmapped one too, selects the import register's check" \
   "$(section run | grep -A3 'sh tests/imports/run.sh DIR' | grep -cE '<- (notes.txt|tools/doom/nor-image.rb): every tracked file is under one row of docs/imports.tsv')" 2
reset

echo "affected: 9. a table naming an unknown test"
printf 'tools/doom/nor-image.rb\tno-such-test\tplanted\n' >> "$R/tools/test/affected.tsv"
ok "exit 2" "$(run)" 2
ok "and says which" "$(grep -c 'names no-such-test, which tests.tsv does not list' "$DIR/err.txt")" 1
reset

echo "affected: 10. deep paths under a /** row"
mkdir -p "$R/docs/core/a" "$R/tests/app/fixtures/build/deep/x"
printf 'x\n' > "$R/docs/core/a/b.md"; printf 'x\n' > "$R/tests/app/fixtures/build/deep/x/app.rb"
ok "exit 0, nothing unmapped" "$(run):$(section unmapped | tr -d ' ')" "0:(none)"
ok "the deep doc selects the docs check" "$(section run | grep -c 'git diff --check BASE -- docs')" 1
ok "the deep fixture selects build.sh" "$(section run | grep -c 'sh tests/app/build.sh')" 1
reset

echo "affected: 11. a file the manifest pins"
printf '# planted\n' >> "$R/examples/doom/bin/doom.rb"
ok "exit 0" "$(run)" 0
ok "verify-sources.sh is selected, and why" "$(section run | grep -A3 'verify-sources.sh' | grep -c 'pinned in tests/doom/manifest.tsv')" 1
ok "and its row's audit too" "$(section long | grep -c 'sh tests/doom-core/audit.sh')" 1
reset
# a file new in a directory the manifest pins files in: verify-sources.sh
# requires the manifest to name it, so it is selected though nothing pins it
printf '# planted\n' > "$R/tools/doom/planted-tool.rb"
ok "exit 0, with a new file in tools/doom" "$(run)" 0
ok "verify-sources.sh is selected for it, and why" \
   "$(section run | grep -A3 'verify-sources.sh' | grep -c 'tools/doom/planted-tool.rb: in tools/doom, where tests/doom/manifest.tsv pins files')" 1
reset
printf '# planted\n' > "$R/tools/doom/planted-tool.sh"
run > /dev/null
ok "control: a new .sh there, which verify-sources.sh leaves out, does not select it" "$(section run | grep -c 'verify-sources.sh')" 0
reset

echo "affected: 12. --scope"
"$RUBY" "$ROOT/tools/test/affected.rb" --scope tools/mlir/native tools/app examples/doom/core tests/doom-core tests/app > "$DIR/scope.txt" 2>&1
ok "this tree's 32-bit trees: every tracked file has a row" "$?|$(grep -c ' 0 no row matches' "$DIR/scope.txt")" "0|1"
mkdir -p "$R/tools/unknown"; printf 'x\n' > "$R/tools/unknown/x.rb"; g add tools/unknown/x.rb
"$RUBY" "$R/tools/test/affected.rb" --root "$R" --scope tools > "$DIR/scope2.txt" 2>&1
ok "a tracked file no row knows is listed, exit 1" "$?|$(grep -c '^  tools/unknown/x.rb$' "$DIR/scope2.txt")" "1|1"
g rm -q --cached tools/unknown/x.rb
reset

echo "affected: 13. a known failure is printed under its test"
printf 'core-stack\tplanted: one check\tabc1234\ta planted row\n' >> "$R/tools/test/known.tsv"
mkdir -p "$R/tests/core-stack"; printf 'x\n' > "$R/tests/core-stack/x.sh"
ok "exit 0" "$(run)" 0
ok "the row is printed under core-stack's command" \
   "$(section run | grep -A3 'sh tests/core-stack/run.sh' | grep -c 'known failure (since abc1234): planted: one check -- a planted row')" 1
reset

echo "affected: 14. a change under tools/ebpf only selects the oracle list's check"
mkdir -p "$R/tools/ebpf"
printf '# planted\n' > "$R/tools/ebpf/README.md"
ok "exit 0: the README has a row (docs-check)" "$(run)" 0
ok "its row names no oracle-check, and oracle-check is selected, and why" \
   "$(grep '^tools/ebpf/{README.md' "$R/tools/test/affected.tsv" | cut -f2 | grep -c oracle-check):$(section run | grep -A3 'sh tests/oracle/check.sh' | grep -c '<- tools/ebpf/README.md: tests/oracle/check.sh reads every file for the oracle patterns')" "0:1"
reset
mkdir -p "$R/tools/ebpf/tools"
printf '# planted\n' > "$R/tools/ebpf/tools/planted.rb"
ok "exit 0: a tools/ebpf tool (the tools/ebpf/** row)" "$(run)" 0
ok "oracle-check is selected for it as well" \
   "$(section run | grep -A3 'sh tests/oracle/check.sh' | grep -c '<- tools/ebpf/tools/planted.rb: tests/oracle/check.sh reads every file for the oracle patterns')" 1
reset

echo "affected: 15. tools/ebpf and the Go path reach their suites"
plant_ebpf() {
  for p in tools/ebpf/src/spinel_ebpf/planted.rb tools/ebpf/tests/spinel_ebpf/planted_test.rb \
           tools/ebpf/go/internal/planted/planted.go examples/ebpf-go/xdp-counter/planted.go tools/ebpf/README.md \
           tools/ebpf/tests/runtime/run_otlp_endpoint.sh tools/ebpf/tests/runtime/run_otlp_grpc.sh; do
    mkdir -p "$R/$(dirname "$p")" && printf '# planted\n' > "$R/$p"
  done
}
reasons() { section run | grep -A12 "^  $1\$" | awk 'NR > 1 && /^  [a-zA-Z]/ { exit } NR > 1'; }
plant_ebpf
ok "exit 0, nothing unmapped" "$(run):$(section unmapped | tr -d ' ')" "0:(none)"
ok "tests/ebpf is selected for the src and tests files and the harness it runs" \
   "$(reasons 'sh tests/ebpf/run.sh' | grep -cE '<- tools/ebpf/(src/spinel_ebpf/planted.rb|tests/spinel_ebpf/planted_test.rb|tests/runtime/run_otlp_endpoint.sh) ')" 3
ok "tests/ebpf is not selected for the README or a harness it does not run" \
   "$(reasons 'sh tests/ebpf/run.sh' | grep -cE '<- tools/ebpf/(README.md|tests/runtime/run_otlp_grpc.sh) ')" 0
ok "tests/ebpf-go is selected for the go/ file and the example" \
   "$(reasons 'sh tests/ebpf-go/run.sh' | grep -cE '<- (tools/ebpf/go/internal/planted/planted.go|examples/ebpf-go/xdp-counter/planted.go) ')" 2
ok "the go/ file does not select tests/ebpf" "$(reasons 'sh tests/ebpf/run.sh' | grep -c 'tools/ebpf/go/')" 0
ok "the README selects its row's docs check" "$(reasons 'git diff --check BASE -- docs' | grep -c '<- tools/ebpf/README.md ')" 1
reset
# the table as it was before these rows
"$RUBY" -e 'f = ARGV[0]; l = File.readlines(f)
  gone = ["tools/ebpf/tests/runtime/run_otlp_{endpoint,enrich}.sh", "tools/ebpf/go/**", "tools/ebpf/**",
          "examples/ebpf-go/**", "tests/ebpf-go/**"]
  n = l.size; l.reject! { |x| gone.include?(x.split("\t").first) }; abort "rows" unless n - l.size == 5
  File.write(f, l.join)' "$R/tools/test/affected.tsv"
g commit -qam "the table before the tools/ebpf rows"
plant_ebpf
ok "sensitivity: exit 1, the four files without a row unmapped" "$(run):$(section unmapped | grep -c 'planted')" "1:4"
ok "sensitivity: neither suite is selected" "$(section run | grep -cE 'sh tests/ebpf(-go)?/run.sh')" 0
reset
g reset -q --hard HEAD^

echo "affected: 16. a file the export manifest pins selects the real export"
if [ ! -f "$R/tools/dist/manifest.json" ]; then
  echo "  SKIP control 16, its 5 checks (export tree: tools/dist is excluded, so tools/dist/manifest.json is absent)"; skipped=1
else
EXP='sh tests/dist/export.sh DIR'
printf '# planted\n' >> "$R/tools/test/tests.tsv"
ok "exit 0" "$(run)" 0
ok "a pinned file (tools/test/tests.tsv) selects the real export, and says why" \
   "$(reasons "$EXP" | grep -c '<- tools/test/tests.tsv: tools/dist/manifest.json pins it ')" 1
reset
printf ' \n' >> "$R/tools/dist/manifest.json"
ok "the manifest itself selects it" "$(run):$(reasons "$EXP" | grep -c "<- tools/dist/manifest.json: the export's manifest")" "0:1"
reset
printf '# planted\n' >> "$R/tools/test/known.tsv"
ok "a file the manifest does not pin (tools/test/known.tsv) does not" "$(run):$(section run | grep -c "^  $EXP\$")" "0:0"
reset
# affected.rb with the rule turned off
"$RUBY" -e 'f = ARGV[0]; s = File.read(f); o = %q{tests.key?("dist-export") && File.file?}
  abort "rule" unless s.scan(o).size == 1; File.write(f, s.sub(o) { "false && #{o}" })' "$R/tools/test/affected.rb"
g commit -qam "affected.rb without the export rule"
printf '# planted\n' >> "$R/tools/test/tests.tsv"
ok "sensitivity: without the rule the pinned file selects no export" "$(run):$(section run | grep -c "^  $EXP\$")" "0:0"
reset
g reset -q --hard HEAD^
fi
echo "affected: 17. the vendor/spinel gitlink alone selects every suite"
# vrow: the vendor/spinel row against tests.tsv, by name
vrow() { "$RUBY" -e 'aff, tests = ARGV
  row = File.readlines(aff).find { |l| l.split("\t").first == "vendor/spinel" } or (puts "no vendor/spinel row"; exit)
  named = row.split("\t")[1].split(",")
  want = File.readlines(tests).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t") }
           .select { |c| %w[run board long].include?(c[1]) }.map(&:first) - %w[dist-controls dist-export]
  m = want - named; x = named - want
  print "missing: #{m.empty? ? "(none)" : m.join(",")}; extra: #{x.empty? ? "(none)" : x.join(",")}"' \
  "$R/tools/test/affected.tsv" "$R/tools/test/tests.tsv"; }
ok "the vendor/spinel row names every run, board and long suite but the export tool's two" "$(vrow)" "missing: (none); extra: (none)"
printf 'planted-suite\trun\tsh tests/planted.sh\ta planted suite no row names\n' >> "$R/tools/test/tests.tsv"
g add tools/test/tests.tsv && g commit -qm "a planted suite"
ok "sensitivity: a suite added to tests.tsv alone is named as missing" "$(vrow)" "missing: planted-suite; extra: (none)"
g reset -q --hard HEAD^
# a planted pin: a gitlink at one made-up commit in the base, moved to another
g update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,vendor/spinel
g commit -qm "a planted pin"
g update-index --cacheinfo 160000,2222222222222222222222222222222222222222,vendor/spinel
want=$("$RUBY" -e 'n = Hash.new(0)
  File.foreach(ARGV[0]) { |l| next if l.start_with?("#") || l.strip.empty?
    id, kind = l.split("\t"); n[kind] += 1 unless %w[dist-controls dist-export].include?(id) }
  print "#{n["run"]}:#{n["board"]}:#{n["long"]}"' "$R/tools/test/tests.tsv")
cmds() { section "$1" | grep -c '^  [a-zA-Z]'; }
ok "exit 0, nothing unmapped" "$(run):$(section unmapped | tr -d ' ')" "0:(none)"
ok "every run, board and long suite but the export tool's two (counted from tests.tsv: $want)" \
   "$(cmds run):$(cmds board):$(cmds long)" "$want"
ok "the reason names the pin" "$(section run | grep -c '<- vendor/spinel (vendor/spinel: the pinned compiler')" "$(echo "$want" | cut -d: -f1)"
g update-index --cacheinfo 160000,1111111111111111111111111111111111111111,vendor/spinel
# the table without the vendor/spinel row
"$RUBY" -e 'f = ARGV[0]; l = File.readlines(f)
  n = l.size; l.reject! { |x| x.split("\t").first == "vendor/spinel" }; abort "row" unless n - l.size == 1
  File.write(f, l.join)' "$R/tools/test/affected.tsv"
# by path: -a would stage the gitlink, which has no directory here, as deleted
g add tools/test/affected.tsv && g commit -qm "the table without the vendor/spinel row"
g update-index --cacheinfo 160000,2222222222222222222222222222222222222222,vendor/spinel
ok "sensitivity: exit 1, the gitlink unmapped" "$(run):$(section unmapped | grep -c '^  vendor/spinel$')" "1:1"
ok "sensitivity: no long or board suite is selected" "$(cmds long):$(cmds board)" "0:0"
g reset -q --hard HEAD~2

echo "affected: $((pass + fail)) checked, $pass pass, $fail fail$( [ "$skipped" = 0 ] || echo ", control 16 skipped (export tree)")"
[ "$fail" = 0 ]
