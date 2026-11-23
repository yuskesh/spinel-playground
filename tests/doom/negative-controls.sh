#!/bin/sh
#
# tests/doom/negative-controls.sh — prove that tests/doom/run.sh actually fails.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 RUBY=ruby tests/doom/negative-controls.sh
#
# A suite that has only ever been shown to pass has not been shown to reject
# anything.  Each control below constructs one defect, runs the real runner over
# it, and requires BOTH a non-zero exit AND the diagnostic that names that
# defect.  Asserting the reason matters: a control that fails for an unrelated
# reason -- a missing tool, a typo in a fixture -- would otherwise read as a
# successful negative control.  That is not hypothetical.  When these controls
# were once run in a checkout whose compiler had not been built, five of the six
# exited non-zero with the wrong diagnostic and were correctly reported as
# failures; on exit status alone they would have read 6/6 green while testing
# nothing.
#
# Each control works on a COPY of this repository's DOOM subtree under the work
# directory, so the tracked files are never mutated and nothing reaches outside
# the checkout.  The copy is a whole little tree -- examples/doom, tests/doom,
# tools/doom -- so the runner under test is the real script resolving its own
# root, not a special-cased variant.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
RUBY="${RUBY:-ruby}"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doom-negctl.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0

# A fresh copy of the subtree under test.
mktree() { # $1 = name -> echoes the copy's root
  t="$WORK/$1"
  mkdir -p "$t/examples" "$t/tests" "$t/tools"
  cp -r "$ROOT/examples/doom" "$t/examples/doom"
  cp -r "$ROOT/tests/doom"    "$t/tests/doom"
  cp -r "$ROOT/tools/doom"    "$t/tools/doom"
  # the runner asks tools/oracle/gate about its reference-Ruby step
  cp -r "$ROOT/tools/oracle"  "$t/tools/oracle"
  cp "$ROOT/tests/ORACLES.tsv" "$t/tests/ORACLES.tsv"
  echo "$t"
}

# Recompute the manifest's LOCAL columns for a copy, keeping the original
# columns, so a deliberate mutation is recorded rather than caught by staging.
remanifest() { # $1 = copy root
  python3 - "$1" <<'PY'
import sys, os, hashlib
root = sys.argv[1]
mf = os.path.join(root, "tests/doom/manifest.tsv")
out, rows = [], []
for line in open(mf):
    if line.startswith("#"):
        out.append(line); continue
    k, op, ob, osha, lp, lb, lsha, mod = line.rstrip("\n").split("\t")
    f = os.path.join(root, lp)
    if not os.path.exists(f):
        continue
    b = open(f, "rb").read()
    s = hashlib.sha256(b).hexdigest()
    # A kind=local row has no original, so its modified column stays "n/a".
    # Recomputing it as no/yes against an original of "-" writes "yes" and the
    # verifier rejects the row -- which it should, and which is why this helper
    # has to know about the kind rather than treating every row alike.
    mod = "n/a" if k == "local" else ("no" if s == osha else "yes")
    rows.append("\t".join([k, op, ob, osha, lp, str(len(b)), s, mod]))
open(mf, "w").write("".join(out) + "\n".join(rows) + ("\n" if rows else ""))
PY
}

# $1 label  $2 expected-diagnostic regex  $3 tree root  $4.. extra env
check() {
  label="$1"; want="$2"; tree="$3"; shift 3
  log="$WORK/$(echo "$label" | tr -c 'a-zA-Z0-9' '_').log"
  set +e
  env "$@" LLVM_PREFIX="$LLVM_PREFIX" RUBY="$RUBY" SPINEL="${CTL_SPINEL:-$SPINEL}" \
      BUILD_DIR="$tree/build" "$tree/tests/doom/run.sh" > "$log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL $label: the runner exited 0; it must fail"; fail=$((fail + 1)); return
  fi
  if ! grep -Eq "$want" "$log"; then
    echo "FAIL $label: exited $rc but never said /$want/ -- it failed for the wrong reason"
    sed 's/^/    /' "$log" | tail -12
    fail=$((fail + 1)); return
  fi
  echo "pass $label (exit $rc, diagnosed: $(grep -Eoh "$want" "$log" | head -1))"
  pass=$((pass + 1))
}

# ---- A. the compiler fails -------------------------------------------------
ta=$(mktree a)
bad_cc="$WORK/failing-spinel"
printf '#!/bin/sh\necho "spinel: deliberate failure (negative control A)" >&2\nexit 1\n' > "$bad_cc"
chmod +x "$bad_cc"
CTL_SPINEL="$bad_cc" check "A compiler failure" "FAIL .*: compilation failed" "$ta" CASES=bytes_le
unset CTL_SPINEL

# ---- B. output matches, but the process exits non-zero ---------------------
tb=$(mktree b)
printf '\nexit 3\n' >> "$tb/tests/doom/cases/bytes_le.rb"
remanifest "$tb"
check "B nonzero exit with matching output" "FAIL bytes_le: (compiled program|.*ruby.*) exited 3" "$tb" CASES=bytes_le

# ---- C. the expectation is wrong by one byte -------------------------------
tc=$(mktree c)
python3 - "$tc/tests/doom/cases/bytes_le.expected" <<'PY'
import sys
p = sys.argv[1]; d = bytearray(open(p, 'rb').read())
i = next(k for k, c in enumerate(d) if 48 <= c <= 56)   # a digit that is not '9'
d[i] += 1
open(p, 'wb').write(bytes(d))
PY
remanifest "$tc"
check "C wrong expected value" "FAIL bytes_le: compiled combined output differs" "$tc" CASES=bytes_le

# ---- D. an imported file no longer matches the manifest --------------------
# The same mutation as C, but WITHOUT re-recording it: verify-sources must stop
# the run before anything is compiled.
td=$(mktree d)
python3 - "$td/tests/doom/cases/bytes_le.expected" <<'PY'
import sys
p = sys.argv[1]; d = bytearray(open(p, 'rb').read())
i = next(k for k, c in enumerate(d) if 48 <= c <= 56)
d[i] += 1
open(p, 'wb').write(bytes(d))
PY
check "D imported file fails its digest" "verify-sources: .* has sha256" "$td" CASES=bytes_le

# ---- E. empty discovery ----------------------------------------------------
te=$(mktree e)
rm -f "$te"/tests/doom/cases/*.rb "$te"/tests/doom/cases/*.expected
remanifest "$te"
check "E empty discovery" "declared cases and imported test programs disagree" "$te"

# ---- F. the program writes to stderr ---------------------------------------
# Only the separate-stream run can catch this, which is why that run exists as a
# second execution rather than as a reconstruction of two captured streams.
#
# For this to be a single-variable control the COMBINED comparison must still
# pass, so the expectation is taken from the mutated program's own combined
# output rather than guessed by appending to the original.  The first attempt
# did guess -- append "noise" to the .expected -- and it failed at the combined
# comparison instead, because stderr is unbuffered while a redirected stdout is
# block-buffered, so the stderr bytes land FIRST in the combined stream.  That
# is the very interleaving a reconstruction cannot recover, which is the reason
# this runner measures each property where it is true; recorded here because the
# failed construction is itself the evidence for that design.
# The expectation is CRuby's output: recording it is an oracle run.
if "$ROOT/tools/oracle/gate" tests/doom/negative-controls.sh control-f; then
  tf=$(mktree f)
  printf '\n$stderr.print "noise"\n' >> "$tf/tests/doom/cases/bytes_le.rb"
  ( cd "$tf/tests/doom/cases" && "$RUBY" bytes_le.rb "$WORK" ) > "$tf/tests/doom/cases/bytes_le.expected" 2>&1 \
    || { echo "negctl: could not record control F's expectation" >&2; exit 1; }
  remanifest "$tf"
  check "F stderr not empty" "FAIL bytes_le: compiled program wrote [0-9]+ bytes to stderr" "$tf" CASES=bytes_le
fi

# ---- G. every available SHA-256 backend agrees --------------------------------
# The digest tool differs by platform -- Debian has sha256sum, macOS has shasum,
# and neither is guaranteed on the other.  tools/doom/sha256.sh picks one; this
# control checks that WHICH one it picks cannot change a verdict, by driving
# each available backend over the same file and requiring identical digests.
# This is a positive control and passes when they agree.
tg=$(mktree g)
agree=1; first=""; seen=""
for t in sha256sum shasum openssl; do
  command -v "$t" >/dev/null 2>&1 || continue
  d=$( . "$tg/tools/doom/sha256.sh"; SP_SHA256_CMD="$t"; sp_sha256_select >/dev/null 2>&1 \
       && [ "$SP_SHA256_TOOL" = "$t" ] && sp_sha256 "$tg/examples/doom/LICENSE" )
  [ -n "$d" ] || { echo "FAIL G backend agreement: $t produced nothing"; agree=0; break; }
  seen="$seen $t"
  if [ -z "$first" ]; then first="$d"; elif [ "$d" != "$first" ]; then
    echo "FAIL G backend agreement: $t gave $d, earlier backends gave $first"; agree=0; break
  fi
done
if [ -z "$first" ]; then
  echo "FAIL G backend agreement: no SHA-256 backend was available to test"
  fail=$((fail + 1))
elif [ "$agree" = 1 ]; then
  echo "pass G backend agreement (identical digest from:$seen)"
  pass=$((pass + 1))
else
  fail=$((fail + 1))
fi

# ---- H. no SHA-256 tool at all ------------------------------------------------
# The verifier must say what is missing and fail, never proceed with the digest
# check skipped.  PATH is rebuilt with every command EXCEPT the three digest
# tools, so the failure is specifically the missing digest tool and not a
# missing shell utility.
th=$(mktree h)
stub="$WORK/h-bin"; mkdir -p "$stub"
for d in /bin /usr/bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=$(basename "$f")
    case "$b" in sha256sum|shasum|openssl) continue ;; esac
    [ -e "$stub/$b" ] || ln -s "$f" "$stub/$b" 2>/dev/null || true
  done
done
hlog="$WORK/h.log"
set +e
env -i PATH="$stub" HOME="$WORK" "$th/tools/doom/verify-sources.sh" > "$hlog" 2>&1
hrc=$?
set -e
if [ "$hrc" -eq 0 ]; then
  echo "FAIL H no digest tool: verify-sources exited 0; it must fail"; fail=$((fail + 1))
elif ! grep -q "no usable SHA-256 tool" "$hlog"; then
  echo "FAIL H no digest tool: exited $hrc but never said what was missing"
  sed 's/^/    /' "$hlog" | tail -8; fail=$((fail + 1))
else
  echo "pass H no digest tool (exit $hrc, diagnosed: $(grep -o 'no usable SHA-256 tool' "$hlog" | head -1))"
  pass=$((pass + 1))
fi

echo "negative-controls: $((pass + fail)) run, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
