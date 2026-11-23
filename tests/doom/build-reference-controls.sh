#!/bin/sh
#
# tests/doom/build-reference-controls.sh — the refusals in build-reference.sh.
#
#   tests/doom/build-reference-controls.sh
#
# Only the cases review raised.  No oracle is run and nothing is re-measured.
#
# **No real toolchain is required and no path is hardcoded.**  Where a control
# needs a compiler that merely exists and can say its version, it gets a fixture
# one written here.  An earlier version hardcoded LLVM_PREFIX=/opt/llvm-23.1.1
# in the ownership control, so on a host without that path it failed for the
# wrong reason -- compiler absent, never reaching the check it was named after.
# The macOS side measured that: 4 of 5, with case 5 failing for compiler
# absence.
#
# Every control also unsets CC and LLVM_PREFIX from the caller's environment
# unless it is setting them itself.  An inherited CC short-circuits the
# LLVM_PREFIX check and hides exactly what case 1 exists to show.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
B="$ROOT/tools/doom/build-reference.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-brctl.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0

# A compiler that exists and identifies itself, and compiles nothing.  Controls
# that are about something else use this so they do not depend on a toolchain.
FIXTURE_CC="$WORK/fixture-cc"
cat > "$FIXTURE_CC" <<'CCEOF'
#!/bin/sh
case "${1:-}" in
  --version) echo "fixture-cc 1.0 (a stand-in for controls that are not about the compiler)"; exit 0 ;;
esac
echo "fixture-cc: asked to compile, which no control here should reach" >&2
exit 90
CCEOF
chmod +x "$FIXTURE_CC"

check() { # $1 label  $2 want  $3.. env assignments
  label="$1"; want="$2"; shift 2
  log="$WORK/$(echo "$label" | tr -c 'a-zA-Z0-9' '_').log"
  set +e
  env -u CC -u LLVM_PREFIX "$@" BUILD_DIR="$WORK/b" "$B" > "$log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then echo "FAIL $label: exited 0; it must fail"; fail=$((fail + 1)); return; fi
  if ! grep -Eq "$want" "$log"; then
    echo "FAIL $label: exited $rc but never said /$want/"; sed 's/^/    /' "$log" | tail -6; fail=$((fail + 1)); return
  fi
  echo "pass $label (exit $rc, diagnosed: $(grep -Eoh "$want" "$log" | head -1))"
  pass=$((pass + 1))
}

# 1. LLVM_PREFIX given but wrong: refuse, do not fall back to cc.  CC is unset
#    by check() so an inherited one cannot satisfy the selection first.
check "1 LLVM_PREFIX without bin/clang" "Refusing to fall back" LLVM_PREFIX="$WORK/nope"

# 2. CC given but not an executable anywhere.
check "2 CC is not executable" "is not on PATH and is not an executable file" CC="$WORK/not-a-compiler"

# 3. CC exists but fails when asked its version.
printf '#!/bin/sh\necho "some output on stdout"\nexit 3\n' > "$WORK/badver"
chmod +x "$WORK/badver"
check "3 compiler cannot identify itself" "exited 3 for --version" CC="$WORK/badver"

# 4. CC exists and succeeds but says nothing.
printf '#!/bin/sh\nexit 0\n' > "$WORK/silentver"
chmod +x "$WORK/silentver"
check "4 compiler reports an empty version" "reported an empty version" CC="$WORK/silentver"

# 5. A clone this script did not make is never reset, cleaned or checked out.
#    The fixture compiler is used so this reaches the ownership check on a host
#    with no LLVM installed.
mkdir -p "$WORK/b/doomgeneric" && : > "$WORK/b/doomgeneric/something"
check "5 unowned build directory" "was not created by this script" CC="$FIXTURE_CC"
rm -rf "$WORK/b"

# 6. `make clean` failing must stop the run, and the build must not be attempted
#    over objects that could not be removed.
#
#    A `make` stub earlier on PATH fails the clean and records every invocation,
#    so "did not proceed to the build" is checked rather than assumed.  The
#    clone is reused from an existing owned build directory when there is one,
#    so this control needs no network; otherwise it says why it could not run
#    rather than reporting a pass it did not earn.
seed=""
for cand in "$ROOT/build/doom-reference-clang" "$ROOT/build/doom-reference"; do
  [ -f "$cand/doomgeneric/.spinel-extended-owned-reference-build" ] || continue
  seed="$cand"; break
done
if [ -z "$seed" ]; then
  echo "FAIL 6 clean failure: no existing owned clone to reuse; run tools/doom/build-reference.sh once first"
  fail=$((fail + 1))
else
  rm -rf "$WORK/b6"; mkdir -p "$WORK/b6"
  cp -R "$seed/doomgeneric" "$WORK/b6/doomgeneric"
  stub="$WORK/stubbin"; mkdir -p "$stub"
  cat > "$stub/make" <<MAKEEOF
#!/bin/sh
echo "\$@" >> "$WORK/make-calls"
for a in "\$@"; do
  if [ "\$a" = clean ]; then
    echo "fixture make: refusing to clean (negative control)" >&2
    exit 2
  fi
done
exit 0
MAKEEOF
  chmod +x "$stub/make"
  : > "$WORK/make-calls"
  log="$WORK/6_clean_failure.log"
  set +e
  env -u CC -u LLVM_PREFIX PATH="$stub:$PATH" CC="$FIXTURE_CC" BUILD_DIR="$WORK/b6" "$B" > "$log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL 6 clean failure: exited 0; it must fail"; fail=$((fail + 1))
  elif ! grep -q "objects that could not be removed" "$log"; then
    echo "FAIL 6 clean failure: exited $rc but did not name the clean refusal"
    sed 's/^/    /' "$log" | tail -6; fail=$((fail + 1))
  elif grep -q -- '-j' "$WORK/make-calls"; then
    echo "FAIL 6 clean failure: it went on to the build anyway:"
    sed 's/^/    /' "$WORK/make-calls"; fail=$((fail + 1))
  else
    echo "pass 6 clean failure stops the run (exit $rc, and make was called $(wc -l < "$WORK/make-calls" | tr -d ' ') time(s), none of them a build)"
    pass=$((pass + 1))
  fi
fi

echo "build-reference-controls: $((pass + fail)) run, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
