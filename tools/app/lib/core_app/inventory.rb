# frozen_string_literal: true
#
# tools/app/lib/core_app/inventory.rb -- the interrupt and exception inventory
# of decision 0014 §9, built from the configuration (the final devicetree, the
# .config and the attested driver rows), never read from the linked image;
# and the classification of a linked image's vector slots against it.
#
# SOURCES. Zephyr's system exceptions -- the system timer (SysTick), PendSV
# and SVC -- and each interrupt an enabled driver connects. A driver is
# taken to connect its interrupts when the devicetree node is enabled, has
# an `interrupts` property, and its compatible has an irq row (irq-rows.tsv)
# that applies under the .config with an irq_source other than `none`. A
# node whose rows name a driver symbol the .config does not set is not
# connected (the driver is not compiled) and is listed as absent; a node
# with a row that does not apply for another reason, or with no row at all,
# is `unknown` -- and unknown refuses the build under realtime (§9).
#
# EACH SOURCE CARRIES its priority (the devicetree cell for an interrupt;
# the values Zephyr sets for the exceptions: _IRQ_PRIO_OFFSET for SysTick
# and SVC, the lowest for PendSV), the priority grouping in effect (all
# bits are preemption bits: Zephyr sets no PRIGROUP), and the name of its
# attested handler reserve, which Task 9's table supplies.
#
# CLASSIFICATION. After word 0, every slot of the image's vector table falls
# into exactly one class: budgeted (an inventory entry), reset, terminal,
# reserved (an architecturally reserved position holding zero), or unused
# (Zephyr's spurious handler). With CONFIG_GEN_SW_ISR_TABLE every interrupt
# slot points at _isr_wrapper and the software table decides, so an
# _isr_wrapper slot is classified by its _sw_isr_table entry. A slot that
# fits no class fails the build, naming it.
require "open3"
require_relative "dts"
require_relative "reserves"

module CoreApp
  module Inventory
    class Error < StandardError; end

    Source = Struct.new(:name, :kind, :slot, :irq, :priority, :node_path, :compatible, :handler, :reserve_item, :row, keyword_init: true)
    Absent = Struct.new(:node_path, :compatible, :symbols, keyword_init: true)
    Result = Struct.new(:sources, :absent, :unknown, keyword_init: true)
    Slot = Struct.new(:index, :word, :symbol, :klass, :detail, keyword_init: true)

    # Cortex-M exception slots (word index in the vector table).
    SLOT_SVC = 11
    SLOT_PENDSV = 14
    SLOT_SYSTICK = 15
    # Armv8-M mainline: 1 Reset, 2 NMI, 3 HardFault, 4 MemManage, 5 BusFault,
    # 6 UsageFault, 7 SecureFault, 8-10 reserved, 11 SVCall, 12 DebugMonitor,
    # 13 reserved, 14 PendSV, 15 SysTick (Armv8-M Architecture Reference
    # Manual, exception numbers). Armv7-M has no SecureFault: 7 is reserved
    # too, and Zephyr's vector table writes 0 there unless CONFIG_ARMV8_M_SE
    # (arch/arm/core/cortex_m/vector_table.S at the pinned commit).
    RESERVED_SLOTS = [8, 9, 10, 13].freeze
    # The SysTick and NVIC compatibles, Armv8-M's and Armv7-M's (the
    # FRDM-IMXRT1186's Cortex-M7, decision 0023)
    SYSTICKS = %w[arm,armv8m-systick arm,armv7m-systick].freeze
    NVICS = %w[arm,v8m-nvic arm,v7m-nvic].freeze
    # The reserve item of a driver interrupt, by the compatible that connects
    # it; a connected source with no entry here, or no applicable row of that
    # item in reserves.tsv, is unknown.
    RESERVE_OF = {
      "arm,cmsdk-uart" => "isr_uart_cmsdk_apb",
      "nxp,lpuart" => "isr_lpuart",
      "nxp,lp-flexcomm" => "isr_lpuart",
      "nxp,kinetis-gpio" => "isr_gpio_mcux_port",
      "nxp,lpc-lpadc" => "isr_lpadc",
      "arm,cmsdk-gpio" => "isr_gpio_cmsdk_ahb",
      "nxp,imx-rgpio" => "isr_gpio_mcux_rgpio",
      # decision 0028: the doorbell's MU, through Zephyr's driver
      "nxp,mbox-imx-mu" => "isr_mbox_nxp_imx_mu",
    }.freeze

    module_function

    # the reserved positions of the board's vector table
    def reserved_slots(config) = config.key?("CONFIG_ARMV8_M_SE") ? RESERVED_SLOTS : [7] + RESERVED_SLOTS

    # `config` is {name => value}; `irq_rows` from Reserves.read_irq_rows.
    def build(dts, config, irq_rows, board:)
      sources = []
      absent = []
      unknown = []
      systick_c = SYSTICKS.find { |c| dts.compatibles(c).first }
      raise Error, "no enabled #{SYSTICKS.join(' or ')} node: the system timer of 0014 §4 is SysTick" unless systick_c
      systick = dts.compatibles(systick_c).first
      sources << Source.new(name: "systick", kind: :exception, slot: SLOT_SYSTICK, irq: nil, priority: 0,
                            node_path: systick.path, compatible: systick_c, handler: "sys_clock_isr",
                            reserve_item: "timer_dispatch", row: irq_rows.find { |r| r.compatible == systick_c })
      sources << Source.new(name: "pendsv", kind: :exception, slot: SLOT_PENDSV, irq: nil, priority: lowest_priority(config),
                            node_path: nil, compatible: nil, handler: "z_arm_pendsv", reserve_item: "pendsv", row: nil)
      sources << Source.new(name: "svc", kind: :exception, slot: SLOT_SVC, irq: nil, priority: 0,
                            node_path: nil, compatible: nil, handler: "z_arm_svc", reserve_item: "svc", row: nil)
      # the NVIC's interrupt cells: the pairs (irq, priority) read below
      nvic = NVICS.lazy.filter_map { |c| dts.compatibles(c).first }.first
      nvic_cells = nvic && nvic.cells("#interrupt-cells").first
      unknown << "the NVIC's #interrupt-cells is #{nvic_cells.inspect}, not 2; no interrupts property can be read as (irq, priority) pairs" unless nvic_cells == 2
      dts.each do |n|
        next unless n.enabled? && !n.compatible.empty?
        if n["interrupts-extended"]
          # a form the inventory does not read: neither connected nor absent
          unknown << "#{n.path} (#{n.compatible.first}): interrupts-extended is not read by the inventory"
          next
        end
        next unless n["interrupts"]
        next if (n.compatible & SYSTICKS).any?
        rows = irq_rows.select { |r| n.compatible.include?(r.compatible) }
        if rows.empty?
          unknown << "#{n.path} (#{n.compatible.join(', ')}): no irq row for its compatible"
          next
        end
        applicable = rows.select { |r| Reserves.applies?(r.applies_when, config, board) }
        if applicable.empty?
          symbols = rows.flat_map { |r| r.applies_when.scan(/(CONFIG_\w+)=y/).flatten }
          if !symbols.empty? && symbols.none? { |s| config.key?(s) }
            absent << Absent.new(node_path: n.path, compatible: n.compatible.first, symbols: symbols)
          else
            unknown << "#{n.path} (#{n.compatible.first}): its irq row does not apply under this configuration (#{rows.map(&:applies_when).join(' | ')})"
          end
          next
        end
        if applicable.size > 1
          unknown << "#{n.path} (#{n.compatible.first}): #{applicable.size} irq rows apply under this configuration; one is required"
          next
        end
        row = applicable.first
        next if row.irq_source == "none"
        cells = n.cells("interrupts")
        unless nvic_cells == 2 && cells.size.even?
          unknown << "#{n.path}: #{cells.size} interrupt cells cannot be read as (irq, priority) pairs"
          next
        end
        names = n.strings("interrupt-names")
        cells.each_slice(2).with_index do |(irq, prio), k|
          item = RESERVE_OF[row.compatible]
          sources << Source.new(name: "#{n.name}#{names[k] ? ".#{names[k]}" : ''}", kind: :irq, slot: 16 + irq, irq: irq, priority: prio,
                                node_path: n.path, compatible: row.compatible, handler: "_isr_wrapper", reserve_item: item, row: row)
          unknown << "#{n.path} irq #{irq}: no handler reserve item is known for #{row.compatible}" if item.nil?
        end
      end
      Result.new(sources: sources.sort_by { |s| s.slot }, absent: absent, unknown: unknown)
    end

    # PendSV's priority: the lowest, IRQ_PRIO_LOWEST of the configuration
    # (2^NUM_IRQ_PRIO_BITS - 1 without zero-latency levels).
    def lowest_priority(config)
      bits = (config["CONFIG_NUM_IRQ_PRIO_BITS"] || "3").to_i
      (1 << bits) - 1
    end

    # The image's vector words (after word 0) and its software ISR table.
    # Where the vector table starts inside `rom_start`: 0 on a board whose
    # image begins with it, past the boot header on one that boots from
    # FlexSPI NOR (the i.MX RT1180's FCB and XMCD come first). Read from the
    # image's own symbols: `_vector_table` against `__rom_region_start`, the
    # address `rom_start` begins at.
    def vector_table_offset(elf, symbols_tool:)
      text, err, st = Open3.capture3(symbols_tool, "--addresses", "--defined", elf)
      raise Error, "#{symbols_tool} failed on #{elf}: #{err.strip}" unless st.success?
      at = {}
      text.lines.each do |l|
        a, _s, _t, n = l.chomp.split("\t", 4)
        at[n] = a.to_i(16) if %w[_vector_table __rom_region_start].include?(n)
      end
      %w[_vector_table __rom_region_start].each { |n| raise Error, "#{elf}: no #{n} symbol" unless at.key?(n) }
      off = at["_vector_table"] - at["__rom_region_start"]
      raise Error, "#{elf}: _vector_table is below __rom_region_start" if off.negative?
      off
    end

    def read_tables(elf, num_irqs, objcopy:, offset: 0)
      vt = dump_section(elf, "rom_start", objcopy).byteslice(offset..) || "".b
      sw = dump_section(elf, "sw_isr_table", objcopy)
      words = vt.unpack("V*")
      entries = sw.unpack("V*").each_slice(2).map { |arg, isr| [arg, isr] }
      raise Error, "#{elf}: the vector table holds #{words.size} words, fewer than 16 + #{num_irqs}" if words.size < 16 + num_irqs
      raise Error, "#{elf}: _sw_isr_table holds #{entries.size} entries, not #{num_irqs}" unless entries.size == num_irqs
      [words, entries]
    end

    def dump_section(elf, name, objcopy)
      out = "#{elf}.#{name}.bin"
      _o, err, st = Open3.capture3(objcopy, "--dump-section", "#{name}=#{out}", elf, "/dev/null")
      raise Error, "#{objcopy} could not dump #{name} from #{elf}: #{err.strip}" unless st.success? && File.file?(out)
      File.binread(out)
    end

    # Defined symbols by address (Thumb bit masked), from object-symbols.
    def symbols_by_address(elf, symbols_tool:)
      text, err, st = Open3.capture3(symbols_tool, "--addresses", "--defined", elf)
      raise Error, "#{symbols_tool} failed on #{elf}: #{err.strip}" unless st.success?
      by = Hash.new { |h, k| h[k] = [] }
      text.lines.each do |l|
        a, _s, _t, n = l.chomp.split("\t", 4)
        by[a.to_i(16) & ~1] << n
      end
      by
    end

    def classify_vectors(elf, inventory, vector_classes, config, symbols_tool:, objcopy:)
      num_irqs = (config["CONFIG_NUM_IRQS"] || raise(Error, "CONFIG_NUM_IRQS is not in the .config")).to_i
      reserved = reserved_slots(config)
      words, entries = read_tables(elf, num_irqs, objcopy: objcopy, offset: vector_table_offset(elf, symbols_tool: symbols_tool))
      syms = symbols_by_address(elf, symbols_tool: symbols_tool)
      klass_of = vector_classes.to_h { |v| [v.symbol, v.klass] }
      by_slot = inventory.sources.to_h { |s| [s.slot, s] }
      slots = []
      failures = []
      (1...(16 + num_irqs)).each do |i|
        word = words[i]
        names = syms[word & ~1]
        # several symbols can share an address (Zephyr's fault handlers are
        # subsections of one body; __start aliases the reset handler): the
        # slot is classified by any of its names, and reported by the first
        # that has a class
        klass = names.map { |n| klass_of[n] }.compact.first
        sym = names.find { |n| klass_of[n] == klass } || names.first
        if reserved.include?(i)
          if word.zero? then slots << Slot.new(index: i, word: word, symbol: nil, klass: :reserved, detail: "architecturally reserved, zero")
          else failures << "slot #{i}: an architecturally reserved position holds #{format('%#x', word)} (#{sym || 'no symbol'})"
          end
          next
        end
        if word.zero?
          failures << "slot #{i}: holds zero, and is not a reserved position"
          next
        end
        if sym.nil?
          failures << "slot #{i}: #{format('%#x', word)} is no defined symbol of the image"
          next
        end
        src = by_slot[i]
        if i == 1
          if klass == "reset" then slots << Slot.new(index: i, word: word, symbol: sym, klass: :reset, detail: "Zephyr's startup path")
          else failures << "slot 1: the reset handler is #{sym}, not a reset-class symbol"
          end
        elsif klass == "terminal"
          slots << Slot.new(index: i, word: word, symbol: sym, klass: :terminal, detail: "ends the run; outside the budget")
        elsif names.include?("_isr_wrapper") && i >= 16
          irq = i - 16
          _arg, isr = entries[irq]
          target = syms[isr & ~1].first
          if syms[isr & ~1].any? { |n| klass_of[n] == "default" }
            slots << Slot.new(index: i, word: word, symbol: sym, klass: :unused, detail: "_sw_isr_table[#{irq}] is #{target}")
          elsif src
            slots << Slot.new(index: i, word: word, symbol: sym, klass: :budgeted, detail: "irq #{irq} -> #{target}: #{src.name} (#{src.compatible}), reserve #{src.reserve_item}")
          else
            failures << "slot #{i}: irq #{irq} is connected to #{target || format('%#x', isr)} and has no inventory entry"
          end
        elsif klass == "default"
          slots << Slot.new(index: i, word: word, symbol: sym, klass: :unused, detail: "Zephyr's spurious handler")
        elsif src && names.include?(src.handler)
          slots << Slot.new(index: i, word: word, symbol: sym, klass: :budgeted, detail: "#{src.name}, reserve #{src.reserve_item}")
        else
          failures << "slot #{i}: #{sym} fits no class (not reset, terminal, reserved, unused, nor an inventory entry)"
        end
      end
      [slots, failures]
    end
  end
end
