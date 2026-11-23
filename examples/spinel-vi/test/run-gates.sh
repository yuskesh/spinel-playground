#!/usr/bin/env bash
# Phase 0 permanent gate.  The fake backend is the authoritative test leg:
# event input and normalized drawing log are independent of a user's terminal.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd -- "$HERE/.." && pwd)
ROOT=$(cd -- "$APP/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spinel-vi-e097.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

"$ROOT/vendor/spinel/bin/spinel" "$APP/app.rb" -o "$WORK/spinel-vi"
"$WORK/spinel-vi" > "$WORK/out.txt"
diff -u "$HERE/expected.txt" "$WORK/out.txt"
printf 'PASS\tfake_event_draw_shutdown\tSpinel native ffi_struct + normalized fake backend\n'

run_pty() {
  local case_name=$1
  local mode=$2
  perl "$HERE/pty-gate.pl" "$WORK/$case_name.typescript" "$WORK/spinel-vi" \
    "$WORK/$case_name.out" "$case_name" "$mode" "${SPINEL_VI_E097_PTY_DELAY:-1}"
}

# `script` gives termbox2 a genuine PTY.  pty-gate.pl uses a macOS-core Perl
# watchdog (new session/process group, TERM then KILL then reap); no timeout(1).
run_pty basic -
cp "$WORK/basic.out" "$WORK/termbox2.out"
grep -a -F 'init=0 backend=1' "$WORK/termbox2.out" >/dev/null
grep -a -F 'poll=1 type=1 ch=120' "$WORK/termbox2.out" >/dev/null
grep -a -F 'TERM_RESTORED' "$WORK/termbox2.out" >/dev/null
printf 'PASS\ttermbox2_pty_key_and_restore\tPTY key U+0078, normal exit, termios restored\n'

run_pty input --probe-input
grep -a -F 'input0=poll=1 type=1 ch=120 key=0 mod=0' "$WORK/input.out" >/dev/null
grep -a -F 'input1=poll=1 type=1 ch=0 key=18 mod=2' "$WORK/input.out" >/dev/null
grep -a -F 'input2=poll=1 type=1 ch=12354 key=0 mod=0' "$WORK/input.out" >/dev/null
grep -a -F 'TERM_RESTORED' "$WORK/input.out" >/dev/null
printf 'PASS\ttermbox2_pty_ctrl_and_utf8\tCtrl-R key and U+3042 input through real PTY\n'

run_pty resize --probe-resize
grep -a -F 'resize-request=0 poll=1 type=2 width=91 height=37' "$WORK/resize.out" >/dev/null
grep -a -F 'TERM_RESTORED' "$WORK/resize.out" >/dev/null
printf 'PASS\ttermbox2_pty_resize\tTIOCSWINSZ + SIGWINCH produces real resize event\n'

# This control runs on every gate invocation.  The deadline override is read
# only by pty-gate.pl (test infrastructure), never by the editor or C ABI.
set +e
SPINEL_VI_E097_PTY_DEADLINE=1 \
  perl "$HERE/pty-gate.pl" "$WORK/watchdog.typescript" "$WORK/spinel-vi" \
    "$WORK/watchdog.out" basic - 2 2> "$WORK/watchdog.err"
watchdog_rc=$?
set -e
test "$watchdog_rc" = 124
grep -F 'E097 pty watchdog: deadline exceeded; process group reaped' \
  "$WORK/watchdog.err" >/dev/null
printf 'PASS\tpty_watchdog_forced_deadline\t1s deadline + 2s delayed input exits 124 and reaps group\n'

widths=$("$WORK/spinel-vi" --probe-widths)
expected_widths=$(printf 'init=0 backend=0\nwidth-ascii=1\nwidth-hiragana=2\nwidth-combining=0\nwidth-emoji=2\ninit\nshutdown')
test "$widths" = "$expected_widths"
printf 'PASS\ttermbox2_snapshot_cell_width\tU+0041=1 U+3042=2 U+0301=0 U+1F600=2\n'

FILE_WORK="$WORK/file"
mkdir -p "$FILE_WORK"
printf 'before' > "$FILE_WORK/note.txt"
"$ROOT/vendor/spinel/bin/spinel" "$APP/probes/file_save_probe.rb" -o "$FILE_WORK/file-save"
same_dir_tmp="$FILE_WORK/.note.spinel-vi.tmp"
file_ok=$("$FILE_WORK/file-save" "$FILE_WORK/note.txt" "$same_dir_tmp")
expected_file_ok=$(printf 'read=before\nsave=ok fsync=0\ncontent=before|saved')
test "$file_ok" = "$expected_file_ok"
test "$(cat "$FILE_WORK/note.txt")" = 'before|saved'
test ! -e "$same_dir_tmp"
printf 'PASS\tfile_same_dir_fsync_rename\tFile.read/open/write/flush/fsync/rename keeps no temp\n'

printf 'before' > "$FILE_WORK/note.txt"
file_fail=$("$FILE_WORK/file-save" "$FILE_WORK/note.txt" "$FILE_WORK/missing/.note.tmp" fail-before-rename)
expected_file_fail=$(printf 'read=before\nsave=error\ncontent=before')
test "$file_fail" = "$expected_file_fail"
test "$(cat "$FILE_WORK/note.txt")" = 'before'
printf 'PASS\tfile_failure_preserves_original\tfailed temporary open leaves target byte-identical\n'

"$ROOT/vendor/spinel/bin/spinel" "$APP/probes/bre_probe.rb" -o "$WORK/bre-probe"
bre=$("$WORK/bre-probe")
grep -F $'capture\trc=0\tstart=1\tend=3\terror=' <<< "$bre" >/dev/null
grep -F $'zero_0\trc=0\tstart=0\tend=0\terror=' <<< "$bre" >/dev/null
grep -F $'invalid\trc=-1\tstart=-1\tend=-1\terror=set' <<< "$bre" >/dev/null
printf 'PASS\tposix_bre_byte_offsets\tBRE literal/capture, zero-length, and invalid pattern C seam\n'
