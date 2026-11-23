#!/bin/sh
#
# tests/core-boundary/artifacts.sh — decision 0007 task 5's fourth bullet:
# every capability through the FULL ADAPTER and through a DIRECT C HARNESS,
# and the CORE artifacts each one produces.
#
#   KERNEL=<spinel-core-kernel> ADAPTER=<...> PACKAGE=<...> \
#     tests/core-boundary/artifacts.sh
#
# The three capability lanes -- capabilities.sh, framebuffer.sh, slots.sh --
# each hold a capability to the original Full code, and each does it through a
# C harness that calls the CORE entry directly. This file asks the other half
# of the question: does the same capability answer the same way when a FULL
# caller reaches it, through the registry and the generated adapter, rather
# than through a pointer?
#
# It is the same harness either way. Each fixture's harness.c compiles twice,
# once plainly and once with -DSPINEL_VIA_ADAPTER, so the parsing, the
# comparison and the printing are the same source and a difference in the
# answer is a difference in the BOUNDARY rather than in two harnesses that
# drifted apart.
#
# WHICH MAKES THE SPELLING OF THAT DEFINE LOAD-BEARING. A define that no longer
# matched the `#ifdef` in the harness would compile a second copy of the DIRECT
# build, and every comparison below would then be a build against itself. So
# the adapter build is required to FAIL to link without the adapter sources --
# a build that needs nothing from them is not going through them.
#
# Five lanes:
#
#   1. artifacts. Every capability's contract produces a CORE object, a header,
#      an adapter pair, a registry pair and a Ruby module. Each object needs
#      NOTHING from the host, the trap hook included: these entries answer with
#      a status rather than trapping. Read out of the symbol table rather than
#      taken on trust, with a control that the reader would report a dependency
#      if there were one. The header's identity is the contract's, as the
#      boundary tool states it.
#   2. one registry, not one per contract. Thirteen entries across three
#      capabilities generate one registry, and it is the same file each time.
#   3. packaging. Each capability packages and verifies, and a package whose
#      object came from a different contract is refused.
#   4. the two paths agree. Each fixture's harness runs every mode twice and
#      the two must print the same thing and exit the same way.
#   5. what the two paths DO NOT share, checked rather than assumed, from both
#      sides. A refused invoke poisons the mutable participants, so a Full
#      caller cannot read a half-written buffer at all; each adapter build
#      requires EVERY refusal to have poisoned, not merely one of them. The
#      other side is the direct one, and it is RUN: slots' check table says how
#      many cells each refused call moved, that declaration is then broken to
#      zero, and the direct harness reads the caller's arrays back and names
#      what it actually found there.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-boundary"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
ADAPTER="${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp kernel "$ADAPTER"
PACKAGE="${PACKAGE:-$ROOT/tools/mlir/native/build/bin/spinel-core-package}"
BOUNDARY="${BOUNDARY:-$ROOT/tools/mlir/native/build/bin/spinel-core-boundary}"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
NM_BIN="${NM:-nm}"
RUBY="${RUBY:-ruby}"

die() { echo "artifacts: $*" >&2; exit 1; }
for t in "$KERNEL" "$ADAPTER" "$PACKAGE" "$BOUNDARY" "$CC_BIN"; do
  [ -x "$t" ] || die "no tool at $t (build it first)"
done
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
"$RUBY" -e 'exit 0' >/dev/null 2>&1 || die "'$RUBY' does not run"
# The floor is checked HERE rather than met halfway through, where a ruby that
# does not understand the fixture becomes a non-zero exit some later check
# would read as a refusal it asked for. Same reasoning as oracle.rb, which
# states the same floor, and as closure.sh, which states its prism requirement
# here rather than inside its census.
"$RUBY" -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.7.0") ? 0 : 1)' \
  >/dev/null 2>&1 || die \
  "the ruby at '$RUBY' is $("$RUBY" -e 'print RUBY_VERSION' 2>/dev/null), below the 2.7 floor
       this suite declares (tests/core-boundary/oracle.rb states it, and
       docs/building.md records that macOS's default 2.6 is not a selected
       reference); set RUBY=<a newer ruby>."
command -v "$NM_BIN" >/dev/null 2>&1 || die "no symbol reader at '$NM_BIN'"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-artifacts.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0
TAB=$(printf '\t')

# The capabilities. Each is a fixture directory holding both a harness.c and
# at least one contract under src/; how each one is driven differs enough that
# the driving is spelled out per capability below rather than tabulated.
#
# The list is DECLARED and then checked against the tree, because a list that
# only named what it felt like would quietly drop a capability -- measured: with
# `capabilities` removed from it the lane came back 18 of 18 and exit 0, having
# skipped thirty cases.
CAPS="capabilities framebuffer slots"

# Mach-O prefixes global symbols with an underscore and ELF does not. Measured
# with a probe rather than guessed from `uname`, which is what tests/core does.
cat > "$WORK/probe.c" <<'EOF'
int spinel_probe_symbol(void) { return 0; }
EOF
"$CC_BIN" -c "$WORK/probe.c" -o "$WORK/probe.o" 2>/dev/null || die "the C compiler will not compile a probe"
if "$NM_BIN" "$WORK/probe.o" 2>/dev/null | grep -q '_spinel_probe_symbol'; then
  U="_"
else
  U=""
fi

# A symbol reader that answered nothing, or a filter that swallowed
# everything, would make the check below pass for every object ever compiled.
# So an object that DOES need the host is compiled first and has to be
# reported, by the same reader and the same filter.
cat > "$WORK/dependent.c" <<'EOF'
extern int spinel_probe_host_call(int);
int spinel_probe_dependent(int x) { return spinel_probe_host_call(x); }
EOF
"$CC_BIN" -c "$WORK/dependent.c" -o "$WORK/dependent.o" 2>/dev/null \
  || die "the C compiler will not compile the symbol control"
# EVERY undefined symbol, with nothing exempt. These entries answer with a
# status rather than trapping, so not even the trap hook is wanted, and the
# documentation says so -- exempting it here would leave the script enforcing
# something weaker than what is written down.
undefs() {
  "$NM_BIN" -u "$1" | awk '{ print $NF }' | grep -v '^$' || true
}
echo "== the derived fixtures say they are derived =="
# The extracted Ruby is copied and adapted from GPL-derived code, so it is
# GPL-derived. Each source names its own origin and each directory carries a
# provenance table -- the capability lanes check both -- but a notice covering
# them as a body is a separate obligation, and one nothing here checked until
# the handoff was being prepared.
NOTICE="$HERE/fixtures/NOTICE.md"
if [ ! -f "$NOTICE" ]; then
  echo "  FAIL there is no notice at $NOTICE"; fail=$((fail + 1))
else
  bad=0
  grep -q "GNU General Public License" "$NOTICE" || { echo "  FAIL the notice does not name the licence"; bad=1; }
  for cap in $CAPS; do
    grep -qF "$cap/src" "$NOTICE" || { echo "  FAIL the notice does not cover $cap/src"; bad=1; }
  done
  # And the licence it points at has to be there, not merely named.
  lic="$ROOT/examples/doom/LICENSE"
  [ -f "$lic" ] || { echo "  FAIL the notice points at $lic, which is not there"; bad=1; }
  # Every directory that is NOT derived must be absent from the table, or the
  # notice would be claiming provenance for work written here.
  for d in "$HERE"/fixtures/*/; do
    name=$(basename "$d")
    case " $CAPS " in *" $name "*) continue ;; esac
    grep -qF "$name/src" "$NOTICE" && { echo "  FAIL the notice claims $name is derived, and it is not"; bad=1; }
  done
  if [ "$bad" -eq 0 ]; then
    echo "  pass the notice covers the three derived directories and no others"
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
fi

echo "== the declared capabilities are the ones that are there =="
found=""
for d in "$HERE"/fixtures/*/; do
  name=$(basename "$d")
  [ -f "$d/harness.c" ] || continue
  ls "$d"/src/*.contract >/dev/null 2>&1 || continue
  found="$found $name"
done
declared=$(printf '%s\n' $CAPS | sort | tr '\n' ' ')
present=$(printf '%s\n' $found | sort | tr '\n' ' ')
if [ "$declared" = "$present" ]; then
  echo "  pass the declared set is exactly the fixture directories that hold a harness and contracts"
  pass=$((pass + 1))
else
  echo "  FAIL declared [$declared] but the tree holds [$present]"
  fail=$((fail + 1))
fi

echo "== the symbol reader reports a dependency when there is one =="
seen=$(undefs "$WORK/dependent.o")
if printf '%s' "$seen" | grep -q "spinel_probe_host_call"; then
  echo "  pass an object that needs the host is reported"
  pass=$((pass + 1))
else
  echo "  FAIL the control object's dependency was not reported; the reader or"
  echo "       the filter is answering nothing, so the lane below means nothing"
  fail=$((fail + 1))
fi

echo "== the artifacts each contract produces =="
n_entry=0
for cap in $CAPS; do
  FIX="$HERE/fixtures/$cap"
  out="$WORK/$cap"
  mkdir -p "$out"
  declared=0; ok=0
  for c in "$FIX"/src/*.contract; do
    stem=$(basename "$c" .contract)
    declared=$((declared + 1))
    # Its own directory as well as the shared one. The shared one is what the
    # harness links against; the private one is what lets every entry's
    # registry be compared below instead of only the last of each capability.
    solo="$WORK/solo/$cap/$stem"
    mkdir -p "$solo"
    "$ADAPTER" "$c" --root "$FIX" --outdir "$solo" >/dev/null 2>&1 || true
    if ! "$KERNEL" "$c" --root "$FIX" -o "$out/$stem.o" \
         --header "$out/spinel_core_$stem.h" --clang "$CC_BIN" >"$out/$stem.build" 2>&1; then
      echo "  FAIL $cap/$stem did not build:"; sed 's/^/      /' "$out/$stem.build" | head -3
      fail=$((fail + 1)); continue
    fi
    if ! "$ADAPTER" "$c" --root "$FIX" --outdir "$out" >"$out/$stem.adapt" 2>&1; then
      echo "  FAIL $cap/$stem produced no adapter:"; sed 's/^/      /' "$out/$stem.adapt" | head -3
      fail=$((fail + 1)); continue
    fi
    missing=""
    for f in "spinel_core_$stem.h" "$stem.o" "spinel_adapter_$stem.h" \
             "spinel_adapter_$stem.c" "spinel_adapter_registry.h" \
             "spinel_adapter_registry.c" "core_$stem.rb"; do
      [ -f "$out/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
      echo "  FAIL $cap/$stem is missing:$missing"; fail=$((fail + 1)); continue
    fi
    # The object's undefined symbols, read out of the table. A CORE object may
    # ask the host for the trap hook and for nothing else; anything more is a
    # dependency the word `core` did not authorise.
    undef=$(undefs "$out/$stem.o")
    if [ -n "$undef" ]; then
      echo "  FAIL $cap/$stem's object needs$(printf ' %s' $undef)"; fail=$((fail + 1)); continue
    fi
    # The header says which contract it describes, and the boundary tool says
    # the same thing from the contract itself.
    want=$("$BOUNDARY" "$c" --root "$FIX" --identity 2>/dev/null) || want=""
    if [ -z "$want" ]; then
      echo "  FAIL $cap/$stem has no identity from the boundary tool"; fail=$((fail + 1)); continue
    fi
    if ! grep -qF "\"$want\"" "$out/spinel_core_$stem.h"; then
      echo "  FAIL $cap/$stem's header does not carry its contract's identity"
      fail=$((fail + 1)); continue
    fi
    ok=$((ok + 1))
    n_entry=$((n_entry + 1))
    pass=$((pass + 1))
  done
  if [ "$ok" -eq "$declared" ]; then
    echo "  pass $cap: all $declared entries have an object needing nothing from the host, a header carrying its identity, an adapter and a module"
  else
    echo "  FAIL $cap: $ok of $declared entries did"
    fail=$((fail + 1))
  fi
done
[ "$n_entry" -gt 0 ] || die "no capability produced an object"

echo "== one registry for all of them, not one per contract =="
# Every entry's own copy, not the last of each capability: the shared outdir is
# overwritten as the entries are generated, so comparing three files there
# would leave ten of the thirteen unread. Both halves of the pair are compared,
# because a consumer includes the header and links the source.
first_c=""; first_h=""; compared=0; same=1
for f in "$WORK"/solo/*/*/spinel_adapter_registry.c; do
  [ -f "$f" ] || { echo "  FAIL no entry generated a registry"; fail=$((fail + 1)); same=0; break; }
  h="$(dirname "$f")/spinel_adapter_registry.h"
  if [ ! -f "$h" ]; then
    echo "  FAIL $(dirname "$f") generated a registry source with no header"; fail=$((fail + 1)); same=0; continue
  fi
  if [ -z "$first_c" ]; then first_c="$f"; first_h="$h"; continue; fi
  compared=$((compared + 1))
  cmp -s "$first_c" "$f" || { echo "  FAIL $(dirname "$f")'s registry source differs"; fail=$((fail + 1)); same=0; }
  cmp -s "$first_h" "$h" || { echo "  FAIL $(dirname "$f")'s registry header differs"; fail=$((fail + 1)); same=0; }
done
want_cmp=$((n_entry - 1))
if [ "$compared" -ne "$want_cmp" ]; then
  echo "  FAIL $compared registry comparison(s) for $n_entry entries, wanted $want_cmp"
  fail=$((fail + 1))
elif [ "$same" -eq 1 ]; then
  echo "  pass $n_entry entries over $(echo $CAPS | wc -w | tr -d ' ') capabilities generate one registry, compared $compared time(s), source and header"
  pass=$((pass + 1))
fi

echo "== packaging =="
for cap in $CAPS; do
  FIX="$HERE/fixtures/$cap"
  out="$WORK/$cap"
  c=$(ls "$FIX"/src/*.contract | head -1)
  stem=$(basename "$c" .contract)
  pkg="$out/pkg"
  rm -rf "$pkg"; mkdir -p "$pkg"
  cp "$out/spinel_core_$stem.h" "$out/$stem.o" "$out/spinel_adapter_$stem.h" \
     "$out/spinel_adapter_$stem.c" "$out/spinel_adapter_registry.h" \
     "$out/spinel_adapter_registry.c" "$out/core_$stem.rb" "$pkg/"
  if "$PACKAGE" write "$c" --root "$FIX" --dir "$pkg" -o "$pkg/package.manifest" \
       >"$out/pkg.write" 2>&1 && "$PACKAGE" verify "$pkg/package.manifest" \
       >"$out/pkg.verify" 2>&1; then
    echo "  pass $cap/$stem packages and verifies"
    pass=$((pass + 1))
  else
    echo "  FAIL $cap/$stem did not package:"
    sed 's/^/      /' "$out/pkg.write" "$out/pkg.verify" | head -5
    fail=$((fail + 1)); continue
  fi
  # An object from a DIFFERENT entry of the same capability, over the same
  # manifest. Nothing in an object says which contract it came from, so this is
  # the swap the manifest exists to refuse -- and it is a swap between two real
  # entries rather than a corrupted file.
  other=$(ls "$FIX"/src/*.contract | sed -n '2p')
  if [ -z "$other" ]; then
    echo "  pass $cap has one entry, so there is no sibling object to swap in"
    pass=$((pass + 1))
  else
    ostem=$(basename "$other" .contract)
    cp "$out/$ostem.o" "$pkg/$stem.o"
    set +e
    "$PACKAGE" verify "$pkg/package.manifest" >"$out/pkg.swap" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      echo "  FAIL $cap accepted $ostem's object in $stem's package"; fail=$((fail + 1))
    else
      echo "  pass $cap refuses $ostem's object in $stem's package"
      pass=$((pass + 1))
    fi
  fi
done

echo "== the direct path and the Full adapter answer the same =="
# Each fixture's own generator writes what its harness reads; the harness is
# then built twice from one source. Anything the two builds print differently
# is a difference in the boundary.
for cap in $CAPS; do
  FIX="$HERE/fixtures/$cap"
  out="$WORK/$cap"
  if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$out" "$FIX/harness.c" "$out"/*.o \
       -o "$out/direct" 2>"$out/cc.direct"; then
    echo "  FAIL $cap's direct harness did not compile:"
    sed 's/^/      /' "$out/cc.direct" | head -5; fail=$((fail + 1)); continue
  fi
  if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror -DSPINEL_VIA_ADAPTER -I"$out" \
       "$FIX/harness.c" "$out"/*.o "$out"/spinel_adapter_*.c -o "$out/via" 2>"$out/cc.via"; then
    echo "  FAIL $cap's adapter harness did not compile:"
    sed 's/^/      /' "$out/cc.via" | head -5; fail=$((fail + 1)); continue
  fi
  # The same source and the same define, WITHOUT the adapter sources. It has to
  # fail to link: a build that needs nothing from the registry or the generated
  # entry points is not going through them, and every comparison below would
  # then be the direct build against itself. Measured: mis-spell the define and
  # this links, which is the whole reason the control is here.
  set +e
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -DSPINEL_VIA_ADAPTER -I"$out" \
    "$FIX/harness.c" "$out"/*.o -o "$out/via-alone" 2>"$out/cc.alone"
  alone=$?
  set -e
  if [ "$alone" -eq 0 ]; then
    echo "  FAIL $cap's adapter build links without the adapter, so it is not using it"
    fail=$((fail + 1)); continue
  fi
  if ! grep -qi "spinel_adapter" "$out/cc.alone"; then
    echo "  FAIL $cap's adapter build failed to link, but not for want of the adapter:"
    sed 's/^/      /' "$out/cc.alone" | head -4; fail=$((fail + 1)); continue
  fi
  echo "  pass $cap's adapter build does not link without the adapter"
  pass=$((pass + 1))

  # Lane 4's inputs and expected answers come from CRuby running the original
  # (oracle.rb, scene.rb, trace.rb), which only the owner's instruction runs.
  "$ROOT/tools/oracle/gate" tests/core-boundary/artifacts.sh two-paths || continue
  case "$cap" in
    capabilities)
      "$RUBY" "$FIX/oracle.rb" "$ROOT" > "$out/expected.tsv" 2>/dev/null \
        || { echo "  FAIL $cap's oracle would not run"; fail=$((fail + 1)); continue; }
      agreed=0; differed=0
      TAB=$(printf '\t')
      while IFS="$TAB" read -r id helper args; do
        case "$id" in \#*|"") continue ;; esac
        set +e
        d=$("$out/direct" "$helper" $(echo "$args" | tr ',' ' ') 2>&1); drc=$?
        v=$("$out/via" "$helper" $(echo "$args" | tr ',' ' ') 2>&1); vrc=$?
        set -e
        want=$(awk -F"$TAB" -v k="$id" '$1 == k { print $2 }' "$out/expected.tsv")
        if [ "$d" = "$v" ] && [ "$drc" -eq "$vrc" ] && [ "$d" = "$want" ]; then
          agreed=$((agreed + 1))
        else
          echo "  FAIL $cap/$id: the original says $want, direct says $d, the adapter says $v"
          differed=$((differed + 1))
        fi
      done < "$FIX/cases.tsv"
      if [ "$differed" -eq 0 ] && [ "$agreed" -gt 0 ]; then
        echo "  pass $cap: $agreed case(s), both paths, both the original's answer"
        pass=$((pass + 1))
      else
        fail=$((fail + 1))
      fi
      ;;
    framebuffer|slots)
      if [ "$cap" = framebuffer ]; then
        gen="scene.rb"; input="$out/scene.txt"; modes="run refuse reverse fuzzfirst"
      else
        gen="trace.rb"; input="$out/trace.txt"; modes="run refuse exhaust shuffle"
      fi
      if ! "$RUBY" "$FIX/$gen" "$ROOT" "$FIX" "$input" >/dev/null 2>"$out/gen.err"; then
        echo "  FAIL $cap's generator would not run:"
        sed 's/^/      /' "$out/gen.err" | head -4; fail=$((fail + 1)); continue
      fi
      bad=0
      for m in $modes; do
        set +e
        d=$("$out/direct" "$input" "$m" 2>&1); drc=$?
        v=$("$out/via" "$input" "$m" 2>&1); vrc=$?
        set -e
        if [ "$drc" -ne 0 ]; then
          echo "  FAIL $cap/$m: the direct path failed: $d"; bad=1; continue
        fi
        if [ "$d" != "$v" ] || [ "$drc" -ne "$vrc" ]; then
          echo "  FAIL $cap/$m: direct($drc) said '$d', the adapter($vrc) said '$v'"; bad=1
        fi
      done
      if [ "$bad" -eq 0 ]; then
        echo "  pass $cap: $(echo $modes | wc -w | tr -d ' ') mode(s), both paths, identical"
        pass=$((pass + 1))
      else
        fail=$((fail + 1))
      fi
      ;;
  esac
done

echo "== what the two paths do not share =="
# TWO HALVES, and neither is a re-run of a lane above. The ADAPTER half is
# already measured: each adapter build fails unless every refusal poisoned its
# mutable storage, and the `refuse` mode above ran it in both fixtures that
# have one.
#
# The DIRECT half is the one that still needs saying, and saying it means
# RUNNING it. This check used to count rows of slots' check table and present
# the count as the direct half; what a direct caller can still read after a
# refusal is a property of the run, not of a table, and a count of rows would
# have read exactly the same with no harness built at all.
#
# So the declaration is BROKEN -- every refusal that declares a move is told it
# moved nothing -- and the direct harness is run again over that trace. It
# reads the caller's arrays back itself, before the call and after, and names
# the number of cells it found changed. A refusal that had left those arrays as
# it found them would agree with the zero, and nothing would be reported.
SLOTS_OUT="$WORK/slots"
declared_moves=$(awk -F"$TAB" '$1 == "check" && $8 != "0" && $9 != "0" { n++ } END { print n + 0 }' \
                 "$HERE/fixtures/slots/trace.tsv")
if ! "$ROOT/tools/oracle/gate" tests/core-boundary/artifacts.sh direct-refusal; then
  : # the trace is lane 4's, which CRuby running the original wrote
elif [ ! -x "$SLOTS_OUT/direct" ] || [ ! -s "$SLOTS_OUT/trace.txt" ]; then
  echo "  FAIL the direct slots harness was not built and run above, so the direct"
  echo "       half of this difference cannot be measured here"
  fail=$((fail + 1))
elif [ "$declared_moves" -eq 0 ]; then
  echo "  FAIL no refusal declares a move, so there is nothing for the direct half"
  echo "       to observe and the claim would rest on the adapter alone"
  fail=$((fail + 1))
else
  # Field 9 of a generated `check` line is the declared count; fields 8 and 9
  # are the status and that count, the same two the table above is read by.
  awk '$1 == "check" && $8 != "0" && $9 != "0" { $9 = 0 } { print }' \
    "$SLOTS_OUT/trace.txt" > "$WORK/nomove.txt"
  set +e
  nomove_out=$("$SLOTS_OUT/direct" "$WORK/nomove.txt" refuse 2>&1)
  nomove_rc=$?
  set -e
  observed=$(printf '%s\n' "$nomove_out" \
             | grep -c 'changed [1-9][0-9]* cell(s), and declares 0' || true)
  if [ "$nomove_rc" -eq 0 ]; then
    echo "  FAIL the direct harness accepted a trace declaring every refusal to have"
    echo "       moved nothing, so it is not reading the caller's cells back at all"
    fail=$((fail + 1))
  elif [ "$observed" -eq 0 ]; then
    echo "  FAIL the direct harness refused that trace, but not over the cells a"
    echo "       refusal left written:"
    printf '%s\n' "$nomove_out" | sed 's/^/      /' | head -4
    fail=$((fail + 1))
  elif [ "$observed" -ne "$declared_moves" ]; then
    echo "  FAIL $declared_moves refusal(s) declare a move and the direct harness found"
    echo "       $observed, so the table and the run do not describe the same thing"
    fail=$((fail + 1))
  else
    echo "  pass the direct caller can still read what $observed refused call(s) wrote into"
    echo "       its own arrays -- counted from the cells, not from the table --"
    echo "       where the same refusal through the adapter poisons them:"
    printf '%s\n' "$nomove_out" | grep 'and declares 0' | sed 's/^/       /' | head -3
    pass=$((pass + 1))
  fi
fi

echo "artifacts: $((pass + fail)) checked, $pass pass, $fail fail, $n_entry entries over $(echo $CAPS | wc -w | tr -d ' ') capabilities"
[ "$fail" -eq 0 ] || exit 1
