# tools/bcc-facts/emit-facts.rb -- the spinel_facts v2 modules of the 35 bcc
# tools in tools/spinel-bpf-mlir/examples/bcc, from this repository's Spinel.
#
#   ruby tools/bcc-facts/emit-facts.rb [--spinel PATH] [--consumer PATH] OUT [TOOL...]
#   ruby tools/bcc-facts/emit-facts.rb --check FACTS ROOT...
#   ruby tools/bcc-facts/emit-facts.rb --check-seam TOOL E I FACTS
#
# For each tool (all 35 when none is named) it asks Spinel for the module with
# one --analysis-root per `BPF.<kind> :<name>` declaration in the source, in
# source order, and writes OUT/<tool>/facts.mlir. A tool that embeds a kernel
# struct (`BPF.kernel_type(..., m: [:struct, S])`, tcpretrans) also gets
# --emit-typing-probe: spinel-mlir's consumer (E079) refuses that tool without
# the module's spinel_facts.typing_probe, and Spinel adds it only on request. Spinel runs from
# tools/spinel-bpf-mlir with `-I ruby/lib`, so the module's paths are relative
# to that tree. OUT must be new.
#
# Each module is then held to the contract as spinel-mlir main 41e4f6c states it
# (docs/spinel_facts.md, its E076 section on analysis-only attributes of
# analyzed nodes). This repository's copy, third_party/spinel-mlir, is from
# 3accdcd and lacks that section; it is refreshed with the consumer's import.
#   - version 2, profile spinel-codegen-v2, status success;
#   - analysis_roots names the requested roots, in order, each with its
#     resolved def_node_id;
#   - spinel_facts.typing_probe (version 1, complete) is there exactly when
#     the probe was requested (Patch 3, E078);
#   - the analysis-only attributes (ANALYSIS_ONLY: integers.enum_copy) appear
#     only on analyzed nodes. A producer may add them there; a pristine node
#     that carries one is refused.
# --check applies the same rules to one module and its requested roots.
# --check-seam applies the seam rules below to one tool's E and I directories.
#
# With --consumer, spinel-mlir's consumer must also accept each module:
# `--verify-only`, then `--emit-dir E --inspect-dir I` (spinel-mlir E075),
# exiting 0 with the seam's outputs as E075 names them:
#   - E: <tool>.mlir, .schema.json and .maps.json non-empty, .records.txt
#     present (empty when the tool declares no record), .uprobe_targets.json
#     non-empty;
#   - I: <tool>.domain.json non-empty, and <tool>.inspect-manifest.json of
#     version 1 whose result is rc 0 with the domain produced, whose facts
#     sha256 is the module's, and whose six outputs name these files by path
#     and by their sha256.
# Nothing is compared with another implementation's output.
#
# OUT/summary.tsv has one row per tool. The exit status is 0 when every tool
# passes, 1 when one does not, 2 on a usage error.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'

# The tools' sources and the modules are UTF-8, and some sources hold
# non-ASCII text. Read them as UTF-8 whatever the locale says: under LC_ALL=C
# Ruby would read them as US-ASCII, and matching them would raise.
Encoding.default_external = Encoding::UTF_8

ROOT = File.expand_path('../..', __dir__)
TREE = File.join(ROOT, 'tools/spinel-bpf-mlir')
# The program kinds a bcc tool declares, and the context class Spinel's
# analysis root takes for each (the frontend's own table, cmd/spinelbpf).
CTX = { 'tracepoint' => 'TracepointCtx', 'kprobe' => 'KprobeCtx', 'kretprobe' => 'KretprobeCtx',
        'tp_btf' => 'TpBtfCtx', 'ksyscall' => 'KsyscallCtx', 'fentry' => 'FentryCtx', 'fexit' => 'FexitCtx',
        'raw_tp' => 'RawTpCtx', 'uprobe' => 'UprobeCtx', 'uretprobe' => 'UretprobeCtx', 'xdp' => 'XdpMd',
        'sched_cls' => 'SkBuff' }.freeze
ANALYSIS_ONLY = { 'integers' => ['enum_copy'] }.freeze

def usage(msg)
  warn "emit-facts: #{msg}"
  warn 'usage: ruby tools/bcc-facts/emit-facts.rb [--spinel PATH] [--consumer PATH] OUT [TOOL...]'
  warn '       ruby tools/bcc-facts/emit-facts.rb --check FACTS ROOT...'
  warn '       ruby tools/bcc-facts/emit-facts.rb --check-seam TOOL E I FACTS'
  exit 2
end

# Whether a tool's source embeds a kernel struct, as the consumer reads it.
def embeds_struct?(src)
  File.readlines(src).any? { |l| l.match?(/^BPF\.kernel_type\(.*\[:struct,/) }
end

# The roots a tool's source declares, as --analysis-root values.
def roots_of(src)
  File.readlines(src).filter_map do |l|
    m = l.match(/^BPF\.(\w+)\s+:([A-Za-z_]\w*)/) or next
    ctx = CTX[m[1]] or raise "#{src}: BPF.#{m[1]} has no analysis-root context here"
    "#{m[2]}:obj_BPF::#{ctx}"
  end
end

# The contract's rules for one module; answers the list of what breaks them.
def contract_errors(text, roots)
  errs = []
  head = text[/\Amodule attributes \{.*?\n/m] || ''
  { 'version' => '2 : i64', 'profile' => '"spinel-codegen-v2"', 'status' => '"success"' }.each do |k, v|
    errs << "spinel_facts.#{k} is not #{v}" unless head.include?("spinel_facts.#{k} = #{v}")
  end
  got = head.scan(/\{method = "([^"]+)", requested_arg_types = \["([^"]+)"\], def_node_id = (-?\d+) : i64/)
  want = roots.map { |r| r.split(':', 2) }
  if got.map { |m, t, _| [m, t] } != want
    errs << "analysis_roots are #{got.map { |m, t, _| "#{m}:#{t}" }.inspect}, requested #{roots.inspect}"
  end
  errs << 'an analysis root has no resolved def_node_id' if got.any? { |_, _, d| d.to_i.negative? }
  cut = text.index('}) {phase = "pristine"')
  if cut.nil? || !text.index('}) {phase = "analyzed"', cut)
    errs << 'the module has no pristine and analyzed tables'
  else
    ANALYSIS_ONLY.each do |dict, keys|
      keys.each do |k|
        text[0, cut].scan(/"spinel_facts\.node"\(\) \{id = (\d+) : i64[^\n]*?\b#{dict} = \{[^}]*"#{k}" = /) do |id|
          errs << "pristine node #{id[0]} carries the analysis-only #{dict}.#{k}"
        end
      end
    end
  end
  errs
end

# The seam's outputs for one tool (E075), as the header says.
def seam_errors(t, ed, id, facts)
  errs = []
  e = ->(x) { File.join(ed, "#{t}#{x}") }
  i = ->(x) { File.join(id, "#{t}#{x}") }
  %w[.mlir .schema.json .maps.json .uprobe_targets.json].each { |x| errs << "no non-empty E/#{t}#{x}" unless File.size?(e.(x)) }
  errs << "no E/#{t}.records.txt" unless File.file?(e.('.records.txt'))
  errs << "no non-empty I/#{t}.domain.json" unless File.size?(i.('.domain.json'))
  m = (JSON.parse(File.read(i.('.inspect-manifest.json'))) rescue nil)
  return errs << "no readable I/#{t}.inspect-manifest.json" unless m
  errs << "the manifest's version is #{m['version'].inspect}, not 1" unless m['version'] == 1
  errs << "the manifest's result is #{m['result'].inspect}" unless m['result'] == { 'rc' => 0, 'domain_produced' => true }
  errs << "the manifest's facts sha256 is not the module's" unless m.dig('facts', 'sha256') == Digest::SHA256.file(facts).hexdigest
  want = { 'mlir' => e.('.mlir'), 'schema' => e.('.schema.json'), 'maps' => e.('.maps.json'), 'domain' => i.('.domain.json'),
           'records' => e.('.records.txt'), 'uprobe_targets' => e.('.uprobe_targets.json') }
  errs << "the manifest's outputs are #{(m['outputs'] || {}).keys.sort.inspect}" unless (m['outputs'] || {}).keys.sort == want.keys.sort
  want.each do |k, p|
    o = m.dig('outputs', k) or next
    errs << "the manifest's #{k} is #{o['path']}, not #{p}" unless File.expand_path(o['path'].to_s) == p
    errs << "the manifest's #{k} sha256 is not the file's" unless File.file?(p) && o['sha256'] == Digest::SHA256.file(p).hexdigest
  end
  errs
end


if ARGV.first == '--check'
  usage('--check needs FACTS and its ROOTs') if ARGV.size < 3
  errs = contract_errors(File.read(ARGV[1]), ARGV[2..])
  errs.each { |e| puts "refused: #{ARGV[1]}: #{e}" }
  puts "ok: #{ARGV[1]}" if errs.empty?
  exit(errs.empty? ? 0 : 1)
end

if ARGV.first == '--check-seam'
  usage('--check-seam needs TOOL E I FACTS') unless ARGV.size == 5
  t, ed, id, facts = ARGV[1..]
  errs = seam_errors(t, File.expand_path(ed), File.expand_path(id), facts)
  errs.each { |e| puts "refused: #{t}: #{e}" }
  puts "ok: #{t}" if errs.empty?
  exit(errs.empty? ? 0 : 1)
end

spinel = File.join(ROOT, 'vendor/spinel/bin/spinel')
consumer = nil
while ARGV.first&.start_with?('--')
  case ARGV.shift
  when '--spinel' then spinel = File.expand_path(ARGV.shift || usage('--spinel needs a path'))
  when '--consumer' then consumer = File.expand_path(ARGV.shift || usage('--consumer needs a path'))
  else usage('unknown option')
  end
end
out = ARGV.shift or usage('OUT is required')
out = File.expand_path(out)
usage("OUT #{out} exists") if File.exist?(out)
usage("no spinel at #{spinel}") unless File.executable?(spinel)
usage("no consumer at #{consumer}") if consumer && !File.executable?(consumer)
all = Dir[File.join(TREE, 'examples/bcc/*/*.rb')].map { |p| File.basename(p, '.rb') }.sort
tools = ARGV.empty? ? all : ARGV
(tools - all).each { |t| usage("no bcc tool #{t}") }
FileUtils.mkdir_p(out)


def run(argv, dir, name, chdir)
  so, se, st = Open3.capture3({ 'LC_ALL' => 'C', 'TMPDIR' => File.join(dir, 'tmp') },
                              '/usr/bin/timeout', '--kill-after=5s', '120s', *argv, chdir: chdir)
  File.binwrite(File.join(dir, "#{name}.stdout"), so)
  File.binwrite(File.join(dir, "#{name}.stderr"), se)
  st.exitstatus
end

rows = tools.map do |t|
  rel = "examples/bcc/#{t}/#{t}.rb"
  roots = roots_of(File.join(TREE, rel))
  dir = File.join(out, t)
  FileUtils.mkdir_p(File.join(dir, 'tmp'))
  facts = File.join(dir, 'facts.mlir')
  probe = embeds_struct?(File.join(TREE, rel))
  rc = run([spinel, '-I', 'ruby/lib', "--emit-mlir=#{facts}", *roots.map { |r| "--analysis-root=#{r}" },
            *(probe ? ['--emit-typing-probe'] : []), rel], dir, 'spinel', TREE)
  row = { tool: t, roots: roots.size, rc: rc, bytes: File.size?(facts).to_i, sha256: '-', contract: '-', consumer: '-',
          probe: probe ? 'yes' : 'no' }
  problems = []
  problems << "spinel exited #{rc}" unless rc == 0
  problems << 'spinel wrote to stdout' unless File.size(File.join(dir, 'spinel.stdout')).zero?
  if row[:bytes] > 0
    row[:sha256] = Digest::SHA256.file(facts).hexdigest
    text = File.read(facts)
    errs = contract_errors(text, roots)
    has = text[/\A[^\n]*/].include?('spinel_facts.typing_probe = {version = 1 : i64, complete = true')
    errs << (probe ? 'the typing probe was requested and the module has no complete version 1 spinel_facts.typing_probe' :
                     'the module has a spinel_facts.typing_probe nobody requested') unless has == probe
    row[:contract] = errs.empty? ? 'ok' : 'refused'
    problems.concat(errs)
  else
    problems << 'no module'
  end
  if consumer && problems.empty?
    v = run([consumer, '--verify-only', facts], dir, 'verify', dir)
    ed = File.join(dir, 'E'); id = File.join(dir, 'I')
    e = run([consumer, '--emit-dir', ed, '--inspect-dir', id, facts], dir, 'emit', dir)
    seam = seam_errors(t, ed, id, facts)
    row[:consumer] = v == 0 && e == 0 && seam.empty? ? 'ok' : "verify #{v}, emit #{e}"
    problems << "the consumer refused it (#{row[:consumer]}; #{dir}/emit.stderr)" unless v == 0 && e == 0
    problems.concat(seam) if v == 0 && e == 0
  end
  puts "#{problems.empty? ? 'ok' : 'FAIL'} #{t}: #{row[:roots]} root(s), #{row[:bytes]} bytes" \
       "#{problems.empty? ? '' : ' -- ' + problems.join('; ')}"
  row.merge(ok: problems.empty?)
end
File.write(File.join(out, 'summary.tsv'),
           "#tool\troots\tspinel_rc\tbytes\tsha256\tcontract\tconsumer\tprobe\n" +
           rows.map { |r| r.values_at(:tool, :roots, :rc, :bytes, :sha256, :contract, :consumer, :probe).join("\t") + "\n" }.join)
bad = rows.count { |r| !r[:ok] }
puts "emit-facts: #{rows.size - bad} of #{rows.size} pass#{consumer ? ', the consumer included' : ''}"
exit(bad.zero? ? 0 : 1)
