# frozen_string_literal: true

module CoreApp
  # The call frames Arm codegen did not reserve, which -fstack-usage leaves
  # out of a function's frame (the kernel's StackBudget.cpp does the same for
  # the CORE objects). When a function's largest outgoing argument area is
  # 2047 bytes or more, clang moves sp around each call instead of reserving
  # the area: measured 2026-10-21, thumbv8m.main, a call with 520 pointer
  # arguments is reported as 24 and made after `sub.w sp, sp, #2064`. On the
  # FRDM-IMXRT1186 that was 3536 bytes in spc_session_doomcore_step, which
  # its .su reported as 296.
  #
  # Read from the object's own code (llvm-objdump -d), against its .su:
  #
  #   * a prologue is a run of sp decrements (push, vpush, sub sp by an
  #     immediate, with frame-pointer setup between them) at the function's
  #     start or beginning with a push (a shrink-wrapped prologue); what the
  #     largest run moves sp by beyond the .su frame is a call frame the
  #     prologue allocated with the frame;
  #   * any other `sub sp, #N` is a call frame of N.
  #
  # The larger of the two is what the frame lacks. A run smaller than the
  # .su frame, or sp moved by a register, has no reading here and is refused.
  # A side compile with unwind tables would mark the prologue with `.pad`, but
  # it changes code: measured the same day, a noreturn thread function gains a
  # `push {r7, lr}` with unwind tables.
  module Unreserved
    class Error < StandardError; end

    INSN = /\A\s*[0-9a-f]+:\s+(?:[0-9a-f]{4}\s?)+\s*\t(\S+)\s*(.*)\z/
    SUB_IMM = /\Asp,\s*(?:sp,\s*)?#(0x[0-9a-f]+|\d+)\z/
    SUB_REG = /\Asp,\s*(?:sp,\s*)?(?:r\d+|ip|lr)\b/

    def self.reglist_bytes(ops)
      ops[/\{(.*)\}/, 1].to_s.split(",").sum do |r|
        r = r.strip
        a, b = r.split("-")
        n = b ? b[/\d+/].to_i - a[/\d+/].to_i + 1 : 1
        n * (a.start_with?("d") ? 8 : 4)
      end
    end

    # {function => bytes} for the functions with an unreserved call frame, from
    # `llvm-objdump -d` text and the unit's frames {function => .su bytes}.
    def self.from_disassembly(text, frames)
      funcs = {}
      cur = nil
      text.each_line do |ln|
        if (m = ln.match(/\A[0-9a-f]+ <(.+)>:\s*\z/))
          cur = (funcs[m[1]] ||= [])
        elsif cur && (m = ln.chomp.match(INSN))
          cur << [m[1], m[2].strip]
        end
      end
      out = {}
      funcs.each do |fn, insns|
        next unless frames.key?(fn)

        runs = []
        run = nil
        later = 0
        insns.each_with_index do |(op, ops), i|
          bytes = if op.match?(/\A(push|vpush|stmdb)(\.w)?\z/) && (op != "stmdb" || ops.start_with?("sp!"))
                    reglist_bytes(ops)
                  elsif op.match?(/\Astr(\.w)?\z/) && ops.match?(/\[sp, #-(\d+)\]!\z/)
                    ops[/#-(\d+)/, 1].to_i
                  end
          sub = op.match?(/\Asubw?(\.w)?\z/) && (s = ops.match(SUB_IMM)) ? Integer(s[1]) : nil
          raise Error, "#{fn} moves sp by a register (#{op} #{ops}), so its call frame has no size here" if op.match?(/\Asubw?(\.w)?\z/) && ops.match?(SUB_REG)

          if bytes && (run.nil? || run[:open])
            run ||= (runs << { bytes: 0, open: true }).last
            run[:bytes] += bytes
          elsif sub && (run&.[](:open) || i.zero?)
            run ||= (runs << { bytes: 0, open: true }).last
            run[:bytes] += sub
          elsif sub
            later = [later, sub].max
          elsif run&.[](:open) && (op.match?(/\A(add|mov)(\.w)?\z/) && ops.match?(/\Ar\d+, sp\b/))
            next # frame-pointer setup inside the prologue
          else
            run[:open] = false if run
            run = nil
          end
        end
        frame = frames[fn]
        prologue = runs.map { |r| r[:bytes] }.max || 0
        raise Error, "#{fn}: its prologue moves sp by #{prologue}, less than its .su frame #{frame}; the frame is not read here" if prologue < frame

        extra = [prologue - frame, later].max
        out[fn] = extra if extra.positive?
      end
      out
    end

    # The method's positive control: a call with 600 arguments, whose area
    # cannot be reserved on Thumb. Its C source.
    CONTROL_ARGS = 600
    CONTROL_FLOOR = 2048
    def self.control_source
      params = (1..CONTROL_ARGS).map { |i| "int a#{i}" }.join(", ")
      args = (1..CONTROL_ARGS).map(&:to_s).join(", ")
      "void spc_unreserved_sink(#{params});\nvoid spc_unreserved_control(void) { spc_unreserved_sink(#{args}); }\n"
    end
  end
end
