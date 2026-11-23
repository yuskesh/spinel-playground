require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'optparse'

# Real source entry point. No oracle, case ID, or expected diagnostic is read.
module SourcePipeline
  module_function
  def sha(path)
    Digest::SHA256.file(path).hexdigest
  end

  def run(argv)
    options = { roots: [] }
    parser = OptionParser.new do |p|
      p.banner = 'usage: compile-spinel --producer BIN --consumer BIN --library DIR --work-dir FRESH [--analysis-root NAME:TYPE] SOURCE'
      %w[producer consumer library work-dir].each { |key| p.on('--' + key + ' PATH') { |v| options[key.tr('-', '_').to_sym] = File.expand_path(v) } }
      %w[inspect-dir producer-metadata].each { |key| p.on('--' + key + ' PATH') { |v| options[key.tr('-', '_').to_sym] = File.expand_path(v) } }
      p.on('--analysis-root ROOT') { |v| options[:roots] << v }
    end
    parser.parse!(argv)
    raise 'one source is required' unless argv.size == 1
    %i[producer consumer library work_dir].each { |key| raise "missing #{key}" unless options[key] }
    source = File.expand_path(argv.first)
    raise 'source is not a file' unless File.file?(source)
    %i[producer consumer].each { |key| raise "#{key} is not executable" unless File.file?(options[key]) && File.executable?(options[key]) }
    raise 'library bpf.rb is missing' unless File.file?(options[:library] + '/bpf.rb')
    out = options[:work_dir]
    raise 'fresh work directory required' if File.exist?(out)
    library = Dir[options[:library] + '/**/*'].select { |p| File.file?(p) }.sort.to_h { |p| [p.delete_prefix(options[:library] + '/'), sha(p)] }
    record = { version: 1, kind: 'source_pipeline', source: source, source_sha256: sha(source),
               producer: options[:producer], producer_sha256: sha(options[:producer]),
               consumer_sha256: sha(options[:consumer]), library: options[:library], library_sha256: library,
               roots: options[:roots] }
    FileUtils.mkdir_p(out + '/tmp')
    base = File.basename(source)
    FileUtils.copy_file(source, out + '/' + base)
    persist = -> { File.write(out + '/execution.json', JSON.pretty_generate(record) + "\n") }
    capture = lambda do |stage, arguments|
      command = ['/usr/bin/timeout', '--kill-after=5s', '60s', options[:producer], '-I', options[:library], *arguments]
      stdout, stderr, status = Open3.capture3({ 'TMPDIR' => out + '/tmp' }, *command, chdir: out)
      File.binwrite(out + '/' + stage + '.stdout', stdout)
      File.binwrite(out + '/' + stage + '.stderr', stderr)
      record[stage] = { argv: command, cwd: out, rc: status.exitstatus, signal: status.termsig,
                        stdout_sha256: sha(out + '/' + stage + '.stdout'), stderr_sha256: sha(out + '/' + stage + '.stderr') }
      persist.call # Save the real result before checking or publishing artifacts.
      [stdout, stderr, status]
    end
    facts = out + '/facts.mlir'
    so, se, status = capture.call('m3', ['--emit-mlir=' + facts, *options[:roots].map { |r| '--analysis-root=' + r }, base])
    result = nil
    diagnostic = ''.b
    if status.success?
      raise 'M3 success requires nonempty facts and empty stdout' unless so.empty? && File.size?(facts)
      command = [options[:consumer], '--emit-dir', out + '/artifacts', facts]
      command.insert(-2, '--inspect-dir', options[:inspect_dir]) if options[:inspect_dir]
      co, ce, cs = Open3.capture3(*command)
      File.binwrite(out + '/consumer.stdout', co)
      File.binwrite(out + '/consumer.stderr', ce)
      record['consumer'] = { argv: command, rc: cs.exitstatus, signal: cs.termsig,
                             stdout_sha256: sha(out + '/consumer.stdout'), stderr_sha256: sha(out + '/consumer.stderr') }
      persist.call
      raise 'consumer signal or unexpected exit' unless !cs.termsig && (options[:inspect_dir] ? [0, 1, 3] : [0, 1]).include?(cs.exitstatus)
      $stdout.write(co)
      diagnostic = ce.b
      result = cs.exitstatus
    else
      # Only a real source loader failure can request the diagnostic-only probe.
      # An absent tool/library, crash, timeout, or unrelated parse error stays loud.
      loader = 'spinel: ' + base + ': cannot load such file -- '
      match = File.readlines(source).each_with_index.filter_map do |line, i|
        m = line.match(/^\s*(require_relative|load)\b/)
        m && [m[1], i + 1, m.begin(1) + 1]
      end.first
      raise 'M3 failed outside the supported loader diagnostic route' unless status.exitstatus == 1 && !status.termsig && match && se.lines.any? { |line| line.start_with?(loader) }
      raise 'M3 failure left facts' if File.exist?(facts)
      _po, pe, ps = capture.call('probe', ['--dump-ast', '--emit-types', base])
      raise 'loader diagnostic probe differs from M3 failure' unless ps.exitstatus == 1 && !ps.termsig && pe.b == se.b
      first_lines = pe.strip.split("\n").take(5).join(' | ')
      name, line, column = match
      diagnostic = "#{base}:#{line}:#{column}: rejected SB001 (UnsupportedConstruct): `#{name}` is not accepted in P001 (the program is one file plus `require \"bpf\"`); spinel: spinel --dump-ast failed: #{first_lines}\n".b
      result = 1
      if options[:inspect_dir]
        begin
          require_relative 'inspection-report'
          InspectionReport.source_failure(options,source,record,name,line,column,first_lines)
        rescue StandardError => error
          $stderr.write(diagnostic)
          $stderr.puts('source-pipeline: inspection failed: '+error.message)
          record['adapter']={rc:3,inspection_error:error.message}
          persist.call
          return 3
        end
      end
    end

    File.binwrite(out + '/adapter.stderr', diagnostic)
    record['adapter'] = { rc: result, stderr_sha256: sha(out + '/adapter.stderr') }
    persist.call
    $stderr.write(diagnostic)
    result
  rescue OptionParser::ParseError, RuntimeError, SystemCallError => e
    error = ('source-pipeline: ' + e.message + "\n").b
    if defined?(record) && record && defined?(persist) && persist
      File.binwrite(out + '/adapter.stderr', error)
      record['adapter'] = { rc: 2, stderr_sha256: sha(out + '/adapter.stderr') }
      persist.call
    end
    $stderr.write(error)
    2
  end
end
