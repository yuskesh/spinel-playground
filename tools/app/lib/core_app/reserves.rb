# frozen_string_literal: true
#
# tools/app/lib/core_app/reserves.rb -- attested reserves and driver rows
# (decision 0014 §9; the plan's Task 9 and "Tables").
#
# A reserve row is an attestation with a justification, never an observed
# high-water mark: `bytes` is the sum of the frames along a path traced by
# hand from the pinned source (tools/app/zephyr/<release>/reserve-harness/
# paths/<board>/<item>.tsv), each frame from the pinned build's GCC `.su`
# file, an assembly handler's pushes read from its source, or the hardware
# exception frame. `applies_when` names the Kconfig symbols and the board
# the path depends on; a row applies only when every predicate holds.
#
# What this file decides:
#   - `applicable(rows, item, config, board)`: the row for an item under a
#     build, or nil -- and nil is never defaulted: the caller's verdict
#     becomes `unknown` (under `realtime`, a refusal);
#   - `path_sum(path, su)`: the bytes a path file justifies, recomputed from
#     the `.su` index of a fresh build, so `reserves.tsv` can be checked
#     against its own justification;
#   - the irq rows and vector classes, read for the inventory (Task 10).
module CoreApp
  module Reserves
    class Error < StandardError; end

    Row = Struct.new(:item, :bytes, :method, :applies_when, :evidence, :line, keyword_init: true)
    IrqRow = Struct.new(:compatible, :irq_source, :priority_source, :post_init_changes, :envelope, :applies_when, :evidence, :line, keyword_init: true)
    VectorClass = Struct.new(:klass, :symbol, :line, keyword_init: true)
    PathStep = Struct.new(:function, :source, :note, keyword_init: true)
    # `su_steps` counts the steps recomputed from the build; a path with none
    # is a literal-only attestation that the recomputation cannot check.
    PathSum = Struct.new(:bytes, :steps, :missing, :su_steps, keyword_init: true)

    # The items every build needs (0014 §9), and the SVC handler's; the
    # isr_<driver> items are per board and read from the table.
    ITEMS = %w[thread_switch thread_kernel_calls isr_entry_exit pendsv svc timer_dispatch uart_calls guard_area].freeze

    module_function

    def read_tsv(path, columns)
      rows = []
      File.foreach(path).with_index(1) do |ln, i|
        next if ln.start_with?("#") || ln.strip.empty?
        f = ln.chomp.split("\t", -1)
        raise Error, "#{path}:#{i}: #{f.size} column(s), want #{columns}" unless f.size == columns
        rows << [f, i]
      end
      rows
    end

    def read(path)
      rows = read_tsv(path, 5).map do |f, i|
        raise Error, "#{path}:#{i}: bytes is a non-negative integer" unless f[1].match?(/\A\d+\z/)
        Row.new(item: f[0], bytes: f[1].to_i, method: f[2], applies_when: f[3], evidence: f[4], line: i)
      end
      # an item with several rows is told apart by board=; a row without
      # that predicate would be invisible under the other board's name
      # rather than in error
      rows.group_by(&:item).each do |item, rs|
        next if rs.size == 1
        bad = rs.reject { |r| r.applies_when.include?("board=") }
        raise Error, "#{path}: #{item} has #{rs.size} rows and line #{bad.first.line} names no board=" unless bad.empty?
      end
      rows
    end

    def read_irq_rows(path)
      rows = read_tsv(path, 7).map do |f, i|
        f.each_with_index { |v, k| raise Error, "#{path}:#{i}: column #{k + 1} is empty" if v.strip.empty? }
        applies?(f[5], {}, "") # the predicate grammar, refused here rather than at use (`always` is the empty set)
        IrqRow.new(compatible: f[0], irq_source: f[1], priority_source: f[2], post_init_changes: f[3],
                   envelope: f[4], applies_when: f[5], evidence: f[6], line: i)
      end
      # a compatible may have several rows, one per configuration of its
      # driver (the LPUART with and without its ISR support compiled); they
      # are told apart by their predicates, so two with the same predicate
      # are refused here, and two that both apply are refused by the
      # inventory
      dup = rows.map { |r| [r.compatible, r.applies_when] }.tally.select { |_, n| n > 1 }.keys
      raise Error, "#{path}: compatible listed twice under one predicate: #{dup.map { |c, a| "#{c} (#{a})" }.join(', ')}" unless dup.empty?
      rows
    end

    def read_vector_classes(path)
      read_tsv(path, 2).map do |f, i|
        raise Error, "#{path}:#{i}: class is reset, terminal or default" unless %w[reset terminal default].include?(f[0])
        VectorClass.new(klass: f[0], symbol: f[1], line: i)
      end
    end

    # `.config` text to {name => value}; a symbol that is not set is absent.
    def read_config(text)
      text.each_line.each_with_object({}) do |ln, h|
        m = ln.chomp.match(/\A(CONFIG_\w+)=(.*)\z/) or next
        h[m[1]] = m[2].strip.delete_prefix('"').delete_suffix('"')
      end
    end

    # Every predicate holds: `CONFIG_X=value` against the build's `.config`
    # (`=n` means the symbol is not set), `board=<name>` against the board;
    # `always` names an empty predicate set, so no cell is empty.
    def applies?(predicates, config, board)
      return true if predicates == "always"
      predicates.split(",").map(&:strip).reject(&:empty?).all? do |p|
        k, v = p.split("=", 2)
        raise Error, "applies_when predicate `#{p}` is `CONFIG_X=value` or `board=name`" unless k && v
        if k == "board" then board == v
        elsif v == "n" then !config.key?(k)
        else config[k] == v
        end
      end
    end

    # The one applicable row for `item`, or nil. Two applicable rows for one
    # item is a table error, not a choice.
    def applicable(rows, item, config, board)
      found = rows.select { |r| r.item == item && applies?(r.applies_when, config, board) }
      raise Error, "reserves: #{found.size} rows apply to #{item} on #{board}; one is required" if found.size > 1
      found.first
    end

    # The verdict over the needed items: [:pass, {item => row}] or
    # [:unknown, [items without a row]].
    def verdict(rows, items, config, board)
      missing = []
      found = {}
      items.each do |it|
        r = applicable(rows, it, config, board)
        r ? found[it] = r : missing << it
      end
      missing.empty? ? [:pass, found] : [:unknown, missing]
    end

    # ---- the justification
    # Every `.su` under a build directory: function name => [[frame,
    # file:line, qualifier], ...], one entry per definition (a definition
    # compiled twice keeps both entries, so differing frames are seen). The
    # qualifier is GCC's `static`, `dynamic` or `dynamic,bounded`: only a
    # `static` frame is a number a reserve can rest on, and a path step on a
    # non-static one is refused. A name defined in more than one file (a
    # weak default and a driver's own) is settled by the path file naming
    # the file, `su:<file>`; unqualified, such a name is refused rather than
    # summed on a guess.
    def su_index(build_dir)
      index = Hash.new { |h, k| h[k] = [] }
      Dir.glob(File.join(build_dir, "**", "*.su")).sort.each do |f|
        File.foreach(f) do |ln|
          m = ln.chomp.match(/\A(.*?):(\d+):(\d+):(\S+)\t(\d+)\t([\w,]+)\z/)
          raise Error, "#{f}: unreadable .su line: #{ln.chomp.inspect}" if m.nil? && !ln.strip.empty?
          next if m.nil?
          name = m[4].sub(/\.(constprop|isra|part|cold)\.\d+\z/, "")
          where = "#{m[1].sub(%r{\A.*?/zephyr/}, '')}:#{m[2]}"
          index[name] << [m[5].to_i, where, m[6]] unless index[name].any? { |n, w, _| w == where && n == m[5].to_i }
        end
      end
      index
    end

    def read_path(path)
      read_tsv(path, 3).reject { |f, _| f[0] == "function" }.map { |f, _| PathStep.new(function: f[0], source: f[1], note: f[2]) }
    end

    # The sum a path file justifies against a `.su` index; `missing` names
    # the steps the index cannot settle.
    def path_sum(path, su)
      steps = read_path(path)
      total = 0
      missing = []
      detail = []
      su_steps = 0
      missing << "the path has no step" if steps.empty?
      steps.each do |st|
        case st.source
        when "su", /\Asu:(.+)\z/
          file = Regexp.last_match(1) if st.source != "su"
          entries = su.key?(st.function) ? su[st.function] : []
          entries = entries.select { |_, w, _| w.start_with?(file + ":") } if file
          if entries.empty?
            missing << "#{st.function}: no .su entry#{file ? " in #{file}" : ''} in this build"
          elsif entries.map(&:first).uniq.size > 1
            missing << "#{st.function}: defined more than once with different frames (#{entries.map { |n, w, _| "#{w}: #{n}" }.join(', ')}); name the file as su:<file>"
          elsif entries.first[2] != "static"
            missing << "#{st.function}: its frame is #{entries.first[2]}, not static; no reserve rests on it"
          else
            total += entries.first[0]
            su_steps += 1
            detail << [st.function, entries.first[0], entries.first[1]]
          end
        when /\Aasm:(\d+)\z/, /\Ahw:(\d+)\z/
          total += Regexp.last_match(1).to_i
          detail << [st.function, Regexp.last_match(1).to_i, st.source]
        else
          missing << "#{st.function}: source #{st.source.inspect} is su, su:<file>, asm:<bytes> or hw:<bytes>"
        end
      end
      PathSum.new(bytes: total, steps: detail, missing: missing, su_steps: su_steps)
    end

    # The C header the harness is built against: one macro per item.
    def header(found)
      out = +"/* generated by tests/app/reserves.sh from reserves.tsv: the reserves this\n * harness is built against, for its board */\n"
      found.each { |item, row| out << "#define SPC_RESERVE_#{item.upcase} #{row.bytes}u\n" }
      out
    end
  end
end
