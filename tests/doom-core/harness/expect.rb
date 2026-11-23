# tests/doom-core/harness/expect.rb — the frame lane's expectations, generated.
#
#   ruby tests/doom-core/harness/expect.rb --pins PINS.tsv [--cases FILE]
#        [--controls FILE] [--keys FILE] [--fills FILE] [--overrides FILE]
#        [--out FILE]
#
# Decision 0009 item 2: a case asserts KEYS, not a joined string. This writes
# tests/doom-core/expect/frame.tsv, which is what harness/run.rb judges a result
# record against. Every value it can take from the frozen pins it takes from
# them MECHANICALLY -- read out of the pinned text by report_keys.rb, never
# retyped and never taken from a new run -- so that a migrated check asserts
# what the check it replaces asserted. A value no pin holds is written `TBD`
# with the origin `run`, and is filled once from a first run. Nothing is
# invented here.
#
# THE ROWS BELONG TO THE JUDGING CASE. run.rb looks a case's rows up by its
# `judged_against` column, not by its own id: a perturbation is judged against
# what it perturbs. So this writes rows for every id some matrix row is judged
# against, and for no other id. The four selftests -- the two mutations, the
# 599-frame run and the killed run -- are judged against
# frame.ruby.none.600 and therefore get no rows of their own; that is what
# makes them tests OF the nominal expectation rather than tests beside it.
#
# WHAT EACH KIND OF CASE ASSERTS. Stage 1 at its reduced scope, and no more:
#
#   nominal   every fault kind of the route equal to 0, the fifteen coverage
#             counts exactly, and the frame count. Coverage loss cannot pass.
#             THE ZEROES AND THE FRAME COUNT COME FROM THE DECLARATION, not
#             from a run: `nominal` MEANS every kind is zero, and the matrix
#             fixes the frame count. A nominal with no pin therefore still
#             asserts them as values -- taking them from a run would let a run
#             that raised a fault write its own count in as the expectation,
#             which is the vacuity 0009 exists to prevent. Only the coverage
#             counts, which nobody can declare in advance, wait for a run.
#   control   its ONE intended kind above zero, that kind's first failure, and
#             the whole set of kinds it raises. The intended kind and its text
#             come from expect/frame-controls.tsv, which took them from the
#             pin; the set is that kind plus the collateral kinds named there.
#             A CONTROL NEWER THAN THE FROZEN REVISION HAS NO PIN, and the same
#             three rows are written from the same table: its intended kind and
#             its raised set are declared there, and its first-failure text is
#             `TBD` with the origin `run`, because only a run can give it. The
#             table stays the one place a control's intent lives; restating the
#             four of them here would be a second declaration that could drift.
#   refusal   the run was refused: `outcome`, `rc` and the message, taken from
#             the composite pin's own part for that control.
#
# THE THREE CASES THE PINS DO NOT COVER -- a session run with a wrong slot in
# its field map, the adapter's refused step, the adapter's untracked result --
# are declared in NEW below, with the keys each needs and the reason, because
# their intent lives in the matrix's origin prose and cannot be read out of any
# pin. Their values are `TBD` except where the case's own declaration fixes
# them; a first run must confirm even those.
#
# THE FOUR RULES OF THE OUTPUT, which run.rb implements:
#   eq   exact: an integer against an integer, a string byte for byte.
#   gt0  an integer above zero. IT HAS NO VALUE: the column holds `-`, because
#        writing the pinned count there would read as an assertion nobody makes.
#   set  a comma-separated set of names, compared as a set.
# and the origin column, which is evidence and not an assertion: `pin` where
# the value came out of a frozen pin -- the header names which line, per case --
# and `run` where no pin asserts it. A `run` row that already carries a value
# carries what the case's own declaration requires; the first run confirms it.
#
# HOW A `TBD` IS FILLED, AND WHY NOT BY HAND. This file is generated, so editing
# its output would be overwritten by the next regeneration and would leave no
# trace of where the value came from. `--fills FILE` reads
# tests/doom-core/expect/frame-fills.tsv instead -- `case_id key value from` --
# and substitutes each row's value for that key's `TBD`. Its `from` column names
# the run directory and record the value was read out of, which is what a review
# checks the number against. That file is itself generated, by
# harness/fills.rb, from the records of a run; nothing in this path is typed.
# The three steps, in order:
#
#   ruby tests/doom-core/harness/expect.rb --pins PINS.tsv --out UNFILLED.tsv
#   ruby tests/doom-core/harness/fills.rb --expect UNFILLED.tsv --records RUNDIR \
#        --out tests/doom-core/expect/frame-fills.tsv
#   ruby tests/doom-core/harness/expect.rb --pins PINS.tsv \
#        --fills tests/doom-core/expect/frame-fills.tsv \
#        --out tests/doom-core/expect/frame.tsv
#
# A fill may only ever REPLACE A `TBD`. A row that names a key this file derived
# from a pin or from the case's own declaration is refused, not applied: it
# would be a hand-written value overriding a mechanical one, which is the whole
# thing the generator exists to prevent.
#
# WHEN THE PORT LEGITIMATELY MOVES A PINNED VALUE. A value taken from a frozen
# pin is otherwise fixed forever: this file takes it from the pin, and there is
# no way to say that the port changed and the key's value now comes from a run
# instead. A capability that changes what the port counts -- the renderer's
# plane walk pushing the sky columns inside the walk, so the port's own push no
# longer counts them -- moves such a value, and neither way out is allowed: the
# pins are the record of what the old checks asserted and are not edited, and
# this file is generated and is not hand-patched.
#
# `--overrides FILE` reads tests/doom-core/expect/frame-overrides.tsv --
# `case_id key value revision reason` -- and substitutes the row's value,
# recording the origin as `run@REVISION` so the generated file itself says the
# value no longer stands on its pin. `revision` is the commit that moved it;
# `reason` names the port change in words. It is 0009 item 3's reviewed update:
# a tracked file, read as a diff, that says which values moved and why. The
# header lists every override, so a reader of the expectations sees them without
# opening another file. The tracked file holds no rows until something moves,
# and an empty one changes nothing: the output is byte-identical without it.
#
# AN OVERRIDE MOVES A MEASURED VALUE AND NEVER A DECLARED ONE. A declared
# invariant never comes from a run, so a run that broke it must never be able to
# write its own result in as the expectation. The two classes, in full, and
# every refusal below quotes them:
#
#   (a) DECLARED, and REFUSED -- every row whose value the case's own
#       declaration fixes rather than a run:
#         on a nominal case:    `rc`, `run.frames`, every `faults.<kind>` eq 0,
#                               `session.other_slots_changed`,
#                               `session.readonly_changed`;
#         on a refusal case and
#         on a control case:    `outcome` and `rc`;
#         on EVERY adapter case, nominal or not:
#                               `adapter.second_release`. It is the harness
#                               declaring what the registry must do with an id,
#                               and a run that answers otherwise has FAILED.
#   (b) MEASURED, and ALLOWED with a revision and a reason -- values a run
#       produces rather than the declaration:
#         coverage counts;
#         measured route counts: `adapter.ids_allocated`,
#                                `adapter.ids_released_once`;
#         a control's first-failure text -- `adapter.session_failed`, which
#         names WHERE a session was refused, is the same kind of fact -- and its
#         raised-kind set;
#         a refusal case's `ended` message, while that case's `outcome` and `rc`
#         stay declared and refused.
#
# Each row carries which class it is in, set where the row is MADE, by the code
# that knows where the value came from -- not guessed afterwards from its name.
# A row made without one is refused rather than allowed: a new key may not
# become overridable by nobody having thought about it.
#
# Each of these is refused by name, because each is a different mistake:
#
#   * no revision, or no reason, or a reason that is only whitespace -- the row
#     would be a bare number nobody can review;
#   * a revision that is not an abbreviated or full hex commit id, or one that
#     names no commit in this repository. BOTH ARE CHECKED HERE, WHEN THE
#     EXPECTATION IS GENERATED, not when it is run: `run@REVISION` is evidence
#     only if the revision can be looked up, and a branch, a tag or `HEAD` names
#     something that moves, which records nothing at all;
#   * a key the named case does not assert, or the same case and key twice;
#   * a value equal to the one it replaces: it moves nothing, and it is a row a
#     review cannot read as a change;
#   * a row still `TBD`: a first value comes from a run through --fills, and an
#     override is for a value that already stands and no longer does;
#   * a `gt0` row, which compares no value, so there is nothing to move;
#   * A ROW OF CLASS (a). For a fault row that is the sharpest case: a case that
#     asserts a kind stays at 0 and raises it instead has FAILED, and overriding
#     the row would write the fault the run raised in as the expectation --
#     exactly the vacuity this layer exists to prevent, and the reason the
#     zeroes come from the declaration and not from a run in the first place;
#   * A COUNT THAT IS NOT A DECIMAL INTEGER, OR ONE BELOW ZERO, in either kind
#     of movable count -- the coverage counts, and the measured route counts
#     `adapter.ids_allocated` and `adapter.ids_released_once`. ONE strict form
#     serves both, because `Integer()` takes `1_0` and ` 5`, which no record can
#     ever equal; and no run reports fewer than none of anything;
#   * A COVERAGE VALUE NUMERICALLY EQUAL TO 0 -- `0`, `00` and ` 0` alike, so
#     that none of them walks past the zero refusal by being spelled
#     differently. A coverage count must be strictly above zero; a measured
#     route count may be 0, because zero released once is a legitimate
#     measurement while zero coverage is the constant nothing can move. A count
#     the new code never increments becomes an exactly-asserted constant nothing
#     can ever move -- the vacuous comparison 0009's context records at 44a7d4b,
#     where a deletion left the output identical because the cells already held
#     the written value. Such a count is DROPPED from COVERAGE below, in a
#     reviewed diff carrying the written reason, and replaced by counts the new
#     code does produce. It is not overridden to the constant. The drop lives in
#     COVERAGE rather than in a file of its own because COVERAGE is where the
#     list is declared: a second file would restate it and could then disagree
#     with it.
#
# GENERATING AN EXPECTATION NEEDS A GIT CHECKOUT; RUNNING ONE DOES NOT. The two
# halves have different requirements, and the revision check is why: looking a
# commit up needs the repository's history, so this generator must run inside a
# checkout. run.rb needs none of that -- it judges a result record against the
# tracked expect/frame.tsv, where the revision is only a label in the origin
# column. A verification line working from an archive can therefore run every
# case; it just cannot regenerate the expectations there.
#
# IT FAILS LOUDLY, NAMING THE PROBLEM, RATHER THAN WRITING A WEAKER FILE:
#
#   * an id some matrix row is judged against that gets no rows -- that case
#     would otherwise pass vacuously, asserting nothing;
#   * a fills row whose key this file did not write as `TBD`, a fills row for a
#     key the named case does not assert, or the same case and key twice in the
#     fills file. A `TBD` no fills row covers is REPORTED, with the count and
#     the rows, rather than refused: an expectation may legitimately be
#     generated before the run that fills it, and run.rb fails that case anyway
#     because no record holds the string `TBD`;
#   * an overrides row that breaks one of the rules above, each refused by its
#     own name;
#   * a control with no row in frame-controls.tsv;
#   * a key with no row in keys.tsv for the case's route, which would be a key
#     the lane does not declare;
#   * a pin that does not parse whole, or that lacks a key this file must take
#     from it, or whose nominal raises a fault, or whose frame count differs
#     from the matrix's;
#   * a control named differently by the matrix and by the pin it claims.
#
# The rows are sorted by case id and then by key, so a regeneration diffs
# cleanly and a review reads a case's assertions together.

require_relative "report_keys"

CASES = "tests/doom-core/cases/frame.tsv".freeze
CONTROLS = "tests/doom-core/expect/frame-controls.tsv".freeze
KEYS = "tests/doom-core/expect/keys.tsv".freeze
OUT = "tests/doom-core/expect/frame.tsv".freeze
OVERRIDES = "tests/doom-core/expect/frame-overrides.tsv".freeze

CASE_COLUMNS = %w[case_id lane route mode control demo frames variant requires judged_against tiers origin].freeze
PINS_COLUMNS = %w[#route mode control frames line run text expected].freeze
CONTROL_COLUMNS = %w[#control kind first collateral line why].freeze
KEY_COLUMNS = %w[#route key type dynamic family stage1 reason].freeze
FILL_COLUMNS = %w[#case_id key value from].freeze
OVERRIDE_COLUMNS = %w[#case_id key value revision reason].freeze

TBD = "TBD".freeze
NONE = "-".freeze

# The coverage a nominal case asserts exactly (0009 item 2). Every one of them
# is a count of work the run did: a port that stopped drawing, stopped pushing
# or stopped comparing moves one of these, and the nominal fails.
#
# A COUNT THE PORT NO LONGER PRODUCES COMES OUT OF THIS LIST, in a reviewed diff
# saying why, together with the counts that replace it. It is not overridden to
# 0 -- nor to `00`, nor to ` 0`: a count fixed at a constant no regression can
# move asserts nothing, and refuse_override refuses every spelling of zero, by
# the number the value parses to, rather than writing the row.
#
# `planes.sky_columns` IS HERE AND `planes.sky_planes_with_columns` IS NOT, and
# the difference is what a defect in the port can move. `sky_columns` is the
# walk's own range of wall jobs: measured at 600 frames on the ruby route it is
# 1296 on the nominal and 0 under sky-skip and under planes-bound-short, both of
# which ran all 600 frames, so neither zero is a truncation. Its neighbour counts
# a property of DEMO1 IN THE ORIGINAL -- how many of the original's sky planes
# pushed a column -- and stayed at 28 on all three runs; no defect in the port
# can move it, so asserting it would assert the demo. It stays in the record and
# in keys.tsv, marked `recorded` there, and it is not coverage.
# `planes.compared` IS NOT HERE. It counted the per-plane comparison the whole
# walk replaced at 94804d4, and nothing increments it any more. Asserting it
# exactly would assert a constant no regression could move, which is the
# vacuous comparison 0009's context records at 44a7d4b -- so it is dropped
# rather than asserted at 0, and the inventory records it as produced and not
# asserted. The counts the walk does produce stand in its place.
#
# `planes.sky_planes_recognized` IS THE PORT-SIDE COUNT THAT STANDS THERE. It is
# what `dc_draw_planes` answers -- the planes ITS walk matched against the sky
# flat -- summed over the run, so a port that stops recognizing the sky moves it
# while `planes.sky`, the same planes counted in the original's records, stays
# put. It is recognized and not drawn: a count of the sky planes the port pushed
# columns for would need either a contract change or the per-plane walk back, and
# is not this key.
#
# ITS DETECTION EVIDENCE IS A FULL RUN, not a truncation. Measured at 600 frames
# on the ruby route: 63 on the nominal and 0 under sky-skip, which hands the walk
# a sky flat number no plane has; both records carry `run.frames` 600, so the
# zero is the walk recognizing nothing and not a run that ended early.
COVERAGE = %w[pushes.wall pushes.masked pushes.marks pushes.checks planes.drawn planes.sky
              planes.spans_emitted planes.sky_columns planes.sky_planes_recognized planes.sentinels
              planes.clears checks.slots_compared exec.runs exec.jobs exec.fuzz_columns exec.screens
              furniture.screens_end leaves.pangle leaves.pdist leaves.sgscale leaves.lindex
              leaves.absang leaves.clipv leaves.segside leaves.fplane leaves.chplane leaves.ssclear
              leaves.crunch leaves.new_planes.fplane leaves.new_planes.chplane leaves.chkbbox
              leaves.vssort leaves.addspr leaves.new_vissprites copy.mobj_alloc_max copy.mobj_cells
              copy.sector_cells leaves.segloop segloop.columns].freeze

# THE COVERAGE COUNTS NO FROZEN PIN CAN CARRY. The pins are tick.sh at e2f5676,
# whose port had no sky column to count, no walk to answer how many planes it
# recognized as sky, and whose `frame planes:` line therefore names none of these
# counters; the plane walk added the sky columns at 94804d4 and the recognized
# count stands where `planes.compared` was dropped. A pin is never edited, so a
# pin-origin nominal cannot take these values from its pin -- there is none to
# take -- and each row is written `TBD` with origin `run`, to be filled from a
# record through --fills like every other value no pin asserts.
#
# THEY ARE NOT OVERRIDES. An override moves a value that already stands on a pin
# and no longer does; these values never stood on one. A name here that the pin
# DOES carry is refused, so the list cannot quietly turn a pinned value into a
# filled one.
#
# `leaves.*` came at 6fe29a9: how often each renderer leaf ran beside the
# original, which is how many comparisons its zero leaf-disagree stands on, and
# how many find_plane and check_plane calls made a new plane, where
# clear_plane_top wrote. A lane that stopped mirroring a leaf moves its count.
# `copy.mobj_*` came at c17d87e: the high-water mark the things' copy ran to and
# the cells it wrote, so a copy that ran to the wrong bound, or stopped, moves.
#
# `furniture.screens_end` came at 12e8db4, with the status bar and the HUD drawn
# on both sides: how many frames the whole screen was compared at the end of,
# after the furniture. A lane that stops drawing the furniture or stops making
# that comparison moves it, and its zero faults would otherwise still pass.
AFTER_THE_PINS = (%w[planes.sky_columns planes.sky_planes_recognized furniture.screens_end] +
                  %w[leaves.pangle leaves.pdist leaves.sgscale leaves.lindex leaves.absang
                     leaves.clipv leaves.segside leaves.fplane leaves.chplane leaves.ssclear
                     leaves.crunch leaves.new_planes.fplane leaves.new_planes.chplane leaves.chkbbox
                     leaves.vssort leaves.addspr leaves.new_vissprites copy.mobj_alloc_max
                     copy.mobj_cells copy.sector_cells leaves.segloop segloop.columns]).freeze

FRAMES_KEY = "run.frames".freeze
# The run prints which demo it played (source-port.rb's `demo` line), so a case
# asserts it: a runner that stopped passing the matrix's demo would otherwise
# pass on DEMO1, the port's default, whatever the matrix said.
DEMO_KEY = "run.demo".freeze

# Class (b)'s measured route counts: the movable rows whose value is a COUNT
# rather than text. They sit beside COVERAGE because the two lists are what
# refuse_count_value distinguishes, and they differ in exactly one way -- a
# coverage count must be strictly above zero, and one of these may be 0, because
# zero ids released once is a legitimate measurement of a run that leaked them
# all, while a coverage count fixed at zero is the constant nothing can move.
MEASURED_COUNTS = %w[adapter.ids_allocated adapter.ids_released_once].freeze

# A decimal integer and nothing else, for EVERY movable count. `Integer()` would
# take `1_0` and ` 5`, which no record can ever equal, so that failure belongs
# here rather than in a run nobody was watching. Leading zeros stay admissible,
# so `00` reaches the coverage zero refusal by the number it parses to and not
# by how it is spelled; the sign is admitted here and refused below, so that a
# negative is named as a negative rather than as a malformed number.
DECIMAL = /\A-?[0-9]+\z/.freeze

# WHAT A NOMINAL MEANS BESIDES ITS ZEROED FAULTS AND ITS COVERAGE.
#
# A completed run with every fault kind 0 and `rc` 1 passed the reduced stage 1
# expectation, and on the adapter route that is precisely an id leak: the run
# compares every frame correctly, then fails to release an id, prints the leak
# and exits 1 -- and the lane called it green. These rows close that.
#
#   rc                             every nominal, every route: a nominal run
#                                  ends clean, and rc is what says so.
#   session.other_slots_changed    the session route: the run wrote only the
#   session.readonly_changed       slots its field map names, and moved nothing
#                                  the layout marks read-only.
#   adapter.ids_allocated          the adapter route: every id the adapter took
#   adapter.ids_released_once      was released exactly once, and a second
#   adapter.second_release         release of any of them is refused.
#
# THE TWO ID COUNTS ARE ASSERTED AS VALUES, NOT AGAINST EACH OTHER. The
# invariant is `ids_released_once == ids_allocated`, and run.rb's three rules --
# eq, gt0, set -- compare a row against ONE key of the record and none of them
# compares two keys. Asserting both counts exactly is what the surrounding file
# already does for every coverage count, needs no fourth rule and no new kind of
# judgement, and is strictly the tighter check: a release that goes missing
# moves `ids_released_once` away from the pinned count and fails, and so does an
# allocation count that changed without anyone saying why.
#
# A value of `nil` here is one only a run can give. Every other value is what
# the word `nominal` itself fixes, so it is asserted even where no pin covers
# the case -- and where a pin does cover it, the pin must agree or it is not a
# nominal pin.
#
# That `nil` is also exactly the override classes' line on this route: a value
# the declaration fixes is class (a), declared and refused, and the two id
# counts, which only a run can give, are class (b)'s measured route counts.
NOMINAL_INVARIANTS = {
  "*" => { "rc" => "0" },
  "session" => { "session.other_slots_changed" => "0", "session.readonly_changed" => "0" },
  "adapter" => { "adapter.ids_allocated" => nil, "adapter.ids_released_once" => nil,
                 "adapter.second_release" => "refused" }
}.freeze

def nominal_invariants(kase)
  NOMINAL_INVARIANTS.fetch("*").merge(NOMINAL_INVARIANTS.fetch(kase["route"], {}))
end

# `faults.raised` is the one key the inventory cannot hold a row for: run.rb
# DERIVES it from the record's `faults.*` counts rather than reading it from a
# line, so it is checked against the inventory kind by kind instead.
RAISED = "faults.raised".freeze

# The two override classes, written once and quoted by every refusal of the
# override path, by the generated file's override listing and by
# frame-overrides.tsv's own header, so that a reader of any one of them reads
# the same rule rather than three restatements that could drift apart.
CLASSES = "An override may move only a MEASURED value, class (b): a coverage count; a measured route " \
          "count -- adapter.ids_allocated, adapter.ids_released_once; a control's first-failure text, " \
          "adapter.session_failed among them, or its raised-kind set; a refusal case's `ended` message, " \
          "while that case's `outcome` and `rc` stay declared and refused. It may never move a DECLARED " \
          "value, class (a) -- one the case's own declaration fixes rather than a run: on a nominal " \
          "case, `rc`, `run.frames`, every `faults.<kind>` eq 0, `session.other_slots_changed` and " \
          "`session.readonly_changed`; on a refusal case and on a control case, `outcome` and `rc`; and " \
          "adapter.second_release on every adapter case, nominal or not. A declared invariant never " \
          "comes from a run, so a run that broke one cannot write its own result in as the " \
          "expectation.".freeze

# The `revision` column holds an abbreviated or full hex commit id. A branch, a
# tag and `HEAD` all move, and an origin that moves records nothing.
REVISION = /\A[0-9a-f]{7,40}\z/.freeze

# The cases no pin covers, with the keys each one needs and why it needs them.
# The matrix declares their intent in prose, in its origin column; this is that
# intent as keys. A value here is one the case's own declaration fixes; every
# other value is filled from a first run.
#
# The fourth column of each row is its override class: `true` for class (a),
# declared, and `false` for class (b), measured. It is written here, beside the
# key, because this is where a reader can see which of the two the case means --
# `outcome` is what the case declares the run to be, and the id counts are what
# the run reports.
NEW = {
  "frame.session.none.60.fields-wrongslot" => {
    why: "the frame lane's only case reaching slot-disagree: the session is handed a field map " \
         "with one wrong slot, and the run must see the disagreement rather than the value",
    rows: [["faults.slot-disagree", "gt0", nil, false],
           ["first.slot-disagree", "eq", TBD, false]]
  },
  # MEASURED, so the next reader need not rediscover it: the adapter prints its
  # id line after a FAILED session too -- `release_all` runs outside the failure
  # branch -- so asserting the three id keys here ends as pass or fail, never as
  # run.rb's "the expectation names a key the record does not carry" error.
  "frame.adapter.push-kind.60" => {
    why: "the refused step ends the session: no further invoke, no poisoned buffer read, " \
         "every id released once, rc=1",
    # What the session did is pinned, on this route, by the check the matrix
    # retires as a route duplicate: it is still the record of what the adapter
    # did with this control. Its session ends in frame 0, so the 60-frame case
    # sees what the 200-frame one saw, and the step-4 run confirms it.
    pin: %w[adapter push-kind],
    # `outcome` is class (a): the case declares the run to be one that completes
    # rather than one that is refused. The two id counts are class (b): they are
    # what the run reports. `adapter.second_release` is class (a) HERE AS ON A
    # NOMINAL -- see the note on the untracked-result case below.
    rows: [["outcome", "eq", "completed", true],
           ["adapter.ids_allocated", "eq", TBD, false],
           ["adapter.ids_released_once", "eq", TBD, false],
           ["adapter.second_release", "eq", TBD, true]]
  },
  "frame.adapter.none.60.untracked-result" => {
    why: "the result cell is allocated and never tracked, so a second release is accepted " \
         "and the run fails, and one id is never released at all",
    # The id counts are what make the leak legible: a second release accepted
    # says an id was released twice, and only the counts say that one was never
    # released. Both are asserted, because a lane that lost track of an id
    # would move the released count and could leave the rest as it was. They are
    # class (b), the route's measured counts, on this case as on a nominal.
    #
    # `adapter.second_release` IS CLASS (a) ON EVERY ADAPTER CASE, not only on a
    # nominal. It is the harness declaring what the registry must do with an id:
    # refuse a second release of a tracked one, and -- here, where the result
    # cell is never tracked -- accept it, which is the whole of what this case
    # exists to show. A run that answers otherwise has FAILED; it is not
    # evidence about the expectation, and overriding the row would write the
    # broken registry's answer in as the rule.
    rows: [["adapter.second_release", "eq", TBD, true],
           ["adapter.ids_allocated", "eq", TBD, false],
           ["adapter.ids_released_once", "eq", TBD, false],
           ["rc", "eq", "1", true]]
  }
}.freeze

# `declared` is the row's override class: true for class (a), which refuse_override
# refuses, and false for class (b), which it may move. Every producer sets it,
# and check_classified refuses a row that left it unset, so a key added later
# cannot become overridable by nobody having decided which class it is in.
Row = Struct.new(:case_id, :key, :rule, :value, :origin, :declared)

def fail_with(message)
  abort("expect.rb: #{message}")
end

# --- the inputs --------------------------------------------------------------

# A TSV of this layer: "#" lines are the file's own header, except the one that
# names the columns, which is checked rather than read by position.
#
# `allow_empty` is for the overrides file alone: every other input here is
# meaningless with no rows, but an overrides file with none is the normal state
# -- nothing has moved off its pin yet -- and must read as no overrides rather
# than as an error.
def read_tsv(path, columns, who, allow_empty: false)
  File.exist?(path) or fail_with("no #{who} at #{path}")
  header = []
  rows = []
  File.readlines(path, chomp: true).each_with_index do |line, i|
    next if line.empty?
    if line.start_with?("#")
      fields = line.split("\t")
      if fields.first == columns.first
        fields == columns or
          fail_with("#{path} has the columns #{fields.join(' ')}, not #{columns.join(' ')}")
      else
        header << line
      end
      next
    end
    fields = line.split("\t", -1)
    fields.length == columns.length or
      fail_with("#{path}:#{i + 1} has #{fields.length} fields, not #{columns.length}")
    rows << fields
  end
  rows.empty? && !allow_empty and fail_with("#{path} holds no rows")
  [header, rows]
end

def read_cases(path)
  # The matrix's header names the columns without a leading "#" on the first
  # one, so it is read with the same rule as the rest of the layer.
  _header, rows = read_tsv(path, ["#" + CASE_COLUMNS.first] + CASE_COLUMNS[1..], "case matrix")
  rows.map { |r| CASE_COLUMNS.zip(r).to_h }
end

def read_controls(path)
  _header, rows = read_tsv(path, CONTROL_COLUMNS, "control table")
  rows.to_h { |control, kind, first, collateral, line, _why| [control, [kind, first, collateral, line]] }
end

# route -> the keys that route declares.
def read_keys(path)
  _header, rows = read_tsv(path, KEY_COLUMNS, "key inventory")
  index = Hash.new { |h, k| h[k] = {} }
  rows.each { |route, key, *| index[route][key] = true }
  index
end

# The fills: [case_id, key] -> [value, from]. Their ORDER is kept, so that a
# message about one of them can say where in the file it sits.
def read_fills(path)
  _header, rows = read_tsv(path, FILL_COLUMNS, "fills file")
  fills = {}
  rows.each do |case_id, key, value, from|
    at = "#{path}: the row #{case_id} #{key}"
    value.empty? and fail_with("#{at} fills nothing: its value column is empty")
    value == TBD and fail_with("#{at} fills #{TBD} with #{TBD}")
    (from.empty? || from == NONE) and
      fail_with("#{at} names no record it came from; the `from` column is how a review traces the value back " \
                "to the run that produced it, and a fill without one is a hand-written value")
    fills.key?([case_id, key]) and
      fail_with("#{at} appears twice, and the two rows could fill the same #{TBD} with different values; " \
                "harness/fills.rb writes one row per #{TBD}")
    fills[[case_id, key]] = [value, from]
  end
  fills
end

# Does the repository hold this commit? The argument has already matched
# REVISION, so it carries nothing a shell could read even if one were involved;
# git is run directly, with no shell at all.
def commit?(revision)
  system("git", "cat-file", "-e", "#{revision}^{commit}", out: File::NULL, err: File::NULL)
end

# The overrides: [case_id, key] -> [value, revision, reason]. Each row says that
# a value no longer stands on its pin, WHICH commit moved it, and WHY. The
# refusals here are about the row as written -- including BOTH revision checks,
# which therefore happen when the expectation is GENERATED, not when it is run;
# refuse_override refuses the ones that are about the row it lands on.
def read_overrides(path) # rubocop:disable Metrics/MethodLength
  _header, rows = read_tsv(path, OVERRIDE_COLUMNS, "overrides file", allow_empty: true)
  overrides = {}
  rows.each do |case_id, key, value, revision, reason|
    at = "#{path}: the row #{case_id} #{key}"
    value.empty? and fail_with("#{at} overrides nothing: its value column is empty. #{CLASSES}")
    (revision.empty? || revision == NONE) and
      fail_with("#{at} names no revision; the `revision` column is the commit that moved the value, " \
                "and an override without one says a value changed without saying when or in what. #{CLASSES}")
    REVISION.match?(revision) or
      fail_with("#{at} names the revision #{revision.inspect}, which is not a commit id: the `revision` " \
                "column holds an abbreviated or full hex id, #{REVISION.inspect}. A branch, a tag and " \
                "`HEAD` all move, and an origin that moves records nothing. #{CLASSES}")
    commit?(revision) or
      fail_with("#{at} names the revision #{revision}, which is not a commit in this repository: " \
                "`git cat-file -e #{revision}^{commit}` failed. `run@REVISION` is evidence only if the " \
                "revision can be looked up, so it is checked HERE, where the expectation is generated, " \
                "and not when it is run. #{CLASSES}")
    reason.strip.empty? and
      fail_with("#{at} gives no reason; the `reason` column names the port change in words, and it is " \
                "the whole of what a review of this row reads. A number with no reason is not " \
                "reviewable. #{CLASSES}")
    overrides.key?([case_id, key]) and
      fail_with("#{at} appears twice, and the two rows could move the same value to different places; " \
                "one row per value that moved. #{CLASSES}")
    overrides[[case_id, key]] = [value, revision, reason]
  end
  overrides
end

# The pins, and the revision and blob they were taken at.
def read_pins(path)
  header, rows = read_tsv(path, PINS_COLUMNS, "pins file")
  revision = header.grep(/\A# revision\t/).first&.split("\t")&.at(1) or
    fail_with("#{path} names no revision; it was not written by harness/pins.rb")
  by_line = {}
  rows.each do |row|
    line = row[4]
    by_line.key?(line) and fail_with("#{path} holds two pins for tick.sh:#{line}")
    by_line[line] = row
  end
  [header, by_line, revision]
end

# --- the matrix's origins ----------------------------------------------------

# origin -> [tick.sh line, part] for a row that claims a pin, nil for a new one.
# A composite pin joins several runs, and a claiming row names which part it is.
def claimed(origin, revision)
  rev = Regexp.escape(revision)
  case origin
  when /\Atick:(\d+)@#{rev}\z/ then [Regexp.last_match(1), nil]
  when /\Atick:(\d+)@#{rev} part (\d+)\z/ then [Regexp.last_match(1), Regexp.last_match(2).to_i]
  end
end

def retired?(kase)
  kase["tiers"].split(",").include?("retired")
end

# --- the pins, read as keys --------------------------------------------------

# One pin's keys. A pin that does not parse WHOLE stops the generator: the
# unclaimed line may be the one holding the value about to be asserted, and a
# partial parse would quietly assert the rest.
def pin_keys(pin)
  route, _mode, control, _frames, line, _run, _text, expected = pin
  keys, unparsed = ReportKeys.pin(expected)
  unparsed.empty? or
    fail_with("the #{route} #{control} pin at tick.sh:#{line} has #{unparsed.length} line(s) " \
              "no rule claims: #{unparsed.join(' / ')}")
  keys
end

# The pin a row claims must be about the run the row declares. A control renamed
# on one side and not the other would otherwise take its values from another
# control's pin.
def pin_for(kase, line, pins)
  pin = pins[line] or
    fail_with("#{kase['case_id']}: claims the pin at tick.sh:#{line}, where the extractor found none")
  pin[2] == kase["control"] or
    fail_with("#{kase['case_id']}: the pin at tick.sh:#{line} is the #{pin[2]} pin, and the matrix " \
              "row says #{kase['control']}")
  pin
end

def pin_value(keys, key, kase, line)
  keys.key?(key) or
    fail_with("#{kase['case_id']}: the pin at tick.sh:#{line} has no #{key}, which this case asserts")
  keys[key]
end

# --- the three kinds of case -------------------------------------------------

# Every fault kind equal to 0, the coverage counts exactly, and the frame count.
def nominal_rows(kase, line, ctx)
  id = kase["case_id"]
  return nominal_declared(kase, ctx) unless line

  pin = pin_for(kase, line, ctx[:pins])
  keys = pin_keys(pin)
  kinds = keys.keys.grep(/\Afaults\.(.+)\z/) { Regexp.last_match(1) }.sort
  kinds.empty? and fail_with("#{id}: the nominal pin at tick.sh:#{line} raises no faults line at all")
  frames = pin_value(keys, FRAMES_KEY, kase, line)
  frames.to_s == kase["frames"] or
    fail_with("#{id}: the pin at tick.sh:#{line} ran #{frames} frames, and the matrix row says #{kase['frames']}")

  rows = kinds.map do |kind|
    count = keys["faults.#{kind}"]
    count.zero? or
      fail_with("#{id}: the nominal pin at tick.sh:#{line} raises #{kind} #{count} times; a nominal " \
                "case asserts every kind equal to 0, and this pin is not a nominal one")
    Row.new(id, "faults.#{kind}", "eq", "0", "pin", true)
  end
  # THE KINDS THE PORT GAINED AFTER THE PINS. A pin cannot name them, so taking
  # the kinds from the pin alone left them unasserted: a nominal passed with no
  # row about the recording, the furniture's status or the end-of-frame screen.
  # They are the route's declared kinds the pin lacks, and a nominal asserts them
  # 0 for the same reason it asserts any kind 0 -- the declaration, not a run.
  declared = ctx[:keys].fetch(kase["route"], {}).keys.grep(/\Afaults\.(.+)\z/) { Regexp.last_match(1) }
  (declared - kinds).sort.each { |kind| rows << Row.new(id, "faults.#{kind}", "eq", "0", "run", true) }
  COVERAGE.each do |key|
    # A coverage count the port gained after the frozen revision waits for a run
    # here, exactly as it does on a case with no pin at all; every other one
    # comes out of the pin.
    if AFTER_THE_PINS.include?(key)
      keys.key?(key) &&
        fail_with("#{id}: #{key} is in AFTER_THE_PINS and the pin at tick.sh:#{line} carries it; " \
                  "a key a frozen pin asserts takes its value from the pin, not from a run")
      rows << Row.new(id, key, "eq", TBD, "run", false)
      next
    end
    rows << Row.new(id, key, "eq", pin_value(keys, key, kase, line).to_s, "pin", false)
  end
  rows << Row.new(id, FRAMES_KEY, "eq", frames.to_s, "pin", true)
  # The demo the case declares is the demo the run says it played.
  rows << Row.new(id, DEMO_KEY, "eq", kase["demo"], "run", true)
  nominal_invariants(kase).each do |key, declared|
    value = pin_value(keys, key, kase, line).to_s
    declared.nil? || value == declared or
      fail_with("#{id}: the nominal pin at tick.sh:#{line} has #{key} #{value}, and a nominal case asserts " \
                "#{key} #{declared}; this pin is not a nominal one")
    # A value the word `nominal` fixes is class (a); the two id counts, which
    # only a run can give, are class (b). The pin supplies the number either
    # way, and does not change which class the row is in.
    rows << Row.new(id, key, "eq", value, "pin", !declared.nil?)
  end
  rows
end

# A nominal with no pin. Its fault kinds are the route's declared ones -- the
# inventory is where a run of that route gets them too -- and every one of them
# is 0 and its frame count is the matrix's, because that is what the case
# DECLARES; only the coverage counts wait for a run. The origin stays `run`:
# these values are not pin-derived, and the first run must still produce them.
def nominal_declared(kase, ctx)
  id = kase["case_id"]
  route = kase["route"]
  kinds = ctx[:keys].fetch(route, {}).keys.grep(/\Afaults\.(.+)\z/) { Regexp.last_match(1) }.sort
  kinds.empty? and fail_with("#{id}: the #{route} route declares no fault kinds in the key inventory")
  rows = kinds.map { |kind| Row.new(id, "faults.#{kind}", "eq", "0", "run", true) }
  COVERAGE.each { |key| rows << Row.new(id, key, "eq", TBD, "run", false) }
  rows << Row.new(id, FRAMES_KEY, "eq", kase["frames"], "run", true)
  rows << Row.new(id, DEMO_KEY, "eq", kase["demo"], "run", true)
  # The route's nominal invariants. The ones the word `nominal` fixes are
  # written as values for the same reason the fault zeros are: taking `rc` or a
  # release count from a first run would let a run that leaked an id write its
  # own leak in as the expectation. Only the two id counts, which nobody can
  # declare in advance, wait for the run.
  nominal_invariants(kase).each do |key, declared|
    rows << Row.new(id, key, "eq", declared || TBD, "run", !declared.nil?)
  end
  rows
end

# The intended kind above zero, its first failure, and the set of kinds raised.
def control_rows(kase, line, ctx)
  id = kase["case_id"]
  control = kase["control"]
  kind, first, collateral, control_line = ctx[:controls][control] ||
    fail_with("#{id}: the control #{control} has no row in #{ctx[:controls_path]}; its intended " \
              "fault kind and first failure are declared there and nowhere else")
  pin_for(kase, line, ctx[:pins])
  control_line == line or
    fail_with("#{id}: the matrix claims the pin at tick.sh:#{line} and #{ctx[:controls_path]} took " \
              "#{control}'s values from tick.sh:#{control_line}")
  raised = ([kind] + (collateral == NONE ? [] : collateral.split(","))).sort
  # A control's first failure and its raised set are class (b): what the control
  # detects is measured, and a port change can legitimately move where it first
  # fails or which collateral kinds come with it.
  [Row.new(id, "faults.#{kind}", "gt0", NONE, "pin", false),
   Row.new(id, "first.#{kind}", "eq", first, "pin", false),
   Row.new(id, RAISED, "set", raised.join(","), "pin", false)]
end

# A CONTROL CASE WHOSE CONTROL HAS NO PIN. Symmetric with nominal_declared
# above, and for the same reason: the control arrived after the frozen revision,
# so no pinned text describes it, and the pins are never edited. The case still
# asserts the three rows every control case asserts, and they still come from
# expect/frame-controls.tsv, which is the one place a control's intent lives --
# hard-coding the four in a table here would restate the control table inside
# this file, where the two could then disagree. What the table cannot give is
# the first-failure text: only a run produces it, so it stays `TBD` and is filled
# through --fills like any other. The origin is `run` throughout, because none of
# the three stands on a pin.
def control_declared(kase, ctx)
  id = kase["case_id"]
  control = kase["control"]
  kind, first, collateral, control_line = ctx[:controls][control] ||
    fail_with("#{id}: the control #{control} has no row in #{ctx[:controls_path]}; its intended " \
              "fault kind and raised set are declared there and nowhere else")
  control_line == NONE or
    fail_with("#{id}: no pin covers it, and #{ctx[:controls_path]} took #{control}'s values from " \
              "tick.sh:#{control_line}; a control with a pin is claimed by its matrix row")
  raised = ([kind] + (collateral == NONE ? [] : collateral.split(","))).sort
  # Class (b) throughout, exactly as on a pinned control: what a control detects
  # and which collateral kinds come with it are measured, not declared.
  [Row.new(id, "faults.#{kind}", "gt0", NONE, "run", false),
   Row.new(id, "first.#{kind}", "eq", first, "run", false),
   Row.new(id, RAISED, "set", raised.join(","), "run", false)]
end

# The composite pin joins one refused run's two lines per part: the message the
# run printed and its exit status. The part the row names is the part read, and
# the message must name the row's own control, so a row cannot take another
# refusal's text.
def refusal_rows(kase, line, part, ctx)
  id = kase["case_id"]
  pin = ctx[:pins][line] or
    fail_with("#{id}: claims part #{part} of the pin at tick.sh:#{line}, where the extractor found none")
  pin[0] == "composite" or
    fail_with("#{id}: claims part #{part} of the pin at tick.sh:#{line}, which joins no runs")
  chunks = pin[7].split("|").reject(&:empty?).each_slice(2).to_a
  parts = pin[3].to_i
  chunks.length == parts && chunks.all? { |c| c.length == 2 } or
    fail_with("#{id}: the composite pin at tick.sh:#{line} names #{parts} runs and holds " \
              "#{pin[7].split('|').reject(&:empty?).length} lines; each refused run prints a message and rc")
  part.between?(1, parts) or
    fail_with("#{id}: claims part #{part} of the composite pin at tick.sh:#{line}, which has #{parts} parts")
  message, rc_line = chunks[part - 1]
  keys, unparsed = ReportKeys.parse([message, rc_line].join("\n"))
  unparsed.empty? or
    fail_with("#{id}: part #{part} of the composite pin at tick.sh:#{line} has line(s) no rule " \
              "claims: #{unparsed.join(' / ')}")
  refusal = keys["refusal"] or
    fail_with("#{id}: part #{part} of the composite pin at tick.sh:#{line} is not a refusal: #{message}")
  rc = keys["rc"] or
    fail_with("#{id}: part #{part} of the composite pin at tick.sh:#{line} names no exit status")
  refusal.start_with?("#{kase['control']} ") or
    fail_with("#{id}: part #{part} of the composite pin at tick.sh:#{line} refuses #{refusal.split.first}, " \
              "and the matrix row says #{kase['control']}")
  # `ended` is the abort's whole message, prefix and all: that is what
  # source-port.rb's record carries, and the pin's line is that same text.
  # `outcome` and `rc` are class (a): a refusal case IS a refused run ending 1,
  # which is what the case declares itself to be. The message it printed is
  # class (b) -- text a port change may legitimately reword.
  [Row.new(id, "outcome", "eq", "refused", "pin", true),
   Row.new(id, "rc", "eq", rc.to_s, "pin", true),
   Row.new(id, "ended", "eq", message, "pin", false)]
end

# A case no pin covers: its keys are declared in NEW, with the reason.
def new_rows(kase, ctx)
  id = kase["case_id"]
  entry = NEW[id] or
    fail_with("#{id}: no pin covers it and NEW declares no keys for it, so it would assert nothing")
  rows = entry[:rows].map do |key, rule, value, declared|
    declared.nil? and fail_with("#{id}: NEW declares #{key} without an override class; the fourth column " \
                                "of the row says whether the value is declared (a) or measured (b)")
    Row.new(id, key, rule, rule == "gt0" ? NONE : value, "run", declared)
  end
  entry[:pin] ? pinned_new_rows(id, entry[:pin], ctx) + rows : rows
end

# The rows a new case takes from a frozen pin of its own route and control.
# That pin is retired -- no row claims it -- but it is what that route did, so
# what it says the run raised and where it first failed are pin-derived, not
# waiting on a run.
def pinned_new_rows(id, (route, control), ctx)
  pin = ctx[:pins].values.find { |row| row[0] == route && row[2] == control } or
    fail_with("#{id}: no #{route} pin runs the control #{control}, so its declared pin describes nothing")
  keys, unparsed = ReportKeys.pin(pin[7])
  unparsed.empty? or
    fail_with("#{id}: the #{route} #{control} pin at tick.sh:#{pin[4]} has #{unparsed.length} " \
              "line(s) no rule claims")
  raised = keys.select { |k, v| k.start_with?("faults.") && v.to_i.positive? }
               .keys.map { |k| k.delete_prefix("faults.") }.sort
  raised.empty? and fail_with("#{id}: the #{route} #{control} pin at tick.sh:#{pin[4]} raises nothing")
  intended, = ctx[:controls][control] ||
              fail_with("#{id}: no intended kind is declared for the control #{control}")
  first = keys["first.#{intended}"] ||
          fail_with("#{id}: the #{route} #{control} pin at tick.sh:#{pin[4]} gives #{intended} no first failure")
  # The first failure and the raised set are class (b), as on any control. `rc`
  # is class (a) on a control case. `adapter.session_failed` is CLASS (b) too:
  # it names WHERE the session was refused, which is the same kind of fact as a
  # control's first-failure text, and that site can move for a legitimate reason
  # -- the step the adapter refuses first is a measurement of the port, not
  # something this case declares. What the case does declare is that the step is
  # refused at all and that the run ends 1, and the fault row and `rc` assert
  # that; this row is the measurement of where it happened.
  [Row.new(id, "faults.#{intended}", "gt0", NONE, "pin", false),
   Row.new(id, "first.#{intended}", "eq", first, "pin", false),
   Row.new(id, "faults.raised", "set", raised.join(","), "pin", false),
   Row.new(id, "adapter.session_failed", "eq", keys.fetch("adapter.session_failed"), "pin", false),
   Row.new(id, "rc", "eq", keys.fetch("rc").to_s, "pin", true)]
end

def rows_for(kase, ctx)
  line, part = claimed(kase["origin"], ctx[:revision])
  if part
    refusal_rows(kase, line, part, ctx)
  elsif kase["control"] == "none" && kase["variant"] == NONE
    nominal_rows(kase, line, ctx)
  elsif line
    control_rows(kase, line, ctx)
  elsif kase["control"] != "none" && !NEW.key?(kase["case_id"])
    # NEW STILL WINS: frame.adapter.push-kind.60 runs a control and declares its
    # own keys there, including the lifecycle rows no control table can hold.
    control_declared(kase, ctx)
  else
    new_rows(kase, ctx)
  end
end

# --- the checks over the finished rows ---------------------------------------

# Every key must be one the lane declares for the route, so an expectation can
# never name a key no record of that route carries.
def check_keys(rows, by_case, ctx)
  rows.each do |row|
    route = by_case[row.case_id]["route"]
    declared = ctx[:keys][route]
    if row.key == RAISED
      row.value.split(",").each do |kind|
        declared.key?("faults.#{kind}") or
          fail_with("#{row.case_id}: #{RAISED} names the kind #{kind}, and the #{route} route has no " \
                    "faults.#{kind} row in #{ctx[:keys_path]}")
      end
      next
    end
    declared.key?(row.key) or
      fail_with("#{row.case_id}: asserts #{row.key}, which has no #{route} row in #{ctx[:keys_path]}")
  end
end

# The rows belong to the JUDGING case. A case judged against an id with no rows
# asserts nothing and passes vacuously, which is the failure this catches.
def check_judged(cases, rows)
  judged = rows.map(&:case_id).uniq
  cases.each do |kase|
    next if retired?(kase)
    target = kase["judged_against"]
    judged.include?(target) or
      fail_with("#{kase['case_id']}: judged against #{target}, which gets no expectation rows; " \
                "it would pass while asserting nothing")
  end
  wanted = cases.reject { |k| retired?(k) }.map { |k| k["judged_against"] }.uniq
  (judged - wanted).each do |id|
    fail_with("#{id}: has expectation rows and no case is judged against it")
  end
end

# Substitutes each fills row's value for that key's `TBD`. Every way a fills row
# can fail to be exactly that is refused by name, because each one is a
# different mistake: a key the case does not assert is a stale or mistyped row,
# a key that is not `TBD` is a hand-written value overriding a derived one, and
# the file's own duplicate check is in read_fills. Returns the rows still `TBD`.
def apply_fills(rows, fills, path)
  index = rows.to_h { |r| [[r.case_id, r.key], r] } # check_unique has run: no row is lost here
  cases = rows.map(&:case_id).uniq
  fills.each do |(case_id, key), (value, _from)|
    row = index[[case_id, key]]
    unless row
      fail_with("#{path}: fills #{case_id} #{key}, and " +
                (cases.include?(case_id) ? "#{case_id} asserts no #{key}" : "no case #{case_id} is judged here") +
                "; a fill may only replace a #{TBD} this generator wrote")
    end
    row.value == TBD or
      fail_with("#{path}: fills #{case_id} #{key}, which is not #{TBD}: it holds #{row.value.inspect}, " \
                "derived from the origin `#{row.origin}`. A fill may only replace a #{TBD}, never restate " \
                "or override a value this generator derived")
    row.value = value
  end
  rows.select { |r| r.value == TBD }
end

# Substitutes each override's value for the value that no longer stands, and
# marks the row `run@REVISION`. It runs AFTER the fills, so what an override is
# checked against -- and refused for restating -- is the value the row finally
# holds, not a `TBD` the fills were about to replace. Returns what it applied,
# for the header, as [case_id, key, was, now, revision, reason].
def apply_overrides(rows, overrides, path)
  index = rows.to_h { |r| [[r.case_id, r.key], r] } # check_unique has run: no row is lost here
  cases = rows.map(&:case_id).uniq
  applied = []
  overrides.each do |(case_id, key), (value, revision, reason)|
    row = index[[case_id, key]] ||
          fail_with("#{path}: overrides #{case_id} #{key}, and " +
                    (cases.include?(case_id) ? "#{case_id} asserts no #{key}" : "no case #{case_id} is judged here") +
                    "; an override may only move a value this generator wrote. #{CLASSES}")
    refuse_override(row, value, path, case_id, key)
    applied << [case_id, key, row.value, value, revision, reason]
    row.value = value
    row.origin = "run@#{revision}"
  end
  applied.sort_by { |a| [a[0], a[1]] }
end

# The refusals that are about the ROW an override lands on. Each names itself,
# because each is a different mistake and the fix differs, and each quotes both
# classes, so a reader of any one refusal reads the whole rule.
def refuse_override(row, value, path, case_id, key) # rubocop:disable Metrics/MethodLength
  at = "#{path}: overrides #{case_id} #{key}"
  row.value == TBD and
    fail_with("#{at}, which is still #{TBD}: it has no value yet, so nothing has moved off anything. " \
              "A first value comes from a run through --fills; an override is for a value that stood " \
              "and no longer does. #{CLASSES}")
  row.rule == "gt0" and
    fail_with("#{at}, which is a gt0 row: it compares no value, so there is no value to move. " \
              "The row asserts only that the count is above zero, and that does not change with a " \
              "count. #{CLASSES}")
  refuse_declared(row, at, case_id, key)
  refuse_count_value(row, value, at, key)
  row.value == value and
    fail_with("#{at} to #{value.inspect}, which is already what it holds. An override moves nothing, " \
              "and a review reads a row that changes no value as a claim it cannot check; drop the " \
              "row. #{CLASSES}")
end

# Class (a): the value comes from what the case declares itself to be, so no run
# may move it. The message says nothing about which KIND of case this is -- the
# rule is about the row, and the fault rows of a control case are covered by it
# exactly as a nominal's are.
def refuse_declared(row, at, case_id, key)
  return unless row.declared

  fault = row.key.start_with?("faults.") && row.rule == "eq"
  detail =
    if fault
      "It is #{case_id}'s assertion that the #{key.delete_prefix('faults.')} fault kind stays at " \
      "#{row.value}. A case that raises a kind it asserts stays at 0 has FAILED, not moved: overriding " \
      "the row would write the fault the run raised in as the expectation, which is the vacuity this " \
      "layer exists to prevent."
    else
      "It is #{case_id}'s assertion that the run is the run the case declares, and #{key} is what says so."
    end
  fail_with("#{at}, which is a DECLARED row, class (a): its value comes from the case's own declaration " \
            "and not from a run. #{detail} #{CLASSES}")
end

# EVERY MOVABLE NUMERIC KEY GETS AN INTEGER CHECK, not only the coverage counts.
# Both kinds are read with the one DECIMAL form above, so a value refused as a
# coverage count is refused identically as an id count; base 10 is explicit so
# that a count is read the way a record writes it. THE TWO DIFFER ONLY IN THEIR
# FLOOR: a coverage count must be strictly above zero, and a measured route
# count need only be at least zero. A NEGATIVE IS REFUSED IN BOTH -- no run
# reports fewer than none of anything, so such a value could never equal what a
# record carries, and it would have failed in a run nobody was watching.
#
# A row that is neither kind carries text, not a number, and passes through.
def refuse_count_value(row, value, at, key)
  coverage = COVERAGE.include?(row.key)
  return unless coverage || MEASURED_COUNTS.include?(row.key)

  what = coverage ? "coverage count" : "measured route count"
  DECIMAL.match?(value) or
    fail_with("#{at} to #{value.inspect}, which is not a decimal integer. A #{what} is a " \
              "count of the work the run did, and a record carries it as a base-10 integer with " \
              "no separator and no surrounding space. #{CLASSES}")
  count = Integer(value, 10)
  count.negative? and
    fail_with("#{at} to #{value.inspect}, which is below zero. A #{what} counts what the run did, and " \
              "no run reports fewer than none of anything; a negative can never equal what a record " \
              "carries. #{CLASSES}")
  return unless coverage

  count.zero? and
    fail_with("#{at} to #{value.inspect}, which is zero. A coverage count the new code never increments " \
              "becomes an exactly-asserted constant no regression can ever move, which asserts nothing " \
              "-- the vacuous comparison 0009's context records at 44a7d4b. Such a count is DROPPED, " \
              "not overridden: take #{key} out of COVERAGE in #{__FILE__}, in a diff whose comment says " \
              "why the port stopped producing it, and add the counts the new code does produce. #{CLASSES}")
end

# Every row must say which override class it is in. A producer that adds a key
# and forgets stops the generator here rather than leaving the key silently
# movable: class (a) is the default nowhere, and "nobody decided" is not
# permission.
def check_classified(rows)
  rows.each do |row|
    [true, false].include?(row.declared) or
      fail_with("#{row.case_id}: the row #{row.key} carries no override class; every row says whether " \
                "its value is declared (a), and refused, or measured (b), and movable. #{CLASSES}")
  end
end

def check_unique(rows)
  seen = {}
  rows.each do |row|
    key = [row.case_id, row.key]
    seen.key?(key) and fail_with("#{row.case_id}: asserts #{row.key} twice")
    seen[key] = true
  end
end

# --- output ------------------------------------------------------------------

# The header carries the provenance: the revision and blob the pins came from,
# copied from the pins file's own header, and the tick.sh line each case's
# pinned values were read out of -- once per case, not once per row.
def report(rows, provenance, pins_header, paths, fills, overrides) # rubocop:disable Metrics/ParameterLists
  out = +"# the frame lane's expectations, generated by tests/doom-core/harness/expect.rb\n"
  out << "# from #{paths[:cases]}, #{paths[:controls]} and #{paths[:keys]}\n"
  pins_header.each { |line| out << line << "\n" }
  out << "# rows\t#{rows.length}\n"
  out << "# rows.pin\t#{rows.count { |r| r.origin == 'pin' }}\n"
  out << "# rows.run\t#{rows.count { |r| r.origin == 'run' }}\n"
  out << "# cases\t#{rows.map(&:case_id).uniq.length}\n"
  out << "# a gt0 row compares no value and holds `-`; a TBD value waits for a run, and is filled\n"
  out << "# from that run's record by harness/fills.rb through expect.rb --fills, never by hand.\n"
  if paths[:fills]
    out << "# filled from\t#{paths[:fills]}\n"
    out << "# rows.filled\t#{fills.length}\n"
    out << "# rows.tbd\t#{rows.count { |r| r.value == TBD }}\n"
    fills.values.map(&:last).tally.sort.each { |from, n| out << "# filled from\t#{from}\t#{n}\n" }
  end
  # The overrides are listed HERE, in the expectations themselves, so a reader
  # of this file sees which values no longer stand on a pin without opening
  # another one. Nothing is written when none are applied: an empty overrides
  # file has nothing to list, and the output stays byte-identical without it.
  unless overrides.empty?
    out << "# overridden from\t#{paths[:overrides]}\n"
    out << "# rows.overridden\t#{overrides.length}\n"
    out << "# these values no longer stand on their pin. Each names the revision that moved it and why.\n"
    out << "# Each is a MEASURED value, class (b): a coverage count, a measured route count, a control's\n"
    out << "# first failure or raised set, or a refusal case's message. A DECLARED value, class (a) --\n"
    out << "# a nominal's rc, frame count, fault zeros and session change counts, any adapter case's\n"
    out << "# second release, and a refusal or control case's outcome and rc -- is refused, never\n"
    out << "# overridden.\n"
    overrides.each do |case_id, key, was, now, revision, reason|
      out << "# override\t#{case_id}\t#{key}\t#{was} -> #{now}\trun@#{revision}\t#{reason}\n"
    end
  end
  out << "# where each case's values come from:\n"
  provenance.each { |id, where| out << "# case\t#{id}\t#{where}\n" }
  out << %w[#case_id key rule value origin].join("\t") << "\n"
  rows.each { |r| out << [r.case_id, r.key, r.rule, r.value, r.origin].join("\t") << "\n" }
  out
end

def where_from(kase, ctx)
  line, part = claimed(kase["origin"], ctx[:revision])
  return "tick.sh:#{line} part #{part}" if part
  return "tick.sh:#{line}" if line && kase["control"] == "none"
  return "tick.sh:#{line} through frame-controls.tsv" if line
  # A case no pin covers carries its reason: NEW's where this file declares its
  # keys, and the matrix's own origin prose where the case is a nominal or a
  # control declared in frame-controls.tsv.
  why = NEW.fetch(kase["case_id"], {})[:why] || kase["origin"].sub(/\Anew:\s*/, "")
  return "frame-controls.tsv and a first run; #{why}" if kase["control"] != "none" && !NEW.key?(kase["case_id"])
  "a first run; #{why}"
end

USAGE = "usage: expect.rb --pins PINS.tsv [--cases FILE] [--controls FILE] [--keys FILE] " \
        "[--fills FILE] [--overrides FILE] [--out FILE]".freeze

def main # rubocop:disable Metrics/MethodLength
  paths = { pins: nil, cases: CASES, controls: CONTROLS, keys: KEYS, fills: nil, overrides: nil, out: nil }
  args = ARGV.dup
  until args.empty?
    flag = args.shift
    name = { "--pins" => :pins, "--cases" => :cases, "--controls" => :controls, "--keys" => :keys,
             "--fills" => :fills, "--overrides" => :overrides, "--out" => :out }[flag] || abort(USAGE)
    paths[name] = args.shift or fail_with("#{flag} needs a value")
  end
  paths[:pins] or abort(USAGE)
  # AFTER_THE_PINS says where a COVERAGE count's value comes from; a name in it
  # that is not a coverage count would say it about nothing.
  extra = AFTER_THE_PINS - COVERAGE
  extra.empty? or
    fail_with("AFTER_THE_PINS names #{extra.join(', ')}, which COVERAGE does not; it may only name a " \
              "coverage count whose value no frozen pin can carry")

  pins_header, pins, revision = read_pins(paths[:pins])
  ctx = { pins: pins, revision: revision,
          controls: read_controls(paths[:controls]), controls_path: paths[:controls],
          keys: read_keys(paths[:keys]), keys_path: paths[:keys] }
  cases = read_cases(paths[:cases])

  by_case = {}
  rows = []
  provenance = []
  cases.each do |kase|
    next if retired?(kase)
    next unless kase["judged_against"] == kase["case_id"]
    by_case[kase["case_id"]] = kase
    made = rows_for(kase, ctx)
    made.empty? and fail_with("#{kase['case_id']}: produced no rows")
    rows.concat(made)
    provenance << [kase["case_id"], where_from(kase, ctx)]
  end

  check_judged(cases, rows)
  check_classified(rows)
  check_unique(rows)
  check_keys(rows, by_case, ctx)

  fills = paths[:fills] ? read_fills(paths[:fills]) : {}
  remaining = paths[:fills] ? apply_fills(rows, fills, paths[:fills]) : rows.select { |r| r.value == TBD }

  # After the fills, so an override is checked against the value the row finally
  # holds, and a row still waiting for its first value is refused rather than
  # overridden.
  overrides = paths[:overrides] ? apply_overrides(rows, read_overrides(paths[:overrides]), paths[:overrides]) : []

  rows.sort_by! { |r| [r.case_id, r.key] }
  provenance.sort_by!(&:first)
  text = report(rows, provenance, pins_header, paths, fills, overrides)
  paths[:out] ? File.write(paths[:out], text) : print(text)
  warn("expect.rb: #{rows.length} rows over #{provenance.length} cases " \
       "(#{rows.count { |r| r.origin == 'pin' }} from pins, #{rows.count { |r| r.origin == 'run' }} " \
       "from a run#{", #{fills.length} of those filled from #{paths[:fills]}" if paths[:fills]}, " \
       "#{"#{overrides.length} overridden from #{paths[:overrides]}, " unless overrides.empty?}" \
       "#{remaining.length} still TBD)")
  # Not a refusal: an expectation may legitimately be generated before the run
  # that fills it. But every uncovered row is named, so nobody has to go looking
  # for which ones they are, and run.rb fails such a case anyway -- no record
  # holds the string TBD.
  return if remaining.empty?
  warn("expect.rb: #{remaining.length} row#{'s' if remaining.length > 1} no fills row covers; " \
       "harness/fills.rb writes them from a run's records:")
  remaining.sort_by { |r| [r.case_id, r.key] }.each { |r| warn("expect.rb:   #{r.case_id}\t#{r.key}") }
end

main
