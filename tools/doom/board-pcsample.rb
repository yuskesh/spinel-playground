# frozen_string_literal: true
#
# tools/doom/board-pcsample.rb — the PC samples of a --pcsample measurement build, counted.
#
#   ruby tools/doom/board-pcsample.rb --record RECORD --samples SAMPLES --elf zephyr.elf
#        --map zephyr.map --out DIR [--nm llvm-nm] [--top 30]
#
# RECORD is the sampler's spc_pcs (tools/app/templates/pcsample_timer.c.erb):
# eight little-endian words -- magic 0x53435050, samples, nested, stopped,
# tics, period_us, capacity, root_hz -- then two 64-bit cycle counts, when
# the timer started and when it stopped. SAMPLES is the first `samples` words of
# spc_pcs_pc: each the PC the loop's thread was preempted at, 0 for a sample
# that landed on another handler.
#
# Each PC is placed in the function whose symbol (llvm-nm --print-size)
# covers it and in the input section (zephyr.map) that holds it. The section's
# object decides the stage:
#
#   input, step, render   doom_core_input.o, doom_core_step.o, doom_core_render.o
#   digest                provider_profile_digests.o (Frame.fnv and Frame.sha)
#   loop                  core_tic.o, the loop's own CORE code (cells, format, put)
#   session               session.o
#   console               the channel units and the UART transport
#   helpers               the compiler's runtime (__aeabi_*, memcpy and the like)
#   kernel                Zephyr and its drivers, the idle loop included
#   other                 anything else
#
# A runtime helper is counted under `helpers`, not under the stage that
# called it: a PC does not say who the caller was. Writes DIR/functions.tsv
# (stage, object, function, samples, share of all, share of the stage) and
# DIR/summary.txt (the record, each stage's total, and its top functions).
require "optparse"
require "fileutils"
require "open3"

opt = { nm: "llvm-nm", top: 30 }
OptionParser.new do |o|
  %i[record samples elf map out nm].each { |k| o.on("--#{k} PATH") { |v| opt[k] = v } }
  o.on("--top N", Integer) { |v| opt[:top] = v }
  o.on("--hz N", Integer) { |v| opt[:hz] = v } # the cycle counter's rate, the build's CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC
end.parse!
%i[record samples elf map out].each { |k| opt[k] or abort("board-pcsample: --#{k} is required") }
FileUtils.mkdir_p(opt[:out])

rec = File.binread(opt[:record])
abort("board-pcsample: the record is #{rec.bytesize} bytes, not 48") unless rec.bytesize == 48
magic, samples, nested, stopped, tics, period_us, capacity, root_hz, first_cyc, last_cyc = rec.unpack("V8Q<2")
abort(format("board-pcsample: the record's magic is 0x%08x, not 0x53435050", magic)) unless magic == 0x53435050
pcs = File.binread(opt[:samples]).unpack("V*")
abort("board-pcsample: #{pcs.size} samples read, the record says #{samples}") unless pcs.size == samples

# functions: [address, size, name], sorted
out, st = Open3.capture2(opt[:nm], "--defined-only", "--print-size", "--numeric-sort", opt[:elf])
abort("board-pcsample: #{opt[:nm]} failed") unless st.success?
funcs = out.lines.filter_map do |l|
  f = l.split
  next unless f.size == 4 && f[2].match?(/\A[tTwW]\z/)
  [f[0].to_i(16), f[1].to_i(16), f[3]]
end.sort_by(&:first)
# one symbol per address, a sized one first; an assembly routine with no
# .size (libgcc's __aeabi_uldivmod) reaches the next symbol
funcs = funcs.group_by(&:first).map { |_, g| g.max_by { |_, size, _| size } }.sort_by(&:first)
funcs.each_with_index do |f, i|
  f[1] = funcs[i + 1][0] - f[0] if f[1].zero? && funcs[i + 1]
end

# input sections: [address, size, object], sorted
sections = []
pending = nil
File.foreach(opt[:map]) do |l|
  # code in the instruction TCM (an .itcm section, decision 0023's M7) runs
  # from address 0, where a discarded section is listed too: it is kept
  if (m = l.match(/\A \.(text|itcm)\S*\s+0x(\h+)\s+0x(\h+)\s+(\S.*)$/))
    sections << [m[2].to_i(16), m[3].to_i(16), m[4].strip, m[1] == "itcm"]
  elsif (pm = l.match(/\A \.(text|itcm)\S*\s*$/))
    pending = pm[1] == "itcm" ? :itcm : :text
  elsif pending && (m = l.match(/\A\s+0x(\h+)\s+0x(\h+)\s+(\S.*)$/))
    sections << [m[1].to_i(16), m[2].to_i(16), m[3].strip, pending == :itcm]
    pending = nil
  else
    pending = nil
  end
end
sections.reject! { |a, s, _, itcm| (a.zero? && !itcm) || s.zero? }
sections.sort_by!(&:first)

def find(table, pc)
  lo = 0
  hi = table.size - 1
  best = nil
  while lo <= hi
    mid = (lo + hi) / 2
    if table[mid][0] <= pc
      best = table[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  best && pc < best[0] + [best[1], 1].max ? best : nil
end

def stage_of(object)
  # the toolchain's libgcc and libc first: their path is under the Zephyr
  # SDK, so the kernel's pattern below would take them
  return "helpers" if object.match?(%r{/libgcc\.a\(|/libc\.a\(|libclang_rt|compiler-rt})
  o = object[/\(([^)]+)\)\z/, 1] || File.basename(object)
  case o
  when "doom_core_input.o" then "input"
  when "doom_core_step.o" then "step"
  when "doom_core_render.o" then "render"
  when "provider_profile_digests.o" then "digest"
  when "core_tic.o" then "loop"
  when "session.o" then "session"
  when /\Achannel_.*\.o\z/, "transport_uart.o" then "console"
  else object.match?(/zephyr|kernel|drivers|soc|arch|hal_nxp|modules/) ? "kernel" : "other"
  end
end

counts = Hash.new(0)
place = {}
unknown = 0
pcs.each do |pc|
  next if pc.zero?
  f = find(funcs, pc)
  s = find(sections, pc)
  unless f && s
    unknown += 1
    next
  end
  key = [stage_of(s[2]), s[2][/\(([^)]+)\)\z/, 1] || File.basename(s[2]), f[2]]
  counts[key] += 1
end
taken = samples - nested
stage_tot = Hash.new(0)
counts.each { |(stage, _, _), n| stage_tot[stage] += n }

File.open(File.join(opt[:out], "functions.tsv"), "w") do |io|
  io.puts %w[stage object function samples share_all share_stage].join("\t")
  counts.sort_by { |(stage, _, _), n| [-stage_tot[stage], -n] }.each do |(stage, obj, fn), n|
    io.puts [stage, obj, fn, n, format("%.4f", n.fdiv(taken)), format("%.4f", n.fdiv(stage_tot[stage]))].join("\t")
  end
end

hz = opt[:hz] || 240_000_000
secs = (last_cyc - first_cyc).fdiv(hz)
summary = []
summary << "record: samples #{samples} (capacity #{capacity}), nested #{nested}, unplaced #{unknown}, stopped #{stopped}, tics #{tics}"
summary << format("period %d us at a %d Hz root; the timer ran %.3f s of %d MHz cycles, so %.1f us per sample",
                  period_us, root_hz, secs, hz / 1_000_000, samples.positive? ? secs * 1e6 / samples : 0)
summary << "stage totals (share of the #{taken} thread samples):"
stage_tot.sort_by { |_, n| -n }.each { |stage, n| summary << format("  %-8s %8d  %6.2f%%", stage, n, 100.0 * n / taken) }
%w[input step render digest loop session console helpers kernel other].each do |stage|
  next unless stage_tot[stage].positive?
  summary << "top #{opt[:top]} of #{stage} (#{stage_tot[stage]} samples):"
  counts.select { |(s, _, _), _| s == stage }.sort_by { |_, n| -n }.first(opt[:top]).each do |(_, obj, fn), n|
    summary << format("  %8d  %6.2f%% of all  %6.2f%% of %s  %s (%s)", n, 100.0 * n / taken, 100.0 * n / stage_tot[stage], stage, fn, obj)
  end
end
File.write(File.join(opt[:out], "summary.txt"), summary.join("\n") + "\n")
puts summary.first(4 + stage_tot.size)
puts "board-pcsample: #{taken} thread samples placed by function, #{File.join(opt[:out], 'functions.tsv')}"
