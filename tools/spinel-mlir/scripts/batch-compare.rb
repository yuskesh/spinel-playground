#!/usr/bin/env ruby
# E009: a partial candidate is never a complete success.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'optparse'

class BatchCompare
  PIN='41b188568cb36a15d4c185d5f72027267b3fa544'
  STATES=%w[matched different error unsupported].freeze
  class Invalid < StandardError; end
  # E024: the Go oracle's positive build.stderr names its own outputs as
  # `spinelbpf: wrote <capture>/positive/<id>/<file>` (E003's reproduction
  # handled only this output prefix). Only these eight named lines are removed,
  # from the oracle side only; every other line is compared byte for byte.
  def self.named_outputs(stem)
    %W[#{stem}.domain.json #{stem}.mlir #{stem}.schema.json #{stem}.maps.json
       #{stem}.compile_warnings.txt #{stem}.bpf.o #{stem}_embed.S #{stem}_embed.o]
  end
  def self.strip_named_wrote(text, id, stem, source_path = nil)
    names = named_outputs(stem)
    # Observed derived cases can succeed in their originally negative capture.
    # Preserve raw stderr; only its actual argv's exact eight outputs qualify.
    original = if source_path.is_a?(String) && source_path.start_with?('/') &&
        File.expand_path(source_path) == source_path &&
        File.basename(source_path) == stem+'.rb' &&
        File.dirname(source_path).end_with?('/negative/'+id)
      File.dirname(source_path)
    end
    text.lines.reject do |line|
      line.start_with?('spinelbpf: wrote /') &&
        names.any? { |n| line.end_with?("/positive/#{id}/#{n}\n") || (original && line == "spinelbpf: wrote #{original}/#{n}\n") }
    end.join
  end
  def self.tsv_row(values)
    escapes={"\t"=>'\\t',"\r"=>'\\r',"\n"=>'\\n',"\\"=>'\\\\'}
    values.map{|v|v.to_s.gsub(/[\t\r\n\\]/){|char|escapes.fetch(char)}}.join("\t")
  end
  def initialize(options)
    @o=options;@rows=[];@commands=0;@metadata={}
  end
  def sha(path); Digest::SHA256.file(path).hexdigest; end
  def read_json(path); JSON.parse(File.binread(path)); end
  def invalid(message); raise Invalid,message; end
  def data(path,empty:false)
    invalid("missing-file: #{path}") unless File.file?(path)
    value=File.binread(path)
    invalid("empty-file: #{path}") if !empty && value.empty?
    value
  end
  def directory(root,relative)
    invalid('invalid-case-directory') unless relative.is_a?(String)
    path=File.expand_path(relative,root)
    invalid('case-directory-outside-candidate') unless path.start_with?(root+'/')
    invalid("missing-case-directory: #{relative}") unless File.directory?(path)
    invalid('case-directory-symlink-escape') unless File.realpath(path).start_with?(File.realpath(root)+'/')
    path
  end
  def execute(tag,*argv,chdir:nil)
    prefix="#{@o['report']}/commands/#{format('%05d',@commands)}-#{tag}"
    @commands+=1
    begin
      stdout,stderr,status=Open3.capture3(*argv,**(chdir ? {chdir:chdir} : {}))
      record={'argv'=>argv,'cwd'=>chdir,'rc'=>status.exitstatus,'signal'=>status.termsig}
    rescue SystemCallError => error
      stdout='';stderr=error.message;record={'argv'=>argv,'cwd'=>chdir,'rc'=>nil,'spawn_error'=>error.message}
    end
    File.binwrite(prefix+'.stdout',stdout);File.binwrite(prefix+'.stderr',stderr)
    record['stdout_bytes']=stdout.bytesize;record['stderr_bytes']=stderr.bytesize
    File.write(prefix+'.json',JSON.pretty_generate(record)+"\n")
    [stdout,stderr,record]
  end
  def byte_check(name,left,right,row,empty:false)
    a=data(left,empty:empty);b=data(right,empty:empty)
    check={'name'=>name,'same'=>a==b,'left_bytes'=>a.bytesize,'right_bytes'=>b.bytesize,
           'left_sha256'=>Digest::SHA256.hexdigest(a),'right_sha256'=>Digest::SHA256.hexdigest(b)}
    row['checks']<<check
    check['same']
  end
  def normalize(path,side,row)
    out,err,record=execute("normalize-#{side}",@o['normalizer'],path)
    row['normalizer']||={};row['normalizer'][side]=record
    invalid("normalizer-#{side}-failed: rc=#{record['rc']} #{err}") unless record['rc']==0
    invalid("normalizer-#{side}-empty") if out.empty?
    out
  end
  def compile(dir,stem,mode,side,row)
    out="#{dir}/#{side}.#{mode}.bpf.o"
    _stdout,err,record=execute("compile-#{side}-#{mode}",@o['compiler'],"#{stem}.mlir",'--schema',"#{stem}.schema.json","--line-info=#{mode}",'-o',out,chdir:dir)
    row['compiler']||={};row['compiler']["#{side}-#{mode}"]=record
    invalid("compile-#{side}-#{mode}-failed: rc=#{record['rc']} #{err}") unless record['rc']==0
    data(out)
    out
  end
  def prepare_work(source,stem,label,id)
    dir="#{@o['report']}/elf/#{id}/#{label}";FileUtils.mkdir_p(dir)
    %w[mlir schema.json].each{|ext|File.binwrite("#{dir}/#{stem}.#{ext}",data("#{source}/#{stem}.#{ext}"))}
    dir
  end
  def positive(oracle,candidate,ac,bc,row)
    if bc['producer_rc']!=0
      row['status']='different';row['reasons']<<'producer-failed';return
    end
    invalid('oracle-positive-build-rc') unless Integer(data("#{oracle}/build.rc"))==0
    stem=File.basename(ac.fetch('source'),'.rb')
    data("#{oracle}/#{stem}.mlir");data("#{candidate}/#{stem}.mlir")
    schema=byte_check('schema',"#{oracle}/#{stem}.schema.json","#{candidate}/#{stem}.schema.json",row)
    maps=byte_check('maps',"#{oracle}/#{stem}.maps.json","#{candidate}/#{stem}.maps.json",row)
    # E024: the warnings a positive prints (SB013 / SB021 …), with only the
    # oracle's eight named output lines removed. A difference does not stop
    # the ELF comparison; it is one more named reason.
    source_argv=ac['argv']; source_path=source_argv.is_a?(Array) && source_argv.size==3 && source_argv[1]=='build' ? source_argv[2] : nil
    expected=BatchCompare.strip_named_wrote(data("#{oracle}/build.stderr"),ac.fetch('id'),stem,source_path)
    actual=data("#{candidate}/build.stderr",empty:true)
    row['checks']<<{'name'=>'warnings','same'=>expected.b==actual.b,'left_bytes'=>expected.bytesize,'right_bytes'=>actual.bytesize,
                    'left_sha256'=>Digest::SHA256.hexdigest(expected),'right_sha256'=>Digest::SHA256.hexdigest(actual)}
    left=normalize("#{oracle}/#{stem}.mlir",'oracle',row)
    right=normalize("#{candidate}/#{stem}.mlir",'candidate',row)
    structure=left==right
    row['checks']<<{'name'=>'structure','same'=>structure,'left_bytes'=>left.bytesize,'right_bytes'=>right.bytesize,'left_sha256'=>Digest::SHA256.hexdigest(left),'right_sha256'=>Digest::SHA256.hexdigest(right)}
    unless schema && maps && structure
      row['status']='different';row['reasons']=row['checks'].reject{|c|c['same']}.map{|c|c['name']}
      row['elf_skipped']='upstream-difference';return
    end
    cd=prepare_work(candidate,stem,'candidate',ac['id'])
    od=prepare_work(oracle,stem,'oracle',ac['id']) if @metadata['elf_arm']=='recompiled-Go-ELF'
    %w[auto off].each do |mode|
      produced=compile(cd,stem,mode,'candidate',row)
      if @metadata['elf_arm']=='saved-ELF'
        invalid('oracle-saved-elf-rc') unless Integer(data("#{oracle}/#{mode}.rc"))==0
        reference="#{oracle}/#{stem}.#{mode}.bpf.o"
        row['compiler']||={};row['compiler']["oracle-#{mode}"]={'rc'=>0,'saved'=>true,'bytes'=>data(reference).bytesize}
      else
        reference=compile(od,stem,mode,'oracle',row)
      end
      byte_check("elf-#{mode}",reference,produced,row)
    end
    row['reasons']=row['checks'].reject{|c|c['same']}.map{|c|c['name']}
    row['status']=row['reasons'].empty? ? 'matched' : 'different'
  end
  def negative(oracle,candidate,_ac,bc,row)
    if bc['producer_rc']==0
      row['status']='different';row['reasons']<<'negative-producer-succeeded';return
    end
    invalid('negative-producer-signal-or-invalid-rc') unless bc['producer_rc'].is_a?(Integer) && bc['producer_rc']>0
    invalid('oracle-negative-rc') unless Integer(data("#{oracle}/build.rc"))>0
    artifacts=Dir["#{candidate}/**/*"].select{|p|File.file?(p)&&p.match?(/(?:\.mlir|\.schema\.json|\.maps\.json|\.bpf\.o)\z/)}
    unless artifacts.empty?
      row['status']='different';row['reasons']<<'negative-success-artifact';return
    end
    byte_check('diagnostic',"#{oracle}/build.stderr","#{candidate}/build.stderr",row)
    byte_check('negative-stdout',"#{oracle}/build.stdout","#{candidate}/build.stdout",row,empty:true)
    row['reasons']=row['checks'].reject{|c|c['same']}.map{|c|c['name']}
    row['status']=row['reasons'].empty? ? 'matched' : 'different'
  end
  def run
    invalid('root-forbidden') if Process.uid.zero?
    invalid('report-exists') if File.exist?(@o['report'])
    FileUtils.mkdir_p("#{@o['report']}/commands")
    @created=true
    oracle=read_json("#{@o['oracle']}/manifest.json")
    inventory=read_json("#{@o['oracle']}/sha256.json")
    inventory.each{|rel,expected|invalid("oracle-hash: #{rel}") unless sha("#{@o['oracle']}/#{rel}")==expected}
    files=Dir["#{@o['oracle']}/**/*"].select{|p|File.file?(p)}.map{|p|p.delete_prefix(@o['oracle']+'/')}-['sha256.json']
    invalid('oracle-inventory-mismatch') unless files.sort==inventory.keys.sort
    known=oracle.fetch('cases')
    if @o['corpus-contract']
      require_relative 'lib/corpus-contract'
      CorpusContract.verify(@o['corpus-contract'],"#{@o['oracle']}/manifest.json",known)
    else
      invalid('oracle-case-count') unless known.count{|c|c['kind']=='positive'}==105 && known.count{|c|c['kind']=='negative'}==504
    end
    invalid('oracle-duplicate-ID') unless known.map{|c|c['id']}.uniq.size==known.size
    groups={}
    data(@o['groups']).each_line do |line|
      m=line.match(/^\|([A-H])\|`([^`]+)`\|/);next unless m
      invalid("group-duplicate: #{m[2]}") if groups.key?(m[2])
      groups[m[2]]=m[1]
    end
    invalid('group-coverage-mismatch') unless groups.keys.sort==known.select{|c|c['kind']=='positive'}.map{|c|c['source']}.sort
    candidate=read_json("#{@o['candidate']}/candidate.json")
    invalid('candidate-version-1: v2 is required (positive build.stderr warnings are compared — E024)') if candidate['version']==1
    invalid('candidate-version') unless candidate['version']==2 && candidate['cases'].is_a?(Array)
    supplied={}
    candidate['cases'].each do |c|
      invalid('candidate-case-shape') unless c.is_a?(Hash) && c['id'].is_a?(String) && c['producer_rc'].is_a?(Integer)
      invalid('candidate-duplicate-ID') if supplied.key?(c['id'])
      supplied[c['id']]=c
    end
    invalid('candidate-unknown-ID') unless (supplied.keys-known.map{|c|c['id']}).empty?
    out,err,version=execute('compiler-version',@o['compiler'],'--version')
    invalid('compiler-version-or-pin') unless version['rc']==0 && (out+err).include?("commit #{PIN}")
    invalid('normalizer-not-executable') unless File.executable?(@o['normalizer'])
    hash=sha(@o['compiler'])
    @metadata={'compiler_sha256'=>hash,'compiler_version'=>out+err,'normalizer_sha256'=>sha(@o['normalizer']),
      'elf_arm'=>hash==oracle.fetch('tools').fetch('ebpf-compile').fetch('sha256') ? 'saved-ELF' : 'recompiled-Go-ELF',
      'group_table_sha256'=>sha(@o['groups']),'oracle_manifest_sha256'=>sha("#{@o['oracle']}/manifest.json"),
      'candidate_manifest_sha256'=>sha("#{@o['candidate']}/candidate.json")}
    File.binwrite("#{@o['report']}/groups-source.md",data(@o['groups']))
    known.each do |ac|
      row={'id'=>ac['id'],'kind'=>ac['kind'],'group'=>ac['kind']=='positive' ? groups.fetch(ac['source']) : 'negative','source'=>ac['source'],'status'=>'unsupported','reasons'=>['candidate-not-emitted'],'checks'=>[]}
      @rows<<row
      next unless (bc=supplied[ac['id']])
      row['producer_rc']=bc['producer_rc'];row['reasons']=[]
      begin
        invalid('candidate-source-or-hash-mismatch') unless %w[source source_sha256].all?{|key|ac[key]==bc[key]}
        ad=directory(@o['oracle'],ac.fetch('raw_dir'))
        cd=directory(@o['candidate'],bc['dir'])
        row['oracle_producer_rc']=Integer(data("#{ad}/build.rc"))
        ac['kind']=='positive' ? positive(ad,cd,ac,bc,row) : negative(ad,cd,ac,bc,row)
      rescue Invalid, SystemCallError, ArgumentError => error
        row['status']='error';row['reasons']<<error.message
      end
    end
    counts=STATES.to_h{|state|[state,@rows.count{|r|r['status']==state}]}
    code=counts['error']>0 ? 2 : counts['different']>0 ? 1 : counts['unsupported']>0 ? 3 : 0
    save(code)
    code
  rescue Invalid, JSON::ParserError, SystemCallError, KeyError, RuntimeError => error
    @metadata['global_error']=error.message
    save(2) if @created
    warn "batch-invalid: #{error.message}"
    2
  end
  def save(code)
    totals=STATES.to_h{|state|[state,@rows.count{|r|r['status']==state}]}
    groups=@rows.group_by{|r|r['group']}.transform_values{|rows|STATES.to_h{|s|[s,rows.count{|r|r['status']==s}]}}
    summary=@metadata.merge('exit'=>code,'total'=>totals,'groups'=>groups,'command_count'=>@commands)
    File.write("#{@o['report']}/summary.json",JSON.pretty_generate(summary)+"\n")
    File.write("#{@o['report']}/cases.json",JSON.pretty_generate(@rows)+"\n")
    File.write("#{@o['report']}/cases.tsv",([%w[group id status reasons].join("\t")]+@rows.map{|r|self.class.tsv_row([r['group'],r['id'],r['status'],r['reasons'].join(';')])}).join("\n")+"\n")
    File.write("#{@o['report']}/groups.tsv",([['group']+STATES]+groups.sort.map{|g,c|[g]+STATES.map{|s|c[s]}}+[['total']+STATES.map{|s|totals[s]}]).map{|r|r.join("\t")}.join("\n")+"\n")
    puts "batch exit=#{code} arm=#{@metadata['elf_arm']} #{totals.map{|k,v|"#{k}=#{v}"}.join(' ')}"
  end
end

if $PROGRAM_NAME==__FILE__
  options={}
  parser=OptionParser.new do |p|
    %w[oracle candidate groups compiler normalizer report corpus-contract].each{|name|p.on("--#{name} PATH"){|v|options[name]=File.expand_path(v)}}
  end
  begin
    parser.parse!
    unless (options.keys-%w[corpus-contract]).size==6 && ARGV.empty?
      warn parser.to_s;exit 2
    end
    exit BatchCompare.new(options).run
  rescue OptionParser::ParseError => error
    warn error.message;exit 2
  end
end
