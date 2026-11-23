# frozen_string_literal: true
#
# tools/app/lib/core_app/declarations.rb -- reads an application's
# declarations with Prism into an App.
#
# Decision 0014 §2 and the plan's "Application declarations": declarations are
# `state`, `every_us`, `every_ms` and `channel` calls at the top level of the
# file, and `core_extern` calls directly in a `module` body. Every argument
# is a literal; a non-literal argument is refused with its location. An entry
# is a top-level `def` named by exactly one trigger, and its parameters name
# declared states and nothing else.
#
# What the reader REFUSES, each with a code the fixtures of tests/app/host.sh
# keep an input for: `declaration` for every malformed declaration (a
# non-literal argument, a bad element or count, a period below 1, an unknown
# keyword, an `mqtt:` transport, a `udp:` transport with an endpoint in the
# source or above one datagram, an entry named by two triggers, a
# trigger naming no top-level def, an entry parameter that is not a state, a
# state declared twice), and `guards-in-source` for a `guards:` or `statics:`
# keyword on an application's own `core_extern`. A contract channel
# (decision 0027 stage 2) is refused with the `.channel` file's own codes
# (core_channel.rb), with `channel-contract` for a file outside the
# repository or that cannot be read, `channel-name` for a contract of
# another name, `channel-type` for an i8, u16 or i16 array (owner,
# 2026-10-26: no state of those elements), and `declaration` for other
# keywords beside `contract:`.
require "prism"
require_relative "app_model"
require_relative "core_channel"

module CoreApp
  module Declarations
    class Refused < StandardError
      attr_reader :diagnostics
      def initialize(diagnostics)
        @diagnostics = diagnostics
        super(diagnostics.map(&:to_s).join("\n"))
      end
    end

    module_function

    # Reads `path` and returns an App, or raises Refused with every diagnostic.
    def read(path)
      Reader.new(path, parse(path)).read
    end

    # Reads a generated package's declaration file (the board's, or the
    # channels'): modules holding core_extern declarations, which may carry
    # guards: and statics:, and integer constants written in a module's own
    # body (the board's counts, aliases and labels: `Led::COUNT = 2`,
    # `Led::LED0 = 0`, spelled `COUNT = 2` inside `module Led`), nothing else.
    # Returns a Package: its externs with `origin` set to `origin`, and its
    # constants by name.
    Package = Struct.new(:externs, :constants, keyword_init: true)
    def read_package(path, origin:)
      reader = Reader.new(path, parse(path), package: true, unknown_bound_ok: origin == "session")
      app = reader.read
      app.externs.each { |e| e.origin = origin }
      Package.new(externs: app.externs, constants: reader.constants)
    end

    def parse(path)
      result = Prism.parse(File.read(path))
      diags = result.errors.map { |e| Diagnostic.new(code: "declaration", file: path, line: e.location.start_line, detail: "syntax: #{e.message}") }
      raise Refused, diags unless diags.empty?
      result.value
    end

    class Reader
      def initialize(path, program, package: false, unknown_bound_ok: false)
        @unknown_bound_ok = unknown_bound_ok
        @path = path
        @program = program
        @package = package
        @member_refs = []
        @constants = {}
        @diags = []
        @states = []
        @triggers = []
        @channels = []
        @externs = []
        @entries = []
        @requires = []
        @helpers = []
        @session = nil
        @fibers = {}
        @scratches = {}
        @session_params = []
      end

      def read
        @program.statements.body.each { |node| top_level(node) }
        bind_entries
        raise Refused, @diags unless @diags.empty?
        App.new(path: @path, states: @states, triggers: @triggers, channels: @channels,
                externs: @externs, definitions: @entries, requires: @requires, helpers: @helpers, member_refs: @member_refs,
                session_path: @session&.first, session_line: @session&.[](1), session_params: @session_params,
                session_dtcm: @session&.[](2) || [], scratches: @scratches.transform_values(&:first))
      end

      attr_reader :constants

      private

      def refuse(node, detail, code: "declaration")
        @diags << Diagnostic.new(code: code, file: @path, line: node.location.start_line, detail: detail)
        nil
      end

      def top_level(node)
        case node
        when Prism::CallNode
          top_call(node)
        when Prism::ModuleNode
          module_body(node)
        when Prism::ConstantWriteNode
          # DECISION 0014 D5: a package's constants live in their module's body
          # (`Led::COUNT`), never at top level. A top-level one is refused even
          # in a package, so the two spellings cannot drift apart.
          refuse(node, "a constant is not a declaration; the board package's constants are written in their module's body (Led::COUNT)")
        when Prism::DefNode
          if node.receiver
            refuse(node, "`def self.#{node.name}` is not an entry; entries are top-level definitions")
          else
            @entries << Entry.new(name: node.name.to_s, params: required_params(node), line: node.location.start_line)
            member_refs(node.body, node.name.to_s)
          end
        else
          refuse(node, "only declarations, modules and definitions are admitted at the top level, not #{node.class.name.split('::').last}")
        end
      end

      # Every `Const.member(...)` call in a body, as the file has it. The
      # tool resolves each against the board and the channels (0014 §3: a
      # reference to a member the board does not provide is a build error);
      # which entry reaches which is the kernel's report.
      def member_refs(node, definition)
        return unless node.is_a?(Prism::Node)
        if node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::ConstantReadNode) &&
           !(node.receiver.name == :Array && node.name == :new) # decision 0041 stage 2
          first = node.arguments&.arguments&.first
          @member_refs << MemberRef.new(module_name: node.receiver.name.to_s, name: node.name.to_s,
                                        line: node.location.start_line, definition: definition,
                                        first_literal: first.is_a?(Prism::IntegerNode) ? first.value : nil)
        end
        node.compact_child_nodes.each { |c| member_refs(c, definition) }
      end

      # A `require_relative` of the application names a helper file beside it
      # (decision 0027: two board applications share their tic): definitions
      # only, packed after the application, and its definitions are the
      # application's helpers. A helper's own requires, declarations, modules
      # and constants are refused, as is a name defined twice.
      def helper(node, lit)
        return refuse(node, "require_relative is an application's, not a package's") if @package
        path = File.expand_path(lit.end_with?(".rb") ? lit : "#{lit}.rb", File.dirname(@path))
        base = File.dirname(File.expand_path(@path))
        return refuse(node, "require_relative #{lit.inspect}: a helper is a file in the application's directory or below it") unless path.start_with?(base + "/")
        return refuse(node, "require_relative #{lit.inspect}: no file #{path}") unless File.file?(path)
        return refuse(node, "require_relative #{lit.inspect}: the helper is required twice") if @helpers.any? { |h| h[2] == path }
        program = Declarations.parse(path)
        program.statements.body.each do |n|
          unless n.is_a?(Prism::DefNode) && n.receiver.nil?
            @diags << Diagnostic.new(code: "declaration", file: path, line: n.location.start_line,
                                     detail: "a helper file holds top-level definitions only, not #{n.class.name.split('::').last}")
            next
          end
          if @entries.any? { |e| e.name == n.name.to_s }
            @diags << Diagnostic.new(code: "declaration", file: path, line: n.location.start_line, detail: "#{n.name} is defined twice")
            next
          end
          @entries << Entry.new(name: n.name.to_s, params: required_params(n), line: n.location.start_line)
          member_refs(n.body, n.name.to_s)
        end
        @helpers << [lit, node.location.start_line, path]
      end

      def required_params(def_node)
        params = def_node.parameters
        return [] unless params
        others = params.optionals + params.posts + params.keywords + [params.rest, params.keyword_rest, params.block].compact
        refuse(def_node, "an entry takes only required positional parameters") unless others.empty?
        params.requireds.map { |p| p.name.to_s }
      end

      def top_call(node)
        return refuse(node, "a top-level call has no receiver") if node.receiver
        args = node.arguments&.arguments || []
        case node.name
        when :require, :require_relative
          lit = literal(node, args[0])
          @requires << [lit, node.location.start_line] if lit.is_a?(String)
          refuse(node, "`#{node.name}` takes one string") unless args.size == 1 && lit.is_a?(String)
          helper(node, lit) if node.name == :require_relative && args.size == 1 && lit.is_a?(String)
        when :state then state(node, args)
        when :scratch then scratch(node, args)
        when :fiber_def, :enum_def, :pool_def
          # Decision 0035 stage 2: a fiber kind and its slot count. The build
          # rewrites it (tools/fiber/spinel-fiber-core) into states and
          # helpers before this reader sees the program; on the host,
          # spinel/core.rb runs it on real Fibers. enum_def, the CORE form of
          # Enumerator.new, and pool_def, decision 0041 stage 3's slot pool,
          # are read the same way.
          return refuse(node, "#{node.name} is an application declaration, not a package's") if @package
          positional, keywords = split_keywords(node, args)
          name = literal(node, positional[0])
          max = keywords[:max]
          unless positional.size == 1 && name.is_a?(Symbol) && keywords.keys == [:max] && max.is_a?(Integer) && max >= 1
            return refuse(node, "#{node.name} takes a symbol and max: with a positive integer, as `#{node.name} :reader, max: 2`")
          end
          return refuse(node, "#{node.name} :#{name} is declared twice") if @fibers.key?(name)
          @fibers[name] = max
        when :every_us then trigger(node, args, 1)
        when :every_ms then trigger(node, args, 1000)
        when :channel then channel(node, args)
        when :core_session
          # Decision 0021: the DOOM entries' contracts, by directory. Once.
          # `dtcm:` names writable fields of the session kept in the data
          # TCM on a board that has one (0021, the screen in DTCM).
          positional, keywords = split_keywords(node, args)
          lit = literal(node, positional[0])
          return refuse(node, "core_session takes one string, the entries' directory") unless positional.size == 1 && lit.is_a?(String) && !lit.empty?
          return refuse(node, "core_session takes only the keyword dtcm:, not #{(keywords.keys - [:dtcm]).map { |k| "#{k}:" }.join(', ')}") unless (keywords.keys - [:dtcm]).empty?
          dtcm = keywords.fetch(:dtcm, [])
          return refuse(node, "core_session dtcm: takes an array of field names") unless dtcm.is_a?(Array) && dtcm.all? { |f| f.is_a?(String) && !f.empty? }
          return refuse(node, "core_session dtcm: names #{dtcm.tally.select { |_, n| n > 1 }.keys.join(', ')} twice") unless dtcm.uniq.size == dtcm.size
          return refuse(node, "core_session is declared twice") if @session
          return refuse(node, "core_session is an application declaration, not a package's") if @package
          @session = [lit, node.location.start_line, dtcm]
        else
          refuse(node, "`#{node.name}` is not a declaration; the top level admits state, scratch, every_us, every_ms, channel, core_session, fiber_def, enum_def, pool_def and require")
        end
      end

      # A literal argument: an Integer, a Symbol, a String, true/false, an Array
      # of literals, or a keyword hash of literals. Anything else is refused.
      def literal(context, node)
        case node
        when Prism::IntegerNode then node.value
        when Prism::SymbolNode then node.value.to_sym
        when Prism::StringNode then node.unescaped
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::ArrayNode then node.elements.map { |e| literal(context, e) }
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.each_with_object({}) do |assoc, h|
            unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
              refuse(assoc, "a declaration keyword must be a symbol key")
              next
            end
            h[assoc.key.value.to_sym] = literal(context, assoc.value)
          end
        when nil then nil
        else
          refuse(context, "a declaration argument must be a literal, not #{node.class.name.split('::').last} at column #{node.location.start_column}")
          :refused
        end
      end

      def split_keywords(node, args)
        keywords = {}
        positional = args.dup
        if positional.last.is_a?(Prism::KeywordHashNode)
          keywords = literal(node, positional.pop) || {}
        end
        [positional, keywords]
      end

      def state(node, args)
        positional, keywords = split_keywords(node, args)
        return refuse(node, "state takes `:name, :element, count`") unless positional.size == 3 && keywords.empty?
        name, element, count = positional.map { |a| literal(node, a) }
        return refuse(node, "state: name is a symbol") unless name.is_a?(Symbol)
        return refuse(node, "state: element is one of #{ELEMENTS.join(', ')}") unless element.is_a?(Symbol) && ELEMENTS.include?(element.to_s)
        return refuse(node, "state: count is an integer literal of at least 1") unless count.is_a?(Integer) && count >= 1
        return refuse(node, "state #{name} is declared twice") if @states.any? { |s| s.name == name.to_s }
        @states << State.new(name: name.to_s, element: element.to_s, count: count, line: node.location.start_line)
      end

      # Decision 0041 stage 2: `scratch 4096, context: :thread`, the bytes of
      # one context's data stack, where its methods make arrays. One per
      # context; the kernel refuses an Array.new in a context without one.
      def scratch(node, args)
        return refuse(node, "scratch is an application declaration, not a package's") if @package
        positional, keywords = split_keywords(node, args)
        bytes = literal(node, positional[0])
        unknown = keywords.keys - %i[context]
        unless positional.size == 1 && unknown.empty?
          return refuse(node, "scratch takes the bytes and optionally context:, as `scratch 4096, context: :thread`")
        end
        return refuse(node, "scratch: the bytes are an integer literal from 16 to 2147483647") unless bytes.is_a?(Integer) && bytes >= 16 && bytes <= 0x7fffffff
        context = keywords.fetch(:context, :thread)
        return refuse(node, "scratch: context is :thread or :interrupt") unless context.is_a?(Symbol) && CONTEXTS.include?(context.to_s)
        if (prior = @scratches[context.to_s])
          return refuse(node, "scratch for the #{context} context is declared twice (first at line #{prior[1]}); a context has one data stack")
        end
        @scratches[context.to_s] = [bytes, node.location.start_line]
      end

      def trigger(node, args, unit)
        positional, keywords = split_keywords(node, args)
        return refuse(node, "#{node.name} takes `n, :entry` and optionally `context:` and `wake:`") unless positional.size == 2
        period, entry = positional.map { |a| literal(node, a) }
        return refuse(node, "#{node.name}: the period is an integer literal of at least 1") unless period.is_a?(Integer) && period >= 1
        return refuse(node, "#{node.name}: the entry is a symbol") unless entry.is_a?(Symbol)
        unknown = keywords.keys - %i[context wake]
        return refuse(node, "#{node.name}: unknown keyword #{unknown.first}") unless unknown.empty?
        context = keywords.fetch(:context, :thread)
        return refuse(node, "#{node.name}: context is :thread or :interrupt") unless context.is_a?(Symbol) && CONTEXTS.include?(context.to_s)
        return refuse(node, "entry #{entry} is named by two triggers") if @triggers.any? { |t| t.entry == entry.to_s }
        # decision 0028 Q4: the channel whose doorbell releases the entry early;
        # the build checks that it is a contract channel this core consumes
        wake = keywords[:wake]
        return refuse(node, "#{node.name}: wake: names a channel, as a symbol") if keywords.key?(:wake) && !wake.is_a?(Symbol)
        return refuse(node, "#{node.name}: wake: releases a thread entry; an interrupt entry woken by the doorbell would run inside the MU's handler (decision 0028, not proposed)") if wake && context.to_s == "interrupt"
        @triggers << Trigger.new(entry: entry.to_s, period_us: period * unit, context: context.to_s, line: node.location.start_line, wake: wake&.to_s)
      end

      def channel(node, args)
        positional, keywords = split_keywords(node, args)
        return contract_channel(node, positional, keywords) if keywords.key?(:contract)
        return refuse(node, "channel takes `:name, :out|:in, size:, depth:` and a transport") unless positional.size == 2
        name, direction = positional.map { |a| literal(node, a) }
        return refuse(node, "channel: name is a symbol") unless name.is_a?(Symbol)
        return refuse(node, "channel: direction is :out or :in") unless %i[out in].include?(direction)
        return refuse(node, "channel: `mqtt:` is not implemented; `uart: true` and `udp: true` are") if keywords.key?(:mqtt)
        unknown = keywords.keys - %i[size depth uart udp]
        return refuse(node, "channel: unknown keyword #{unknown.first}") unless unknown.empty?
        size = keywords[:size]
        depth = keywords[:depth]
        return refuse(node, "channel: size is an integer literal of at least 1") unless size.is_a?(Integer) && size >= 1
        return refuse(node, "channel: depth is an integer literal of at least 1") unless depth.is_a?(Integer) && depth >= 1
        transports = %i[uart udp].select { |t| keywords.key?(t) }
        return refuse(node, "channel: the transport is one of `uart: true` and `udp: true`") unless transports.size == 1
        if keywords.key?(:udp)
          # 0014 §5: endpoints come from configuration, never from the source
          return refuse(node, "channel: the transport is `udp: true`; the endpoint comes from the network file the build is given (--net), not from the source") unless keywords[:udp] == true
          return refuse(node, "channel: a `udp:` message is at most #{UDP_PAYLOAD_MAX} bytes, one datagram in one Ethernet frame (size: #{size})") if size > UDP_PAYLOAD_MAX
        else
          return refuse(node, "channel: the transport is `uart: true`") unless keywords[:uart] == true
        end
        return refuse(node, "channel #{name} is declared twice") if @channels.any? { |c| c.name == name.to_s }
        @channels << Channel.new(name: name.to_s, direction: direction.to_s, size: size, depth: depth, uart: keywords.key?(:uart),
                                 udp: keywords.key?(:udp), line: node.location.start_line)
      end

      # `channel :name, contract: "FILE.channel"` (decision 0027 stage 2): the
      # file, relative to the application's, read by CoreChannel; the
      # direction is the build's, from the board's core
      def contract_channel(node, positional, keywords)
        return refuse(node, "channel :name, contract: \"FILE.channel\" takes the name alone") unless positional.size == 1
        name = literal(node, positional[0])
        return refuse(node, "channel: name is a symbol") unless name.is_a?(Symbol)
        unless keywords.keys == [:contract]
          return refuse(node, "channel #{name}: a contract channel takes its size and depth from the contract, and its other end is the other core")
        end
        rel = keywords[:contract]
        return refuse(node, "channel #{name}: contract: is a string literal, the file's path from the application's") unless rel.is_a?(String)
        path = File.expand_path(rel, File.dirname(File.expand_path(@path)))
        unless path.start_with?("#{CoreChannel::REPO_ROOT}/")
          return refuse(node, "channel #{name}: #{rel} is outside the repository (AGENTS.md: no sibling checkout)", code: "channel-contract")
        end
        return refuse(node, "channel #{name}: cannot read #{rel}", code: "channel-contract") unless File.file?(path) && File.readable?(path)
        return refuse(node, "channel #{name} is declared twice") if @channels.any? { |c| c.name == name.to_s }
        k, diags = CoreChannel.parse(path)
        @diags.concat(diags)
        return nil unless k
        return refuse(node, "the application names channel :#{name}; the contract is channel #{k.name}", code: "channel-name") unless k.name == name.to_s
        narrow = k.fields.select { |f| f.array && %w[i8 u16 i16].include?(f.type) }
        narrow.each do |f|
          @diags << Diagnostic.new(code: "channel-type", file: path, line: f.line,
                                   detail: "field #{f.name}: #{f.type} arrays need #{f.type} state, which the application tool does not have yet (owner, 2026-10-26)")
        end
        return nil unless narrow.empty?
        @channels << Channel.new(name: name.to_s, direction: nil, size: k.msg_bytes, depth: k.depth, uart: false, udp: false,
                                 line: node.location.start_line, contract: k)
      end

      def module_body(node)
        path = node.constant_path
        return refuse(node, "a module is named by one constant") unless path.is_a?(Prism::ConstantReadNode)
        mod = path.name.to_s
        body = node.body
        return if body.nil?
        return refuse(node, "a module body holds core_extern declarations only") unless body.is_a?(Prism::StatementsNode)
        body.body.each do |stmt|
          # DECISION 0014 D5: the package's constants, `Mod::NAME`, an integer
          # literal in the module's own body. Recorded under that key, which is
          # how the packed root spells them and how the checked boundary
          # resolves them.
          if @package && stmt.is_a?(Prism::ConstantWriteNode)
            unless stmt.value.is_a?(Prism::IntegerNode)
              refuse(stmt, "#{mod}::#{stmt.name} is not an integer literal; a constant in a module body is one integer written there")
              next
            end
            key = "#{mod}::#{stmt.name}"
            refuse(stmt, "constant #{key} is assigned twice") if @constants.key?(key)
            @constants[key] = stmt.value.value
            next
          end
          unless stmt.is_a?(Prism::CallNode) && stmt.name == :core_extern && stmt.receiver.nil?
            refuse(stmt, "a module body holds core_extern declarations only")
            next
          end
          core_extern(mod, stmt)
        end
      end

      def core_extern(mod, node)
        args = node.arguments&.arguments || []
        positional, keywords = split_keywords(node, args)
        return refuse(node, "core_extern takes `:name` and keywords") unless positional.size == 1
        name = literal(node, positional[0])
        return refuse(node, "core_extern: the name is a symbol") unless name.is_a?(Symbol)
        %i[guards statics].each do |k|
          next if @package
          return refuse(node, "`#{k}:` is a keyword of generated declarations only; an application's core_extern has no precondition surface", code: "guards-in-source") if keywords.key?(k)
        end
        return refuse(node, "core_extern: `requires:` is not a keyword; preconditions are internal to generated packages") if keywords.key?(:requires)
        unknown = keywords.keys - %i[params returns reads writes isr_ok bound provider] - (@package ? %i[guards statics] : [])
        return refuse(node, "core_extern: unknown keyword #{unknown.first}") unless unknown.empty?
        params = keywords.fetch(:params, {})
        return refuse(node, "core_extern: params is an ordered hash of names to domains") unless params.is_a?(Hash)
        eps = params.map do |pname, ptype|
          case ptype
          when Symbol
            return refuse(node, "core_extern: scalar parameter #{pname} is one of #{SCALARS.join(', ')}") unless SCALARS.include?(ptype.to_s)
            ExternParam.new(name: pname.to_s, kind: :scalar, type: ptype.to_s)
          when Array
            return refuse(node, "core_extern: a buffer parameter is [:buf, element]") unless ptype.size == 2 && ptype[0] == :buf && ELEMENTS.include?(ptype[1].to_s)
            ExternParam.new(name: pname.to_s, kind: :buffer, type: ptype[1].to_s)
          else
            return refuse(node, "core_extern: parameter #{pname} has no admitted type")
          end
        end
        returns = keywords[:returns]
        return refuse(node, "core_extern: returns is one of #{SCALARS.join(', ')}, or omitted") unless returns.nil? || (returns.is_a?(Symbol) && SCALARS.include?(returns.to_s))
        reads = Array(keywords.fetch(:reads, [])).map(&:to_s)
        writes = Array(keywords.fetch(:writes, [])).map(&:to_s)
        buffers = eps.select(&:buffer?).map(&:name)
        (reads + writes).each do |b|
          return refuse(node, "core_extern: #{b} in reads:/writes: is not a buffer parameter") unless buffers.include?(b)
        end
        return refuse(node, "core_extern: bound: is required, in 0010's grammar (`iterations <expr>`)") unless keywords[:bound].is_a?(String) && keywords[:bound].start_with?("iterations ")
        # DECISION 0021 (owner, 2026-10-20): `iterations unknown "<reason>"` is
        # the bound of an extern whose work has no derived bound. Only the
        # three DoomCore members core_session generates may declare it; every
        # other extern, the application's own among them, is refused.
        if keywords[:bound].start_with?("iterations unknown")
          return refuse(node, "core_extern: `bound: \"iterations unknown\"` is admitted only for the DoomCore members core_session generates (decision 0021)") unless @unknown_bound_ok && mod == "DoomCore"
          reason = keywords[:bound][/\Aiterations unknown "(.*)"\z/m, 1]
          return refuse(node, "core_extern: an unknown bound names its reason: `iterations unknown \"<reason>\"`") if reason.nil? || reason.strip.empty?
        end
        return refuse(node, "core_extern: provider: is required, the C source the build compiles") unless keywords[:provider].is_a?(String) && !keywords[:provider].empty?
        return refuse(node, "core_extern: #{mod}.#{name} is declared twice") if @externs.any? { |e| e.module_name == mod && e.name == name.to_s }
        @externs << Extern.new(module_name: mod, name: name.to_s, params: eps, returns: returns&.to_s,
                               reads: reads, writes: writes, isr_ok: keywords.fetch(:isr_ok, false) == true,
                               bound: keywords[:bound], provider: keywords[:provider],
                               guards: Array(keywords[:guards]).map(&:to_s), statics: Array(keywords[:statics]).map(&:to_s),
                               origin: "app", line: node.location.start_line, end_line: node.location.end_line)
      end

      # Entries are the definitions the triggers name; each parameter names a
      # state. A trigger naming no definition, and a definition named by a
      # trigger whose parameters are not all states, are refused.
      def bind_entries
        @triggers.each do |t|
          e = @entries.find { |d| d.name == t.entry }
          unless e
            @diags << Diagnostic.new(code: "declaration", file: @path, line: t.line, detail: "trigger names no top-level def #{t.entry}")
            next
          end
          e.params.each do |p|
            next if @states.any? { |s| s.name == p }
            # with a core_session, the session resolves it (or refuses it) once
            # the image is read; without one it names nothing
            if @session
              @session_params << [e.name, p]
              next
            end
            @diags << Diagnostic.new(code: "declaration", file: @path, line: e.line, detail: "entry #{e.name}: parameter #{p} is not a declared state")
          end
          dup = e.params.tally.select { |_, n| n > 1 }.keys
          @diags << Diagnostic.new(code: "declaration", file: @path, line: e.line, detail: "entry #{e.name}: state #{dup.first} is named twice") unless dup.empty?
        end
      end
    end
  end
end
