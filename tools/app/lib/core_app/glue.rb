# frozen_string_literal: true
#
# tools/app/lib/core_app/glue.rb -- renders the Zephyr application around the
# CORE objects (decision 0014 §8 step 8): main.c with the storage, the entry
# wrappers, the scheduler thread, the timer dispatch and the failure handler;
# and the skeleton of step 2 (CMakeLists.txt, prj.conf, app.overlay).
require "erb"
require_relative "app_model"
require_relative "trace"

module CoreApp
  module Glue
    TEMPLATES = File.expand_path("../../templates", __dir__)
    # the narrow three are 0018's, reached only through a core_session's states
    CTYPE = { "u8" => "uint8_t", "i32" => "int32_t", "u32" => "uint32_t", "i64" => "int64_t",
              "i8" => "int8_t", "u16" => "uint16_t", "i16" => "int16_t" }.freeze
    WIDTH = { "u8" => 1, "i32" => 4, "u32" => 4, "i64" => 8, "i8" => 1, "u16" => 2, "i16" => 2 }.freeze

    module_function

    def render(name, b)
      ERB.new(File.read(File.join(TEMPLATES, name)), trim_mode: "<>").result(b)
    end

    # `board_pkg` is the Board::Package; `owned` is {context => [[module,
    # index]]}; `cycles_per_sec` the board's CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC.
    # `verify` is nil for a production build, else {timer_ctx:, horizon_us:,
    # drain_us:, nest_timer:} (Task 11); `cross` the names of the
    # cross-context states.
    # `adapter_threads` is [{name:, cls:}] for the marks a verification run prints.
    # `session` is nil, or {base:} for an application with a core_session.
    # `failure_sites` is nil, or the entries whose site globals the build's
    # objects define (spinel-core-kernel --failure-sites): the application's
    # scheduled entries first, in their order, then the session's.
    def main_c(app, board_pkg, owned, app_name:, board:, cycles_per_sec:, verification:, verify: nil, cross: [], adapter_threads: [], stress: false, pcsample: false, session: nil, failure_sites: nil, pair: nil)
      ctype = CTYPE
      width = WIDTH
      timer_ctx = verify&.dig(:timer_ctx)
      horizon_us = verify&.dig(:horizon_us)
      drain_us = verify&.dig(:drain_us)
      nest_timer = verify&.dig(:nest_timer)
      board_modules = board_pkg.modules.map do |m|
        { name: m.name, stem: m.name.downcase, class_dir: File.basename(m.spec.dir), table: m.spec.table,
          init: m.spec.table != "none", safe: m.spec.safe_state == "none" ? nil : m.spec.safe_state }
      end
      mods = board_pkg.modules.to_h { |m| [m.name, m] }
      owned_rows = owned.transform_values do |list|
        list.filter_map do |mod_name, idx|
          m = mods[mod_name] or next
          next if m.spec.safe_state == "none"
          [{ table: m.spec.table, safe: m.spec.safe_state }, idx, m.name.downcase, File.basename(m.spec.dir)]
        end
      end
      owned = owned_rows
      render("main.c.erb", binding)
    end

    def cmakelists(app_name:, wrap: [])
      render("CMakeLists.txt.erb", binding)
    end

    # The stimulus thread's unit (Task 11): the script's items resolved
    # against the application (an inbound item's channel index) and the
    # board (which classes it has).
    StimItem = Struct.new(:id, :kind, :time, :a, :b, :channel_index, keyword_init: true)
    def stimulus_c(app, stim, board_pkg, cycles_per_sec:)
      mods = board_pkg.modules.map(&:name)
      has_adc = mods.include?("Adc")
      has_button = mods.include?("Button")
      items = stim.items.map do |it|
        ci = nil
        if it.kind == "inbound"
          ci = app.channels.index { |c| c.name == it.a } or raise "#{stim.path}:#{it.line}: no channel #{it.a}"
        elsif it.kind == "adc"
          raise "#{stim.path}:#{it.line}: the board has no Adc instance for an adc item" unless has_adc
        elsif it.kind == "gpio"
          raise "#{stim.path}:#{it.line}: the board has no Button instance for a gpio item" unless has_button
        end
        StimItem.new(id: it.id, kind: it.kind, time: it.time, a: it.a, b: it.b, channel_index: ci)
      end
      render("stimulus.c.erb", binding)
    end

    def nest_timer_c(cycles_per_sec:, nest_ctx:, priority:, period_us:, busy_us:)
      render("nest_timer.c.erb", binding)
    end

    # DECISION 0014 Task 12: the sampling source. `spans` is one entry per
    # ring span, [label stem, op, part], from the application's channels --
    # the stem is what `SPC_LABEL` emitted around that span in the generated
    # channel body, so the handler classifies a PC against the same labels
    # `labels.rb` checks in the linked image.
    def stress_timer_c(app, cycles_per_sec:, priority:, period_us:, report_at:)
      spans = app.channels.flat_map do |c|
        %w[put get].flat_map do |op|
          %w[copy pub].map { |part| ["spc_ring_#{c.name}_#{op}_#{part}", op, part] }
        end
      end
      render("stress_timer.c.erb", binding)
    end

    # The PC sampler of a frdm_imxrt1186 measurement build (decision 0022's
    # board profile): GPT1, its samples kept in RAM for a debugger to read.
    def pcsample_timer_c(priority:, period_us:, tics:, capacity:)
      render("pcsample_timer.c.erb", binding)
    end

    # `subsystems` are the Kconfig symbols of the classes the application
    # refers to, in order, each once.
    def prj_conf(verification:, subsystems:)
      render("prj.conf.erb", binding)
    end

    def overlay(board_overlay:)
      render("app.overlay.erb", binding)
    end

    def placeholder = File.read(File.join(TEMPLATES, "spc_placeholder.c"))

    CFIELD = { "u8" => "uint8_t", "u16" => "uint16_t", "u32" => "uint32_t", "u64" => "uint64_t", "i32" => "int32_t", "i64" => "int64_t" }.freeze

    # recorder.h, generated from trace_schema.tsv (0014 plan, "Trace": the C
    # recorder header and the Ruby decoder read one schema): the kind ids,
    # the codes, the limits, and one emitter per kind whose parameters are
    # the kind's fields in schema order (a `bytes` field is a pointer and a
    # length; XCALL's `args` is the builder in recorder.c). Each emitter
    # serialises its body little-endian into a stack buffer and hands it to
    # spc_rec_write, which takes the sequence number inside the critical
    # section. `body_max` is the largest body the application can produce,
    # so the buffers are sized by the declarations, not guessed.
    def recorder_h(app, body_max:, contexts:, states:, ring:)
      sc = Trace.schema
      out = +"/* generated from tools/app/lib/core_app/trace_schema.tsv by spinel-core-app build\n"
      out << " * (decision 0014 §10, the plan's \"Trace\"). Do not edit: the decoder reads the\n * same schema. */\n"
      out << "#ifndef SPC_RECORDER_H\n#define SPC_RECORDER_H\n#include <stdint.h>\n\n"
      out << "#define SPC_TRACE_VERSION #{sc.version}u\n#define SPC_TRACE_MAGIC \"SPTR\"\n#define SPC_REC_HEADER_LEN #{Trace::HEADER_LEN}u\n"
      out << "#define SPC_REC_BODY_MAX #{body_max}u\n#define SPC_REC_ARGS_MAX #{sc.limits.fetch('args')}u\n#define SPC_NO_ENTRY 255u\n"
      out << "#define SPC_REC_CONTEXTS #{contexts}u /* 0 scheduler, 1 transport, 2 stimulus, 3.. the inventory's interrupt sources */\n"
      out << "#define SPC_REC_STATES #{states}u\n#define SPC_REC_RING #{ring}u /* bytes per context */\n\n"
      sc.ids.each { |kind, id| out << "#define SPC_TK_#{kind} #{id}u\n" }
      out << "\n"
      sc.codes.each { |kind, fields| fields.each { |field, names| names.each { |n, v| out << "#define SPC_#{kind}_#{field.upcase}_#{n.upcase} #{v}u\n" } } }
      out << "\n/* the critical section of 0014 §10 (a): PRIMASK saved, set and restored, with\n * compiler barriers; a recorded operation is performed inside it together\n * with the appending of its record */\n"
      out << "static inline uint32_t spc_rec_section_enter(void)\n{\n\tuint32_t primask;\n\t__asm__ volatile(\"mrs %0, primask\\n\\tcpsid i\" :\"=r\"(primask) :: \"memory\");\n\treturn primask;\n}\n"
      out << "static inline void spc_rec_section_leave(uint32_t primask)\n{\n\t__asm__ volatile(\"msr primask, %0\" :: \"r\"(primask) : \"memory\");\n}\n"
      out << "/* the current context and entry (recorder.c), set and restored by every actor around its recorded work */\n"
      out << "extern volatile uint8_t spc_rec_ctx;\nextern volatile uint8_t spc_rec_entry;\n"
      out << "\n/* the writer (recorder.c): the critical section, the sequence number, the ring */\n"
      out << "void spc_rec_write(uint8_t ctx, uint8_t entry, uint16_t kind, const uint8_t *body, uint32_t len);\n"
      out << "void spc_rec_oversize(uint8_t ctx); /* a body over SPC_REC_BODY_MAX: an overflow, counted */\n"
      out << "static inline void spc_rec_put8(uint8_t *p, uint8_t v) { p[0] = v; }\n"
      out << "static inline void spc_rec_put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }\n"
      out << "static inline void spc_rec_put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) { p[i] = (uint8_t)(v >> (8 * i)); } }\n"
      out << "static inline void spc_rec_put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) { p[i] = (uint8_t)(v >> (8 * i)); } }\n\n"
      sc.fields.each do |kind, fields|
        next if fields.any? { |f| f.type == "args" } # XCALL: the builder in recorder.c
        params = ["uint8_t rec_ctx", "uint8_t rec_entry"]
        fixed = 0
        var = false
        cn = ->(n) { %w[extern].include?(n) ? "#{n}_" : n } # a field named like a C keyword
        fields.each do |f|
          if f.type == "bytes"
            params << "const uint8_t *#{f.name}" << "uint32_t #{f.name}_len"
            fixed += 4
            var = true
          else
            params << "#{CFIELD.fetch(f.type)} #{cn.call(f.name)}"
            fixed += Trace::TYPE_WIDTH.fetch(f.type)
          end
        end
        out << "static inline void spc_tr_#{kind}(#{params.join(', ')})\n{\n"
        out << "\tuint8_t body[#{var ? 'SPC_REC_BODY_MAX' : fixed}];\n\tuint32_t p = 0;\n"
        fields.each do |f|
          n = cn.call(f.name)
          case f.type
          when "bytes"
            out << "\tif (p + 4u + #{f.name}_len > SPC_REC_BODY_MAX) { spc_rec_oversize(rec_ctx); return; } /* a body the declarations said cannot happen */\n"
            out << "\tspc_rec_put32(body + p, #{f.name}_len); p += 4;\n"
            out << "\tfor (uint32_t i = 0; i < #{f.name}_len; i++) { body[p + i] = #{f.name}[i]; }\n\tp += #{f.name}_len;\n"
          when "u8" then out << "\tspc_rec_put8(body + p, #{n}); p += 1;\n"
          when "u16" then out << "\tspc_rec_put16(body + p, #{n}); p += 2;\n"
          when "u32" then out << "\tspc_rec_put32(body + p, #{n}); p += 4;\n"
          when "i32" then out << "\tspc_rec_put32(body + p, (uint32_t)#{n}); p += 4;\n"
          when "u64" then out << "\tspc_rec_put64(body + p, #{n}); p += 8;\n"
          when "i64" then out << "\tspc_rec_put64(body + p, (uint64_t)#{n}); p += 8;\n"
          end
        end
        out << "\tspc_rec_write(rec_ctx, rec_entry, SPC_TK_#{kind}, body, p);\n}\n\n"
      end
      out << "/* XCALL: a tagged argument list (0 a scalar, 1 a buffer), built in recorder.c */\n"
      out << "struct spc_rec_arg { uint8_t tag; int64_t scalar; const uint8_t *buf; uint32_t len; };\n"
      out << "void spc_tr_XCALL(uint8_t ctx, uint8_t entry, uint16_t ext, uint8_t argc, const struct spc_rec_arg *args);\n"
      out << "#endif\n"
      out
    end

    # One prototype in the C ABI of 0014 (a scalar by its domain; a buffer
    # as pointer then `uint32_t <name>_len`, const when `in`), the form
    # spinel-core-kernel's --extern-header writes; step 7 checks the two
    # agree, so the kernel stays the authority and the provider still has a
    # header to compile against at step 5.
    def prototype(e)
      args = e.params.map do |pa|
        if pa.buffer?
          "#{e.writes.include?(pa.name) ? '' : 'const '}#{CTYPE.fetch(pa.type)} *#{pa.name}, uint32_t #{pa.name}_len"
        else
          "#{CTYPE.fetch(pa.type)} #{pa.name}"
        end
      end
      "#{e.returns ? CTYPE.fetch(e.returns) : 'void'} #{e.symbol}(#{args.empty? ? 'void' : args.join(', ')});"
    end

    # The header the application's own providers include (its core_extern
    # declarations only; board members and channels have their own).
    def externs_h(app)
      lines = ["/* generated by spinel-core-app build (0014 §8 step 5): the prototypes of the",
               " * application's core_extern declarations; a provider whose definition",
               " * disagrees does not compile. Checked against spinel-core-kernel's",
               " * --extern-header at step 7. */",
               "#ifndef SPC_APP_EXTERNS_H", "#define SPC_APP_EXTERNS_H", "#include <stdint.h>"]
      app.externs.each { |e| lines << prototype(e) }
      lines << "#endif"
      lines.join("\n") + "\n"
    end
  end
end
