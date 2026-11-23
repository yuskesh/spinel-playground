# frozen_string_literal: true
#
# tools/app/lib/core_app/board.rb -- generates the board package from a final
# zephyr.dts (decision 0014 §3; the plan's "Board package").
#
# INPUTS: the devicetree (CoreApp::Dts::Tree), the build's `.config`, the
# effect table (tools/app/zephyr/<release>/effects.tsv) and the adapters
# (tools/app/adapters/<class>/class.tsv, adapter.c, sim.rb).
#
# INSTANCES come from the devicetree alone. A class's `source` says where:
#   children <compatible>   the enabled children of every enabled node with
#                           that compatible (gpio-leds, gpio-keys, pwm-leds),
#                           in devicetree order;
#   io-channels <node>      the entries of that node's io-channels (the ADC
#                           channels of zephyr,user);
#   node <compatible>...    the node itself (the system timer), of any of
#                           the compatibles named (Armv8-M's SysTick and
#                           Armv7-M's, decision 0023).
# Each instance names the device that drives it: the controller its
# `controller` property references plus the channel on it (the pin, the ADC
# channel, the PWM channel: the first cell after the reference), or the node
# itself. Ownership (§4) is by that device, written to board.tsv as
# `node_path` -- `<controller path>:<channel>` -- so two instances on one
# controller channel are one device and two channels of one controller are
# two, as §4 says ("the same node, or the same controller channel").
#
# EFFECTS follow the instance (§3): the effect table row whose compatible is
# one of the controller's, whose bus is the controller's (i2c or spi when an
# ancestor is such a controller, mmio otherwise) and whose applies_when
# predicates all hold in `.config`. No row: not isr_ok, blocking unknown. A
# class whose instances differ in effect is split: the instances that are
# isr_ok and non-blocking keep the class's module name, and each other group
# becomes its own module, named by its bus (LedI2c) or, with no row at all,
# Unattested (LedUnattested). Indexes restart at 0 in each module.
#
# CONSTANTS live in their own module and are unprefixed -- Led::COUNT,
# Led::LED0 (alias), Led::USERLED0 (label), Led::LED_0 (node name) -- which is
# the notation the checked boundary resolves since 0014 D5, and the one CRuby
# resolves natively. A name that would collide INSIDE a module is refused by
# name; no prefix is invented to separate two of them.
#
# THE INDEX GUARD (D2, approved 2026-09-22): every member taking `index`
# carries `guard index < COUNT else bounds`; the adapter never receives an
# index out of range.
#
# OUTPUTS, all regenerated at every build and never tracked: board.rb (the
# declarations), board_host.rb (the simulators, from each class's sim.rb),
# board_port.c (the tables and the spc_board_<module>_<fn> functions),
# board.tsv (one row per instance) and provenance.json.
require "json"
require "fileutils"
require "digest"
require_relative "app_model"
require_relative "dts"

module CoreApp
  module Board
    class Error < StandardError; end

    Fn = Struct.new(:name, :params, :returns, keyword_init: true) # params: [[name, type]]
    ClassSpec = Struct.new(:dir, :module_name, :source_kind, :source, :controller, :table, :spec, :header,
                           :fns, :safe_state, :index_guard, :glue, :subsystems, :threads, :config_constants, keyword_init: true)
    Instance = Struct.new(:index, :name, :node, :controller, :channel, :compatible, :bus, :names, :row, keyword_init: true) do
      def device = channel ? "#{controller.path}:#{channel}" : controller.path
    end
    EffectRow = Struct.new(:compatible, :bus, :isr_ok, :blocking, :applies_when, :evidence, :line, keyword_init: true)
    ModuleOut = Struct.new(:name, :spec, :instances, :isr_ok, :blocking, :evidence, :config_constants, keyword_init: true)
    # A constant a module takes from the build's .config, admitted one by one
    # (0014 D5 resolves `Mod::NAME`; this table is the only way a value of the
    # configuration becomes one, and nothing else is opened by it):
    #   Clock::CYCLES_PER_SECOND (owner, 2026-10-22, decision 0024): the Hz of
    #   the counter Clock.cycles32 reads, CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC of
    #   this build, on a board whose timer's frequency is fixed at build time;
    #   a configuration that reads it at run time
    #   (CONFIG_TIMER_READS_ITS_FREQUENCY_AT_RUNTIME) gives no constant, so an
    #   application that names it is refused.
    CONFIG_CONSTANTS = { ["Clock", "CYCLES_PER_SECOND"] => "CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC" }.freeze
    Package = Struct.new(:modules, :rows, :files, :provenance, keyword_init: true)

    module_function

    # ---- inputs
    def read_class(dir)
      kv = Hash.new { |h, k| h[k] = [] }
      File.foreach(File.join(dir, "class.tsv")).with_index(1) do |ln, i|
        next if ln.start_with?("#") || ln.strip.empty?
        k, v = ln.chomp.split("\t", 2)
        raise Error, "#{dir}/class.tsv:#{i}: `key<TAB>value`" unless k && v
        kv[k] << v
      end
      one = ->(k) { kv[k].size == 1 ? kv[k][0] : raise(Error, "#{dir}/class.tsv: one #{k} row is required") }
      kind, src = one.call("source").split(" ", 2)
      raise Error, "#{dir}/class.tsv: source is `children <compatible>`, `io-channels <node>` or `node <compatible>`" unless %w[children io-channels node].include?(kind) && src
      fns = kv["fn"].map do |f|
        m = f.match(/\A(\w+)\((.*)\)\s*->\s*(i32|u32|i64)\z/) or raise Error, "#{dir}/class.tsv: fn `#{f}` is `name(a: t, ...) -> t`"
        params = m[2].split(",").map(&:strip).reject(&:empty?).map do |p|
          pm = p.match(/\A(\w+):\s*(u32|i32|i64)\z/) or raise Error, "#{dir}/class.tsv: parameter `#{p}`"
          [pm[1], pm[2]]
        end
        Fn.new(name: m[1], params: params, returns: m[3])
      end
      raise Error, "#{dir}/class.tsv: at least one fn" if fns.empty?
      safe = one.call("safe_state")
      raise Error, "#{dir}/class.tsv: safe_state is `none` or `<fn>(index, <integer>)`" unless safe == "none" || safe.match?(/\A\w+\(index, -?\d+\)\z/)
      ClassSpec.new(dir: dir, module_name: one.call("module"), source_kind: kind, source: src,
                    controller: one.call("controller"), table: one.call("table"), spec: kv["spec"].first,
                    header: one.call("header"), fns: fns, safe_state: safe,
                    index_guard: one.call("index_guard") == "on", glue: kv["glue"],
                    subsystems: kv["subsystem"], # the Kconfig symbols the class's driver needs, enabled only when an application refers to the class
                    # `config_constant <NAME> <CONFIG_SYMBOL>`: one of CONFIG_CONSTANTS
                    config_constants: kv["config_constant"].map do |c|
                      n, sym = c.split(" ")
                      raise Error, "#{dir}/class.tsv: config_constant #{c} is not one CONFIG_CONSTANTS admits" unless CONFIG_CONSTANTS[[one.call("module"), n]] == sym
                      [n, sym]
                    end,
                    # `thread <name> <unit> <macro> <object> <entry> <init> <item>...`: a thread a
                    # glue unit creates; the build derives its requirement from the unit's frames
                    # (all but <init>, which runs on the main thread) and the reserve <item>s,
                    # compiles the unit with -D<macro>=R, and reads <object>'s size and the
                    # word named <object>_size back from the image (0014 §9)
                    threads: kv["thread"].map { |t| f = t.split(" "); raise Error, "#{dir}/class.tsv: thread is `<name> <unit> <macro> <object> <entry> <init> <item>...`" unless f.size >= 7; { name: f[0], unit: f[1], macro: f[2], object: f[3], entry: f[4], init: f[5], items: f[6..] } })
    end

    def read_classes(adapters_dir)
      Dir.children(adapters_dir).sort.map { |d| File.join(adapters_dir, d) }.select { |d| File.file?(File.join(d, "class.tsv")) }
         .map { |d| read_class(d) }
    end

    def read_effects(path)
      rows = []
      File.foreach(path).with_index(1) do |ln, i|
        next if ln.start_with?("#") || ln.strip.empty?
        f = ln.chomp.split("\t", -1)
        raise Error, "#{path}:#{i}: #{f.size} column(s), want 6" unless f.size == 6
        raise Error, "#{path}:#{i}: isr_ok is true or false" unless %w[true false].include?(f[2])
        raise Error, "#{path}:#{i}: blocking is true or false" unless %w[true false].include?(f[3])
        raise Error, "#{path}:#{i}: bus is mmio, i2c or spi" unless %w[mmio i2c spi].include?(f[1])
        if rows.any? { |r| r.compatible == f[0] && r.bus == f[1] && r.applies_when == f[4] }
          raise Error, "#{path}:#{i}: a second row for #{f[0]} on #{f[1]} under `#{f[4]}`; the first would always win"
        end
        rows << EffectRow.new(compatible: f[0], bus: f[1], isr_ok: f[2] == "true", blocking: f[3] == "true",
                              applies_when: f[4], evidence: f[5], line: i)
      end
      rows
    end

    # `.config` text to {name => value}; `# CONFIG_X is not set` is absent.
    def read_config(text)
      text.each_line.each_with_object({}) do |ln, h|
        m = ln.chomp.match(/\A(CONFIG_\w+)=(.*)\z/) or next
        h[m[1]] = m[2].strip.delete_prefix('"').delete_suffix('"')
      end
    end

    def applies?(predicates, config, board)
      predicates.split(",").map(&:strip).reject(&:empty?).all? do |p|
        k, v = p.split("=", 2)
        raise Error, "applies_when predicate `#{p}` is `CONFIG_X=value` or `board=name`" unless k && v
        k == "board" ? board == v : config[k] == v
      end
    end

    # ---- instances
    # The bus a controller sits on, from the nearest ancestor that declares a
    # compatible: an I2C or SPI controller, a simple bus or the SoC (memory
    # mapped), a `zephyr,memory-region` window that maps its children into
    # the address space with `ranges` (memory mapped: the i.MX RT1180's
    # peripheral bus, nxp_rt118x_cm33.dtsi:40-42 at the pin), or something
    # the reader does not know, recorded as `unknown`
    # rather than guessed -- no effect row has that bus, so the instance stays
    # unattested.
    def bus_of(controller)
      n = controller.parent
      while n
        c = n.compatible.join(" ")
        unless c.empty?
          return "i2c" if c.match?(/i2c/)
          return "spi" if c.match?(/spi/)
          return "mmio" if c.match?(/simple-bus|arm,mps2|^arm,|,soc$/) || n.parent.nil?
          return "mmio" if c == "zephyr,memory-region" && !n["ranges"].nil?
          return "unknown"
        end
        n = n.parent
      end
      "mmio"
    end

    def instances_of(spec, dts)
      out = []
      case spec.source_kind
      when "children"
        dts.compatibles(spec.source).each do |parent|
          parent.children.each do |child|
            next unless child.enabled?
            cells = child.cells(spec.controller) or raise Error, "#{child.path}: no #{spec.controller} property"
            ref = cells.first
            raise Error, "#{child.path}: #{spec.controller} does not start with a &reference" unless ref.is_a?(Dts::Ref)
            ctl = dts.resolve(ref, child.path)
            raise Error, "#{child.path}: its controller #{ctl.path} is disabled in the devicetree" unless ctl.enabled?
            out << Instance.new(index: out.size, name: child.name, node: child, controller: ctl, channel: cells[1], names: [child.name])
          end
        end
      when "io-channels"
        node = dts.by_path("/#{spec.source}")
        if node
          cells = node.cells(spec.controller) || []
          names = node.strings("io-channel-names")
          i = 0
          k = 0
          while i < cells.size
            ref = cells[i]
            raise Error, "#{node.path}: #{spec.controller} entry #{k} does not start with a &reference" unless ref.is_a?(Dts::Ref)
            ctl = dts.resolve(ref, node.path)
            raise Error, "#{node.path}: io-channels entry #{k} names #{ctl.path}, which is disabled in the devicetree" unless ctl.enabled?
            ncells = (ctl.cells("#io-channel-cells") || [1]).first
            chan = cells[i + 1, ncells]
            name = names[k] || "ch#{chan.first}"
            out << Instance.new(index: out.size, name: name, node: node, controller: ctl, channel: chan.first, names: [name])
            i += 1 + ncells
            k += 1
          end
        end
      when "node"
        spec.source.split(" ").flat_map { |c| dts.compatibles(c) }.each do |n|
          out << Instance.new(index: out.size, name: n.name, node: n, controller: n, names: [n.name])
        end
      end
      aliases = dts.by_path("/aliases")
      out.each do |inst|
        inst.compatible = inst.controller.compatible.first || ""
        inst.bus = inst.controller.equal?(inst.node) ? "mmio" : bus_of(inst.controller)
        aliases&.properties&.each { |a, v| inst.names << a if v.is_a?(Array) && v.first.is_a?(Dts::Ref) && dts.by_label(v.first.label).equal?(inst.node) }
        label = inst.node.string("label")
        inst.names << label if label && !inst.node.equal?(inst.controller)
      end
      out
    end

    # ---- generation
    def constant_name(s)
      c = s.upcase.gsub(/[^A-Z0-9]/, "_").gsub(/_+/, "_").delete_prefix("_").delete_suffix("_")
      c = "X_#{c}" unless c.match?(/\A[A-Z]/)
      c
    end

    def generate(dts:, config:, effects:, adapters:, out:, board:, release:, dts_sha256:, config_sha256:, flags_sha256:)
      classes = adapters.is_a?(String) ? read_classes(adapters) : adapters
      rows = effects.is_a?(String) ? read_effects(effects) : effects
      cfg = config.is_a?(Hash) ? config : read_config(config)
      modules = []
      classes.each do |spec|
        insts = instances_of(spec, dts)
        insts.each do |inst|
          inst.row = rows.find { |r| inst.controller.compatible.include?(r.compatible) && r.bus == inst.bus && applies?(r.applies_when, cfg, board) }
        end
        groups = insts.group_by { |i| i.row ? [i.row.isr_ok, i.row.blocking, i.bus] : [:none, i.bus] }
        groups.each do |key, members|
          name = if key == [true, false, "mmio"] then spec.module_name
                 elsif key.first == :none then "#{spec.module_name}Unattested"
                 elsif key.last != "mmio" then "#{spec.module_name}#{key.last.capitalize}"
                 else "#{spec.module_name}Restricted"
                 end
          raise Error, "two effect groups of #{spec.module_name} would both be named #{name}" if modules.any? { |m| m.name == name }
          members.each_with_index { |m, i| m.index = i }
          row = members.first.row
          # a configuration whose timer frequency is read at run time, or that
          # has no such symbol, gives no constant: an application that names it
          # is then refused by the checked boundary as naming a constant the
          # module does not carry
          consts = spec.config_constants.reject { |_, sym| cfg["CONFIG_TIMER_READS_ITS_FREQUENCY_AT_RUNTIME"] == "y" || cfg[sym].nil? }.to_h do |n, sym|
            v = cfg[sym].to_s
            raise Error, "#{spec.module_name}::#{n}: the configuration has no integer #{sym} (#{v.inspect})" unless v.match?(/\A[1-9]\d*\z/) && v.to_i < 2**31
            [n, v.to_i]
          end
          modules << ModuleOut.new(name: name, spec: spec, instances: members, config_constants: consts,
                                   isr_ok: row ? row.isr_ok : false, blocking: row ? row.blocking.to_s : "unknown",
                                   evidence: row ? "effects.tsv:#{row.line}" : "none")
        end
      end
      modules.sort_by!(&:name)
      files = {
        "board.rb" => board_rb(modules, board),
        "board_host.rb" => board_host_rb(modules),
        "board_port.c" => board_port_c(modules, board),
        "board.tsv" => board_tsv(modules),
      }
      provenance = {
        "format" => "spinel-board-package", "version" => 1, "board" => board, "zephyr_release" => release,
        "dts_sha256" => dts_sha256, "config_sha256" => config_sha256, "flags_sha256" => flags_sha256,
        "effects_sha256" => effects.is_a?(String) ? Digest::SHA256.file(effects).hexdigest : nil,
        "modules" => modules.map { |m| { "name" => m.name, "class" => m.spec.module_name, "count" => m.instances.size, "isr_ok" => m.isr_ok, "blocking" => m.blocking } },
      }
      files["provenance.json"] = JSON.pretty_generate(provenance) + "\n"
      if out
        FileUtils.mkdir_p(out)
        files.each { |n, text| File.write(File.join(out, n), text) }
      end
      Package.new(modules: modules, rows: tsv_rows(modules), files: files, provenance: provenance)
    end

    def symbol_stem(m) = m.name.downcase
    # The module's constants, unprefixed: COUNT and one per alias, label and
    # node name (0014 D5). The collision refusal names the constant as an
    # application writes it, `Led::LED0`.
    def constants_of(m)
      names = { "COUNT" => m.instances.size }.merge(m.config_constants || {})
      m.instances.each do |inst|
        inst.names.uniq.each do |n|
          c = constant_name(n)
          if names.key?(c) && names[c] != inst.index
            raise Error, "#{m.name}: the constant #{m.name}::#{c} would name instance #{names[c]} and instance #{inst.index} (#{inst.name}); an alias, label or node name that collides across instances is refused"
          end
          names[c] = inst.index
        end
      end
      names
    end

    def board_rb(modules, board)
      out = +"# generated board package for #{board} (decision 0014 §3): declarations.\n"
      out << "# Each module carries its own constants (0014 D5: Led::COUNT, Led::LED0).\n"
      modules.each do |m|
        out << "module #{m.name}\n"
        constants_of(m).each { |k, v| out << "  #{k} = #{v}\n" }
        m.spec.fns.each do |fn|
          params = fn.params.map { |n, t| "#{n}: :#{t}" }.join(", ")
          guards = fn.params.any? { |n, _| n == "index" } && m.spec.index_guard ? ", guards: [\"index < #{m.instances.size} else bounds\"]" : ""
          out << "  core_extern :#{fn.name}, params: {#{params}}, returns: :#{fn.returns}, isr_ok: #{m.isr_ok},\n"
          out << "              bound: \"iterations 1\", provider: \"#{File.basename(m.spec.dir)}/adapter.c\"#{guards}\n"
        end
        out << "end\n"
      end
      out
    end

    def board_host_rb(modules)
      out = +"# generated board package: the simulators for CRuby.\nrequire \"core_app/board_host\"\n"
      modules.each do |m|
        out << "module #{m.name}\n"
        constants_of(m).each { |k, v| out << "  #{k} = #{v}\n" }
        out << "end\n"
        sim = File.read(File.join(m.spec.dir, "sim.rb")).lines.reject { |l| l.start_with?("#") }
        # A stimulus item (`gpio <index> ...`, `adc <index> ...`) addresses the
        # class's primary module; a split module registers no handler, and
        # says so, since its indexes restart at 0 and the item cannot name it.
        if m.name != m.spec.module_name
          sim = sim.map { |l| l.include?("BoardHost.stimulus") ? "# #{m.name} is a split module: the stimulus addresses #{m.spec.module_name}\n" : l }
        end
        out << sim.join.gsub("%MODULE%", m.name).gsub("%COUNT%", m.instances.size.to_s)
      end
      out
    end

    def dt_path(node)
      comps = node.path.delete_prefix("/").split("/").map { |c| c.downcase.gsub(/[^a-z0-9]/, "_") }
      "DT_PATH(#{comps.join(', ')})"
    end

    def board_port_c(modules, board)
      out = +"/* generated board package for #{board} (decision 0014 §3): the tables\n * and the spc_board_<module>_<fn> functions over the class adapters. */\n"
      out << "#include <stdint.h>\n#include <zephyr/devicetree.h>\n"
      modules.map { |m| m.spec.header }.uniq.each { |h| out << "#include <#{h}>\n" }
      modules.map { |m| File.basename(m.spec.dir) }.uniq.each { |d| out << "#include \"adapters/#{d}/adapter.h\"\n" }
      out << "#if defined(SPC_VERIFY)\n/* a verification build (0014 §10) records each member call and its return,\n * the extern numbered as the trace numbers it: the board's members first, in\n * this order, then the channels', then the application's own */\n#include \"recorder.h\"\n#endif\n"
      out << "\n"
      xi = -1 # the extern's index in the trace's numbering
      modules.each do |m|
        stem = symbol_stem(m)
        cls = File.basename(m.spec.dir)
        n = m.instances.size
        out << "/* #{m.name}: #{n} instance(s), isr_ok #{m.isr_ok}, blocking #{m.blocking} */\n"
        if m.spec.table != "none"
          out << "const #{m.spec.table} spc_board_#{stem}_table[#{[n, 1].max}] = {\n"
          m.instances.each do |inst|
            spec = m.spec.spec.gsub("%NODE%", dt_path(inst.node)).gsub("%INDEX%", inst.index.to_s)
            out << "\t#{spec}, /* #{inst.name}: #{inst.node.path} */\n"
          end
          out << "};\n"
          out << "const uint32_t spc_board_#{stem}_count = #{n}u;\n"
          out << "static atomic_t spc_board_#{stem}_words[#{[n, 1].max}];\n" if cls == "adc"
        end
        m.spec.fns.each do |fn|
          cparams = fn.params.map { |pn, t| "#{{ 'u32' => 'uint32_t', 'i32' => 'int32_t', 'i64' => 'int64_t' }[t]} #{pn}" }
          cret = { "u32" => "uint32_t", "i32" => "int32_t", "i64" => "int64_t" }[fn.returns]
          xi += 1
          out << "#{cret} spc_board_#{stem}_#{fn.name}(#{cparams.empty? ? 'void' : cparams.join(', ')})\n{\n"
          args = fn.params.map(&:first)
          table = m.spec.table == "none" ? [] : (cls == "adc" ? ["spc_board_#{stem}_words"] : ["spc_board_#{stem}_table"])
          call = "spc_adapter_#{cls}_#{fn.name}(#{(table + args).join(', ')})"
          out << "#if defined(SPC_VERIFY)\n"
          out << "\t#{cret} r;\n"
          out << "\tstruct spc_rec_arg a[#{[args.size, 1].max}] = { #{args.empty? ? '{ 0, 0, 0, 0u }' : args.map { |x| "{ 0u, (int64_t)#{x}, 0, 0u }" }.join(', ')} };\n\n"
          out << "\tspc_tr_XCALL(spc_rec_ctx, spc_rec_entry, #{xi}u, #{args.size}u, a);\n"
          out << "\tr = #{call};\n"
          out << "\tspc_tr_XRET(spc_rec_ctx, spc_rec_entry, #{xi}u, (int64_t)r);\n\treturn r;\n"
          out << "#else\n\treturn #{call};\n#endif\n}\n"
        end
        next if m.spec.table == "none"
        init_args = cls == "adc" ? "spc_board_#{stem}_table, spc_board_#{stem}_words, #{n}u" : "spc_board_#{stem}_table, #{n}u"
        out << "int32_t spc_board_#{stem}_init(void)\n{\n\treturn spc_adapter_#{cls}_init(#{init_args});\n}\n"
        if m.spec.safe_state != "none"
          out << "void spc_board_#{stem}_safe(void)\n{\n\tspc_adapter_#{cls}_safe(spc_board_#{stem}_table, #{n}u);\n}\n"
        end
        out << "\n"
      end
      out.rstrip + "\n"
    end

    def tsv_rows(modules)
      modules.flat_map do |m|
        m.instances.map do |inst|
          [m.name, inst.index, inst.name, inst.device, inst.compatible, inst.bus, m.isr_ok.to_s, m.blocking, m.evidence]
        end
      end
    end

    def board_tsv(modules)
      out = +"# module\tindex\tname\tnode_path\tcompatible\tbus\tisr_ok\tblocking\tevidence\n"
      tsv_rows(modules).each { |r| out << r.join("\t") << "\n" }
      out
    end
  end
end
