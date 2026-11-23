# frozen_string_literal: true
#
# tools/app/lib/core_app/contracts.rb -- writes one `core-contract 2` per
# application entry (the plan's "core-contract 2"), and packages the root the
# contracts name.
#
# THE CONTRACT IS WRITTEN FROM DECLARATIONS ONLY. The context is the trigger's;
# the parameters are the entry's state names with their declared element and
# count; `cross` marks a state that entries of more than one context name
# (0014 §5: reached from more than one context); the externs are every member
# the file references that the board, the channels or the application declare,
# with the guards and statics of the generated packages. What the entry does
# with them -- writes, call counts, the closure -- is the kernel's to derive
# and report, and the cross-entry checks read the reports.
#
# THE PACKAGED ROOT is one file: the application, then `spinel/net.rb`, then
# one module per board and channel module, holding that module's integer
# constants and nothing else (0014 D5: `Led::COUNT`) (the kernel reads the
# declarations from the contract, and the pinned analyser must see no
# `core_extern` in the snapshot, and no `require`, which the pinned analyser
# refuses when it cannot satisfy it: each `require` line of the application
# becomes a comment on the same line, and so does each line of its own
# `core_extern` declarations, so the map still holds). It follows
# 0008's source-pack approach --
# units read once, digested, joined by nothing but a newline, with a map from
# packed lines back to unit and digest -- without the 0008 packer itself,
# whose rules refuse the declaration calls an application file consists of.
require "digest"
require_relative "app_model"

module CoreApp
  module Contracts
    module_function

    # Writes `<dir>/<entry>.contract` for every entry and returns
    # {entry name => path}. `board` and `channels` are the externs of the two
    # packages (Extern values); `root` is the packaged root's file name.
    def write(app, board, channels, dir, root: "app.rb")
      externs = referenced(app, board + channels + app.externs)
      contexts = contexts_of_states(app)
      app.scheduled.to_h do |entry, trigger|
        lines = ["core-contract 2", "root #{root}", "entry #{entry.name}", "context #{trigger.context}", "result none"]
        # decision 0041 stage 2: the context's data stack, when it declares one
        lines << "scratch #{app.scratches[trigger.context]}" if app.scratches[trigger.context]
        entry.params.each do |p|
          s = app.state(p)
          cross = contexts.fetch(s.name, []).size > 1 ? " cross" : ""
          lines << "param #{s.name} buffer #{s.element} inout count const #{s.count}#{cross}"
        end
        externs.each { |e| lines << extern_line(e) }
        path = File.join(dir, "#{entry.name}.contract")
        File.write(path, lines.join("\n") + "\n")
        [entry.name, path]
      end
    end

    # The declared externs the file references, in declaration order; a
    # reference to an undeclared member is the checks' `unknown-member`, and
    # not the contract writer's to report.
    def referenced(app, declared)
      names = app.member_refs.map(&:full).uniq
      declared.select { |e| names.include?(e.full) }
    end

    # State name => the contexts of the entries naming it.
    def contexts_of_states(app)
      app.scheduled.each_with_object({}) do |(entry, trigger), h|
        entry.params.each { |p| (h[p] ||= []) << trigger.context unless (h[p] ||= []).include?(trigger.context) }
      end
    end

    def extern_line(e)
      parts = ["extern #{e.full} symbol #{e.symbol}"]
      e.params.each do |p|
        if p.buffer?
          parts << "arg #{p.name} buffer #{p.type} #{e.writes.include?(p.name) ? 'inout' : 'in'}"
        else
          parts << "arg #{p.name} #{p.type}"
        end
      end
      parts << "returns #{e.returns}" if e.returns
      parts << "isr_ok" if e.isr_ok
      e.guards.each { |g| parts << "guard #{g}" }
      e.statics.each { |s| parts << "static #{s}" }
      parts << "bound #{e.bound} evidence evidence/#{e.symbol}.json"
      parts.join(" ")
    end

    Unit = Struct.new(:path, :bytes, :sha256, :start, :finish, keyword_init: true)

    # A helper's unit name in the pack map, and its file: the units
    # relocate maps back to their sources.
    def helper_unit(name) = "helper/#{name.end_with?('.rb') ? name : "#{name}.rb"}"
    def units_of(app, net) = { "app.rb" => app.path, "spinel/net.rb" => net }.merge(app.helpers.to_h { |(n, _l, p)| [helper_unit(n), p] })

    # The application's bytes with its `require` lines and its own
    # `core_extern` declarations turned into comments, line for line, so the
    # snapshot holds no declaration the pinned analyser would expand and the
    # map's line numbers stay the source's.
    def blank_requires(app)
      lines = File.binread(app.path).lines
      app.requires.each { |(name, line)| lines[line - 1] = "# packed: require #{name.inspect}\n" }
      # decision 0021: the session is the tool's to place, not the kernel's to read
      lines[app.session_line - 1] = "# packed: core_session #{app.session_path.inspect}\n" if app.session_line
      app.externs.each do |e|
        (e.line..e.end_line).each { |l| lines[l - 1] = "# packed: core_extern #{e.full}#{l == e.line ? '' : ' (continued)'}\n" }
      end
      lines.join
    end

    # Packs the root: `<dir>/<root>` and `<dir>/<root>.map`. Returns the
    # packed file's sha256. `net` is the path of spinel/net.rb.
    def pack(app, board, channels, net, dir, root: "app.rb", constants: {})
      units = []
      units << Unit.new(path: "app.rb", bytes: blank_requires(app), sha256: Digest::SHA256.file(app.path).hexdigest)
      # decision 0027: each helper file, as it is, after the application
      app.helpers.each { |(name, _line, path)| units << Unit.new(path: helper_unit(name), bytes: File.binread(path)) }
      units << Unit.new(path: "spinel/net.rb", bytes: File.binread(net))
      # A module the application declares its own extern for is not emitted as
      # a stub: the application's own `module` block carries that declaration.
      stubs = (board + channels).map(&:module_name).uniq - app.externs.map(&:module_name)
      # DECISION 0014 D5: the board's constants are written inside their own
      # module (`Led::COUNT`), so each module is emitted with its constants in
      # its body. A module's CONSTANTS are emitted whether or not the
      # application declares its own extern for that module -- the application
      # declares members, never the board's constants, and dropping them would
      # leave `Led::LED0` unresolvable in exactly the applications that extend
      # `Led`. Ruby reopens the module; the kernel reads both bodies.
      by_module = constants.each_with_object({}) do |(k, v), h|
        mod, name = k.split("::", 2)
        raise "the board package's constant #{k} is not `Mod::NAME`" unless name
        (h[mod] ||= []) << [name, v]
      end
      decl = (stubs | by_module.keys).map do |m|
        "module #{m}\n" + (by_module[m] || []).map { |(n, v)| "  #{n} = #{v}\n" }.join + "end\n"
      end.join
      units << Unit.new(path: "<declared modules>", bytes: decl) unless decl.empty?
      out = +""
      line = 1
      units.each do |u|
        u.sha256 ||= Digest::SHA256.hexdigest(u.bytes)
        text = u.bytes.dup.force_encoding("UTF-8")
        raise "#{u.path} is not valid UTF-8" unless text.valid_encoding?
        text << "\n" unless text.end_with?("\n")
        u.start = line
        u.finish = line + text.count("\n") - 1
        line = u.finish + 1
        out << text
      end
      File.binwrite(File.join(dir, root), out)
      sha = Digest::SHA256.hexdigest(out)
      map = +"# core-app pack map\n# packed #{root} sha256 #{sha}\n# app.rb: its require lines (#{app.requires.map(&:last).join(', ')}) are comments in the pack; the digest is the source's\n# start\tend\tunit\tsha256\n"
      units.each { |u| map << [u.start, u.finish, u.path, u.sha256].join("\t") << "\n" }
      File.write(File.join(dir, "#{root}.map"), map)
      sha
    end

    # The kernel names the packed root, `<dir>/<root>:<line>:` (the directory
    # perhaps through another spelling of its real path). Through the
    # map pack wrote beside it, each such place becomes the unit's own file
    # and line: `units` maps a unit's name in the map (`app.rb`,
    # `spinel/net.rb`) to its path. A line in no named unit is left alone.
    def relocate(text, dir, units, root: "app.rb")
      map = File.join(dir, "#{root}.map")
      return text unless File.exist?(map)
      rows = File.readlines(map, chomp: true).reject { |l| l.start_with?("#") }.map { |l| l.split("\t") }
      home = (File.realpath(dir) rescue dir)
      text.gsub(/(?<![\w\/.])((?:[^\s:]*\/)?)#{Regexp.escape(root)}:(\d+):/) do |m|
        prefix, line = Regexp.last_match(1), Regexp.last_match(2).to_i
        # only the packed root: the bare name, or a path into this directory
        next m unless prefix.empty? || ((File.realpath(prefix) rescue nil) == home)
        row = rows.find { |r| r[0].to_i <= line && line <= r[1].to_i }
        path = row && units[row[2]]
        path ? "#{path}:#{line - row[0].to_i + 1}:" : m
      end
    end
  end
end
