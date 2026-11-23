# frozen_string_literal: true
#
# tools/app/lib/core_app/stack.rb -- the two inequalities of decision 0014 §9,
# with every consumer listed and every term's evidence kind named.
#
# THREAD STACK (PSP), one requirement R per generated thread (the scheduler
# thread; the transport thread when channels are declared). A thread an
# adapter's glue creates (the Adc sampler) is not generated and has no
# requirement here: the build lists it as unbudgeted in build.json, with
# its measured frames and its literal stack, until the driver path it
# blocks in has an attested reserve.
#   glue frames: the sum of the frames of every glue function the thread can
#                run (its loop, the selection, the entry wrappers, the
#                failure handler and the safe-state calls, the recorder in
#                a verification build). The sum over the call tree bounds
#                every path through it whatever clang inlined: an inlined
#                function's locals are in its caller's frame and its own
#                line reads 0, so no path is undercounted.  [measurement]
#   + max over the thread's entries of the entry's kernel_stack, which the
#     kernel's report already composes with the attested extern frames
#     (0010 step 2, `properties.stack.kernel_stack`)            [measurement + attestation]
#   + thread_kernel_calls + guard_area                           [attested reserves]
#   + thread_switch: the hardware exception frame an interrupt or PendSV
#     pushes on this stack, 32 bytes without an FPU plus alignment [attested reserve]
#   = R
# The generated stack size is set to R, so "size >= requirement" holds by
# construction and proves nothing about R; the two independent gates are R
# against the board's attested maximum thread stack, and the image against
# the board's memory.
#
# INTERRUPT STACK (MSP), shared by every nested handler:
#   sum over the worst nesting chain of the inventory's priorities of
#     ( hardware frame + alignment padding [for the nested entries, whose
#                                            frames land on MSP]
#     + handler cost )
#   <= CONFIG_ISR_STACK_SIZE
# The chain takes, from the lowest priority level up, the costliest source at
# each level: distinct priority levels can nest, equal ones cannot. The
# lowest level's entry comes from thread mode and pushes its frame on PSP;
# every level above it pushes its frame on MSP. That nested-entry term is
# carried explicitly, whatever its cause on a given run (the Task 9 carry-over
# row). A source's handler cost is its attested reserve; for the system
# timer it is timer_dispatch plus the dispatch glue plus the worst interrupt
# entry's kernel_stack; for PendSV the pendsv reserve.
module CoreApp
  module Stack
    class Error < StandardError; end

    HW_FRAME = 36 # 32 bytes without an FPU, plus up to 4 of alignment

    Term = Struct.new(:name, :bytes, :evidence, :detail, keyword_init: true)
    Requirement = Struct.new(:name, :terms, :total, :limit, :limit_evidence, :verdict, :reason, keyword_init: true) do
      def pass? = verdict == :pass
    end
    Verdicts = Struct.new(:threads, :interrupt, :gates, :evidence_kinds, keyword_init: true) do
      def pass? = threads.all?(&:pass?) && interrupt.pass? && gates.all?(&:pass?)
      def failures
        (threads + [interrupt] + gates).reject(&:pass?).map { |r| "#{r.name}: #{r.reason}" }
      end
    end

    module_function

    def reserve(reserves, item)
      row = reserves[item] or raise Error, "no applicable reserve for #{item}"
      Term.new(name: item, bytes: row.bytes, evidence: "attestation", detail: row.evidence)
    end

    # The glue functions of main.c that never run on the scheduler thread
    # (main runs on Zephyr's main thread; the timer expiry in the system
    # clock interrupt) and never in the timer expiry (the thread's loop).
    # The doorbell's callback (decision 0028) runs in the MU's interrupt, on
    # neither: the MU source is charged it.
    NOT_ON_THREAD = %w[main spc_timer_expiry spc_doorbell].freeze
    NOT_IN_EXPIRY = %w[main spc_scheduler_thread spc_doorbell].freeze
    DOORBELL_ISR = "spc_doorbell"
    MU_COMPATIBLES = %w[nxp,mbox-imx-mu].freeze
    # The transport unit's functions that run from main, not on its thread:
    # its start, the udp: sockets it opens (transport_udp.c), and the
    # interrupt-driven transmit's callback, which runs in
    # the UART's interrupt (SPC_UART_TX_IRQ, from the board's own
    # CONFIG_UART_INTERRUPT_DRIVEN, decision 0023)
    NOT_ON_TRANSPORT = %w[spc_transport_start spc_transport_uart_isr spc_transport_udp_open].freeze
    UART_ISR = "spc_transport_uart_isr"
    UART_COMPATIBLES = %w[nxp,lpuart arm,cmsdk-uart].freeze

    def tree_sum(frames, except)
      names = frames.keys.reject { |n| except.include?(n) }.sort
      [names.sum { |n| frames[n] }, names]
    end

    # `glue` is {name => bytes} from the glue object's .su (measurement),
    # `transport` the same for the transport unit and the channel ring units;
    # `entries` is {entry => {context:, kernel_stack:, evidence:}} from the
    # reports; `reserves` is {item => Row}; `board` is {key => [value,
    # evidence]}; `config` the .config hash; `inventory` the Inventory result.
    # A verification build (Task 11) adds to every path the recorder's frames
    # (`vglue[:recorder]`: the hooks CORE calls in place of its cross accesses,
    # the writer, the emitters, the XCALL builder), to the entries' paths the
    # __aeabi_ldivmod wrapper (`vglue[:cycles]` plus its 24 bytes of pushes),
    # and to the nesting source's chain level its handler (`vglue[:nest]`).
    # Each is measured (.su) and summed over its call tree, as the glue is.
    LDIVMOD_WRAP_PUSHES = 24 # push {r4, lr}, push {r0-r3}: cycles.c
    NOT_ON_RECORD_PATH = %w[spc_rec_drain spc_rec_pending spc_rec_register_state spc_rec_sequence].freeze

    # `adapter_threads` is [{name:, frames: {fn => bytes} of the unit, exclude:
    # [fn], items: [reserve item]}]: a thread an adapter's glue creates (the
    # Adc sampler), whose requirement is the unit's frames but the excluded
    # ones (its init runs on the main thread), the named reserves -- the
    # driver's blocking path and the kernel calls, alternatives summed, which
    # bounds either -- and the guard and switch of every thread.
    def check(glue:, transport:, entries:, reserves:, inventory:, board:, config:, verification: false, vglue: nil, adapter_threads: [])
      raise Error, "a verification build's stack check needs the recorder's, the cycle wrapper's and the nesting handler's frames" if verification && vglue.nil?
      vterms = lambda do |with_wrapper|
        out = []
        next out unless verification
        rb, rn = tree_sum(vglue[:recorder], NOT_ON_RECORD_PATH)
        out << Term.new(name: "recorder", bytes: rb, evidence: "measurement", detail: "recorder .su, the sum over #{rn.size} functions: #{rn.join(' ')}")
        if with_wrapper
          cb, cn = tree_sum(vglue[:cycles], [])
          out << Term.new(name: "ldivmod wrapper", bytes: LDIVMOD_WRAP_PUSHES + cb, evidence: "measurement", detail: "cycles.c: #{LDIVMOD_WRAP_PUSHES} bytes of pushes (assembly literal) + its C (#{cb}: #{cn.join(' ')})")
        end
        out
      end
      threads = []
      thread_entries = entries.select { |_, e| e[:context] == "thread" }
      isr_entries = entries.select { |_, e| e[:context] == "interrupt" }
      worst = ->(es) { es.max_by { |_, e| e[:kernel_stack] } }
      # the roots are address-taken (k_thread_create, k_timer_init) so they
      # are emitted whenever reachable; anything below them may be inlined
      # away. The timer expiry is dead, and dropped, when no entry runs in
      # interrupt context.
      raise Error, "the glue's .su has no frame for spc_scheduler_thread" unless glue.key?("spc_scheduler_thread")
      raise Error, "the glue's .su has no frame for spc_timer_expiry, and #{isr_entries.keys.join(' ')} run in interrupt context" if !isr_entries.empty? && !glue.key?("spc_timer_expiry")
      raise Error, "a verification build has no recorder frames" if verification && vglue[:recorder].empty?
      # the scheduler thread
      terms = []
      bytes, names = tree_sum(glue, NOT_ON_THREAD)
      terms << Term.new(name: "glue frames on the thread", bytes: bytes, evidence: "measurement", detail: "glue .su, the sum over #{names.size} functions: #{names.join(' ')}")
      if (w = worst.call(thread_entries))
        terms << Term.new(name: "worst thread entry (#{w[0]})", bytes: w[1][:kernel_stack], evidence: w[1][:evidence], detail: "properties.stack.kernel_stack of the entry's report, extern frames attested")
      end
      terms.concat(vterms.call(true))
      %w[thread_kernel_calls guard_area thread_switch].each { |i| terms << reserve(reserves, i) }
      threads << requirement("scheduler thread", terms, board, "max_thread_stack")
      # the transport thread, when the application declares a channel
      # (`transport` is empty otherwise: no unit was generated)
      unless transport.empty?
        terms = []
        unit = transport.reject { |n, _| n.match?(/\Aspc_channel_/) }
        raise Error, "the transport's .su has no frame for spc_transport_step" unless unit.key?("spc_transport_step")
        bytes, names = tree_sum(unit, NOT_ON_TRANSPORT)
        terms << Term.new(name: "transport frames on the thread", bytes: bytes, evidence: "measurement", detail: "transport .su, the sum over #{names.size} functions: #{names.join(' ')}")
        terms << Term.new(name: "ring operation", bytes: transport.values_at(*transport.keys.grep(/\Aspc_channel_.*_(put|get)\z/)).max || 0, evidence: "measurement", detail: "the largest channel unit frame (a separate object: never inlined into the transport)")
        terms.concat(vterms.call(false))
        if verification
          # the drainer's own recorder functions, which only this thread calls
          db, dn = tree_sum(vglue[:recorder].select { |n, _| NOT_ON_RECORD_PATH.include?(n) }, [])
          terms << Term.new(name: "recorder drain", bytes: db, evidence: "measurement", detail: "recorder .su, the drainer's functions: #{dn.join(' ')}")
        end
        %w[uart_calls thread_kernel_calls guard_area thread_switch].each { |i| terms << reserve(reserves, i) }
        threads << requirement("transport thread", terms, board, "max_thread_stack")
      end
      adapter_threads.each do |at|
        terms = []
        bytes, names = tree_sum(at[:frames], at[:exclude])
        terms << Term.new(name: "#{at[:name]} frames", bytes: bytes, evidence: "measurement", detail: "the unit's .su, the sum over #{names.size} functions: #{names.join(' ')}")
        # the thread's own reserves are alternative blocking paths, not one
        # sequence: summing them bounds whichever the thread is in, and the
        # term says so rather than leaving the sum to read as a chain
        at[:items].each do |i|
          r = reserve(reserves, i)
          terms << (at[:items].size > 1 ? Term.new(name: r.name, bytes: r.bytes, evidence: r.evidence, detail: "#{r.detail}; one of #{at[:items].size} alternative blocking paths of this thread, summed so the requirement bounds whichever it is in") : r)
        end
        %w[guard_area thread_switch].each { |i| terms << reserve(reserves, i) }
        threads << requirement("#{at[:name]} thread", terms, board, "max_thread_stack")
      end
      # the interrupt stack: the worst nesting chain
      by_level = inventory.sources.group_by(&:priority)
      levels = by_level.keys.sort.reverse # lowest priority (largest number) first
      chain = []
      levels.each_with_index do |prio, k|
        costs = by_level[prio].map do |src|
          cost = reserve(reserves, src.reserve_item).bytes
          detail = src.reserve_item
          if src.name == "systick"
            gb, gn = tree_sum(glue, NOT_IN_EXPIRY)
            cost += gb + (worst.call(isr_entries)&.dig(1, :kernel_stack) || 0)
            detail += " + timer dispatch glue (#{gb}: #{gn.join(' ')}) + worst interrupt entry"
            vterms.call(true).each { |t| cost += t.bytes; detail += " + #{t.name} #{t.bytes}" }
          elsif transport.key?(UART_ISR) && UART_COMPATIBLES.include?(src.compatible)
            # the UART's driver handler calls the transport's transmit
            # callback (the driver's part, its FIFO fill and the enables, is in
            # the source's reserve); every UART source is charged it, which
            # bounds the console's whichever it is
            cost += transport[UART_ISR]
            detail += " + the transport's transmit callback (#{transport[UART_ISR]}: #{UART_ISR})"
          elsif glue.key?(DOORBELL_ISR) && MU_COMPATIBLES.include?(src.compatible)
            # the MU driver's handler calls the doorbell's callback (decision
            # 0028); its k_sem_give is in the source's reserve, the glue's
            # own frame is measured here
            cost += glue[DOORBELL_ISR]
            detail += " + the doorbell's callback (#{glue[DOORBELL_ISR]}: #{DOORBELL_ISR})"
          elsif src.name == "nest_timer"
            nb, nn = tree_sum(vglue[:nest], [])
            cost += nb
            detail += " + the nesting handler (#{nb}: #{nn.join(' ')})"
            vterms.call(false).each { |t| cost += t.bytes; detail += " + #{t.name} #{t.bytes}" }
          end
          [cost, src, detail]
        end
        cost, src, detail = costs.max_by(&:first)
        nested = k.positive? ? HW_FRAME : 0
        chain << Term.new(name: "priority #{prio}: #{src.name}", bytes: cost + nested,
                          evidence: "attestation", detail: "#{detail}#{nested.positive? ? " + nested entry's hardware frame #{HW_FRAME}" : " (entered from thread mode; its frame is on the thread's stack)"}")
      end
      isr_size = (config["CONFIG_ISR_STACK_SIZE"] || "0").to_i
      total = chain.sum(&:bytes)
      interrupt = Requirement.new(name: "interrupt stack", terms: chain, total: total, limit: isr_size, limit_evidence: "CONFIG_ISR_STACK_SIZE, configuration",
                                  verdict: total <= isr_size ? :pass : :fail,
                                  reason: total <= isr_size ? nil : "the worst nesting chain needs #{total} bytes and CONFIG_ISR_STACK_SIZE is #{isr_size}")
      # gates independent of R
      gates = []
      fpu = config.key?("CONFIG_FPU")
      gates << Requirement.new(name: "no FPU", terms: [], total: fpu ? 1 : 0, limit: 0, limit_evidence: "declaration: no FPU (0014 §9)",
                               verdict: fpu ? :fail : :pass, reason: fpu ? "CONFIG_FPU=y: the exception frame and the reserves assume no FPU" : nil)
      Verdicts.new(threads: threads, interrupt: interrupt, gates: gates,
                   evidence_kinds: %w[measurement attestation declaration])
    end

    def requirement(name, terms, board, key)
      total = terms.sum(&:bytes)
      limit, evidence = board[key] || [nil, nil]
      if limit.nil?
        Requirement.new(name: name, terms: terms, total: total, limit: nil, limit_evidence: nil, verdict: :fail, reason: "the board's #{key} is not attested")
      else
        Requirement.new(name: name, terms: terms, total: total, limit: limit.to_i, limit_evidence: "board #{key}: #{evidence}",
                        verdict: total <= limit.to_i ? :pass : :fail,
                        reason: total <= limit.to_i ? nil : "R = #{total} exceeds the board's #{key} #{limit}")
      end
    end

    # The image-size gate: text + data + bss against the board's RAM and
    # flash, from `size`-like figures the caller read from the image.
    def memory_gate(sizes, board)
      ram = board["ram_bytes"]&.first.to_i
      used = sizes[:data] + sizes[:bss]
      Requirement.new(name: "image fits the board's RAM", terms: [Term.new(name: "data + bss", bytes: used, evidence: "measurement", detail: "the linked image's sections")],
                      total: used, limit: ram, limit_evidence: "board ram_bytes: #{board['ram_bytes']&.last}",
                      verdict: ram.positive? && used <= ram ? :pass : :fail,
                      reason: ram.positive? && used <= ram ? nil : "data + bss = #{used} against ram_bytes #{ram}")
    end
  end
end
