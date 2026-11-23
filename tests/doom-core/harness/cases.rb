# tests/doom-core/harness/cases.rb — the frame lane's case matrix, checked.
#
#   ruby tests/doom-core/harness/cases.rb --pins <pins.tsv> [--cases FILE]
#
# tests/doom-core/cases/frame.tsv declares the lane's cases as data (0009 item
# 4). The migration's point is that no pinned check is lost and none is
# invented, so the matrix and the frozen pins must account for each other.
#
# THE CORRESPONDENCE IS NOT ONE-TO-ONE ANY MORE. Stage 1 runs the lane's
# controls on the compiled route only; the other routes' control pins assert the
# same keys at a different frame count and are retired as route duplicates. So
# the rule is weaker in shape and no weaker in force:
#
#   EVERY PIN IS EITHER CLAIMED BY EXACTLY ONE ROW OR RETIRED BY EXACTLY ONE
#   ROW, NEVER BOTH AND NEVER NEITHER.
#
# A pin that no row mentions fails. Retired is not deleted-and-forgotten: a
# retired row names the pin's line, repeats the route, mode, control and frame
# count it is retiring, and carries the reason in its origin, which is what
# 0009's Validation requires of a check retired rather than migrated.
#
# It checks, and names what fails:
#
#   * every case id is unique and is built from the row's own route, control,
#     frame count and variant, so a perturbed row cannot wear an unperturbed
#     row's name;
#   * every column holds a value from its vocabulary -- a misspelled lane, mode,
#     control, demo, tier, variant or requirement would otherwise select nothing
#     and go unnoticed -- and `requires` is never empty, so a skip can always
#     name what is missing;
#   * `requires` matches the ROUTE. Each route needs exactly one set of things
#     present, so a row that declares another set is wrong whichever way it
#     errs: too little and the case runs without its prerequisite present and
#     fails as if the port were wrong; too much and it skips where it should
#     have run. Both are named, item by item, so the row says what to add and
#     what to drop;
#   * every row whose origin names a tick.sh line agrees with the pin at that
#     line in route, mode, control and frame count;
#   * a row that stands in for a pin RUNS, AS ITSELF: it carries a tier an
#     ordinary run selects, it is judged against its own expectation, and it
#     carries no variant. Each of those, left unchecked, leaves the pinned check
#     asserted by nothing while the row still accounts for its pin;
#   * the composite refusal check is claimed by its two FRAME-mode parts, each
#     row naming which part it is, and not by its queued ones;
#   * `judged_against` names a case that exists, so a perturbation cannot be
#     judged against an expectation nobody wrote;
#   * a retirement that calls itself a ROUTE DUPLICATE of another case names one
#     that runs THE SAME CONTROL. A route duplicate's whole claim is that the
#     surviving case asserts the same thing on another route, and a case running
#     a different control asserts something else; naming one retires a check
#     nothing replaces, while still reading as accounted for;
#   * a selftest or retired row is tiered that and nothing else, so the
#     harness's own tests and its retirements cannot creep into the commit,
#     milestone or macOS sets.
#
# WHAT IT CANNOT CHECK. The pins table names a composite's parts by run name,
# which carries the route, the mode and the control but not the frame count. The
# 60 frames the two refusal rows declare are therefore checked against tick.sh
# by reading, not by this program.
#
# Exit status is 0 when the matrix and the pins account for each other exactly.

CASES = "tests/doom-core/cases/frame.tsv".freeze
PORT = "tests/doom-core/source-port.rb".freeze
COLUMNS = %w[case_id lane route mode control demo frames variant requires judged_against tiers origin].freeze
LANES = %w[frame].freeze
ROUTES = %w[ruby compiled session adapter].freeze
MODES = %w[frame].freeze
DEMOS = %w[DEMO1 DEMO2 DEMO3].freeze
TIERS = %w[commit milestone macos selftest retired].freeze
RUNNABLE = %w[commit milestone macos].freeze
# A tier that must stand alone: nothing an ordinary run selects may also be one
# of the harness's own tests, and a retirement runs nowhere at all.
SOLE = %w[selftest retired].freeze
# What a case needs PRESENT to run. Stage 1 has no artifact cache and the
# runner builds nothing, so what it waits on is the built object, not the
# kernel and compiler that made it; a skip then names the thing that is
# actually missing.
REQUIRES = %w[wad source-lib adapter-lib session-dir].freeze
# What each ROUTE needs present, which is one set per route and not a choice:
# the Ruby route runs the port alone; the compiled route loads the built shared
# object; the session route loads it inside a session directory; the adapter
# route goes through the adapter's own object instead. A row declaring anything
# else either runs without a prerequisite or skips where it should have run.
ROUTE_REQUIRES = {
  "ruby" => %w[wad],
  "compiled" => %w[wad source-lib],
  "session" => %w[wad source-lib session-dir],
  "adapter" => %w[wad adapter-lib session-dir]
}.freeze
# Every perturbation the lane declares. `-` is an unperturbed run.
VARIANTS = ["-", "fields=wrongslot", "untracked=result",
            "mutate=clear-counters", "mutate=clear-clips", "kill"].freeze
# The modes a pins.rb run name can carry. The matrix is frame mode only; a
# composite check joins runs from other modes, and those parts must be readable
# here in order to be told apart from the frame-mode ones.
RUN_MODES = %w[frame queued direct].freeze

# The controls the lane accepts, read from the program that accepts them: a
# control renamed there and not here would otherwise select nothing and pass.
def controls(path)
  text = File.read(path)
  list = text[/^CONTROLS = %w\[(.*?)\]/m, 1] or
    abort("cases.rb: #{path} has no CONTROLS list; the matrix cannot be checked against it")
  list.split
end

def read_tsv(path)
  File.exist?(path) or abort("cases.rb: no file at #{path}")
  rows = []
  header = nil
  File.readlines(path, chomp: true).each_with_index do |line, i|
    next if line.empty?
    if line.start_with?("#")
      next unless line.count("\t") > 3
      header.nil? or abort("cases.rb: #{path} has a second column header at line #{i + 1}")
      header = line.sub("#", "").split("\t")
      next
    end
    rows << [i + 1, line.split("\t", -1)]
  end
  header or abort("cases.rb: #{path} has no column header")
  [header, rows]
end

# The id a row must carry, built from the row itself. A variant is part of the
# name, so a perturbed run and the case it is judged against are never one id.
def want_id(c)
  base = ["frame", c["route"], c["control"], c["frames"]].join(".")
  c["variant"] == "-" ? base : "#{base}.#{c['variant'].tr('=', '-')}"
end

# A pins.rb run name -> [route, mode, control]. Only the Ruby route's names
# carry all three; the others fold the control into a caller-chosen tag, and a
# composite has never named one.
def run_parts(name)
  segs = name.split("-")
  return nil unless segs[0] == "sp" && segs.length > 2 && RUN_MODES.include?(segs[1])
  ["ruby", segs[1], segs[2..].join("-")]
end

# origin -> [kind, line, part, reason]. kind is :claim, :retired or :new.
def origin(text, revision)
  rev = Regexp.escape(revision)
  case text
  when /\Atick:(\d+)@#{rev}\z/ then [:claim, $1, nil, nil]
  when /\Atick:(\d+)@#{rev} part (\d+)\z/ then [:claim, $1, $2.to_i, nil]
  when /\Atick:(\d+)@#{rev} retired: *(.*)\z/ then [:retired, $1, nil, $2]
  when /\Anew(?:: *(.*))?\z/ then [:new, nil, nil, $1]
  end
end

def check_row(c, known, problems) # rubocop:disable Metrics/MethodLength
  id = c["case_id"]
  { "lane" => LANES, "route" => ROUTES, "mode" => MODES, "demo" => DEMOS, "variant" => VARIANTS }
    .each { |col, vocab| problems << "#{id}: #{col} #{c[col]}" unless vocab.include?(c[col]) }
  problems << "#{id}: control #{c['control']}, which source-port.rb does not accept" unless known.include?(c["control"])
  problems << "#{id}: frames #{c['frames']}" unless c["frames"] =~ /\A\d+\z/
  problems << "#{id}: the row is #{want_id(c)}" unless id == want_id(c)

  tiers = c["tiers"].split(",")
  problems << "#{id}: no tier at all, so nothing selects it" if tiers.empty?
  (tiers - TIERS).each { |t| problems << "#{id}: tier #{t}" }
  SOLE.each { |t| problems << "#{id}: a #{t} case is tiered #{c['tiers']}" if tiers.include?(t) && tiers != [t] }

  requires = c["requires"].split(",")
  problems << "#{id}: no prerequisite, so a skip could not name one" if requires.empty?
  (requires - REQUIRES).each { |r| problems << "#{id}: requirement #{r}" }
  check_requires(c, requires, problems)
end

# The route fixes the set, so what is wrong is named item by item.
def check_requires(c, requires, problems)
  want = ROUTE_REQUIRES[c["route"]] or return # an unknown route is already a problem
  return if requires.sort == want.sort

  missing = want - requires
  unwanted = requires - want
  said = [("missing #{missing.join(',')}" unless missing.empty?),
          ("unwanted #{unwanted.join(',')}" unless unwanted.empty?)].compact.join(", ")
  problems << "#{c['case_id']}: the #{c['route']} route requires #{want.join(',')}, and this row " \
              "declares #{c['requires']} (#{said})"
end

# judged_against. A retirement judges nothing; everything else names a case that
# exists, so a perturbation cannot be judged against an expectation nobody wrote.
# A perturbed row can never carry the name of the case it is judged against,
# because the variant and the frame count are part of the id.
def check_judgement(c, ids, problems)
  id = c["case_id"]
  judged = c["judged_against"]
  if c["tiers"].split(",").include?("retired")
    problems << "#{id}: a retired row judges nothing, so judged_against must be -, not #{judged}" if judged != "-"
    return
  end
  problems << "#{id}: judged against #{judged}, which is not a case" unless ids.include?(judged)
end

# A row that stands in for a pin must run, as itself.
def check_claim(c, problems)
  id = c["case_id"]
  tiers = c["tiers"].split(",")
  problems << "#{id}: stands in for a pin and is tiered #{c['tiers']}, so no ordinary run selects it" \
    if (tiers & RUNNABLE).empty?
  problems << "#{id}: stands in for a pin and is judged against #{c['judged_against']}" if c["judged_against"] != id
  problems << "#{id}: stands in for a pin and carries the variant #{c['variant']}" if c["variant"] != "-"
end

def check_retirement(c, reason, by_id, problems)
  id = c["case_id"]
  unless c["tiers"] == "retired"
    problems << "#{id}: its origin retires a pin and it is tiered #{c['tiers']}"
    return
  end
  if reason.to_s.strip.empty?
    problems << "#{id}: retires a pin with no reason, which 0009 requires of a check not migrated"
    return
  end
  # A reason that points at the surviving case must point at one that exists.
  named_cases(reason).each do |named|
    problems << "#{id}: its reason names #{named}, which is not a case" unless by_id.key?(named)
  end
  # And a ROUTE DUPLICATE must be a duplicate: the surviving case runs the same
  # control on another route. A different control asserts something else, so
  # naming it retires a check that nothing replaces.
  reason.scan(/route duplicate of (frame\.[A-Za-z0-9.=-]+)/).flatten
        .map { |t| t.sub(/[.,;]\z/, "") }.each do |named|
    other = by_id[named] or next
    next if other["control"] == c["control"]
    problems << "#{id}: is retired as a route duplicate of #{named}, which runs the control " \
                "#{other['control']}, not #{c['control']}"
  end
end

def named_cases(reason)
  reason.scan(/frame\.[A-Za-z0-9.=-]+/).map { |t| t.sub(/[.,;]\z/, "") }
end

# The row and the pin it names must describe the same run.
def compare(c, want, line, problems)
  got = [c["route"], c["mode"], c["control"], c["frames"]]
  return if got == want
  problems << "#{c['case_id']}: the pin at #{line} is #{want.join(' ')}, the row says #{got.join(' ')}"
end

# The composite check joins several runs, and only its FRAME-mode parts belong
# to this lane. Each claiming row names which part it is, so claiming the queued
# ones -- which would migrate two refusals nobody asked for and leave the two
# that were asked for unasserted -- is caught by name and not by count alone.
def check_composite(pin, claimed, problems) # rubocop:disable Metrics/MethodLength
  line = pin[4]
  names = pin[2].split(",")
  problems << "the composite pin at #{line} joins #{names.length} runs, and names #{pin[3]}" \
    if names.length.to_s != pin[3]
  parts = names.map { |n| [n, run_parts(n)] }
  parts.each { |n, p| problems << "the composite pin at #{line} names the run #{n}, which is not a readable run name" if p.nil? }
  frame_parts = parts.each_index.select { |i| parts[i][1] && parts[i][1][1] == "frame" }
  taken = {}
  claimed.each do |c, part|
    id = c["case_id"]
    unless part && part.between?(1, names.length)
      problems << "#{id}: claims the composite at #{line} without naming which of its #{names.length} parts it is"
      next
    end
    problems << "#{id}: claims part #{part} of the composite at #{line}, which is also claimed by #{taken[part]}" \
      if taken.key?(part)
    taken[part] = id
    name, p = parts[part - 1]
    next if p.nil?
    unless p[1] == "frame"
      problems << "#{id}: claims part #{part} of the composite at #{line}, the #{p[1]}-mode run #{name}; " \
                  "only its frame-mode parts belong to this lane"
      next
    end
    compare(c, [p[0], p[1], p[2], c["frames"]], "#{line} part #{part}", problems)
  end
  missing = frame_parts.map { |i| i + 1 } - taken.keys
  problems << "the composite pin at #{line} has frame-mode parts claimed by no row: " +
              missing.map { |i| "part #{i} (#{names[i - 1]})" }.join(", ") unless missing.empty?
end

def main # rubocop:disable Metrics/MethodLength
  pins_path = nil
  cases_path = CASES
  args = ARGV.dup
  until args.empty?
    case args.shift
    when "--pins" then pins_path = args.shift
    when "--cases" then cases_path = args.shift
    else abort("usage: cases.rb --pins <pins.tsv> [--cases FILE]")
    end
  end
  pins_path or abort("cases.rb: --pins is required; produce it with harness/pins.rb")

  header, rows = read_tsv(cases_path)
  header == COLUMNS or abort("cases.rb: #{cases_path} has columns #{header.inspect}, expected #{COLUMNS.inspect}")
  _pins_header, pins_rows = read_tsv(pins_path)
  revision = File.readlines(pins_path, chomp: true).grep(/\A# revision\t/).first&.split("\t")&.at(1) or
    abort("cases.rb: #{pins_path} names no revision; it was not written by harness/pins.rb")
  pins = pins_rows.map(&:last)
  known = controls(PORT)

  problems = []
  rows.each do |n, r|
    r.length == COLUMNS.length or
      abort("cases.rb: #{cases_path}:#{n} has #{r.length} fields, not #{COLUMNS.length}")
  end
  cases = rows.map { |_n, r| COLUMNS.zip(r).to_h }
  ids = cases.map { |c| c["case_id"] }
  ids.tally.each { |id, n| problems << "case id #{id} appears #{n} times" if n > 1 }
  # id -> row, for the checks that must look at the case a reason names.
  by_id = cases.to_h { |c| [c["case_id"], c] }

  claims = {}   # tick.sh line -> [[case, part], ...]
  retired = {}  # tick.sh line -> [case, ...]
  new_rows = 0
  cases.each do |c|
    check_row(c, known, problems)
    check_judgement(c, ids, problems)
    kind, line, part, reason = origin(c["origin"], revision)
    unless kind
      problems << "#{c['case_id']}: origin #{c['origin']}, which names neither a pin at #{revision} nor a new case"
      next
    end
    case kind
    when :claim
      check_claim(c, problems)
      (claims[line] ||= []) << [c, part]
    when :retired
      check_retirement(c, reason, by_id, problems)
      (retired[line] ||= []) << c
    when :new
      new_rows += 1
      problems << "#{c['case_id']}: origin new with no reason" if reason.to_s.strip.empty?
      problems << "#{c['case_id']}: is tiered retired and its origin retires no pin" if c["tiers"] == "retired"
    end
  end

  # EVERY PIN IS ACCOUNTED FOR, ONCE, ON ONE SIDE OR THE OTHER.
  counts = { claimed: 0, retired: 0, unaccounted: 0 }
  pins.each do |pin|
    route, mode, control, frames, line, * = pin
    claimed = claims[line] || []
    gone = retired[line] || []
    if !claimed.empty? && !gone.empty?
      problems << "the pin at #{line} is both claimed by #{claimed.map { |c, _| c['case_id'] }.join(', ')} " \
                  "and retired by #{gone.map { |c| c['case_id'] }.join(', ')}"
      next
    end
    if claimed.empty? && gone.empty?
      counts[:unaccounted] += 1
      problems << "the pin at #{line} (#{route} #{control} #{frames}) is claimed by no row and retired by none"
      next
    end
    unless gone.empty?
      counts[:retired] += 1
      problems << "the pin at #{line} is retired by #{gone.length} rows" if gone.length != 1
      gone.each { |c| compare(c, [route, mode, control, frames], line, problems) }
      next
    end
    counts[:claimed] += 1
    if route == "composite"
      problems << "the composite pin at #{line} is claimed by #{claimed.length} rows, expected its 2 frame-mode parts" \
        unless claimed.length == 2
      check_composite(pin, claimed, problems)
      next
    end
    if claimed.length != 1
      problems << "the pin at #{line} (#{route} #{control} #{frames}) is claimed by #{claimed.length} rows"
      next
    end
    c, part = claimed.first
    problems << "#{c['case_id']}: names part #{part} of the pin at #{line}, which joins no runs" if part
    compare(c, [route, mode, control, frames], line, problems)
  end
  (claims.keys + retired.keys).uniq.each do |line|
    problems << "a row names tick.sh line #{line}, where the extractor found no pin" unless pins.any? { |p| p[4] == line }
  end

  problems.each { |p| puts "cases: #{p}" }
  tiers = TIERS.to_h { |t| [t, cases.count { |c| c["tiers"].split(",").include?(t) }] }
  puts "cases: #{cases.length} rows, #{pins.length} pins, #{problems.length} problems"
  puts "cases: tiers #{tiers.map { |t, n| "#{t} #{n}" }.join(', ')}"
  puts "cases: origins claim #{claims.values.sum(&:length)}, retired #{retired.values.sum(&:length)}, new #{new_rows}"
  puts "cases: pins claimed #{counts[:claimed]}, retired #{counts[:retired]}, unaccounted #{counts[:unaccounted]}"
  exit(problems.empty? ? 0 : 1)
end

main
