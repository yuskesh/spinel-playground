# tests/doom-core/harness/keys.rb — the frame lane's declared key inventory.
#
#   ruby tests/doom-core/harness/keys.rb --pins PINS.tsv [--cases FILE]
#     [--controls FILE] [--contracts DIR] [--out FILE]
#
# The 0009 stage 1 expectations assert keys, not joined strings. Before a single
# expectation can be written, each route needs a DECLARED KEY SET: the names the
# route's result record may carry, which of them a record may legitimately lack,
# and which of them stage 1 actually asserts. This writes that inventory.
#
# IT TAKES THE PINS AS INPUT, and never runs pins.rb itself. pins.rb reads
# tick.sh at a frozen revision; which revision is the caller's decision, and
# baking a call to it here would hide that decision inside a generator. The
# revision and blob the pins carry are copied into the output, so an inventory
# always names the tick.sh it was derived from.
#
# THE DECLARED KEY SET of a route is the union of three sources:
#
#   1. every key ReportKeys.pin yields from the route's non-composite pins,
#      nominal and control alike -- a control's filtered pin asserts a subset of
#      the report, so the union over all of them is what the route can print;
#   2. `rc`, the exit status tick.sh appends and the record carries as a field;
#   3. the record-only keys, which no printed line carries: `first_at.<kind>`
#      `.frame` and `.tic` for every fault kind THIS route has, and
#      `adapter.session_failed` on the adapter route. The kinds are read out of
#      the route's own `faults.<kind>` keys, so a route that gains or loses a
#      kind changes this inventory by being regenerated, not by being edited;
#   4. the keys a printed line carries that NO FROZEN PIN CAN, because the port
#      gained them after e2f5676 and the pins are never edited -- PLANES_RECORD_ONLY
#      below, with the revision that added them and why.
#
# Composite rows are skipped: that pin joins four runs, and ReportKeys refuses
# it for the reason given there.
#
# DYNAMIC IS A CLAIM ABOUT THE EMITTER, not about the pins. A key is dynamic
# when a legitimate record of that route may lack it -- a mode that does not
# print the line, a session that failed before it, an entry the run never
# reached. That cannot be inferred from the pins, which are all 600-frame frame
# mode, so it comes from the rule table below; each rule carries the short
# reason that goes in the output, so a reader never has to guess why a key may
# be absent. Absence of a non-dynamic key is a defect, and stage 1's checks may
# read it as one.
#
# STAGE1 HAS FOUR VALUES, AND ONLY ONE OF THEM MEANS "NOT ASSERTED":
#
#   asserted  the ordinary row;
#   relaxed   asserted, with no detection evidence behind it -- see below;
#   recorded  RECORDED AND NOT ASSERTED. The record carries the key and stage 1
#             asserts nothing about it, because nothing the port can do moves
#             it. NOT_ASSERTED below is the whole list, each with the reason;
#   retired   a name only the frozen pins can produce, kept because the pin is
#             the record of what the old check asserted. RETIRED below.
#
# STAGE1 SEPARATES ASSERTED FROM RELAXED, AND RELAXED IS NOT UNASSERTED. A
# NOMINAL CASE ASSERTS EVERY FAULT KIND EQUAL TO 0 -- relaxed kinds included.
# That is 0009 item 2, and nothing here weakens it: `relaxed` never removes an
# assertion, and a generated expectation that dropped one would be a defect.
#
# What `relaxed` marks is the OTHER half of the evidence, the half stage 1 does
# not have. A kind is relaxed on a route when no control of the case matrix
# reaches it there: the 0 a nominal asserts is then backed by no run that has
# ever shown the counter moving off 0, so the assertion cannot distinguish a
# port that keeps the kind at 0 from a port that could not raise it at all.
# Every relaxed row's reason says both halves in those words -- asserted eq 0 on
# nominal cases, and no detection evidence -- so the label can never be read as
# permission to stop asserting. It is a gap in sensitivity, not in coverage.
#
# WHICH KINDS ARE REACHED IS DERIVED FROM THE CASE MATRIX, not from the pins.
# Stage 1 runs the lane's controls on the compiled route only, so the old
# all-route control pins no longer say what any route reaches. The matrix is
# therefore an input: for every row an ordinary run selects (a tier in
# RUNNABLE_TIERS -- retired rows run nowhere, and selftest rows are judged
# against a nominal's expectation and assert no count of their own),
#
#   * a control row reaches the kinds frame-controls.tsv says that control
#     raises: its intended kind together with its collateral kinds, which is the
#     same `faults.raised` set the control's expectation asserts;
#   * a row that perturbs the run reaches what VARIANT_KINDS declares for its
#     variant -- the wrong-slot field map is the lane's only case reaching
#     slot-disagree, and it carries no control;
#   * a row claiming a part of the composite REFUSAL pin reaches nothing: the
#     program prints why it will not run the control and exits nonzero before
#     any frame, so that run has no counters at all.
#
# A control the matrix runs and frame-controls.tsv does not describe, and a kind
# a control raises on a route whose records have no key for it, both stop the
# generator: either is a matrix and a control table that have parted company.

require_relative "report_keys"

ROUTES = %w[ruby compiled session adapter].freeze

# The first dotted segment of every key the lane can produce. A key whose family
# is not here is unrecognized, and the inventory refuses to describe it.
FAMILIES = %w[run pushes planes clears checks exec sites remaining native faults
              first first_at session adapter golden furniture copy leaves segloop].freeze
# The record's envelope: how the process ended, the status it left where it
# left one, and the message of an ending that was not a clean finish. No
# printed line carries them, and an expectation may name them, so they are
# declared here with everything else rather than exempted somewhere else.
EXIT_KEYS = { "rc" => "int", "outcome" => "str", "ended" => "str" }.freeze
EXIT_KEY = "rc"
EXIT_FAMILY = "exit"

# The plane counters the port gained after the pins were frozen. Two arrived at
# 94804d4, where the renderer's whole plane walk and the sky plane drawn as
# texture columns did: how many sky columns the walk pushed, and how many sky
# planes pushed at least one. The third is the count of planes THE PORT
# RECOGNIZED AS SKY -- `dc_draw_planes`' own scalar result, summed over the run
# -- which stands where `planes.compared` stood before the whole walk replaced
# the per-plane comparison it counted. It says recognized and not drawn on
# purpose: what the walk hands back is the number of planes whose picnum it
# matched against the sky flat, and a count of the planes it actually drew
# columns for is a different fact this line does not carry.
#
# THE FROZEN PINS CANNOT CARRY THEM, and not because a rule is missing. Source 1
# is the pins, and the pins are tick.sh at e2f5676 -- a revision whose port had
# no sky column to count and whose `frame planes:` line therefore names neither
# counter. The pins are never edited (0009's stage 1 clarification), so a key the
# port gained AFTER them has no pin to be read out of, now or ever, and pin_types
# is the only source of `planes.*` keys. Declaring them here is the same move
# EXIT_KEYS makes above: a key the record carries, that no frozen pin describes,
# is declared rather than inferred. Every case of this lane runs frame mode, and
# the line is printed on every route, so every route declares them.
PLANES_RECORD_ONLY = { "planes.sky_columns" => "int", "planes.sky_planes_with_columns" => "int",
                       "planes.sky_planes_recognized" => "int" }.freeze

# THE RECORDING AND THE FURNITURE, also gained after the pins. e468f73 compared
# the port's screen with the recording (tests/doom-core/fixtures/screens) and
# 12e8db4 drew the status bar and the HUD on both sides and compared the whole
# screen once more at the end of the frame, where the recorder hashes it; the
# boundary copy's skip line came with the batch that declared where each skipped
# copy must first show. Two fault kinds came with them:
#
#   furniture-status   a status bar or HUD entry answering other than 0
#   screen-disagree    the whole screen at the end of the frame
#
# The faults line prints both on every route in frame mode, so every route
# declares them, and a nominal asserts each equal to 0 like any other kind --
# which it could not do while they were missing here: a pin-derived nominal
# takes its kinds from its pin, and no pin has these.
#
# golden-disagree, the port's screen against the recording, is NOT here. The
# faults line prints it only where SOURCE_PORT_GOLDEN names a recording, and no
# case of this lane names one -- run.rb clears the variable -- so a declared
# zero for it would be a row no run could fail. The recording is checked by
# tests/doom-core/screens.sh, over every route and the whole demo.
#
# leaf-disagree came with the renderer's leaves at 6fe29a9: a leaf run beside
# the original at a call answered or wrote otherwise. Printed on every route in
# frame mode, like the other two.
LATER_FAULT_KINDS = %w[furniture-status screen-disagree leaf-disagree].freeze
# The printed lines' keys. `furniture.drawn` is printed on every frame-mode run;
# the others only where what they count happens -- see dynamic_reason.
FURNITURE_RECORD_ONLY = { "golden.frames" => "int", "golden.full_agree" => "int",
                          "furniture.drawn" => "str", "furniture.screens_end" => "int",
                          "copy.skipped" => "str", "copy.first_frame" => "int",
                          "copy.expected" => "int",
                          # which demo ran, stated by every run; and how often the
                          # status bar took its two rare branches, where it is drawn
                          "run.demo" => "str", "run.map" => "str", "run.demo_tics" => "int",
                          "furniture.na" => "int", "furniture.key_erase" => "int",
                          # how often each renderer leaf ran beside the original, and
                          # how many plane calls made a new plane; printed in frame mode
                          "leaves.pangle" => "int", "leaves.pdist" => "int",
                          "leaves.sgscale" => "int", "leaves.lindex" => "int",
                          "leaves.absang" => "int", "leaves.clipv" => "int",
                          "leaves.segside" => "int", "leaves.fplane" => "int",
                          "leaves.chplane" => "int", "leaves.ssclear" => "int",
                          "leaves.crunch" => "int", "leaves.chkbbox" => "int",
                          "leaves.vssort" => "int",
                          "leaves.addspr" => "int", "leaves.new_vissprites" => "int",
                          "leaves.segloop" => "int",
                          # what the walls' seg loop check compared, where the leaves run;
                          # the masked calls and the original's pushes are the original's
                          # own counts, which no port defect moves, and screens.sh asserts
                          # them per demo
                          "segloop.columns" => "int", "segloop.masked_calls" => "int",
                          "segloop.original_pushes" => "int",
                          # what the things' copy ran to and wrote, where the leaves run
                          "copy.mobj_alloc_max" => "int", "copy.mobj_cells" => "int", "copy.sector_cells" => "int",
                          "leaves.new_planes.fplane" => "int", "leaves.new_planes.chplane" => "int" }.freeze

# RECORDED AND NOT ASSERTED: a key stage 1 keeps in the record and asserts
# nothing about, because no defect in the port can move it. This is not
# `relaxed`, which is an assertion with no detection evidence; it is the absence
# of an assertion, and a key reaches it only by the reason written beside it.
#
# `planes.sky_planes_with_columns` counts a property of the DEMO IN THE ORIGINAL:
# how many of the original's sky planes pushed at least one wall job, counted in
# port_planes_whole from the records `draw_sky_plane` leaves as the ORIGINAL's
# loop runs. Nothing the port's walk does is in it, so asserting it would assert
# DEMO1 rather than the port. Measured at 600 frames on the ruby route: 28 on the
# nominal, 28 under sky-skip and 28 under planes-bound-short, the two controls
# that take `planes.sky_columns` to 0 -- both of which ran all 600 frames, so
# neither number is a truncation.
#
# `planes.sky_columns`, beside it, IS asserted and IS a coverage count: it is the
# walk's own range of wall jobs, 1296 on the nominal and 0 under each of those
# two controls. It is in expect.rb's COVERAGE; this key is not, and must not be.
#
# `planes.sky_planes_recognized` is asserted for the same reason and on the same
# kind of evidence: it is the walk's OWN answer, and sky-skip takes it from 63 to
# 0 over all 600 frames -- measured, with `run.frames` 600 in both records, so
# the zero is the port recognizing no sky and not a run that stopped.
NOT_ASSERTED = {
  "planes.sky_planes_with_columns" =>
    "recorded and not asserted: the count is a property of the demo in the original -- the original's " \
    "sky planes that pushed at least one column, counted from draw_sky_plane's own records -- so no " \
    "defect in the port can move it, and asserting it would assert the demo rather than the port",
  "planes.compared" => "recorded and not asserted: it counted the per-plane comparison the " \
    "whole walk replaced at 94804d4, and nothing increments it now; asserting a constant no " \
    "regression can move asserts nothing, so it is dropped from the coverage counts rather " \
    "than asserted at 0, and planes.sky_planes_recognized -- the sky planes the port's own " \
    "walk recognized, which sky-skip moves -- is the coverage count that stands in its place"
}.freeze

# A KEY ONLY THE FROZEN PINS CAN PRODUCE IS RETIRED. Source 1 is the pins, and a
# pin is never edited, so a name the port has since renamed stays in the pins
# forever: the frame lane's `native calls` line printed `dplane=4787` at
# e2f5676, and the renderer's whole plane walk at 94804d4 renamed that entry to
# `dplanes`. No contract of the lane names `dplane` now, so no current contract
# declares the key and no current run can carry it.
#
# THE RULE HAS TWO HALVES, AND BOTH ARE IMPLEMENTED:
#
#   * the key STAYS IN THIS INVENTORY, marked `retired` with the revision that
#     retired it and the reason. A frozen pin is the record of what the old
#     check asserted, so reading one must not become an error: pin_types goes on
#     yielding the key and row_for goes on writing its row;
#   * A CURRENT RECORD THAT CARRIES A RETIRED KEY IS AN ERROR, so a renamed
#     entry cannot come back silently under its old name. That half needs a
#     record, which this generator never sees -- it lives in
#     tests/doom-core/harness/keys-agree.rb, which reads the `retired` rows of
#     THIS FILE'S OUTPUT, so the name is declared in one place and not two.
#
# THIS TABLE IS NOT THE AUTHORITY ON WHICH KEYS ARE STALE. The entry contracts
# are, and stale_keys derives the set from them; the table carries only what no
# derivation can give -- the revision and the reason. A stale key with no row
# here, and a row here for a key the lane still produces, both stop the
# generator rather than reaching the inventory unexplained.
RETIRED = {
  "native.dplane" => ["94804d4",
                      "the renderer's whole plane walk renamed the entry to dplanes at 94804d4: no " \
                      "contract of the lane names dplane, so no current run can carry the key, while " \
                      "the frozen pins print dplane=4787 forever and a pin is never edited"]
}.freeze

# The lane's entry contracts: one per compiled entry, which is the domain of the
# native.* keys. tick.sh compiles exactly these.
CONTRACTS = "tests/doom-core/fixtures/source"

# The source sites the lane labels, from source-port.rb: the initial one and the
# three that the inserted producer lines set.
SITES = %w[none sky wall masked].freeze

PINS_HEADER = %w[#route mode control frames line run text expected].freeze

# THIS INVENTORY IS THE FRAME LANE'S. Every case of it runs in frame mode, so the
# run.* keys of the frame/job line are in every record of every route here and
# are not dynamic. The tic/column/span line direct mode prints belongs to a lane
# with its own declared set, which is not this file.

# checks.* that name the line's shape rather than one statistic.
CHECKS_FIXED = %w[checks.stats_text checks.slots_compared].freeze

# Both halves, in the words the header fixes: what the key is still asserted to
# be, and what stage 1 cannot show about it. The sensitivity half is a plain
# absence -- there is no run behind the key at all -- and not a weaker kind of
# evidence held somewhere else.
RELAXED_REASON = "the kind is asserted eq 0 on nominal cases; no stage 1 control reaches it on " \
                 "this route, so there is no detection evidence and no sensitivity evidence for the key"

# The case matrix and the control table this reads, and the columns each must
# have. A matrix or a table with other columns is a version this cannot read,
# and saying so beats deriving from the wrong field.
CASES = "tests/doom-core/cases/frame.tsv"
CASE_COLUMNS = %w[case_id lane route mode control demo frames variant requires
                  judged_against tiers origin].freeze
CONTROL_TABLE = "tests/doom-core/expect/frame-controls.tsv"
CONTROL_COLUMNS = %w[#control kind first collateral line why].freeze

# The tiers an ordinary run selects, as tests/doom-core/harness/cases.rb defines
# them. A retired row runs nowhere; a selftest row is judged against a nominal's
# expectation, so it asserts no count of its own and reaches nothing either.
RUNNABLE_TIERS = %w[commit milestone macos].freeze
# The control column of a row that runs no control.
NOMINAL = "none"
# The kinds a perturbation reaches on its own, for the rows that carry no
# control. A variant named here and carried by no runnable row is stale, and
# stops the generator rather than relaxing a kind some case does reach.
VARIANT_KINDS = { "fields=wrongslot" => %w[slot-disagree] }.freeze
# `-` in the control table's collateral column, and in the matrix's variant one.
NONE = "-"

# --- the pins file -----------------------------------------------------------

Pins = Struct.new(:path, :rows, :header)

# The TSV pins.rb writes: "#" header lines kept whole for the output's own
# header, the column row checked against what this reads, data rows split.
def read_pins(path)
  File.exist?(path) or abort("keys.rb: no pins file at #{path}")
  header = []
  rows = []
  File.readlines(path, chomp: true).each do |line|
    next if line.empty?
    if line.start_with?("#")
      fields = line.split("\t")
      if fields.first == PINS_HEADER.first
        fields == PINS_HEADER or
          abort("keys.rb: #{path} has the columns #{fields.join(' ')}, not #{PINS_HEADER.join(' ')}")
      else
        header << line
      end
      next
    end
    fields = line.split("\t", -1)
    fields.length == PINS_HEADER.length or
      abort("keys.rb: #{path} has a row of #{fields.length} fields, not #{PINS_HEADER.length}: #{line[0, 80]}")
    rows << fields
  end
  rows.empty? and abort("keys.rb: #{path} holds no pin rows")
  ROUTES.each do |route|
    rows.any? { |r| r.first == route } or abort("keys.rb: #{path} holds no #{route} rows")
  end
  Pins.new(path, rows, header)
end

# --- the case matrix and the control table -----------------------------------

# The two TSVs this derives the reached kinds from. Both are written by other
# programs of the layer, so both are read by their column header rather than by
# position: a column inserted there must stop this, not shift it silently.
def read_table(path, columns, what)
  File.exist?(path) or abort("keys.rb: no #{what} at #{path}")
  rows = []
  header = nil
  File.readlines(path, chomp: true).each_with_index do |line, i|
    next if line.empty?
    if line.start_with?("#")
      fields = line.split("\t")
      next unless fields.first == columns.first
      header = fields
      next
    end
    fields = line.split("\t", -1)
    fields.length == columns.length or
      abort("keys.rb: #{path}:#{i + 1} has #{fields.length} fields, not #{columns.length}")
    rows << fields
  end
  header == columns or
    abort("keys.rb: the #{what} #{path} has the columns #{header.inspect}, not #{columns.inspect}")
  rows.empty? and abort("keys.rb: the #{what} #{path} holds no rows")
  rows
end

def read_cases(path)
  # The matrix writes its first column without the leading "#", which is the
  # one difference from the layer's other tables.
  columns = ["##{CASE_COLUMNS.first}"] + CASE_COLUMNS[1..]
  read_table(path, columns, "case matrix").map { |r| CASE_COLUMNS.zip(r).to_h }
end

# control -> the kinds it raises: its intended kind and its collateral kinds,
# which is the `faults.raised` set the control's expectation asserts.
def read_controls(path)
  read_table(path, CONTROL_COLUMNS, "control table").to_h do |control, kind, _first, collateral, *|
    [control, ([kind] + (collateral == NONE ? [] : collateral.split(","))).uniq]
  end
end

# --- which kinds a stage 1 run reaches ---------------------------------------

# A composite part is a REFUSAL: the program says why it will not run the
# control on this route and exits nonzero, before any frame and therefore
# before any counter. Reading the refusal out of the pin, rather than trusting
# the claim, keeps a row that quietly became a running case from relaxing
# nothing while claiming to reach kinds it never had.
def refusal_part?(pin, part)
  fields = pin[7].to_s.split("|")
  message, status = fields[((part.to_i - 1) * 2), 2]
  !message.nil? && message.start_with?("source-port.rb:") && status.to_s.match?(/\Arc=[1-9]/)
end

def claimed_line(origin)
  origin =~ /\Atick:(\d+)@\S+(?: part (\d+))?\z/ ? [Regexp.last_match(1), Regexp.last_match(2)] : nil
end

# route -> kind -> the first case that reaches it. Everything about relaxed
# follows from this: a kind with no case here has no detection evidence on that
# route, whatever the pins of the other routes once showed.
# The kinds a control raised on one route, from that route's own frozen pin.
# nil where no pin ran that control there.
def route_raised(pins, route, control)
  pin = pins.rows.find { |row| row[0] == route && row[2] == control } or return nil
  keys, unparsed = ReportKeys.pin(pin[7])
  unparsed.empty? or
    abort("keys.rb: the #{route} #{control} pin at tick.sh:#{pin[4]} has #{unparsed.length} " \
          "line(s) no rule claims, so what it raised cannot be read")
  raised = keys.select { |k, v| k.start_with?("faults.") && v.to_i.positive? }
               .keys.map { |k| k.delete_prefix("faults.") }.sort
  raised.empty? ? nil : raised
end

def reached_kinds(cases, controls, pins)
  by_line = pins.rows.to_h { |row| [row[4], row] }
  reached = ROUTES.to_h { |route| [route, {}] }
  variants_used = []
  cases.each do |c|
    id = c["case_id"]
    next if (c["tiers"].split(",") & RUNNABLE_TIERS).empty?
    route = reached[c["route"]] ||
            abort("keys.rb: the matrix runs #{id} on the unknown route #{c['route']}")
    line, part = claimed_line(c["origin"])
    pin = line && by_line[line]
    if pin && pin[0] == "composite"
      refusal_part?(pin, part) or
        abort("keys.rb: #{id} claims part #{part.inspect} of the composite pin at tick.sh:#{line}, " \
              "which is not a refusal; a part that runs may raise kinds this cannot see")
      next
    end
    kinds = []
    unless c["control"] == NOMINAL
      # THE ROUTE'S OWN PIN WINS. frame-controls.tsv describes the compiled
      # route, where stage 1 runs the controls. A case that runs the same
      # control on another route does not raise the same kinds there: the
      # adapter's push-kind ends its session in frame 0, so it never reaches the
      # frame or fuzz-count kinds the compiled run does. Where a frozen pin for
      # that route and control exists -- retired or not, it is still the record
      # of what that route did -- it is what this reads.
      kinds += route_raised(pins, c["route"], c["control"]) ||
               controls[c["control"]] ||
               abort("keys.rb: the matrix runs the control #{c['control']} as #{id}, which " \
                     "#{CONTROL_TABLE} does not describe; regenerate it with controls.rb or fix the matrix")
    end
    if VARIANT_KINDS.key?(c["variant"])
      variants_used << c["variant"]
      kinds += VARIANT_KINDS[c["variant"]]
    end
    kinds.each { |kind| route[kind] ||= id }
  end
  stale = VARIANT_KINDS.keys - variants_used
  stale.empty? or
    abort("keys.rb: VARIANT_KINDS names the variant(s) #{stale.join(', ')}, which no runnable row of " \
          "#{CASES} carries; update it for the matrix's current variants")
  reached
end

# A kind reached on a route whose records have no key for it is a control table
# and a route that disagree about what the route can raise.
def check_reached(reached, types)
  ROUTES.each do |route|
    kinds = fault_kinds(types[route])
    reached[route].each do |kind, id|
      kinds.include?(kind) or
        abort("keys.rb: #{id} reaches #{kind} on the #{route} route, which has no faults.#{kind} key")
    end
  end
end

# --- the declared key sets ---------------------------------------------------

# route -> key -> type, from the pins. A pin that does not parse whole, and a
# key that parses to two different types within one route, are both defects of
# the pin or of report_keys.rb, and stop the generator rather than reaching the
# inventory as a guess.
def pin_types(pins)
  types = {}
  ROUTES.each { |r| types[r] = {} }
  seen = {}
  pins.rows.each do |route, _mode, control, _frames, line, _run, _text, expected|
    next if route == "composite"
    ROUTES.include?(route) or abort("keys.rb: the pin at tick.sh:#{line} names the unknown route #{route}")
    keys, unparsed = ReportKeys.pin(expected)
    unparsed.empty? or
      abort("keys.rb: the #{route} #{control} pin at tick.sh:#{line} has #{unparsed.length} " \
            "line(s) no rule claims: #{unparsed.join(' / ')}")
    keys.each do |key, value|
      type = type_of(value) ||
             abort("keys.rb: the #{route} #{control} pin at tick.sh:#{line} gives #{key} the " \
                   "value #{value.inspect}, which is neither an integer nor a string")
      if types[route].key?(key) && types[route][key] != type
        abort("keys.rb: #{key} is #{types[route][key]} in the #{route} #{seen[[route, key]]} pin and " \
              "#{type} in the #{route} #{control} pin at tick.sh:#{line}")
      end
      types[route][key] = type
      seen[[route, key]] ||= control
    end
  end
  ROUTES.each do |route|
    types[route].empty? and abort("keys.rb: the #{route} pins of #{pins.path} yield no keys at all")
  end
  types
end

def type_of(value)
  case value
  when Integer then "int"
  when String then "str"
  end
end

# The route's fault kinds, read out of the keys the pins already gave it.
def fault_kinds(keys)
  keys.keys.grep(/\Afaults\.(.+)\z/) { Regexp.last_match(1) }.sort
end

# Sources 2, 3 and 4: the exit status, the keys no printed line carries, and the
# keys a printed line carries that no frozen pin can.
#
# THE DYNAMIC FAMILIES ARE DECLARED FROM THEIR DOMAIN, NOT FROM THE PINS. A pin
# shows the entries and sites one run reached, which is not the set a legitimate
# record may carry: the nominal run calls 18 of the 22 compiled entries, and a
# control that pushes walls as spans calls a nineteenth. Declaring only what the
# pins happened to show would make a record of that control carry a key with no
# row -- measured, `native.pspan` on the adapter route. So the entries come from
# the contracts the lane compiles and the sites from the labels the lane sets.
def add_record_only(route, types, entries)
  EXIT_KEYS.each { |name, type| types[name] ||= type }
  PLANES_RECORD_ONLY.each { |name, type| types[name] ||= type }
  FURNITURE_RECORD_ONLY.each { |name, type| types[name] ||= type }
  fault_kinds(types).each do |kind|
    types["first_at.#{kind}.frame"] = "int"
    types["first_at.#{kind}.tic"] = "int"
  end
  types["adapter.session_failed"] = "str" if route == "adapter"
  entries.each { |e| types["native.#{e}"] = "int" } unless route == "ruby"
  SITES.each do |site|
    types["sites.#{site}.count"] = "int"
    types["sites.#{site}.first"] = "str"
  end
  types
end

# The kinds the pins predate, beside the ones they hold. Added before anything
# asks which kinds a route has -- the reached-kind check included -- so a control
# that raises one is described like one raising any other.
def add_later_kinds(route, types)
  LATER_FAULT_KINDS.each do |kind|
    types.key?("faults.#{kind}") and
      abort("keys.rb: the pins give the #{route} route faults.#{kind}, which LATER_FAULT_KINDS says they predate")
    types["faults.#{kind}"] = "int"
    types["first.#{kind}"] = "str"
  end
  types
end

# --- the keys the lane can no longer produce ---------------------------------

# The declared keys that no current run can carry. Only the native family has a
# CURRENT domain to be checked against -- the entry contracts the lane compiles,
# one per compiled entry -- so it is the family this can decide. Every other
# family's names come from rules in report_keys.rb that claim the pin's own
# lines, where a name the port has stopped printing is invisible by
# construction; those are found by comparing a record against the inventory,
# which is keys-agree.rb's half of the rule and not this one's.
def stale_keys(types, entries)
  types.keys.grep(%r{\Anative\.(.+)\z}) { Regexp.last_match(1) }
       .reject { |entry| entries.include?(entry) }
       .map { |entry| "native.#{entry}" }
end

# The retirement table against what is actually stale, both ways.
def check_retired(stale)
  (stale.uniq - RETIRED.keys).sort.each do |key|
    abort("keys.rb: #{key} comes from a frozen pin and names no entry under the lane's contracts, so " \
          "no current run can carry it; give it a RETIRED row in #{__FILE__} naming the revision that " \
          "retired it and why")
  end
  (RETIRED.keys - stale).sort.each do |key|
    abort("keys.rb: RETIRED names #{key}, which the lane still produces; a key a current run can carry " \
          "is not retired, and a record carrying it must not be refused")
  end
end

# A NOT_ASSERTED row for a key no route declares would be a rule about nothing.
def check_not_asserted(declared)
  (NOT_ASSERTED.keys - declared).sort.each do |key|
    abort("keys.rb: NOT_ASSERTED names #{key}, which no route of this inventory declares; drop the row " \
          "or fix the key")
  end
end

# The entries the lane compiles, one contract each.
def entry_names(dir)
  names = Dir[File.join(dir, "*.contract")].map { |p| File.basename(p, ".contract") }.sort
  names.empty? and abort("keys.rb: no entry contracts under #{dir}; --contracts must name the lane's fixtures")
  names
end

# --- the columns -------------------------------------------------------------

def family_of(key, route)
  return EXIT_FAMILY if EXIT_KEYS.key?(key)
  family = key.split(".").first
  FAMILIES.include?(family) or
    abort("keys.rb: the #{route} key #{key} falls into no family; add it to FAMILIES or fix the key")
  family
end

# The rule table of the comment above: the reason a record of this route may
# lack the key, or nil when every record of the route must carry it.
def dynamic_reason(key, family)
  case
  when %w[native sites].include?(family)
    "the set depends on which entries and sites the run actually reached"
  when family == "checks" && !CHECKS_FIXED.include?(key)
    "a truncated session reaches no statistic and the line prints an empty list"
  when key == "ended"
    "present only where the run ended as something other than a clean finish"
  when family == "first_at"
    "present only for a kind that was raised"
  when key == "adapter.session_failed"
    nil # the record answers it on both paths
  when family == "adapter"
    "printed only after a session that succeeded"
  when family == "session"
    "absent when there is no session and when the session failed before the end-of-run block"
  when family == "golden"
    "printed only where a recording is named"
  when %w[copy.mobj_alloc_max copy.mobj_cells copy.sector_cells].include?(key)
    nil
  when family == "segloop"
    nil
  when family == "copy"
    "printed only where a boundary copy is skipped"
  when %w[furniture.screens_end furniture.na furniture.key_erase].include?(key)
    "printed only where the furniture is drawn"
  end
end

# The fault kind a key is about, for the three shapes that carry one.
def kind_of(key)
  case key
  when /\Afaults\.(.+)\z/, /\Afirst\.(.+)\z/, /\Afirst_at\.(.+)\.(?:frame|tic)\z/ then Regexp.last_match(1)
  end
end

def relaxed?(key, route, reached)
  kind = kind_of(key)
  !kind.nil? && !reached[route].key?(kind)
end

# The four stage1 values, in the order they win. `retired` comes first because a
# key no current run can carry is not asserted, relaxed or recorded of anything;
# `recorded` comes before `relaxed` because a key nothing can move has no
# assertion for detection evidence to be missing from.
def stage1_of(key, route, reached)
  if RETIRED.key?(key)
    revision, why = RETIRED[key]
    ["retired", "retired at #{revision}: #{why}"]
  elsif NOT_ASSERTED.key?(key)
    ["recorded", NOT_ASSERTED[key]]
  elsif relaxed?(key, route, reached)
    ["relaxed", RELAXED_REASON]
  else
    ["asserted", nil]
  end
end

def row_for(key, type, route, reached)
  family = family_of(key, route)
  dynamic_why = dynamic_reason(key, family)
  dynamic = dynamic_why.nil? ? "n" : "y"
  stage1, stage1_why = stage1_of(key, route, reached)
  # A key can be both: why a record may lack it, and what stage 1 does or does
  # not do with it. Both reasons are kept, because dropping either leaves a
  # reader guessing about the half that is gone.
  why = [dynamic_why, stage1_why].compact
  [route, key, type, dynamic, family, stage1, why.empty? ? "-" : why.join("; ")]
end

# --- output ------------------------------------------------------------------

def inventory(pins, entries, cases, controls)
  types = pin_types(pins)
  ROUTES.each { |route| add_later_kinds(route, types[route]) }
  reached = reached_kinds(cases, controls, pins)
  check_reached(reached, types)
  rows = []
  counts = {}
  stale = []
  all = []
  ROUTES.each do |route|
    declared = add_record_only(route, types[route], entries)
    counts[route] = declared.size
    stale += stale_keys(declared, entries)
    all |= declared.keys
    declared.keys.sort.each { |key| rows << row_for(key, declared[key], route, reached) }
  end
  check_retired(stale)
  check_not_asserted(all)
  [rows, counts, reached]
end

# The header carries the detection evidence itself: one line per kind a stage 1
# run reaches, naming the first case of the matrix that reaches it. A route with
# no line reaches nothing, and every one of its fault kinds is relaxed.
def report(pins, rows, counts, reached)
  out = +"# the frame lane's declared key inventory, generated by tests/doom-core/harness/keys.rb\n"
  out << "# reached, below, is derived from #{CASES} and #{CONTROL_TABLE}\n"
  pins.header.each { |line| out << line << "\n" }
  out << "# keys\t#{rows.length}\n"
  ROUTES.each { |route| out << "# keys.#{route}\t#{counts[route]}\n" }
  ROUTES.each do |route|
    relaxed = rows.count { |r| r[0] == route && r[5] == "relaxed" }
    out << "# relaxed.#{route}\t#{relaxed}\n"
  end
  # The two lists a reader should not have to find by grepping a column: what is
  # recorded and not asserted, and what is retired and with it the revision that
  # retired it.
  NOT_ASSERTED.keys.sort.each { |key| out << "# recorded\t#{key}\n" }
  RETIRED.keys.sort.each { |key| out << "# retired\t#{key}\t#{RETIRED[key].first}\n" }
  ROUTES.each do |route|
    reached[route].keys.sort.each { |kind| out << "# reached\t#{route}\t#{kind}\t#{reached[route][kind]}\n" }
  end
  out << %w[#route key type dynamic family stage1 reason].join("\t") << "\n"
  rows.each { |row| out << row.join("\t") << "\n" }
  out
end

USAGE = "usage: keys.rb --pins PINS.tsv [--cases FILE] [--controls FILE] [--contracts DIR] [--out FILE]".freeze

def main
  path = nil
  out = nil
  contracts = CONTRACTS
  cases_path = CASES
  controls_path = CONTROL_TABLE
  args = ARGV.dup
  until args.empty?
    flag = args.shift
    %w[--pins --out --contracts --cases --controls].include?(flag) or abort(USAGE)
    value = args.shift or abort("keys.rb: #{flag} needs a value")
    case flag
    when "--pins" then path = value
    when "--out" then out = value
    when "--contracts" then contracts = value
    when "--cases" then cases_path = value
    when "--controls" then controls_path = value
    end
  end
  path or abort(USAGE)

  pins = read_pins(path)
  rows, counts, reached = inventory(pins, entry_names(contracts), read_cases(cases_path), read_controls(controls_path))
  text = report(pins, rows, counts, reached)
  out ? File.write(out, text) : print(text)
  relaxed = ROUTES.to_h { |r| [r, rows.count { |row| row[0] == r && row[5] == "relaxed" }] }
  warn("keys.rb: #{rows.length} keys (#{ROUTES.map { |r| "#{r} #{counts[r]}" }.join(', ')}) from #{path}")
  warn("keys.rb: relaxed #{ROUTES.map { |r| "#{r} #{relaxed[r]}" }.join(', ')}; " \
       "reached #{ROUTES.map { |r| "#{r} #{reached[r].size}" }.join(', ')}")
end

main if $PROGRAM_NAME == __FILE__
