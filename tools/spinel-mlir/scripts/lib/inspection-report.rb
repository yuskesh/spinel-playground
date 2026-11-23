require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Diagnostic-only source-loader report. It receives the existing adapter's real
# failure, never a case ID, oracle file, or fabricated facts module.
module InspectionReport
  module_function
  def encode(value, indent=0)
    pad=' '*indent
    child=' '*(indent+2)
    case value
    when Hash
      return '{}' if value.empty?
      "{\n"+value.map { |key,v| child+JSON.generate(key)+': '+encode(v,indent+2) }.join(",\n")+"\n"+pad+'}'
    when Array
      return '[]' if value.empty?
      "[\n"+value.map { |v|child+encode(v,indent+2) }.join(",\n")+"\n"+pad+']'
    else JSON.generate(value)
    end
  end
  def go_json(value)
    encode(value).gsub('<','\\u003c').gsub('>','\\u003e').gsub('&','\\u0026')
      .gsub("\u2028",'\\u2028').gsub("\u2029",'\\u2029')+"\n"
  end
  def source_failure(options, source, record, name, line, column, first_lines)
    directory=options.fetch(:inspect_dir)
    raise 'inspection directory already exists' if File.exist?(directory)
    metadata_path=options.fetch(:producer_metadata){raise 'inspection source failure requires --producer-metadata'}
    metadata=JSON.parse(File.binread(metadata_path))
    raise 'producer metadata version' unless metadata.fetch('version')==1
    raise 'producer metadata commit' unless metadata.fetch('commit').match?(/\A[0-9a-f]{40}\z/)
    raise 'producer metadata revision' unless metadata.fetch('producer_revision').split('+').first==metadata.fetch('commit')
    raise 'producer metadata binary hash' unless metadata.fetch('binary_sha256')==Digest::SHA256.file(options.fetch(:producer)).hexdigest
    stdout,stderr,status=Open3.capture3(options.fetch(:consumer),'--build-info')
    raise 'consumer build-info failed' unless status.success? && stderr.empty?
    info=JSON.parse(stdout)
    raise 'consumer build-info version' unless info.fetch('version')==1
    pins=info.fetch('pins')
    pins['spinel']=metadata.slice('commit','producer_revision','binary_sha256').merge('producer_source'=>'metadata')
    %w[consumer bpf_mlir].each { |k| raise 'build-info pin' unless pins.fetch(k).fetch('commit').match?(/\A[0-9a-f]{40}\z/) }
    base=File.basename(source);stem=File.basename(source,'.rb')
    raise 'inspection source stem' if stem.empty? || stem==base
    message="`#{name}` is not accepted in P001 (the program is one file plus `require \"bpf\"`); spinel: spinel --dump-ast failed: #{first_lines}"
    domain={'source'=>base,'roots'=>[],'functions'=>[],'edges'=>[],
      'diagnostics'=>[{'verdict'=>'rejected','code'=>'SB001','name'=>'UnsupportedConstruct',
        'pos'=>{'file'=>base,'line'=>line,'col'=>column},'message'=>message}]}
    bytes=go_json(domain)
    manifest={'version'=>1,'source'=>{'path'=>source,'sha256'=>Digest::SHA256.file(source).hexdigest},
      'facts'=>nil,'execution'=>'source_pipeline','pins'=>pins,
      'result'=>{'rc'=>1,'domain_produced'=>true},
      'outputs'=>{'domain'=>{'path'=>File.join(directory,stem+'.domain.json'),'sha256'=>Digest::SHA256.hexdigest(bytes)}}}
    temp=Dir.mktmpdir(File.basename(directory)+'.tmp',File.dirname(directory))
    begin
      File.binwrite(File.join(temp,stem+'.domain.json'),bytes)
      File.binwrite(File.join(temp,stem+'.inspect-manifest.json'),JSON.pretty_generate(manifest)+"\n")
      File.rename(temp,directory)
    ensure
      FileUtils.remove_entry(temp) if File.exist?(temp)
    end
    record['producer_metadata']={'path'=>metadata_path,'sha256'=>Digest::SHA256.file(metadata_path).hexdigest}
  end
end
