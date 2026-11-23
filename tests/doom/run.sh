#!/bin/sh
#
# tests/doom/run.sh — the IWAD-independent DOOM acceptance checks.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/run.sh
#
# Self-contained: the DOOM sources are imported into this repository
# (examples/doom/ and tests/doom/cases/), and nothing here reads any other
# checkout.  There is no source-path override and no fallback, because a build
# or test that fetched the sources from the predecessor would make it a build
# dependency -- which AGENTS.md and decision 0006 both forbid.
#
# Overrides, all explicit, all defaulting inside this checkout or into a fresh
# owned temporary directory:
#
#   LLVM_PREFIX  LLVM 23.1.1 tree; its bin/clang compiles every generated C
#                and every C helper.                    default /opt/llvm-23.1.1
#   RUBY         the reference Ruby.                    default ruby
#   BUILD_DIR    compiled programs and per-case output. default <root>/build/doom-tests
#   WORK_DIR     scratch a case may write into.         default a fresh mktemp -d
#   WAD          an IWAD, for cases that need one.      default <root>/build/doom-wad/doom1.wad
#   SPINEL       the pinned compiler.            default <root>/vendor/spinel/bin/spinel
#   CASES        space-separated subset to run.         default: every declared case
#
# None of the five cases here needs WAD; it is exposed because this runner is
# what task 3 extends, and a case that needs it must fail loudly when it is
# absent rather than silently skip.
#
# What the runner requires of each case, all of them and in this order:
#
#   1. compilation succeeds                      (a failed compiler is a failure,
#                                                 never a skip)
#   2. the compiled program exits 0
#   3. its COMBINED stdout+stderr equals the recorded .expected, byte for byte
#   4. a SECOND run, with the streams kept apart, has empty stderr
#   5. the reference Ruby run reproduces 2 and 3 as well
#
# Step 4 is a separate execution on purpose: reconstructing a combined stream
# from two separately captured ones does not preserve interleaving, so a
# concatenation cannot stand in for the recorded bytes and the recorded bytes
# cannot be split back into two streams.  Each is measured where it is true.
#
# A missing .expected is an error.  Nothing here regenerates a golden file, and
# there is no flag that would.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
CC_BIN="$LLVM_PREFIX/bin/clang"
RUBY="${RUBY:-ruby}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/doom-tests}"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
WAD="${WAD:-$ROOT/build/doom-wad/doom1.wad}"
CASEDIR="$ROOT/tests/doom/cases"

ALL_CASES="bytes_le fixed_and_bsp info_and_span palette_colormap wad_and_picture"
CASES="${CASES:-$ALL_CASES}"

die() { echo "doom-tests: $*" >&2; exit 1; }

[ -x "$SPINEL" ] || die "no pinned compiler at $SPINEL (build it first; see docs/building.md)"
[ -x "$CC_BIN" ] || die "no clang at $CC_BIN (set LLVM_PREFIX)"
command -v "$RUBY" >/dev/null 2>&1 || die "no reference Ruby '$RUBY' on PATH (set RUBY)"

mkdir -p "$BUILD_DIR"
if [ -n "${WORK_DIR:-}" ]; then
  mkdir -p "$WORK_DIR"; OWNED_WORK=""
else
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/doom-tests.XXXXXX") || die "cannot create a work directory"
  OWNED_WORK="$WORK_DIR"
fi
cleanup() { [ -n "$OWNED_WORK" ] && rm -rf "$OWNED_WORK"; }
trap cleanup EXIT INT TERM

# The imported sources must be the ones the manifest records, in both
# directions, before anything is compiled.
"$ROOT/tools/doom/verify-sources.sh" || die "the imported sources do not match tests/doom/manifest.tsv"

echo "doom-tests: spinel=$("$SPINEL" --cc="$CC_BIN" --version)"
echo "doom-tests: ruby=$("$RUBY" -v 2>&1 | head -1)"
echo "doom-tests: build=$BUILD_DIR work=$WORK_DIR"

# Bijection between the declared case list and the imported test programs.
declared=$(mktemp "$WORK_DIR/decl.XXXXXX")
present=$(mktemp "$WORK_DIR/pres.XXXXXX")
for c in $ALL_CASES; do echo "$c"; done | sort > "$declared"
( cd "$CASEDIR" && ls *.rb 2>/dev/null | sed 's/\.rb$//' ) | sort > "$present"
if ! cmp -s "$declared" "$present"; then
  echo "doom-tests: declared cases and imported test programs disagree:" >&2
  diff -u "$declared" "$present" >&2 || true
  die "fix the case list or the import"
fi
[ -s "$declared" ] || die "no cases declared"

# Step 5 runs the reference Ruby: an oracle, asked about once here.
if "$ROOT/tools/oracle/gate" tests/doom/run.sh reference-ruby; then reference=1; else reference=0; fi
pass=0; fail=0; ran=0
for c in $CASES; do
  case " $ALL_CASES " in *" $c "*) ;; *) die "unknown case '$c'" ;; esac
  ran=$((ran + 1))
  src="$CASEDIR/$c.rb"
  exp="$CASEDIR/$c.expected"
  out="$BUILD_DIR/$c"
  [ -f "$src" ] || die "$c: no test program at $src"
  [ -f "$exp" ] || die "$c: no expectation at $exp -- a missing expectation is an error"

  scratch="$WORK_DIR/$c"; rm -rf "$scratch"; mkdir -p "$scratch"
  why=""

  if ! "$SPINEL" "$src" --cc="$CC_BIN" -o "$out.bin" > "$out.compile.log" 2>&1; then
    why="compilation failed"
  fi

  if [ -z "$why" ]; then
    ( cd "$scratch" && "$out.bin" "$scratch" ) > "$out.combined" 2>&1 || why="compiled program exited $?"
  fi
  if [ -z "$why" ] && ! cmp -s "$exp" "$out.combined"; then
    why="compiled combined output differs from $c.expected"
  fi
  if [ -z "$why" ]; then
    rm -rf "$scratch"; mkdir -p "$scratch"
    ( cd "$scratch" && "$out.bin" "$scratch" ) > "$out.stdout" 2> "$out.stderr" || why="compiled program exited $? on the split-stream run"
    if [ -z "$why" ] && [ -s "$out.stderr" ]; then
      why="compiled program wrote $(wc -c < "$out.stderr" | tr -d ' ') bytes to stderr"
    fi
  fi
  if [ -z "$why" ] && [ "$reference" = 1 ]; then
    rm -rf "$scratch"; mkdir -p "$scratch"
    ( cd "$scratch" && "$RUBY" "$src" "$scratch" ) > "$out.ruby.combined" 2>&1 || why="$RUBY exited $?"
  fi
  if [ -z "$why" ] && [ "$reference" = 1 ] && ! cmp -s "$exp" "$out.ruby.combined"; then
    why="$RUBY combined output differs from $c.expected"
  fi

  if [ -n "$why" ]; then
    fail=$((fail + 1))
    echo "FAIL $c: $why"
    [ -s "$out.compile.log" ] && sed 's/^/    /' "$out.compile.log" | head -20
    for f in "$out.combined" "$out.ruby.combined"; do
      [ -f "$f" ] && { echo "    --- diff $(basename "$f") vs expected ---"; diff -u "$exp" "$f" 2>&1 | head -20 | sed 's/^/    /'; }
    done
  else
    pass=$((pass + 1))
    echo "pass $c"
  fi
done

echo "doom-tests: $ran run, $pass pass, $fail fail"
[ "$ran" -gt 0 ] || die "no cases ran"
[ "$fail" -eq 0 ] || exit 1
