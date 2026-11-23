#!/bin/sh
#
# tests/llvm/run.sh — the LLVM backend driver (tools/llvm), end to end.
#
#   LLVM_PREFIX=... sh tests/llvm/run.sh [--runtime-members-only]
#
# --runtime-members-only checks existing archives without rebuilding/linking.
# SPINEL_DIR selects the vendor; LLVM_RT_BUILD_DIR selects existing archives.
#
# 1. build_rt_bc.sh turns the pinned runtime into two archives of LLVM bitcode,
#    one member per runtime source;
# 2. spinel-llvm builds a sample of the upstream test programs three ways --
#    the stock `spinel` (cc -O2), `--mode clang-O2` and `--mode thinlto` -- and
#    each binary prints the program's own test/<name>.rb.expected. The sample
#    is every 100th program with no .args or .stdin, plus a threaded program
#    with the bundled native packages (the mt archive and native_obj path);
# 3. --mode ir writes LLVM IR; -v shows ThinLTO linking the bitcode archive;
#    --link supplies an external method definition (Patch 1) to the link;
# 4. the driver refuses a bad mode, --link with ir, a missing input, and a
#    program that does not compile, naming the stage and its exit code.
#
# The three builds come from one compiler and one source; the expectation is
# the upstream suite's own file, not another implementation's output.
#
# Exit 0 when everything passed, 1 on any failure.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SP="${SPINEL_DIR:-$REPO/vendor/spinel}"
RT_BUILD="${LLVM_RT_BUILD_DIR:-$REPO/tools/llvm/build}"
members_only=0
case "${1:-}" in
  "") [ "$#" -eq 0 ] || exit 2 ;;
  --runtime-members-only) [ "$#" -eq 1 ] || exit 2; members_only=1 ;;
  *) echo "usage: $0 [--runtime-members-only]" >&2; exit 2 ;;
esac
DRV="$REPO/tools/llvm/spinel-llvm"
[ -n "${LLVM_PREFIX:-}" ] || { echo "---- llvm: SKIP (LLVM_PREFIX is not set)"; exit 2; }
[ -x "$SP/bin/spinel" ] || { echo "---- llvm: SKIP (build vendor/spinel first)"; exit 2; }
export LLVM_PREFIX

pass=0
fail=0
W=$(mktemp -d "${TMPDIR:-/tmp}/llvm-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

echo "== 1. runtime bitcode"
if [ "$members_only" -eq 0 ]; then
  if SPINEL_DIR="$SP" BUILD_DIR="$RT_BUILD" bash "$REPO/tools/llvm/build_rt_bc.sh" -f >"$W/bc.log" 2>&1; then
    ok "build_rt_bc.sh: $(tail -1 "$W/bc.log")"
  else
    bad "build_rt_bc.sh"; sed 's/^/      /' "$W/bc.log"
  fi
fi
# Optional C-extension sources are not members of the ordinary runtime.
rt_members=$(sed -n 's/^RT_MEMBERS[[:space:]]*=[[:space:]]*//p' "$SP/Makefile" | head -1)
re_sources=$(sed -n 's/^RE_SRC[[:space:]]*=[[:space:]]*//p' "$SP/Makefile" | head -1)
if [ -z "$rt_members" ] || [ -z "$re_sources" ]; then
  bad "vendor Makefile declares RT_MEMBERS and RE_SRC"; exit 1
fi
{ for m in $rt_members; do printf '%s.o\n' "$m"; done
  for f in $re_sources; do basename "$f" .c | sed 's/$/.o/'; done
} | sort > "$W/expected-members"
nsrc=$(wc -l < "$W/expected-members" | tr -d ' ')
if [ "$(sort -u "$W/expected-members" | wc -l | tr -d ' ')" != "$nsrc" ]; then
  bad "runtime source basenames are unique"; exit 1
fi
for a in libspinel_rt_lto.a libspinel_rt_mt_lto.a; do
  A="$RT_BUILD/$a"
  if ! "$LLVM_PREFIX/bin/llvm-ar" t "$A" > "$W/actual-members" 2>"$W/ar.err"; then
    bad "$a: archive cannot be read"; continue
  fi
  sort "$W/actual-members" > "$W/sorted-members"
  n=$(wc -l < "$W/actual-members" | tr -d ' ')
  nbc=0
  for m in $("$LLVM_PREFIX/bin/llvm-ar" t "$A"); do
    # Consume the whole member before reading its magic: od -N4 on a pipe
    # closes early and LLVM 23's ar reports a broken-pipe error.
    if "$LLVM_PREFIX/bin/llvm-ar" p "$A" "$m" > "$W/member.bc"; then
      magic=$(od -An -tx1 -N4 "$W/member.bc" | tr -d ' \n')
      case "$magic" in 4243c0de|dec0170b) nbc=$((nbc + 1)) ;; esac
    fi
  done
  if cmp -s "$W/expected-members" "$W/sorted-members" && [ "$nbc" = "$n" ]; then
    ok "$a: $n exact runtime members, all LLVM bitcode"
  else
    bad "$a: $n members ($nsrc expected), $nbc of them bitcode"
    diff -u "$W/expected-members" "$W/sorted-members" || true
  fi
done

if [ "$members_only" -eq 1 ]; then
  echo "---- llvm runtime members: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]; exit $?
fi

echo "== 2. three builds of the same programs"
: > "$W/sample"
i=0
for f in "$SP"/test/*.rb; do
  i=$((i + 1))
  [ $((i % 100)) = 1 ] || continue
  [ -f "$f.expected" ] && [ ! -f "$f.args" ] && [ ! -f "$f.stdin" ] || continue
  echo "$f" >> "$W/sample"
done
echo "$SP/test/issue_3342_threads_with_native_packages.rb" >> "$W/sample"
while read -r f; do
  n=$(basename "$f" .rb)
  agree=1
  for m in stock clang-O2 thinlto; do
    if [ "$m" = stock ]; then
      "$SP/bin/spinel" "$f" -o "$W/$n.$m" >"$W/b.log" 2>&1
    else
      "$DRV" "$f" -o "$W/$n.$m" --mode "$m" >"$W/b.log" 2>&1
    fi
    if [ $? != 0 ]; then bad "$n: the $m build fails"; sed 's/^/      /' "$W/b.log" | head -5; agree=0; continue; fi
    (cd "$SP" && "$W/$n.$m" > "$W/$n.$m.out" 2>/dev/null)
    if ! cmp -s "$W/$n.$m.out" "$f.expected"; then bad "$n: the $m build does not print its .expected"; agree=0; fi
  done
  [ "$agree" = 0 ] || ok "$n: stock, clang-O2 and thinlto all print its .expected"
done < "$W/sample"

echo "== 3. modes and --link"
cat > "$W/hello.rb" <<'RB'
def add(a, b)
  a + b
end
puts add(2, 3)
RB
if "$DRV" "$W/hello.rb" --mode ir -o "$W/hello.ll" >/dev/null 2>&1 &&
   grep -q '^define .*@main' "$W/hello.ll"; then
  ok "--mode ir writes LLVM IR with main"
else
  bad "--mode ir"
fi
if "$DRV" "$W/hello.rb" -o "$W/hello" -v 2>"$W/v.log" && "$W/hello" | grep -qx 5 &&
   grep -q -- '-flto=thin' "$W/v.log" && grep -q 'libspinel_rt_lto.a' "$W/v.log"; then
  ok "thinlto links the bitcode runtime (-v shows -flto=thin and libspinel_rt_lto.a)"
else
  bad "thinlto link line"; sed 's/^/      /' "$W/v.log" | head -5
fi
printf '#include <stdint.h>\nintptr_t sp_add(intptr_t lv_a, intptr_t lv_b) { return lv_a * 100 + lv_b; }\n' > "$W/add.c"
"$LLVM_PREFIX/bin/clang" -O2 -flto=thin -c "$W/add.c" -o "$W/add.o"
if SPINEL_EXTERN_METHODS=add "$DRV" "$W/hello.rb" -o "$W/hello_ext" --link "$W/add.o" >"$W/l.log" 2>&1 &&
   [ "$("$W/hello_ext")" = 203 ]; then
  ok "--link supplies an external method definition (203, not 5)"
else
  bad "--link with SPINEL_EXTERN_METHODS"; sed 's/^/      /' "$W/l.log" | head -5
fi

echo "== 4. refusals"
refuse() {  # <name> <expected text> <args...>
  name=$1; want=$2; shift 2
  "$DRV" "$@" >"$W/r.log" 2>&1
  rc=$?
  if [ "$rc" != 0 ] && grep -q -- "$want" "$W/r.log"; then ok "$name (exit $rc)"
  else bad "$name (exit $rc)"; sed 's/^/      /' "$W/r.log" | head -3; fi
}
refuse "a bad --mode is refused" "--mode expects" "$W/hello.rb" --mode fast
refuse "--link with --mode ir is refused" "meaningless with --mode ir" "$W/hello.rb" --mode ir --link "$W/add.o"
refuse "a missing input is refused" "No such file" "$W/none.rb"
printf 'def broken(\n' > "$W/broken.rb"
refuse "a program that does not compile names the stage" "stage 'spinel -c' failed" "$W/broken.rb" -o "$W/broken"

echo "---- llvm: $pass passed, $fail failed"
[ "$fail" = 0 ]
