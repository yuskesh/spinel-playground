# frozen_string_literal: true
#
# tools/app/lib/core_app/app_checks.rb -- the cross-entry checks of decision
# 0014 §3, §4 and §5, over the kernel's per-entry reports.
#
# The kernel admits one entry at a time and knows nothing of the others. What
# needs every entry -- which context writes a state, which contexts reach a
# device, which contexts stand at a channel's end -- is decided here, from the
# reports' derived facts (the write set, the externs each entry reaches with
# the constant arguments at each site) and the declarations' contexts. Nothing
# here re-derives reachability from the source.
#
# Codes, each with a fixture under tests/app/fixtures/apps/ that trips it:
#
#   shared-writer   a cross-context state written from two contexts (§5)
#   device-owner    a device reached from two contexts (§4); a device is a
#                   board.tsv row, identified by its node_path, and a call
#                   whose instance index is not a literal reaches every
#                   instance of the module
#   channel-end     a channel's CORE end used from two contexts (§5: one
#                   producer context, one consumer context)
#   channel-buffer  `get` into a state shorter than the channel's size (§5),
#                   which the kernel refuses through the extern's static; the
#                   refusal is carried here under its code
#   unknown-member  a reference to a member no package declares (§3)
#   member-effect   an extern that is not isr_ok reached from interrupt
#                   context, or one whose instance is blocking or of unknown
#                   blocking, which `realtime` refuses (§3, §6)
#   declaration     a malformed declaration (Declarations raises these; the
#                   tool maps them to the same Diagnostic)
require "json"
require_relative "app_model"

module CoreApp
  module AppChecks
    # One board.tsv row: `module index name node_path compatible bus isr_ok
    # blocking evidence`.
    BoardRow = Struct.new(:module_name, :index, :name, :node_path, :compatible, :bus, :isr_ok, :blocking, :evidence,
                          keyword_init: true)

    module_function

    def read_board_tsv(path)
      rows = []
      File.foreach(path).with_index(1) do |ln, i|
        next if ln.start_with?("#") || ln.strip.empty?
        f = ln.chomp.split("\t", -1)
        raise "#{path}:#{i}: #{f.size} column(s), want 9" unless f.size == 9
        rows << BoardRow.new(module_name: f[0], index: Integer(f[1], 10), name: f[2], node_path: f[3], compatible: f[4],
                             bus: f[5], isr_ok: f[6], blocking: f[7], evidence: f[8])
      end
      rows
    end

    # `board` is {externs: [Extern], rows: [BoardRow]}; `channels` the channel
    # package's externs; `reports` is {entry name => parsed report JSON, or
    # {"refused" => [{"code", "line", "detail"}]} for an entry the kernel
    # refused}. Returns the diagnostics, in a fixed order.
    def run(app, board, channels, reports)
      diags = []
      declared = board[:externs] + channels + app.externs
      declared_names = declared.map(&:full)

      # unknown-member: the file's references against the declarations.
      app.member_refs.each do |r|
        next if declared_names.include?(r.full)
        diags << Diagnostic.new(code: "unknown-member", file: app.path, line: r.line,
                                detail: "#{r.full} is not a member of the board, the channels or this application")
      end

      # member-effect at the reference (0014 §3: an effect the calling context
      # requires but the member lacks): a reference written directly in an
      # interrupt entry's body to a member that is not isr_ok. A reach through
      # a helper is the kernel's extern-context refusal, and the per-instance
      # rows are checked over the reports below.
      app.member_refs.each do |r|
        decl = declared.find { |e| e.full == r.full }
        next unless decl && app.context_of(r.definition) == "interrupt" && !decl.isr_ok
        diags << Diagnostic.new(code: "member-effect", file: app.path, line: r.line,
                                detail: "entry #{r.definition} runs in interrupt context and calls #{r.full}, which is not isr_ok")
      end

      # The kernel's refusals, under their own codes (channel-buffer among them).
      reports.each do |entry, rep|
        next unless rep.is_a?(Hash) && rep["refused"]
        rep["refused"].each do |d|
          diags << Diagnostic.new(code: d["code"], file: app.path, line: d["line"] || app.definition(entry)&.line || 0,
                                  detail: "entry #{entry}: #{d['detail']}")
        end
      end

      # From here on, the admitted reports. An entry the kernel refused has no
      # report and takes no part in the checks below: its refusal is already in
      # `diags`, so the verdict is a refusal either way; only the companion
      # diagnostics the cross-entry checks might have added for it are lost.
      admitted = reports.select { |_, rep| rep.is_a?(Hash) && rep["application"] }

      # shared-writer: every cross state has at most one writing context.
      writers = Hash.new { |h, k| h[k] = {} }
      admitted.each do |entry, rep|
        ctx = app.context_of(entry)
        rep["application"]["buffers"].each do |b|
          next unless b["written"]
          (writers[b["name"]][ctx] ||= []) << entry
        end
      end
      writers.each do |state, by_ctx|
        next if by_ctx.size < 2
        s = app.state(state)
        diags << Diagnostic.new(code: "shared-writer", file: app.path, line: s&.line || 0,
                                detail: "state #{state} is written from #{by_ctx.map { |c, es| "#{c} (#{es.join(', ')})" }.join(' and ')}; a cross-context state has one writing context")
      end

      # device-owner and channel-end: the contexts at each device and each
      # channel end, from the sites' constant instance indexes.
      devices = Hash.new { |h, k| h[k] = {} }   # node_path => {context => [entry]}
      ends = Hash.new { |h, k| h[k] = {} }      # Module.fn => {context => [entry]}
      admitted.each do |entry, rep|
        ctx = app.context_of(entry)
        rep["application"]["externs"].each do |x|
          sites = x["const_args"] || []
          next if sites.empty?
          decl = declared.find { |e| e.full == x["name"] }
          next unless decl
          if decl.origin == "channel"
            (ends[x["name"]][ctx] ||= []) << entry
            next
          end
          next unless decl.origin == "board"
          index_at = decl.params.index { |p| p.name == "index" }
          rows = board[:rows].select { |r| r.module_name == decl.module_name }
          sites.each do |args|
            idx = index_at && args[index_at]
            touched = idx ? rows.select { |r| r.index == idx } : rows
            touched.each { |r| ((devices[r.node_path][ctx] ||= []) << entry).uniq! }
          end
        end
      end
      devices.each do |node, by_ctx|
        next if by_ctx.size < 2
        diags << Diagnostic.new(code: "device-owner", file: app.path, line: 0,
                                detail: "device #{node} is reached from #{by_ctx.map { |c, es| "#{c} (#{es.join(', ')})" }.join(' and ')}; every device has one owning context")
      end
      ends.each do |name, by_ctx|
        next if by_ctx.size < 2
        diags << Diagnostic.new(code: "channel-end", file: app.path, line: 0,
                                detail: "#{name} is called from #{by_ctx.map { |c, es| "#{c} (#{es.join(', ')})" }.join(' and ')}; a channel end belongs to one context")
      end

      # member-effect: isr_ok in interrupt context; blocking, or unknown
      # blocking, anywhere (application entries build under realtime).
      admitted.each do |entry, rep|
        ctx = app.context_of(entry)
        rep["application"]["externs"].each do |x|
          sites = x["const_args"] || []
          next if sites.empty?
          decl = declared.find { |e| e.full == x["name"] }
          next unless decl
          if ctx == "interrupt" && !decl.isr_ok
            diags << Diagnostic.new(code: "member-effect", file: app.path, line: app.definition(entry).line,
                                    detail: "entry #{entry} runs in interrupt context and calls #{x['name']}, which is not isr_ok")
          end
          next unless decl.origin == "board"
          index_at = decl.params.index { |p| p.name == "index" }
          rows = board[:rows].select { |r| r.module_name == decl.module_name }
          sites.each do |args|
            idx = index_at && args[index_at]
            (idx ? rows.select { |r| r.index == idx } : rows).each do |r|
              if ctx == "interrupt" && r.isr_ok != "true"
                diags << Diagnostic.new(code: "member-effect", file: app.path, line: app.definition(entry).line,
                                        detail: "entry #{entry} runs in interrupt context and calls #{x['name']} on #{r.node_path}, whose isr_ok is #{r.isr_ok}")
              end
              next if r.blocking == "false"
              diags << Diagnostic.new(code: "member-effect", file: app.path, line: app.definition(entry).line,
                                      detail: "entry #{entry} calls #{x['name']} on #{r.node_path}, whose blocking is #{r.blocking}; realtime admits only non-blocking members")
            end
          end
        end
      end
      diags.uniq { |d| [d.code, d.detail] }
    end
  end
end

module CoreApp
  module AppChecks
    module_function

    # The board instances each context reaches, for the failure handler's
    # safe states (0014 §4): {context => [[module name, index], ...]}, from the
    # admitted reports' const_args as `run` reads them; a site with a computed
    # index reaches every instance of its module.
    def owners(app, board_externs, board_rows, reports)
      owned = Hash.new { |h, k| h[k] = [] }
      reports.each do |entry, rep|
        next unless rep.is_a?(Hash) && rep["application"]
        ctx = app.context_of(entry)
        rep["application"]["externs"].each do |x|
          sites = x["const_args"] || []
          next if sites.empty?
          decl = board_externs.find { |e| e.full == x["name"] } or next
          index_at = decl.params.index { |p| p.name == "index" }
          rows = board_rows.select { |r| r.module_name == decl.module_name }
          sites.each do |args|
            idx = index_at && args[index_at]
            (idx ? rows.select { |r| r.index == idx } : rows).each do |r|
              owned[ctx] << [r.module_name, r.index] unless owned[ctx].include?([r.module_name, r.index])
            end
          end
        end
      end
      owned
    end
  end
end
