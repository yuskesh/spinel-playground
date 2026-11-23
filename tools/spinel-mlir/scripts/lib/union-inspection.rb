# E077 opt-in collection only. Legacy union capture never loads this module.
require 'json';require 'digest'
module UnionInspection
  module_function
  def verify(run,record,input,rc)
    stem=File.basename(record.fetch('source'),'.rb');inspect=run+'/inspection';emit=run+'/artifacts'
    expected=[stem+'.domain.json',stem+'.inspect-manifest.json']
    raise 'inspection file set' unless Dir[inspect+'/*'].select{|p|File.file?(p)}.map{|p|File.basename(p)}.sort==expected.sort
    path=inspect+'/'+stem+'.inspect-manifest.json';m=JSON.parse(File.binread(path))
    raise 'inspection manifest result/source' unless m.fetch('version')==1&&m.dig('result','rc')==rc&&m.dig('result','domain_produced')==true&&!m.fetch('result').key?('failure_stage')&&m.dig('source','sha256')==record.fetch('source_sha256')
    if input.dig('execution','kind')=='source_pipeline'
      raise 'inspection source pipeline provenance' unless m['facts'].nil?&&m.fetch('execution')=='source_pipeline'&&m.dig('pins','spinel','producer_source')=='metadata'
    else
      raise 'inspection facts provenance' unless m.dig('facts','sha256')==input.fetch('sha256')&&m.fetch('execution')=='consumer'&&m.dig('pins','spinel','producer_source')=='facts'
    end
    names={'mlir'=>'mlir','schema'=>'schema.json','maps'=>'maps.json','records'=>'records.txt','uprobe_targets'=>'uprobe_targets.json','domain'=>'domain.json'}
    wanted=rc==0 ? names.keys : ['domain'];raise 'inspection output set' unless m.fetch('outputs').keys.sort==wanted.sort
    m.fetch('outputs').each do |key,value|
      file=(key=='domain' ? inspect : emit)+'/'+stem+'.'+names.fetch(key)
      raise 'inspection output path/hash '+key unless value.fetch('path')==file&&File.file?(file)&&Digest::SHA256.file(file).hexdigest==value.fetch('sha256')
    end
    {dir:inspect,files:Dir[inspect+'/*'].sort.to_h{|p|[File.basename(p),{bytes:File.size(p),sha256:Digest::SHA256.file(p).hexdigest}]}}
  end
end
