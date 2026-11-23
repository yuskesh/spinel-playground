#!/bin/sh
#
# tests/imports/run.sh -- docs/imports.tsv against this checkout, and the
# controls of tools/provenance/check-imports.rb.
#
#   sh tests/imports/run.sh DIR
#
# 0. this checkout: every tracked file under exactly one row (exit 0).
#
# The controls run the checker over a small planted tree in DIR: a register
# with one declared batch, a provenance record with its heading, three files
# and a file list. The planted tree passes as it is (the positive control);
# each control then changes one thing and requires exit 1 and the failure of
# its own kind, by name:
#
#   1. a file no row covers                  unregistered
#   2. a second row over a covered file      overlap
#   3. a row no file is under                empty row
#   4. a licence word outside the vocabulary unknown license
#   5. a file whose SPDX line its row does
#      not name                              SPDX mismatch
#   6. a batch no @batch line declares       unknown batch
#   7. an @batch heading the record lacks    no section
#
#   9. a third-party file with no licence
#      file beside or above it                licence text
#  10. an SPDX line of the project's own
#      with no LICENSES/<id> above it         licence text
#  11. a file with an IWAD header             game data
#  12. a file named *.WAD                     game data
#  13. a NUL byte in a GPL row's file         GPL binary
#  15. a NUL byte in a project-ported file whose
#      SPDX line says GPL-2.0                 GPL binary
#  16. a NUL byte in a project file
#      below a GPL COPYING                    GPL binary
#  17. a NUL byte after 64 KiB of text in a
#      GPL row's file                         GPL binary
#
# and 8: an SPDX line in a project-ported row is counted, not failed.
#
# 0b. THIRD_PARTY.md is what tools/provenance/third-party.rb gives for this
# checkout; its control (14) plants a git tree with one MIT file, generates
# the list, edits it, and requires --check to exit 1.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: run.sh DIR}
RUBY=${RUBY:-ruby}
CHECK=$ROOT/tools/provenance/check-imports.rb
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
mkdir -p "$DIR" || exit 2
T=$DIR/tree
[ -e "$T" ] && { echo "imports: $T exists; give a fresh DIR" >&2; exit 2; }

echo "imports: 0. this checkout"
"$RUBY" "$CHECK" > "$DIR/self.txt" 2>&1
ok "every tracked file is under exactly one row" "$?|$(grep -c '^FAIL' "$DIR/self.txt")" "0|0"
sed -n '/^  /p' "$DIR/self.txt"
"$RUBY" "$ROOT/tools/provenance/third-party.rb" --check > "$DIR/third.txt" 2>&1
ok "0b. THIRD_PARTY.md is current" "$?|$(cat "$DIR/third.txt")" "0|third-party: THIRD_PARTY.md is current"

# The planted tree.
mkdir -p "$T/docs" "$T/src" "$T/lib"
printf '# Provenance\n\n## The planted import (2026-01-01)\n' > "$T/docs/provenance.md"
printf 'puts 1\n' > "$T/src/a.rb"
printf '// SPDX-%s: MIT\nint b;\n' License-Identifier > "$T/lib/b.c"
printf '// SPDX-%s: GPL-2.0\nint c;\n' License-Identifier > "$T/lib/c.c"
mkdir -p "$T/LICENSES" "$T/gpl"
printf 'MIT text\n' > "$T/lib/LICENSE"
printf 'GPL text\n' > "$T/LICENSES/GPL-2.0"
printf 'GNU GENERAL PUBLIC LICENSE\n' > "$T/gpl/COPYING"
printf 'int d;\n' > "$T/gpl/d.c"
printf 'docs/provenance.md\nsrc/a.rb\nlib/b.c\nlib/c.c\nlib/LICENSE\nLICENSES/GPL-2.0\ngpl/COPYING\ngpl/d.c\n' > "$DIR/files.txt"
base() {
  printf '@batch\tplanted\tThe planted import (2026-01-01)\n'
  printf 'docs/**/*\toriginal\tproject\n'
  printf 'src/*.rb\toriginal\tproject\n'
  printf 'lib/b.c\tplanted\tMIT\n'
  printf 'lib/c.c\tplanted\tproject-ported\n'
  printf 'lib/LICENSE\tplanted\tMIT\n'
  printf 'LICENSES/*\toriginal\tproject\n'
  printf 'gpl/*\tplanted\tGPL-2.0\n'
}
# check REGISTER: runs the checker over the planted tree; prints its exit status
check() { "$RUBY" "$CHECK" --root "$T" --register "$1" --files "$DIR/files.txt" > "$DIR/out.txt" 2>&1; echo $?; }
has() { grep -c "^FAIL $1: $2" "$DIR/out.txt"; }

echo "imports: the planted tree as it is"
base > "$DIR/reg.tsv"
ok "passes, with no failure" "$(check "$DIR/reg.tsv")|$(grep -c '^FAIL' "$DIR/out.txt")" "0|0"
ok "8. the GPL-2.0 SPDX line in a project-ported row is counted, not failed" \
   "$(grep -c '^  SPDX GPL-2.0 in a project-ported row: 1 files$' "$DIR/out.txt")" 1

echo "imports: 1. an unregistered file"
{ cat "$DIR/files.txt"; echo src/new/x.rb; } > "$DIR/files1.txt"
"$RUBY" "$CHECK" --root "$T" --register "$DIR/reg.tsv" --files "$DIR/files1.txt" > "$DIR/out.txt" 2>&1
ok "fails, naming the file" "$?|$(has unregistered 'src/new/x.rb$')" "1|1"

echo "imports: 2. an overlap"
{ base; printf 'src/**/*\toriginal\tproject\n'; } > "$DIR/reg2.tsv"
ok "fails, naming the file and both rows" "$(check "$DIR/reg2.tsv")|$(has overlap 'src/a.rb: reg2.tsv:3, reg2.tsv:9$')" "1|1"

echo "imports: 3. an empty row"
{ base; printf 'tools/**/*\toriginal\tproject\n'; } > "$DIR/reg3.tsv"
ok "fails, naming the row" "$(check "$DIR/reg3.tsv")|$(has 'empty row' 'reg3.tsv:9: tools/\*\*/\*$')" "1|1"

echo "imports: 4. an unknown licence word"
base | sed 's/^src\/\*\.rb\toriginal\tproject$/src\/*.rb\toriginal\tWTFPL/' > "$DIR/reg4.tsv"
ok "fails, naming the word" "$(check "$DIR/reg4.tsv")|$(has 'unknown license' 'reg4.tsv:3: WTFPL$')" "1|1"

echo "imports: 5. an SPDX mismatch"
base | sed 's/^lib\/b\.c\tplanted\tMIT$/lib\/b.c\tplanted\tApache-2.0/' > "$DIR/reg5.tsv"
ok "fails, naming the file, its line and the row" \
   "$(check "$DIR/reg5.tsv")|$(has 'SPDX mismatch' 'lib/b.c: the file says MIT, reg5.tsv:4 says Apache-2.0$')" "1|1"

echo "imports: 6. an undeclared batch"
base | sed 's/^lib\/b\.c\tplanted\t/lib\/b.c\tplanted+other\t/' > "$DIR/reg6.tsv"
ok "fails, naming the batch" "$(check "$DIR/reg6.tsv")|$(has 'unknown batch' 'reg6.tsv:4: other$')" "1|1"

echo "imports: 7. a batch heading the record lacks"
base | sed 's/The planted import (2026-01-01)/A planted import that is not recorded/' > "$DIR/reg7.tsv"
ok "fails, naming the batch" "$(check "$DIR/reg7.tsv")|$(has 'no section' 'reg7.tsv:1: batch planted: ')" "1|1"

echo "imports: 9. a third-party file with no licence file"
grep -v '^lib/LICENSE$' "$DIR/files.txt" > "$DIR/files9.txt"
grep -v '^lib/LICENSE	' "$DIR/reg.tsv" > "$DIR/reg9.tsv"
"$RUBY" "$CHECK" --root "$T" --register "$DIR/reg9.tsv" --files "$DIR/files9.txt" > "$DIR/out.txt" 2>&1
ok "fails, naming the file and its row" \
   "$?|$(has 'licence text' 'lib/b.c: reg9.tsv:4 says MIT, and no licence file is beside it or above it$')" "1|1"

echo "imports: 10. an SPDX line of the project's own with no LICENSES text"
grep -v '^LICENSES/GPL-2.0$' "$DIR/files.txt" > "$DIR/files10.txt"
"$RUBY" "$CHECK" --root "$T" --register "$DIR/reg.tsv" --files "$DIR/files10.txt" > "$DIR/out.txt" 2>&1
ok "fails, naming the file and its SPDX id" \
   "$?|$(has 'licence text' 'lib/c.c: its SPDX line says GPL-2.0, and no LICENSES/GPL-2.0 is above it$')" "1|1"

echo "imports: 11. an IWAD header"
printf 'IWAD\001\000\000\000' > "$T/src/level.rb"
{ cat "$DIR/files.txt"; echo src/level.rb; } > "$DIR/files11.txt"
"$RUBY" "$CHECK" --root "$T" --register "$DIR/reg.tsv" --files "$DIR/files11.txt" > "$DIR/out.txt" 2>&1
ok "fails, naming the file" "$?|$(has 'game data' 'src/level.rb: ')" "1|1"

echo "imports: 12. a .WAD name"
printf 'x\n' > "$T/docs/demo.WAD"
{ cat "$DIR/files.txt"; echo docs/demo.WAD; } > "$DIR/files12.txt"
"$RUBY" "$CHECK" --root "$T" --register "$DIR/reg.tsv" --files "$DIR/files12.txt" > "$DIR/out.txt" 2>&1
ok "fails, naming the file" "$?|$(has 'game data' 'docs/demo.WAD: ')" "1|1"

echo "imports: 13. a binary file in a GPL row"
printf 'int\000d;\n' > "$T/gpl/d.c"
ok "fails, naming the file and its row" "$(check "$DIR/reg.tsv")|$(has 'GPL binary' 'gpl/d.c: reg.tsv:8 says GPL-2.0')" "1|1"

printf 'int d;\n' > "$T/gpl/d.c"

echo "imports: 15. a binary file whose SPDX line says GPL, in a project-ported row"
printf '// SPDX-%s: GPL-2.0\nint\000c;\n' License-Identifier > "$T/lib/c.c"
ok "fails, naming the file and its SPDX line" "$(check "$DIR/reg.tsv")|$(has 'GPL binary' 'lib/c.c: its SPDX line says GPL-2.0, ')" "1|1"
printf '// SPDX-%s: GPL-2.0\nint c;\n' License-Identifier > "$T/lib/c.c"

echo "imports: 16. a binary file of the project's own below a GPL COPYING"
printf '\177ELF\000\000' > "$T/gpl/probe.o"
{ base; printf 'gpl/probe.o\toriginal\tproject\n'; } | sed 's|^gpl/\*\t|gpl/[!p]*\t|' > "$DIR/reg16.tsv"
{ cat "$DIR/files.txt"; echo gpl/probe.o; } > "$DIR/files16.txt"
"$RUBY" "$CHECK" --root "$T" --register "$DIR/reg16.tsv" --files "$DIR/files16.txt" > "$DIR/out.txt" 2>&1
ok "fails, naming the GPL directory" "$?|$(has 'GPL binary' 'gpl/probe.o: it is under gpl/, whose licence is the GPL')" "1|1"

echo "imports: 17. a NUL byte after 64 KiB of text in a GPL row's file"
"$RUBY" -e 'print "x" * 65_536, "\0"' > "$T/gpl/d.c"
ok "fails, naming the file" "$(check "$DIR/reg.tsv")|$(has 'GPL binary' 'gpl/d.c: reg.tsv:8 says GPL-2.0')" "1|1"
printf 'int d;\n' > "$T/gpl/d.c"

echo "imports: 14. a stale THIRD_PARTY.md"
G=$DIR/git-tree
mkdir -p "$G/docs" "$G/lib"
printf 'lib/b.c\tplanted\tMIT\nlib/LICENSE\tplanted\tMIT\n' > "$G/docs/imports.tsv"
printf 'int b;\n' > "$G/lib/b.c"
printf 'MIT text\n' > "$G/lib/LICENSE"
git -C "$G" init -q && git -C "$G" add docs lib
"$RUBY" "$ROOT/tools/provenance/third-party.rb" --root "$G" > /dev/null 2>&1
"$RUBY" "$ROOT/tools/provenance/third-party.rb" --root "$G" --check > /dev/null 2>&1
ok "control: freshly generated, --check passes and lists lib/b.c" "$?|$(grep -c '^| `lib/b.c` | MIT | `lib/LICENSE` |' "$G/THIRD_PARTY.md")" "0|1"
printf 'edited\n' >> "$G/THIRD_PARTY.md"
"$RUBY" "$ROOT/tools/provenance/third-party.rb" --root "$G" --check > "$DIR/out.txt" 2>&1
ok "an edited list fails --check" "$?|$(grep -c 'differs from what docs/imports.tsv gives' "$DIR/out.txt")" "1|1"

echo "imports: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
