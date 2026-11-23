# tests/doom-core/harness/controls.rb — what each frame-lane control is for.
#
#   ruby tests/doom-core/harness/controls.rb --pins PINS.tsv [--out FILE]
#
# A CONTROL CASE ASSERTS THREE ROWS, and this table is where all three come
# from:
#
#   * the intended kind, `gt0` -- the one thing the control is for;
#   * that kind's first-failure text, `eq` -- where it first went wrong;
#   * `faults.raised`, `set` -- the intended kind TOGETHER WITH its collateral
#     kinds, by name, with no counts.
#
# Most of the old pins raise several kinds -- plane-skip raises push, plane,
# check and frame -- because one wrong thing early makes everything after it
# disagree too. Only one of those is what the control is FOR; the rest are that
# one defect arriving again further down. The collateral kinds are therefore not
# asserted by count, which would pin numbers the control is not about; they are
# asserted by NAME, as members of the raised set.
#
# WHY THE SET IS THERE AND NOT DROPPED. clear-skip and clear-drop-counters share
# their intended kind, clear-disagree, and their first-failure text byte for
# byte: both first fail at `frame 1 after clear_planes lastvisplane port 10
# original 0`. On the first two rows alone the two controls are indistinguishable
# -- each would pass the other's expectation. They differ only in what else they
# raise: skipping the clear moves the planes and the screen as well, while
# undoing the counter writes moved nothing else at the pins -- since 6fe29a9 it
# also moves the renderer leaves, which read lastvisplane (LATER_COLLATERAL
# below), and still not the planes or the screen. clear-drop-counters is the
# 7a1df0b vacuity guard, so without the raised set it is exactly the case a
# wrong implementation passes, which is the failure mode 0009 recorded.
#
# The first-failure text comes out of the frozen pin named in the line column,
# not from a new run.
#
# A CONTROL THAT HAS NO PIN IS DECLARED INSTEAD. The pins are tick.sh at
# e2f5676 and are never edited (0009's stage 1 clarification), so a control the
# port gained after that revision has no pinned text, now or ever. For such a
# control DECLARED below carries what can be said without a run -- the intended
# kind, and the whole set of kinds it raises, both read off what the control
# changes in source-port.rb -- and nothing else: the first-failure text is
# written `TBD`, because only a run can produce it, and it is filled through the
# layer's ordinary path, harness/fills.rb into expect.rb --fills. The line column
# holds `-`, because there is no pin to name. NOTHING ELSE CHANGES: a declared
# control's three assertions are the same three a pinned one makes, and the
# consumers -- keys.rb's reached kinds, expect.rb's control rows -- read the
# table the same way for both.
#
# THE ROUTE MATTERS FOR TWO OF THEM. A capacity or a bounds refusal is a fault
# of the port on the Ruby route and a status from the entry on every compiled
# one: push-cap-low is push-capacity with a Ruby bank and native-status
# `pwall status 4 CAPACITY` with a compiled one, and push-kind cannot run on the
# Ruby route at all, because the records it makes are outside the screen and
# only a compiled entry refuses them. The table is therefore per route, and the
# compiled route is the one that carries all fifteen.
#
# IT REFUSES A CHOICE THE PIN DOES NOT SUPPORT. A kind named here that the pin
# does not raise, or raises with no first failure, stops the generator: that is
# a control whose intent and whose behaviour have parted company.

require_relative "report_keys"

# The collateral column of a control that raises nothing else, and the line
# column of a control with no pin.
NONE = "-"
# The first-failure text of a control no pin describes: only a run can give it,
# and expect.rb --fills is where it comes from.
TBD = "TBD"

# control => [intended kind, why this one and not the others]
INTENDED = {
  "frame-order" => ["frame-disagree",
                    "the schedule is walked backwards, so every push, mark and check still " \
                    "agrees and only the screen the executor draws can differ"],
  "frame-fuzz-phase" => ["frame-disagree",
                         "the fuzz phase is one later, which changes drawn pixels and nothing else; " \
                         "the first failure is the first frame with a fuzz column"],
  "frame-wrong-bank" => ["frame-disagree",
                         "the executor is given the previous frame's span bank, so the banks the " \
                         "pushes filled still agree and only the screen differs"],
  "push-skip-sched" => ["push-disagree",
                        "the schedule entry is written where nothing reads it, which the push " \
                        "comparison sees at the second push; the planes and the screen follow from it"],
  "push-kind" => ["native-status",
                  "wall pushes are issued as span pushes, whose records name rows past the screen. " \
                  "What the control is for is that a COMPILED entry refuses them -- the span check " \
                  "answers BOUNDS -- which is why it cannot run on the Ruby route at all"],
  "push-phase-counter" => ["phase-disagree",
                           "phase 1 is marked from the span counter instead of the wall counter, so " \
                           "the mark differs; the check tables built to that mark differ in turn"],
  "push-cap-low" => ["native-status",
                     "the wall bank is given a capacity of 100, and what the control is for is the " \
                     "refusal at the 101st push. With a compiled entry that is a CAPACITY status, " \
                     "not the port's own push-capacity, which stays 0 there"],
  "check-lo-one" => ["check-disagree",
                     "the phase-0 wall table is built from the second job, so the interval table " \
                     "differs and nothing upstream of it does"],
  "check-skip-span" => ["check-disagree",
                        "the span table is left unbuilt on odd frames, so its statistics differ; " \
                        "the first failure is the first odd frame"],
  "plane-skip" => ["plane-disagree",
                   "every plane 1 more than a multiple of 3 is left undrawn, which the per-plane " \
                   "comparison sees; the missing spans then move the pushes, checks and screen"],
  "plane-wrong" => ["plane-disagree",
                    "the next plane's arrays are drawn in this plane's place, which the per-plane " \
                    "comparison sees as a different picnum, height and light"],
  "plane-wrong-height" => ["plane-disagree",
                           "every plane's height is loaded 1.0 high, which the per-plane comparison " \
                           "sees; the spans it emits then differ and the screen with them"],
  "clear-skip" => ["clear-disagree",
                   "clear_planes is left out on odd frames, so the cells it should have written " \
                   "keep the values the frame before left"],
  "clear-drop-counters" => ["clear-disagree",
                            "the four counter writes are undone after the port's clear. It is the " \
                            "7a1df0b vacuity guard: before that commit the port started from the " \
                            "written value, so deleting the writes changed nothing observable"],
  "clear-drop-clips" => ["clear-disagree",
                         "the clip writes are undone after the port's clear, which the per-field " \
                         "clear comparison sees at floorclip[0] in frame 0"]
}.freeze

# A KIND THE PORT GAINED AFTER THE PINS, raised alongside one the pins already
# hold. 12e8db4 added `screen-disagree`: the whole screen compared once more at
# the END of the frame, after the status bar and the HUD are drawn, where the
# recorder hashes it. `frame-disagree` compares the same screen earlier, after
# the executor; a defect it sees in the view is still there when the frame ends,
# so every control that raises `frame-disagree` raises `screen-disagree` too.
# Measured on the compiled route after the status bar's fields were reshaped:
# all fourteen such controls raise it, and none of the five that do not raise
# `frame-disagree` does. A pin cannot hold the later kind,
# so the rule adds it to a pinned control's collateral; a DECLARED control below
# names it in its set, as it names every other kind.
# later kind => the pinned kind it follows
LATER_KINDS = { "screen-disagree" => "frame-disagree" }.freeze

# A LATER KIND RAISED BY NAMED CONTROLS, for a reason the rule above cannot
# state. The renderer's leaves (6fe29a9) run find_plane and check_plane over the
# port's own lastvisplane, which the ported clear_planes resets each frame. A
# control that stops that reset -- clear-skip on odd frames, clear-drop-counters
# on every frame -- leaves the port's count where the original's is not, so the
# next plane lookup disagrees too. clear-drop-clips undoes only the clip arrays,
# which no leaf reads, and does not raise it. Measured on the compiled route at
# 6fe29a9.
# control => kinds added to its pinned collateral
LATER_COLLATERAL = {
  "clear-skip" => %w[leaf-disagree],
  "clear-drop-counters" => %w[leaf-disagree]
}.freeze

# control => [intended kind, the whole set of kinds it raises, why this one]
#
# The four controls 94804d4 added with the renderer's whole plane walk and the
# sky plane drawn as texture columns. No pin runs them -- they did not exist at
# e2f5676 -- so each says here what it raises, and its first failure waits for a
# run. The set is the WHOLE set, intended kind included; the generator splits the
# collateral out of it, so the two tables are read the same way downstream.
DECLARED = {
  "sky-skip" => ["plane-disagree", %w[plane-disagree push-disagree check-disagree frame-disagree screen-disagree],
                 "the walk is handed a private skyflatnum buffer holding -1, which no plane's picnum " \
                 "equals, so the walk recognizes no plane as sky and draws every sky plane as an " \
                 "ordinary flat. What the control is for is that the walk's own sky-plane count then " \
                 "disagrees with the original's, which the comparison after the walk sees; the spans it " \
                 "emits where the original pushed columns move the pushes, the check tables and the screen"],
  "sky-texmid" => ["plane-disagree", %w[plane-disagree frame-disagree screen-disagree],
                   "the walk is handed a private skytexturemid buffer 1.0 high, so every sky column is " \
                   "pushed with a wrong texturemid and nothing else moves: the same planes are drawn and " \
                   "the same number of columns pushed. The wall-bank comparison of the sky columns is " \
                   "what sees it, and only the screen the executor draws from those jobs follows"],
  "sky-iscale" => ["plane-disagree", %w[plane-disagree frame-disagree screen-disagree],
                   "the walk is handed a private pspriteiscale buffer 1 higher, so every sky column is " \
                   "pushed with a wrong iscale, one field over from sky-texmid's and with the same " \
                   "shape: the wall-bank comparison of the sky columns sees it, and only the screen " \
                   "follows"],
  "planes-bound-short" => ["plane-disagree", %w[plane-disagree push-disagree check-disagree frame-disagree screen-disagree],
                           "the walk's lastvisplane cell is loaded one lower than the original's, so the " \
                           "walk stops one plane short of the visplanes the original drew. What the " \
                           "control is for is that the missing plane leaves the counters the walk " \
                           "reports short of the original's, which the comparison after the walk sees; " \
                           "the spans and schedule entries it never pushed move the pushes, the check " \
                           "tables and the screen"]
}.freeze

# A control is in one table or the other, never both and never in DECLARED with a
# pin behind it: either would leave two answers for one control's three rows.
def check_tables(pins)
  (INTENDED.keys & DECLARED.keys).each do |control|
    abort("controls.rb: #{control} is in INTENDED and in DECLARED; a control's intended kind is " \
          "declared once, and a pinned control takes its first failure from the pin")
  end
  DECLARED.each_key do |control|
    pin = pins.find { |r| r[0] == "compiled" && r[2] == control } or next
    abort("controls.rb: #{control} is declared with no pin, and the pins hold a compiled one at " \
          "tick.sh:#{pin[4]}; move it to INTENDED, where its first failure comes from that pin")
  end
end

# A pinned control's three values, read out of the frozen pin: the kind must be
# raised there, and with a first failure, or the control's intent and its
# behaviour have parted company.
def pinned_row(control, kind, why, pins)
  pin = pins.find { |r| r[0] == "compiled" && r[2] == control } or
    abort("controls.rb: no compiled pin for the control #{control}; it is named here and run nowhere")
  keys, = ReportKeys.pin(pin[7])
  count = keys["faults.#{kind}"]
  count.to_i.positive? or
    abort("controls.rb: #{control} names #{kind} as its intended kind, and the pin at " \
          "tick.sh:#{pin[4]} raises it #{count.inspect} times")
  first = keys["first.#{kind}"] or
    abort("controls.rb: #{control} raises #{kind} in the pin at tick.sh:#{pin[4]} with no first failure")
  others = keys.select { |k, v| k.start_with?("faults.") && v.to_i.positive? }
               .keys.map { |k| k.delete_prefix("faults.") } - [kind]
  raised = others + [kind]
  LATER_KINDS.each do |later, after|
    raised.include?(later) and
      abort("controls.rb: the pin at tick.sh:#{pin[4]} raises #{later}, which the pins predate; " \
            "LATER_KINDS is wrong about it")
    others += [later] if raised.include?(after)
  end
  LATER_COLLATERAL.fetch(control, []).each do |later|
    raised.include?(later) and
      abort("controls.rb: the pin at tick.sh:#{pin[4]} raises #{later}, which LATER_COLLATERAL says it predates")
    others += [later]
  end
  [control, kind, first, others.empty? ? NONE : others.join(","), pin[4], why]
end

# A declared control's three values: the kind and the set come from the table
# above, and the first failure is the one thing only a run can give.
def declared_row(control, kind, raised, why)
  raised.include?(kind) or
    abort("controls.rb: #{control} names #{kind} as its intended kind, and its raised set " \
          "#{raised.join(',')} does not hold it; the set is the whole set, intended kind included")
  LATER_KINDS.each do |later, after|
    raised.include?(after) == raised.include?(later) or
      abort("controls.rb: #{control} raises #{after} and #{raised.include?(later) ? 'names' : 'does not name'} " \
            "#{later}; LATER_KINDS says the two go together")
  end
  others = raised - [kind]
  [control, kind, TBD, others.empty? ? NONE : others.join(","), NONE, why]
end

def read_pins(path)
  File.exist?(path) or abort("controls.rb: no pins file at #{path}")
  rows = []
  header = []
  File.readlines(path, chomp: true).each do |line|
    next if line.empty?
    if line.start_with?("#")
      header << line unless line.start_with?("#route")
      next
    end
    rows << line.split("\t", -1)
  end
  rows.empty? and abort("controls.rb: #{path} holds no pin rows")
  [header, rows]
end

def main
  pins_path = nil
  out = nil
  args = ARGV.dup
  until args.empty?
    case (flag = args.shift)
    when "--pins" then pins_path = args.shift
    when "--out" then out = args.shift
    else abort("usage: controls.rb --pins PINS.tsv [--out FILE]")
    end
    abort("controls.rb: #{flag} needs a value") if (flag == "--pins" && pins_path.nil?) || (flag == "--out" && out.nil?)
  end
  pins_path or abort("usage: controls.rb --pins PINS.tsv [--out FILE]")

  header, pins = read_pins(pins_path)
  check_tables(pins)
  rows = INTENDED.map { |control, (kind, why)| pinned_row(control, kind, why, pins) }
  rows += DECLARED.map { |control, (kind, raised, why)| declared_row(control, kind, raised, why) }

  text = +"# what each frame-lane control is for: its one intended fault kind, and that\n"
  text << "# kind's first failure, taken from the frozen pin named in the line column.\n"
  text << "# collateral names the other kinds that pin raises: the same defect arriving\n"
  text << "# again further down.\n"
  text << "# A CONTROL CASE ASSERTS THREE ROWS FROM EACH ROW HERE: the intended kind gt0,\n"
  text << "# that kind's first-failure text eq, and faults.raised set -- the intended kind\n"
  text << "# TOGETHER WITH its collateral kinds, by name and with no counts. The collateral\n"
  text << "# kinds are asserted as members of that set, never by count.\n"
  text << "# The set is not droppable: clear-skip and clear-drop-counters share their\n"
  text << "# intended kind and their first-failure text byte for byte, so on the first two\n"
  text << "# rows alone each would pass the other's expectation. They differ only in what\n"
  text << "# else they raise. clear-drop-counters is the 7a1df0b vacuity guard, so without\n"
  text << "# the set it is exactly the case a wrong implementation passes.\n"
  text << "# A ROW WHOSE line IS - HAS NO PIN: the control is newer than the frozen\n"
  text << "# revision, so its intended kind and its raised set are DECLARED in controls.rb\n"
  text << "# from what the control changes, and its first failure is TBD until a run gives\n"
  text << "# it, through harness/fills.rb and expect.rb --fills.\n"
  header.each { |line| text << line << "\n" }
  text << %w[#control kind first collateral line why].join("\t") << "\n"
  rows.each { |row| text << row.join("\t") << "\n" }
  out ? File.write(out, text) : print(text)
  warn("controls.rb: #{rows.length} controls, #{rows.count { |r| r[3] != NONE }} of them with collateral kinds, " \
       "#{rows.count { |r| r[4] == NONE }} declared with no pin and a #{TBD} first failure")
end

main
