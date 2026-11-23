# The sample's verification run, as a fixture

`trace.txt` is the decoded trace of one verification run of the acceptance
sample (`tests/app/fixtures/build/sample`) on mps2/an521 under QEMU with
`tests/app/fixtures/stimulus/sample.tsv` (Debian, 2026-09-23, `spinel-core-app
verify`, icount shift 5): 712 records, 62 invocations, the end marker
quiescent and drained. `board.rb` and `board_host.rb` are the board package
of that build, which the replay's host side needs -- edited since only to
move their constants into their modules (0014 D5), which changed no value and
no member; they are that run's package in every other respect, and not the
current generator's output for this board.
A note on what this fixture does and does not pin: the trace is compared with
itself and with the mutations, on whatever host runs them. It is never
compared with a live run: a trace is reproducible within a host and not
across hosts (see `docs/building.md`), and a fresh run at a later tip differs
from this one by design -- the sampler item alone moved it from 712 records
to 711. `tests/app/verify.sh`
applies every mutation of `tests/app/mutate.rb` to this trace and requires
`spinel-core-app verify --trace-text` to refuse each with the check's own
rule as its first failure,
and requires the unmutated trace to pass -- so the controls run on a host
without QEMU too. The fixture is data: a change in the recorder's format or
the checks' rules is caught here before any run.
