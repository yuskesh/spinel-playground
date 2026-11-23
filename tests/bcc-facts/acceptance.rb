# tests/bcc-facts/acceptance.rb -- an oracle: the bcc tools' generated files,
# built here through spinel-mlir's consumer, against the ones spinel-bpf-mlir
# committed (its examples/bcc/artefacts.sha256: 224 files at v0.7.0, 280 at
# v0.8.0).
#
#   ALLOW_ORACLE=1 EBPF_OPT=PATH ruby tests/bcc-facts/acceptance.rb OURS REF OUT
#
# OURS is the examples/bcc directory of a tree the tools were built in
# (`spinelbpf build --seam-emit E --seam-inspect I`); REF is that release's
# examples/bcc, outside this checkout (git archive of the tag). Each REF file is
# first held to artefacts.sha256. EBPF_OPT is the ebpf-opt of the bpf-mlir the
# release pins. Each listed file is then:
#   same          byte for byte equal;
#   version-line  a .mlir equal once its second line, the producer's version
#                 comment (`// spinel-bpf-mlir v…`, in either file), is left out;
#   generic       a .mlir equal in ebpf-opt's generic form with locations
#                 (--mlir-print-op-generic --mlir-print-debuginfo
#                 --mlir-print-local-scope), once the locations the parser gives
#                 from the .mlir file itself are read as loc(unknown): the IR and
#                 its Ruby source locations agree, the text form does not;
#   ast           a .mlir that differs in that form too;
#   json-escape   a .json whose bytes differ and whose parsed values are equal;
#   json-value    a .json whose parsed values differ;
#   bytes         any other file that differs (an ELF, an embed, warnings);
#   missing       not built here.
# OUT/files.tsv has one row per file, OUT/summary.txt the counts. It runs only
# with ALLOW_ORACLE=1 (tests/ORACLES.tsv, section artefacts), on the owner's
# instruction: once at each acceptance.
#
# The owner's criterion (2026-10-27, docs/building.md "The acceptance"): every
# file but the .mlir is byte for byte the same, and each .mlir is same,
# version-line or generic. Exit 0 when it holds, 1 when it does not, 2 on a
# usage or reference error. The run of 2026-10-26 (v0.7.0) predates the generic
# class: it exited 1 with the 28 .mlir as `ast`, and their generic form was read
# from its outputs by hand.
#
#   ruby tests/bcc-facts/acceptance.rb --generic-check EBPF_OPT A.mlir B.mlir
# applies the generic comparison alone to two files (exit 0 equal, 1 not); it
# reads no reference and is not gated.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative '../../tools/oracle/gate'

# The generic form of one .mlir: nil when ebpf-opt cannot read it.
def generic_form(ebpf_opt, path)
  out, _err, st = Open3.capture3(ebpf_opt, '--mlir-print-op-generic', '--mlir-print-debuginfo',
                                 '--mlir-print-local-scope', path)
  return nil unless st.success?
  out.gsub(/loc\(#{Regexp.escape(path.inspect)}:\d+:\d+\)/, 'loc(unknown)')
end

def generic_equal?(ebpf_opt, a, b)
  ga = generic_form(ebpf_opt, a)
  gb = generic_form(ebpf_opt, b)
  !ga.nil? && ga == gb
end

if ARGV.first == '--generic-check'
  abort 'usage: ruby tests/bcc-facts/acceptance.rb --generic-check EBPF_OPT A.mlir B.mlir' unless ARGV.size == 4
  exit(generic_equal?(*ARGV[1..].map { |p| File.expand_path(p) }) ? 0 : 1)
end

exit 0 unless OracleGate.allow?("tests/bcc-facts/acceptance.rb", "artefacts")
ours, ref, out = ARGV.map { |p| File.expand_path(p) }
abort 'usage: ALLOW_ORACLE=1 EBPF_OPT=PATH ruby tests/bcc-facts/acceptance.rb OURS REF OUT' unless out
ebpf_opt = ENV.fetch('EBPF_OPT', '')
abort "EBPF_OPT #{ebpf_opt.inspect} is not an executable" unless File.executable?(ebpf_opt)
abort "OUT #{out} exists" if File.exist?(out)
list = File.join(ref, 'artefacts.sha256')
abort "no #{list}" unless File.file?(list)
rows = File.readlines(list).map(&:split).reject(&:empty?)
tools = Dir[File.join(ref, '*/')].count { |d| File.file?(File.join(d, "#{File.basename(d)}.rb")) }
unless rows.size == 8 * tools && rows.all? { |r| r.size == 2 }
  warn "acceptance: #{list} has #{rows.size} rows, not 8 for each of the #{tools} tools"
  exit 2
end
bad_ref = rows.reject { |h, p| File.file?(File.join(ref, p)) && Digest::SHA256.file(File.join(ref, p)).hexdigest == h }
unless bad_ref.empty?
  warn "acceptance: #{bad_ref.size} reference file(s) do not match artefacts.sha256: #{bad_ref.first(3).map(&:last).join(', ')}"
  exit 2
end

def drop_version(text)
  l = text.lines
  l.delete_at(1) if l[1]&.start_with?('// spinel-bpf-mlir v')
  l.join
end

FileUtils.mkdir_p(out)
result = rows.map do |_, p|
  mine = File.join(ours, p)
  theirs = File.join(ref, p)
  cls = if !File.file?(mine) then 'missing'
        elsif File.binread(mine) == File.binread(theirs) then 'same'
        elsif p.end_with?('.mlir')
          if drop_version(File.binread(mine)) == drop_version(File.binread(theirs)) then 'version-line'
          elsif generic_equal?(ebpf_opt, mine, theirs) then 'generic'
          else 'ast'
          end
        elsif p.end_with?('.json')
          (JSON.parse(File.read(mine)) rescue :bad) == (JSON.parse(File.read(theirs)) rescue :bad2) ? 'json-escape' : 'json-value'
        else 'bytes'
        end
  [p, cls]
end
File.write(File.join(out, 'files.tsv'), "#file\tclass\n" + result.map { |r| r.join("\t") + "\n" }.join)
by_class = result.map(&:last).tally
by_kind = result.group_by { |p, _| p[/(_embed\.[So]|\.[a-z_]+\.json|\.bpf\.o|\.compile_warnings\.txt|\.mlir)\z/] }
                .transform_values { |v| v.map(&:last).tally }
summary = "acceptance: #{result.size} files: #{by_class.sort.map { |k, v| "#{k} #{v}" }.join(', ')}\n" +
          by_kind.sort.map { |k, v| "  #{k}: #{v.sort.map { |c, n| "#{c} #{n}" }.join(', ')}\n" }.join
File.write(File.join(out, 'summary.txt'), summary)
puts summary
held = result.all? { |p, c| p.end_with?('.mlir') ? %w[same version-line generic].include?(c) : c == 'same' }
exit(held ? 0 : 1)
