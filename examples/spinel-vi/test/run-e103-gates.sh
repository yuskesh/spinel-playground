#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd -- "$HERE/.." && pwd)
ROOT=$(cd -- "$APP/../.." && pwd)
BUILD="$APP/build/e103-gates"
mkdir -p "$BUILD"
"$ROOT/vendor/spinel/bin/spinel" "$HERE/save_shim.rb" -o "$BUILD/save-shim"
"$ROOT/vendor/spinel/bin/spinel" "$HERE/load_shim.rb" -o "$BUILD/load-shim"

printf 'ok\n' > "$BUILD/valid.txt"
test "$("$BUILD/load-shim" "$BUILD/valid.txt")" = 'text="ok\n"'
printf 'PASS\tv3_utf8_lf_regular_file\tvalid UTF-8/LF regular file loads\n'
printf 'bad\r\n' > "$BUILD/crlf.txt"
test "$("$BUILD/load-shim" "$BUILD/crlf.txt")" = 'error=CRLF is not supported; use LF'
printf 'PASS\tv3_crlf_rejected\tloud rejection before editor buffer construction\n'
printf 'a\0b' > "$BUILD/nul.txt"
test "$("$BUILD/load-shim" "$BUILD/nul.txt")" = 'error=NUL is not supported'
printf '\377' > "$BUILD/invalid.txt"
test "$("$BUILD/load-shim" "$BUILD/invalid.txt")" = 'error=invalid UTF-8'
printf 'PASS\tv3_nul_invalid_utf8_rejected\treasoned loud rejection before editor buffer construction\n'
ln -sf "$BUILD/valid.txt" "$BUILD/link.txt"
test "$("$BUILD/load-shim" "$BUILD/link.txt")" = 'error=symlink is not supported'
printf 'PASS\tv3_symlink_rejected\tloud lstat rejection\n'

# V3 is byte-preserving for accepted Unicode scalar values.  Exercise both
# load and save using files so NUL and truncated sequences never pass through
# argv.  Every rejected save must leave its target and its same-directory temp
# namespace untouched.
utf8_valid() {
  local name=$1 bytes=$2 expected=$3 payload="$BUILD/utf8-$1.bin" target="$BUILD/utf8-$1.txt" out
  printf '%b' "$bytes" > "$payload"
  out=$("$BUILD/load-shim" "$payload" --bytes)
  test "$out" = "bytes=$expected"
  printf 'before' > "$target"
  out=$("$BUILD/save-shim" "$target" "$payload" --payload-file)
  test "$out" = 'rc=0 error='
  cmp -s "$payload" "$target"
  test "$(find "$BUILD" -name ".utf8-$name.txt.spinel-vi.*" | wc -l | tr -d ' ')" = 0
}

utf8_invalid() {
  local name=$1 bytes=$2 error=$3 payload="$BUILD/utf8-$1.bin" target="$BUILD/utf8-$1.txt" out
  printf '%b' "$bytes" > "$payload"
  out=$("$BUILD/load-shim" "$payload" --bytes)
  test "$out" = "error=$error"
  printf 'before' > "$target"
  out=$("$BUILD/save-shim" "$target" "$payload" --payload-file)
  test "$out" = "rc=-1 error=$error"
  test "$(cat "$target")" = before
  test "$(find "$BUILD" -name ".utf8-$name.txt.spinel-vi.*" | wc -l | tr -d ' ')" = 0
}

utf8_valid u007f '\177' '127'
utf8_valid u0080 '\302\200' '194,128'
utf8_valid u07ff '\337\277' '223,191'
utf8_valid u0800 '\340\240\200' '224,160,128'
utf8_valid ud7ff '\355\237\277' '237,159,191'
utf8_valid ue000 '\356\200\200' '238,128,128'
utf8_valid u10ffff '\364\217\277\277' '244,143,191,191'
printf 'PASS\tv3_utf8_boundary_valid_load_save\t7 scalar boundaries load and save byte-identically\n'

utf8_invalid overlong2 '\300\200' 'invalid UTF-8'
utf8_invalid overlong3 '\340\200\200' 'invalid UTF-8'
utf8_invalid surrogate '\355\240\200' 'invalid UTF-8'
utf8_invalid overmax '\364\220\200\200' 'invalid UTF-8'
utf8_invalid truncated2 '\302' 'invalid UTF-8'
utf8_invalid truncated3 '\341\200' 'invalid UTF-8'
utf8_invalid truncated4 '\361\200\200' 'invalid UTF-8'
utf8_invalid badcontinuation '\341\101\200' 'invalid UTF-8'
utf8_invalid nul '\000' 'NUL is not supported'
printf 'PASS\tv3_utf8_boundary_invalid_load_save\t9 invalid forms are loud; save preserves original and removes temp\n'

# A file's permission bits: stat -f %Lp on macOS, stat -c %a on Linux (portable form).
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
save_ok() { "$BUILD/save-shim" "$BUILD/note.txt" after; }
printf 'before' > "$BUILD/note.txt"
chmod 640 "$BUILD/note.txt"
out=$(save_ok); test "$out" = 'rc=0 error='
test "$(cat "$BUILD/note.txt")" = after; test "$(fmode "$BUILD/note.txt")" = 640
test "$(find "$BUILD" -name '.note.txt.spinel-vi.*' | wc -l | tr -d ' ')" = 0
printf 'PASS\tv4_success_mode_replace\twrite/flush/file-fsync/rename/dir-fsync completed; mode kept\n'

for stage in open write fsync rename; do
  printf 'before' > "$BUILD/note.txt"
  out=$(SPINEL_VI_SAVE_FAIL="$stage" save_ok); test "$(cat "$BUILD/note.txt")" = before
  test "$(find "$BUILD" -name '.note.txt.spinel-vi.*' | wc -l | tr -d ' ')" = 0
  case "$out" in rc=-1\ error=*) ;; *) exit 1;; esac
  printf 'PASS\tv4_%s_failure\tloud; original unchanged; temporary removed\n' "$stage"
done

printf 'before' > "$BUILD/note.txt"
out=$(SPINEL_VI_SAVE_FAIL=dir-fsync save_ok); test "$(cat "$BUILD/note.txt")" = after
test "$(find "$BUILD" -name '.note.txt.spinel-vi.*' | wc -l | tr -d ' ')" = 0
case "$out" in rc=-1\ error=*directory\ fsync*) ;; *) exit 1;; esac
printf 'PASS\tv4_dir_fsync_failure\tloud after rename; target replaced, durability uncertain, no temporary\n'

# The E102 app binary supplies three E103 fake-terminal screen goldens without
# an additional Spinel entry point or compile.  spinel-extended: the E101/E102
# gates lived in the predecessor's experiment archive, which is not imported;
# tests/spinel-vi/run.sh runs run-editor-gates.sh (E102) before this script and
# the non-oracle E101 checks itself.
test -x "$ROOT/examples/spinel-vi/build/e102-gates/editor" ||
  bash "$HERE/run-editor-gates.sh"
EDITOR="$ROOT/examples/spinel-vi/build/e102-gates/editor"

printf 'one\ntwo\n' > "$BUILD/command-trace.txt"
"$EDITOR" --fake-command-trace "$BUILD/command-trace.txt" > "$BUILD/fake-command.out"
actual=$(shasum -a 256 "$BUILD/fake-command.out" | awk '{print $1}')
expected=$(tr -d '\n' < "$HERE/editor_e103_command.expected.sha256")
test "$actual" = "$expected"
grep -F $'event\t1\tU+0064\t0\t0\t0\t0' "$BUILD/fake-command.out" >/dev/null
grep -F $'event\t1\tU+0071\t0\t0\t0\t0' "$BUILD/fake-command.out" >/dev/null

printf 'ok\n' > "$BUILD/wq-trace.txt"
"$EDITOR" --fake-wq-trace "$BUILD/wq-trace.txt" > "$BUILD/fake-wq.out"
actual=$(shasum -a 256 "$BUILD/fake-wq.out" | awk '{print $1}')
expected=$(tr -d '\n' < "$HERE/editor_e103_wq.expected.sha256")
test "$actual" = "$expected"

"$EDITOR" --fake-redo-trace > "$BUILD/fake-redo.out"
actual=$(shasum -a 256 "$BUILD/fake-redo.out" | awk '{print $1}')
expected=$(tr -d '\n' < "$HERE/editor_e103_redo.expected.sha256")
test "$actual" = "$expected"
grep -F $'event\t1\tU+0000\t18\t0\t0\t0' "$BUILD/fake-redo.out" >/dev/null
printf 'PASS\tfake_command_screen_goldens\tdd/yy/p, pending cancel, :w/:q/:q!/:wq, undo/redo and redo discard render through fake terminal\n'
