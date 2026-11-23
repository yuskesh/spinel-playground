# tests/doom-core/harness/retired.sh — the Stage-1 mixed lanes, retired.
#
# THE OWNER'S DECISION OF 2026-09-17 (docs/decisions/0009, "Clarification
# (2026-09-17): the Stage-1 mixed lanes, retired"). tests/doom-core/source-port.rb
# ran the ported code BESIDE the running original, with the boundary copy
# sequencing a ported side against an unported one. Both of its questions are now
# answered elsewhere, so the lanes are SUPERSEDED AND REFUNDED, not abandoned:
#
#   * "does the ported code agree with the original" -- tests/doom-core/verify.sh:
#     step-diff.rb, render-diff.rb and input-diff.rb on the three real entries
#     (examples/doom/core/src/doomentry.rb), and those entries built by the kernel;
#   * the boundary copy -- refunded: both real entries take the one allocation.
#
# tests/doom-core/leaf-modes.rb IS INSIDE THE RETIRED BLOCK FOR THE SAME REASON,
# and it is not a third question: it is the support for the first one in the
# form that question took. The leaf oracle ran in job mode 2 and the shipped
# default is job mode 0, so its mode-2 results stood for mode 0 only because
# every leaf sees the same calls, returns the same results and leaves the same
# state in both -- which is what leaf-modes.rb digests and compares. When the
# leaf oracle went, the thing that needed the equality went with it. THE
# EQUALITY ITSELF IS NOT DARK: screens.sh's "the recording does not depend on
# the job mode" replays a demo in mode 2 against the mode-0 recording on every
# default run, outside this block. What is dark is the PER-CALL form, which no
# live lane consumes -- none runs a port in mode 2, and Full refuses mode 2
# outright (tests/doom-core/mode-one.rb).
#
# THE EVIDENCE STAYS, AT ITS REVISION. The lanes are frozen at 0af8ba0, the
# revision 0009's Stage-1 clarification records green on both hosts; checking it
# out and running the same scripts reproduces that run. Here the sections SAY
# they are retired, with that revision, rather than disappearing or going red
# against a port they no longer describe. STAGE1_LANES=run runs them anyway,
# against this tree, and they are expected to fail: that is not a fix path.
#
# Sourced; defines two functions and sets nothing else.
STAGE1_FROZEN=0af8ba0
stage1_lanes_run() { [ "${STAGE1_LANES:-}" = run ]; }
stage1_retired() { # what
  echo "  RETIRED $1: frozen at $STAGE1_FROZEN (0009, 2026-09-17); superseded by tests/doom-core/verify.sh" \
       "on the real entries, the boundary copy refunded; reproduce with: git checkout $STAGE1_FROZEN"
}
