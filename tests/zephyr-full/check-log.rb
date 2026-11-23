# frozen_string_literal: true
#
# tests/zephyr-full/check-log.rb -- read one console capture of a board run
# (decision 0038) and compare the program's output with its hand-written
# expectation.
#
#   ruby tests/zephyr-full/check-log.rb LOG EXPECTED [STATUS]
#
# The program's output is every line after "ZFULL<TAB>MODE..." and before
# "ZFULL<TAB>GC..." (src/host.c prints both); carriage returns and NUL bytes
# from the serial line are dropped. It must equal EXPECTED byte for byte, and
# "ZFULL<TAB>EXIT<TAB>n" must carry STATUS (default 0). Prints the mode, the
# collection count and the status; a fault report is named when present.
# Exit 0 on a match, 1 otherwise, 64 on usage.

unless (2..3).cover?(ARGV.size)
  warn "usage: ruby check-log.rb LOG EXPECTED [STATUS]"
  exit 64
end
log, expected, status = ARGV
want_status = Integer(status || "0")
lines = File.binread(log).delete("\r\0").force_encoding("UTF-8").scrub.lines
mode_at = lines.index { |l| l.start_with?("ZFULL\tMODE") }
gc_at = lines.index { |l| l.start_with?("ZFULL\tGC") }
exit_line = lines.find { |l| l.start_with?("ZFULL\tEXIT\t") }
fault = lines.find { |l| l.include?("FAULT") }

problems = []
problems << "no ZFULL MODE line" unless mode_at
problems << "no ZFULL GC line after it" unless gc_at && mode_at && gc_at > mode_at
problems << "no ZFULL EXIT line" unless exit_line
problems << "a fault report: #{fault.strip}" if fault
got_status = exit_line && Integer(exit_line.split("\t")[2], exception: false)
problems << "exit status #{got_status.inspect}, expected #{want_status}" if exit_line && got_status != want_status
if mode_at && gc_at && gc_at > mode_at
  got = lines[(mode_at + 1)...gc_at].join
  want = File.read(expected)
  unless got == want
    gl = got.lines
    wl = want.lines
    i = (0...[gl.size, wl.size].max).find { |k| gl[k] != wl[k] }
    problems << "output differs at line #{i + 1}: got #{gl[i].inspect}, expected #{wl[i].inspect}"
  end
end

mode = mode_at ? lines[mode_at].strip.split("\t")[2] : "?"
gc = gc_at ? lines[gc_at].strip.split("\t")[2] : "?"
summary = "mode #{mode}, gc #{gc}, exit #{got_status.inspect}"
if problems.empty?
  puts "MATCH  #{File.basename(log)}: #{summary}"
  exit 0
end
puts "DIFFER #{File.basename(log)}: #{summary}"
problems.each { |p| puts "  #{p}" }
exit 1
