#!/bin/sh
#
# tests/doom-core/abort-controls.sh — an interrupted suite reports an abort, not a finding.
#
#   sh tests/doom-core/abort-controls.sh [DIR]
#
# THE DEFECT THIS EXISTS FOR, measured on 2026-09-18. Both suites below had
#
#   trap 'rm -rf "$W"' EXIT INT TERM
#
# and THE HANDLER DID NOT EXIT. A shell trap that returns resumes the script, so
# a TERM deleted the work directory and the run CARRIED ON: the next check could
# not find its file, failed, and the suite printed
#
#   audit: 263 checked, 262 pass, 1 fail
#
# as though it had finished. The run had been killed by a `timeout`. Nobody
# reading that output could tell it from a real defect in the tree, and a
# Ctrl-C, a CI limit or a closed laptop produces the same thing. It was found
# only because the person who sent the signal knew they had sent it.
#
# WHAT IS REQUIRED OF AN INTERRUPTED SUITE, checked here for SIGTERM on each
# suite (see the note on SIGINT below):
#
#   * IT PRINTS NO SUMMARY LINE. A count is a claim to have checked things;
#     an aborted run has no such claim to make.
#   * IT EXITS NONZERO, and not with a status that reads as "checks failed":
#     143 for TERM, 130 for INT, the conventional 128+signal.
#   * IT STILL CLEANS UP: it leaves no work directory of its own behind. The
#     reason the handler existed is still a reason.
#
# THE SIGNAL IS SENT EARLY, a second or two in, because what is under test is
# the handler and not the suite: neither run here is a run of the checks, and
# neither reports on the tree.
#
# SIGTERM AND NOT SIGINT, and the reason is a rule rather than a preference. A
# command a shell starts in the background has SIGINT SET TO IGNORE (POSIX,
# asynchronous lists), and a signal ignored on entry cannot be reset by the
# shell it is handed to -- so `kill -INT` on a suite started from a script does
# nothing, and measuring that proves nothing about the handler. Testing it
# would need job control this script does not have. THE INT HANDLER IS THE
# SAME LINE AS THE TERM HANDLER in both suites, and what is checked here is
# that shape: clean up, say so, exit 128+signal.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:-${TMPDIR:-/tmp}/doom-core-abort.$$}
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
mkdir -p "$DIR"

# One suite, one signal: start it, wait until it has begun, signal it, and
# judge it by its status and its output. The suite is signalled by pid -- not
# by a pattern, and not by process group, which would reach this script too.
interrupt() { # suite signal expected-status label-of-summary
  suite=$1; sig=$2; want=$3; label=$4
  # the prefix each suite gives mktemp, which is not its file name
  case $suite in audit) short=audit ;; source-pack) short=pack ;;
    *) echo "  FAIL $suite: this control does not know its work-directory prefix"; fail=$((fail + 1)); return ;;
  esac
  out="$DIR/$suite-$sig.out"
  before=$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c "^doom-core-$short\." || true)
  SPINEL_TYPEDUMP="$READER" sh "$ROOT/tests/doom-core/$suite.sh" "$DIR/$suite-$sig.d" > "$out" 2>&1 &
  pid=$!
  # Wait for it to be running rather than sleeping a fixed time: the handler is
  # only under test once the suite owns a work directory.
  n=0
  while [ "$n" -lt 100 ]; do
    [ -s "$out" ] && break
    kill -0 "$pid" 2>/dev/null || break
    n=$((n + 1)); sleep 0.2
  done
  kill -"$sig" "$pid" 2>/dev/null || true
  # AND A BOUND ON WAITING FOR IT TO GO. A suite that ignores the signal would
  # otherwise be waited on to completion -- audit.sh is forty minutes -- and a
  # control that hangs for forty minutes reports nothing while looking busy.
  set +e
  n=0
  while [ "$n" -lt 60 ] && kill -0 "$pid" 2>/dev/null; do n=$((n + 1)); sleep 0.5; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rc=stayed-up
  else
    wait "$pid"
    rc=$?
  fi
  set -e
  ok "$suite refuses to summarise after $sig" \
     "$rc|$(grep -cE "^$label: [0-9]+ checked, " "$out")" "$want|0"
  ok "  and says it was stopped"  "$(grep -cE "^$suite: (interrupted|terminated) \(SIG$sig\); no summary follows$" "$out")" 1
  # NOTHING OF ITS OWN LEFT BEHIND. The suites make their work directory with
  # mktemp and never name it, so this counts the directories with that suite's
  # prefix before and after: the set must not have grown. A concurrent run of
  # the same suite on this host would make it grow for an innocent reason, and
  # the lanes are run one at a time.
  after=$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c "^doom-core-$short\." || true)
  ok "  and left no work directory behind" "$after" "$before"
}

echo "== an interrupted suite does not report a result =="
interrupt source-pack TERM 143 source-pack
interrupt audit       TERM 143 audit

# NO pkill SWEEP HERE, deliberately. A suite killed mid-check can leave a
# reader or a ruby of its own behind, and the obvious tidy-up is a pattern
# kill -- but a pattern wide enough to catch them matches ANOTHER RUN OF THE
# SAME SUITE on the same host, and one narrow enough to be safe matches this
# script's own command line, which is how the first version of this file killed
# itself. The signal is sent a second or two in, so what can be left is one
# short-lived child; that is the smaller mess.
echo "abort-controls: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ]
