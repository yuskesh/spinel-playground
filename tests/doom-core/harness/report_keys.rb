# tests/doom-core/harness/report_keys.rb — a report's printed lines, as keys.
#
# The frame lane has two sides that must reach the same verdict during the
# 0009 stage 1 migration: the pinned strings in tick.sh, and the result records
# source-port.rb writes. This turns the FIRST into the SECOND's key names, so
# that the two are compared key by key rather than as joined strings.
#
# It is deliberately NOT the record's own key builder. The record builds its
# keys beside the lines, from the values those lines print; this reads the
# printed text back. Running both over one run and requiring equality is the
# check that neither drifted -- tests/doom-core/harness/keys-agree.rb does it.
#
# EVERY LINE MUST BE CLAIMED, WHOLE. A line no rule matches, a line a rule
# gives up on part way through, and a line whose keys an earlier line already
# gave are all returned in `unparsed`, and contribute no keys; a caller that
# ignores them is reading a report it does not understand. `fctl` in tick.sh
# drops lines from a control pin, so a parsed
# report is a subset of a whole one; that is expected, and absence is never
# read as a value.
#
# The record also holds keys no printed line carries -- `first_at.<kind>.frame`
# and `.tic`, taken where the fault was raised. Those can only come from a run.
#
# ONE REPORT IS ONE RUN. The pin at tick.sh's composite refusal check joins the
# output of four runs, so it is refused here rather than flattened: the second
# run's `rc=1` would otherwise silently overwrite the first's. That check
# becomes four cases, each with its own report.

module ReportKeys
  # The clear line's two field lists, in the order source-port.rb prints them.
  CLEAR_LOADED = %w[lastvisplane lastopening floorplane ceilingplane floorclip ceilingclip].freeze
  CLEAR_MISMATCH = %w[lastvisplane lastopening floorplane ceilingplane basexscale baseyscale
                      floorclip ceilingclip cachedheight].freeze

  # text -> [keys, unparsed lines]. `text` is either the program's stdout or a
  # pin with its "|" separators turned back into newlines.
  def self.parse(text)
    keys = {}
    unparsed = []
    text.split("\n").each do |l|
      next if l.empty?
      # A line's keys land in the report's map only once the WHOLE line is
      # claimed: a rule that gives up half way leaves nothing behind, so a key
      # is never evidence of a line the parser did not actually understand.
      one = {}
      unless claim(l, one)
        unparsed << l
        next
      end
      dup = one.keys.find { |k| keys.key?(k) }
      if dup
        unparsed << "#{l} (the key #{dup} was already given by an earlier line)"
        next
      end
      keys.merge!(one)
    end
    [keys, unparsed]
  end

  def self.pin(expected)
    parse(expected.split("|").join("\n"))
  end

  # One line. Returns false when no rule claims it.
  def self.claim(l, k) # rubocop:disable Metrics/MethodLength
    case l
    when /\Aproducers added (\d+) markers (\d+) pre-tick port (.+) original (.+)\z/
      k["run.producers"], k["run.markers"] = $1.to_i, $2.to_i
      k["run.pre_port"], k["run.pre_original"] = $3, $4
    when /\Atics (\d+) columns (\d+) spans (\d+)\z/
      k["run.tics"], k["run.columns"], k["run.spans"] = $1.to_i, $2.to_i, $3.to_i
    when /\Aframes (\d+) wall-jobs (\d+) span-jobs (\d+) masked-jobs (\d+) zone-jobs (\d+) resets (\d+) of (\S+) cells\z/
      k["run.frames"], k["run.wall_jobs"], k["run.span_jobs"] = $1.to_i, $2.to_i, $3.to_i
      k["run.masked_jobs"], k["run.zone_jobs"], k["run.resets"] = $4.to_i, $5.to_i, $6.to_i
      k["run.reset_cells"] = $7
    when /\Aframe pushes wall (\d+) masked (\d+) marks (\d+) checks (\d+)\z/
      k["pushes.wall"], k["pushes.masked"], k["pushes.marks"], k["pushes.checks"] =
        $1.to_i, $2.to_i, $3.to_i, $4.to_i
    # THREE SHAPES, ALL REAL, AND THE TWO OPTIONAL GROUPS ARE NESTED BECAUSE THE
    # SHAPES ARE. The line grew twice and never shrank, so each shape is the one
    # before it plus a suffix, and nesting is what says so: a line naming the
    # port's recognized sky planes without naming the sky columns is a shape this
    # lane has never printed, and two independent `?` groups would quietly accept
    # it. In order:
    #
    #   oldest   the frozen pins, tick.sh at e2f5676, from before the walk was
    #            ported; a pin is never edited, so this shape is permanent;
    #   middle   a record written from 94804d4, where the whole plane walk and
    #            the sky plane drawn as texture columns added the sky-column
    #            counts. Records already written in that shape must keep parsing;
    #   newest   the port's own recognized sky-plane count beside them.
    when %r{\Aframe planes: drawn (\d+) \(sky (\d+)\) spans emitted (\d+)(?: sky columns (\d+) \(sky planes with columns (\d+)\)(?: sky planes recognized by the port (\d+))?)? planes compared (\d+) sentinels compared (\d+) clears (\d+); loaded from the original (.+)\z}
      k["planes.drawn"], k["planes.sky"], k["planes.spans_emitted"] = $1.to_i, $2.to_i, $3.to_i
      # Absent in an older shape, and absent is not zero: a line that does not
      # name them yields no key, which is what `dynamic` in the inventory means.
      unless $4.nil?
        k["planes.sky_columns"], k["planes.sky_planes_with_columns"] = $4.to_i, $5.to_i
      end
      k["planes.sky_planes_recognized"] = $6.to_i unless $6.nil?
      k["planes.compared"], k["planes.sentinels"], k["planes.clears"] = $7.to_i, $8.to_i, $9.to_i
      k["planes.loaded"] = $10
    when /\Aclears (\d+): the port loaded with the original's pre-clear values, differing from what clear_planes writes at (.+); mismatches after the port's clear (.+)\z/
      k["clears.count"] = $1.to_i
      fields(CLEAR_LOADED, $2, "clears.loaded.", k) && fields(CLEAR_MISMATCH, $3, "clears.mismatch.", k) or
        return false
    when /\Aframe check statistics reached ?(.*?) ?slots compared (\d+)\z/
      stats, k["checks.slots_compared"] = $1, $2.to_i
      k["checks.stats_text"] = stats
      stats.split.each do |pair|
        name, value = pair.split("=", 2)
        return false unless value =~ /\A-?\d+\z/
        k["checks.#{name}"] = value.to_i
      end
    when /\Aframe executor runs (\d+) jobs (\d+) fuzz-columns (\d+) screens compared (\d+) x (\d+) bytes\z/
      k["exec.runs"], k["exec.jobs"], k["exec.fuzz_columns"] = $1.to_i, $2.to_i, $3.to_i
      k["exec.screens"], k["exec.screen_bytes"] = $4.to_i, $5.to_i
    # THE RECORDING, THE FURNITURE AND A SKIPPED COPY, printed after e2f5676, so
    # no frozen pin carries them: the golden line only where a recording is named,
    # the end-of-frame line only where the furniture is drawn, the copy line only
    # where a boundary copy is skipped.
    when /\Aframes compared against the recording (\d+), full screen agreeing (\d+)\z/
      k["golden.frames"], k["golden.full_agree"] = $1.to_i, $2.to_i
    when /\Ascreens compared at the end of the frame (\d+)\z/
      k["furniture.screens_end"] = $1.to_i
    when /\Ademo (\S+) map (\S+) tics (\d+)\z/
      k["run.demo"], k["run.map"], k["run.demo_tics"] = $1, $2, $3.to_i
    when /\Aleaves calls (\S+) new-planes fplane=(\d+),chplane=(\d+)\z/
      calls, fp, cp = $1, $2.to_i, $3.to_i
      k["leaves.new_planes.fplane"], k["leaves.new_planes.chplane"] = fp, cp
      calls.split(",").each do |call|
        call =~ /\A([a-z]+)=(\d+)\z/ or return false
        k["leaves.#{$1}"] = $2.to_i
      end
    when /\Acopy mobj alloc-max (\d+) cells (\d+) new-vissprites (\d+)\z/
      k["copy.mobj_alloc_max"], k["copy.mobj_cells"], k["leaves.new_vissprites"] = $1.to_i, $2.to_i, $3.to_i
    when /\Acopy sectors cells (\d+)\z/
      k["copy.sector_cells"] = $1.to_i
    when /\Asegloop columns (\d+) masked-calls (\d+) original-pushes (\d+)\z/
      k["segloop.columns"], k["segloop.masked_calls"], k["segloop.original_pushes"] = $1.to_i, $2.to_i, $3.to_i
    when /\Afurniture branches na (\d+) key-erase (\d+)\z/
      k["furniture.na"], k["furniture.key_erase"] = $1.to_i, $2.to_i
    when /\Afurniture drawn (yes|no)\z/
      k["furniture.drawn"] = $1
    when /\Acopy skipped (\S+) first disagreement frame (\d+|none) expected (\d+)\z/
      k["copy.skipped"], k["copy.expected"] = $1, $3.to_i
      # `none` is recorded as -1, the "not here" spelling first_at uses.
      k["copy.first_frame"] = $2 == "none" ? -1 : $2.to_i
    when /\Asites (.*)\z/
      $1.split(",").each do |site|
        site =~ /\A(\S+)=(\d+)@(\S+)\z/ or return false
        k["sites.#{$1}.count"], k["sites.#{$1}.first"] = $2.to_i, $3
      end
    when /\Amasked remaining wad-min (\S+) zone-max (\S+) zone-windows (\d+)\z/
      k["remaining.wad_min"], k["remaining.zone_max"] = num_or_dash($1), num_or_dash($2)
      k["remaining.zone_windows"] = $3.to_i
    when /\Anative calls (.*)\z/
      $1.split(",").each do |call|
        call =~ /\A(\S+)=(\d+)\z/ or return false
        k["native.#{$1}"] = $2.to_i
      end
    when /\Afaults (.+)\z/
      # kind and count, alternating, to the end of the line: a word that is not
      # one of those pairs means this is not the line we think it is.
      words = $1.split
      return false unless words.length.even?
      words.each_slice(2) do |kind, n|
        return false unless n =~ /\A\d+\z/
        k["faults.#{kind}"] = n.to_i
      end
    when /\Afirst (\S+) (.+)\z/
      k["first.#{$1}"] = $2
    when /\Arc=(\d+)\z/
      k["rc"] = $1.to_i
    when /\Asource-port\.rb: (.+)\z/
      # A refused run prints one message and nothing else. The record carries
      # the same text as `ended`, under `outcome` "refused".
      k["refusal"] = $1
    when /\Asession fields (\d+) pre-tick (.+)\z/
      k["session.fields"] = $1.to_i
      $2.split.each do |pair|
        pair =~ /\A(\S+)=(-?\d+)\z/ or return false
        k["session.pre.#{$1}"] = $2.to_i
      end
    when /\Asession selector slots hold the original's converted choice at the end (yes|no)\z/
      k["session.selectors_held"] = $1
    when /\Asession other core_state slots changed (\d+)( first (\S+))?\z/
      k["session.other_slots_changed"] = $1.to_i
      k["session.other_slots_first"] = $3 || "-"
    when /\Asession read-only fields changed (\d+) of (\d+)(.*)\z/
      k["session.readonly_changed"], k["session.readonly_read_back"] = $1.to_i, $2.to_i
      # The line names a separate total only where fewer fields were read back
      # than the session holds, and a first field only where one moved.
      tail, compared = $3.dup, $2
      total = tail.slice!(/\A read back, of (\d+)/) && $1
      first = tail.slice!(/\A first (\S+)\z/) && $1
      return false unless tail.empty?
      k["session.readonly_total"] = (total || compared).to_i
      k["session.readonly_first"] = first || "-"
    when /\Aadapter session failed at (.+): no further invoke, no poisoned buffer read\z/
      k["adapter.session_failed"] = $1
    when /\Aadapter a refused column answers (-?\d+); its screen then answers a load (-?\d+) and a step (-?\d+); its read-only colormap and state still load (\S+) (-?\d+)\z/
      k["adapter.refused_column_answers"], k["adapter.screen_load"], k["adapter.screen_step"] =
        $1.to_i, $2.to_i, $3.to_i
      k["adapter.readonly_colormap"], k["adapter.readonly_state"] = $4, $5.to_i
    when /\Aadapter core_state passed as both the reset's state and its table answers (-?\d+)\z/
      k["adapter.duplicate_participant"] = $1.to_i
    when /\Aadapter ids allocated (\d+), released once (\d+), (.+)\z/
      k["adapter.ids_allocated"], k["adapter.ids_released_once"] = $1.to_i, $2.to_i
      k["adapter.second_release"] =
        case $3
        when "every id then refuses a second release" then "refused"
        when /\Aa second release is accepted by (.+), never released\z/ then $1
        else return false
        end
    else
      return false
    end
    true
  end

  # "a=1 b=2" against the field list the line is built from: the names and their
  # order must be exactly that list, or the line is not the line we think it is.
  def self.fields(names, text, prefix, k)
    pairs = text.split.map { |p| p.split("=", 2) }
    return false unless pairs.map(&:first) == names
    return false unless pairs.all? { |_, v| v =~ /\A-?\d+\z/ }
    pairs.each { |name, v| k["#{prefix}#{name}"] = v.to_i }
    true
  end

  def self.num_or_dash(s)
    s == "-" ? "-" : s.to_i
  end
end
