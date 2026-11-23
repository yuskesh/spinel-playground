#!/bin/sh
# tests/spinel-fork/argv-fill.sh -- the fork's argv-fill-order patch: the
# generated main counts only the ARGV slots it has written in sp_argv.len, so a
# collection started while ARGV is copied never marks an unwritten slot.
#
#   sh tests/spinel-fork/argv-fill.sh
#
# The unwritten slots are harmless while malloc returns zeroed memory, which a
# fresh process does. glibc's MALLOC_PERTURB_ fills each new block with a byte
# instead, standing in for a reused block's old contents, and
# SPINEL_GC_STRESS=1 collects every 2,048 bytes of strings, so a first argument
# of 3,000 bytes starts a collection while the second is copied.
#
# The control builds the same program with the fill loop turned back to the old
# order (len first) through a --cc wrapper, and expects that build to crash
# under the same conditions and to answer correctly without them.
#
# Needs glibc (MALLOC_PERTURB_); elsewhere it reports SKIP.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SPINEL="$REPO/vendor/spinel/spinel"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS  $1"; else fail=$((fail + 1)); printf 'FAIL  %s\n      got:  %s\n      want: %s\n' "$1" "$2" "$3"; fi; }

if ! getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
  echo "SKIP  not glibc: MALLOC_PERTURB_ is a glibc switch"
  echo "---- argv-fill: 0 passed, 0 failed, 1 skipped"
  exit 0
fi
[ -x "$SPINEL" ] || { echo "FAIL  no built compiler at $SPINEL"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/argv-fill.XXXXXX") || exit 1
trap 'rm -rf "${T:?}"' EXIT
printf 'puts ARGV.size\nputs ARGV[0].size\nputs ARGV[-1]\n' > "$T/prog.rb"

# The control's compiler: the generated C with the fill loop in the old order.
# Re-pinned at the 2026-11-14 upstream synchronisation (fork b1b0702da): `n`
# is the line that fork generates (len reset to 0, each slot through
# sp_str_retained, len set after each write); `o` is exactly the line plain
# upstream f8ff01939 generates, so the control reverts to upstream's own fill.
cat > "$T/old-order-cc" <<EOF
#!/bin/sh
for a in "\$@"; do
  case \$a in
    *.c) ruby -e 'f = ARGV[0]; s = File.read(f)
      n = "sp_argv.len = 0; sp_argv.data = (const char**)malloc(sizeof(const char*) * (size_t)(argc > 1 ? argc - 1 : 1)); for (int _ai = 0; _ai < argc - 1; _ai++) { sp_argv.data[_ai] = sp_str_retained(sp_str_dup_external(argv[_ai + 1])); sp_argv.len = _ai + 1; }"
      o = "sp_argv.len = argc - 1; sp_argv.data = (const char**)malloc(sizeof(const char*) * (size_t)(argc > 1 ? argc - 1 : 1)); for (int _ai = 0; _ai < argc - 1; _ai++) sp_argv.data[_ai] = sp_str_retained(sp_str_dup_external(argv[_ai + 1]));"
      s.scan(n).size == 1 or abort "old-order-cc: the fill loop was not found"
      File.write(f, s.sub(n, o)); File.write("$T/reverted", "1")' "\$a" || exit 1 ;;
  esac
done
exec cc "\$@"
EOF
chmod +x "$T/old-order-cc"

"$SPINEL" "$T/prog.rb" -o "$T/new" > "$T/new.log" 2>&1
ok "the program builds" "$?" 0
"$SPINEL" "$T/prog.rb" -o "$T/old" --cc="$T/old-order-cc" > "$T/old.log" 2>&1
ok "control: the program builds with the fill loop in the old order" "$?:$(cat "$T/reverted" 2>/dev/null)" 0:1

BIG=$(head -c 3000 /dev/zero | tr '\0' x)
run() { # out-file bin args...: the exit status, then the output on one line
  o=$1; shift
  "$@" > "$o" 2>&1; rc=$?
  echo "$rc $(tr '\n' ' ' < "$o")"
}
ok "plain run" "$(run "$T/o1" "$T/new" "$BIG" y)" "0 2 3000 y "
ok "GC stress and perturbed malloc, two arguments" \
   "$(run "$T/o2" env SPINEL_GC_STRESS=1 MALLOC_PERTURB_=165 "$T/new" "$BIG" y)" "0 2 3000 y "
set -- ; i=0; while [ $i -lt 40 ]; do set -- "$@" "$BIG"; i=$((i + 1)); done
ok "GC stress and perturbed malloc, 40 arguments of 3,000 bytes" \
   "$(run "$T/o3" env SPINEL_GC_STRESS=1 MALLOC_PERTURB_=165 "$T/new" "$@" z)" "0 41 3000 z "
ok "control: the old order answers without the stress" "$(run "$T/o4" "$T/old" "$BIG" y)" "0 2 3000 y "
env SPINEL_GC_STRESS=1 MALLOC_PERTURB_=165 "$T/old" "$BIG" y > "$T/o5" 2>&1
rc=$?
ok "control: the old order crashes under the stress (exit 139 or 134, got $rc)" \
   "$(case $rc in 139|134) echo crashed ;; *) echo "rc=$rc" ;; esac)" crashed

echo "---- argv-fill: $pass passed, $fail failed, 0 skipped"
[ "$fail" -eq 0 ]
