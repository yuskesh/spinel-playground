# E049 opt-in audit. The ordinary measure-union path remains independent.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'optparse'

module ConsumerSanitizers
  MODE='consumer-only-sanitizers'
  TARGET_MAIN='e04cfc15dd1a13848ca479d3f11495dce69a2619'
  def self.sha(path); Digest::SHA256.file(path).hexdigest; end
  def self.consumer_cases(accepted_ledger)
    rows=accepted_ledger.fetch('cases');total=accepted_ledger.fetch('total')
    abort 'audit requires complete pinned ledger' unless total==rows.size && rows.map { |r|r.fetch('id') }.uniq.size==total
    excluded=[]
    accepted=rows.reject do |row|
      pipeline=row.fetch('execution',{}).fetch('kind',nil)=='source_pipeline'
      missing=row.fetch('facts').nil?
      abort 'audit source pipeline/facts mismatch: '+row.fetch('id') unless pipeline==missing
      excluded << {id:row.fetch('id'),reason:'source_pipeline has no consumer facts'} if pipeline
      pipeline
    end
    [accepted,excluded]
  end
  def self.environment
    {'PATH'=>'/usr/bin:/bin','LC_ALL'=>'C',
     'ASAN_OPTIONS'=>'detect_leaks=1:symbolize=1:halt_on_error=1:abort_on_error=0:exitcode=86',
     'UBSAN_OPTIONS'=>'print_stacktrace=1:halt_on_error=1:exitcode=87',
     'ASAN_SYMBOLIZER_PATH'=>'/opt/llvm-23.1.1/bin/llvm-symbolizer',
     'LLVM_SYMBOLIZER_PATH'=>'/opt/llvm-23.1.1/bin/llvm-symbolizer'}
  end
  def self.classify(stderr)
    reports=[]
    stderr.lines.each do |line|
      if (m=line.match(/ERROR: (AddressSanitizer|LeakSanitizer): ([^\n]+)/))
        reports << {'family'=>m[1],'description'=>m[2].strip,'line'=>line.chomp}
      elsif line.include?('runtime error:')
        reports << {'family'=>'UndefinedBehaviorSanitizer','description'=>line.split('runtime error:',2)[1].strip,'line'=>line.chomp}
      elsif line.include?('AddressSanitizer:DEADLYSIGNAL')
        reports << {'family'=>'AddressSanitizer','description'=>'DEADLYSIGNAL','line'=>line.chomp}
      elsif line.match?(/(AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer):/) &&
          !line.start_with?('SUMMARY:')
        reports << {'family'=>'sanitizer-other','description'=>line.strip,'line'=>line.chomp}
      end
    end
    if reports.empty? && stderr.match?(/SUMMARY: (AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer):/)
      reports << {'family'=>'sanitizer-summary-only','description'=>stderr.lines.find { |l|l.start_with?('SUMMARY:') }.to_s.strip}
    end
    reports.uniq
  end
  def self.run(arguments)
    options={}
    parser=OptionParser.new do |p|
      p.on('--inspection') { options[:inspection]=true }
      p.on('--consumer-only') { options[:enabled]=true }
      p.on('--consumer PATH') { |v|options[:consumer]=File.expand_path(v) }
      p.on('--target-main REV') { |v|options[:target_main]=v }
      p.on('--audit-ledger PATH') { |v|options[:audit_ledger]=File.expand_path(v) }
    end
    positional=parser.parse(arguments.dup)
    abort 'usage: measure-union REPO PLAN WARNINGS FRESH_OUT --consumer-only --consumer PATH [--target-main REV] [--audit-ledger PATH]' unless options[:enabled] && options[:consumer] && positional.size==4
    repo,plan_path,_warnings,out=positional.map { |p|File.expand_path(p) }
    abort 'root forbidden' if Process.uid.zero?
    abort 'fresh output required' if File.exist?(out)
    abort 'consumer missing' unless File.executable?(options[:consumer])
    abort 'symbolizer missing' unless File.executable?(environment.fetch('ASAN_SYMBOLIZER_PATH'))
    target_main,target_status=Open3.capture2('git','-C',repo,'rev-parse','--verify','--end-of-options',"#{options.fetch(:target_main,TARGET_MAIN)}^{commit}")
    abort 'audit target commit missing' unless target_status.success?
    target_main=target_main.strip
    source_diff,diff_status=Open3.capture2('git','-C',repo,'diff',target_main,'--','lib','include','tools','CMakeLists.txt','cmake')
    abort 'audit target source changed' unless diff_status.success? && source_diff.empty?
    plan=JSON.parse(File.binread(plan_path))
    ledger_path=options.fetch(:audit_ledger,repo+'/docs/union/ledger.json')
    accepted_ledger=JSON.parse(File.binread(ledger_path))
    accepted,excluded=consumer_cases(accepted_ledger)
    expected_cases=accepted.size
    abort 'audit requires complete pinned ledger' unless
      plan.size==expected_cases && plan.map { |r|r.fetch('id') }.uniq.size==expected_cases &&
      plan.map { |r|r.fetch('id') }.sort==accepted.map { |r|r.fetch('id') }.sort
    records=accepted.to_h { |r|[r.fetch('id'),r] }
    plan.each { |r|abort 'facts hash: '+r.fetch('id') unless sha(r.fetch('facts'))==r.fetch('sha256') && records.fetch(r.fetch('id')).fetch('facts').fetch('sha256')==r.fetch('sha256') }
    FileUtils.mkdir_p(out+'/tools')
    pin=sha(options[:consumer]);FileUtils.cp(options[:consumer],out+'/tools/consumer');File.chmod(0755,out+'/tools/consumer')
    abort 'consumer changed' unless sha(out+'/tools/consumer')==pin && sha(options[:consumer])==pin
    FileUtils.cp(plan_path,out+'/plan.json')
    File.write(out+'/excluded.json',JSON.pretty_generate({ledger_total:accepted_ledger.fetch('total'),consumer_cases:expected_cases,cases:excluded})+"\n")
    tool_record={mode:MODE,target_main:target_main,consumer_sha256:pin,runner_sha256:sha(repo+'/scripts/measure-union.rb'),audit_module_sha256:sha(__FILE__),environment:environment,compatibility_comparison:false,compiler_execution:0,normalizer_execution:0}
    tool_record[:audit_ledger]={path:ledger_path,sha256:sha(ledger_path)} if options[:audit_ledger]
    tool_record[:inspection]=true if options[:inspection]
    File.write(out+'/tools.json',JSON.pretty_generate(tool_record)+"\n")
    ledger=[]
    plan.each do |input|
      id=input.fetch('id');record=records.fetch(id)
      dir=out+'/cases/'+id;FileUtils.mkdir_p(dir)
      argv=['/usr/bin/timeout','--kill-after=5s','60s',out+'/tools/consumer','--emit-dir',dir+'/artifacts',input.fetch('facts')]
      argv.insert(-2,'--inspect-dir',dir+'/inspection') if options[:inspection]
      start=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout,stderr,status=Open3.capture3(environment,*argv,unsetenv_others:true,rlimit_core:0)
      elapsed=((Process.clock_gettime(Process::CLOCK_MONOTONIC)-start)*1000).round
      File.binwrite(dir+'/consumer.stdout',stdout);File.binwrite(dir+'/consumer.stderr',stderr)
      row=input.merge('mode'=>MODE,'kind'=>record.fetch('kind'),'argv'=>argv,'rc'=>status.exitstatus,'signal'=>status.termsig,'elapsed_ms'=>elapsed,
          'timeout'=>[124,137].include?(status.exitstatus),'stdout_bytes'=>stdout.bytesize,'stderr_sha256'=>Digest::SHA256.hexdigest(stderr),
          'reports'=>classify(stderr),'first_stack_frame'=>stderr.lines.find { |line|line.match?(/^\s*#0\s/) }.to_s.chomp)
      ledger<<row
      # Preserve the actual process result before inspecting artifacts.
      File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
      artifacts=Dir[dir+'/artifacts/*']
      row['artifacts']=artifacts.to_h { |p|[File.basename(p),{bytes:File.size(p),sha256:sha(p)}] }
      expected=record.fetch('kind')=='positive' ? 0 : 1
      shape=expected==0 ? artifacts.size==3 && artifacts.all? { |p|File.size?(p) } : artifacts.empty?
      if options[:inspection]
        stem=File.basename(record.fetch('source'),'.rb')
        names=%w[mlir schema.json maps.json records.txt uprobe_targets.json].map { |k|stem+'.'+k }
        shape=expected==0 ? artifacts.map { |p|File.basename(p) }.sort==names.sort &&
          artifacts.all? { |p|File.basename(p).end_with?('.records.txt') ? File.file?(p) : File.size?(p) } : artifacts.empty?
        inspected=Dir[dir+'/inspection/*']
        row['inspection']=inspected.to_h { |p|[File.basename(p),{bytes:File.size(p),sha256:sha(p)}] }
        shape &&= inspected.map { |p|File.basename(p) }.sort==[stem+'.domain.json',stem+'.inspect-manifest.json'].sort && inspected.all? { |p|File.size?(p) }
        if shape
          begin
            manifest=JSON.parse(File.binread(dir+'/inspection/'+stem+'.inspect-manifest.json'))
            shape &&= manifest.fetch('version')==1 && manifest.dig('result','rc')==expected &&
              manifest.dig('source','sha256')==record.fetch('source_sha256') &&
              manifest.dig('facts','sha256')==input.fetch('sha256') &&
              manifest.fetch('outputs').all? { |_,r|File.file?(r.fetch('path')) && sha(r.fetch('path'))==r.fetch('sha256') }
          rescue JSON::ParserError,KeyError,SystemCallError => error
            row['inspection_error']=error.message
            shape=false
          end
        end
      end
      row['expected_rc']=expected
      row['unexpected_product_result']=status.exitstatus!=expected || status.termsig || !stdout.empty? || !shape
      File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    end
    findings=ledger.select { |r|!r.fetch('reports').empty? || r.fetch('unexpected_product_result') || r.fetch('timeout') }
    File.write(out+'/findings.json',JSON.pretty_generate(findings)+"\n")
    summary={mode:MODE,expected:expected_cases,executed:ledger.size,sanitizer_cases:ledger.count { |r|!r.fetch('reports').empty? },
        report_entries:ledger.sum { |r|r.fetch('reports').size },signals:ledger.count { |r|r['signal'] },timeouts:ledger.count { |r|r['timeout'] },
        unexpected_product_results:ledger.count { |r|r.fetch('unexpected_product_result') },finding_cases:findings.size,
        status:findings.empty? ? 'complete-no-findings' : 'complete-with-findings',compatibility_comparison:false}
    File.write(out+'/summary.json',JSON.pretty_generate(summary)+"\n")
    puts JSON.generate(summary)
    0
  rescue OptionParser::ParseError,JSON::ParserError,SystemCallError,KeyError => error
    warn 'sanitizer-audit-harness: '+error.message
    2
  end
end
