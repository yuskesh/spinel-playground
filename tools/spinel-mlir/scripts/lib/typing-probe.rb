# Optional v2 analysis observations only. Never authenticates a lowering node/callee.
require 'json';require 'digest'
require_relative '../facts-inventory'
module TypingProbe
 module_function
 def read(path,required:false)
  header=nil;sources={}
  File.foreach(path) do |line|
   header=FactsAttrs.new(line.delete_prefix('module attributes ')).value if line.start_with?('module attributes ')
   if line.include?('"spinel_facts.source"() ')
    a=FactsAttrs.new(line.split('"spinel_facts.source"() ',2).last).value;raise 'probe-source-duplicate' if sources.key?(a.fetch('file_id'));sources[a.fetch('file_id')]=a
   end
  end
  raise 'probe-module-missing' unless header
  p=header['spinel_facts.typing_probe'];raise 'probe-metadata-required' if required&&!p;return nil unless p
  validate(header,sources,p)
 end
 def validate(header,sources,p)
  raise 'probe-metadata-shape' unless p.is_a?(Hash)
  required=%w[version complete producer_patch source_file_id source_sha256 analysis_roots before_json after_json before_stderr]
  raise 'probe-metadata-keys' unless p.keys.sort==required.sort
  raise 'probe-version-or-completeness' unless header.fetch('spinel_facts.version')==2&&p.fetch('version')==1&&p.fetch('complete')==true&&p.fetch('producer_patch')=='M4'
  raise 'probe-source-file' unless p.fetch('source_file_id').is_a?(Integer)&&sources.key?(p.fetch('source_file_id'))
  source=sources.fetch(p.fetch('source_file_id'));raise 'probe-source-hash' unless p.fetch('source_sha256').is_a?(String)&&p.fetch('source_sha256')==Digest::SHA256.hexdigest(source.fetch('text'))
  roots=header.fetch('spinel_facts.analysis_roots').map{|r|r.slice('method','requested_arg_types')};raise 'probe-roots-mismatch' unless !roots.empty?&&p.fetch('analysis_roots')==roots
  raise 'probe-before-stderr' unless p.fetch('before_stderr').is_a?(String)
  parsed={}
  %w[before after].each do |arm|
   text=p.fetch(arm+'_json');raise 'probe-json-string' unless text.is_a?(String)
   j=JSON.parse(text);raise 'probe-json-shape' unless j.is_a?(Hash)&&%w[types diagnostics codegen].all?{|key|j[key].is_a?(Array)}
   paths=sources.values.map{|v|v.fetch('path')}
   j.fetch('types').each do |r|
    raise 'probe-type-record' unless r.is_a?(Hash)&&%w[file kind type rbs].all?{|k|r[k].is_a?(String)}&&%w[line col].all?{|k|r[k].is_a?(Integer)}
    raise 'probe-type-source' unless paths.include?(r.fetch('file'))&&r.fetch('line')>0&&r.fetch('col')>=0
    ends=r.values_at('end_line','end_col');raise 'probe-type-end-span' unless ends.all?(&:nil?)||(ends.all?{|x|x.is_a?(Integer)}&&ends[0]>=r.fetch('line')&&ends[1]>=0)
    %w[name owner signature].each{|k|raise 'probe-type-text' if r.key?(k)&&!r[k].is_a?(String)}
    %w[singleton widened].each{|k|raise 'probe-type-flag' if r.key?(k)&&![true,false].include?(r[k])}
   end
   parsed[arm]=j
  end
  {header:header,sources:sources,metadata:p,observations:parsed}
 rescue JSON::ParserError=>e
  raise 'probe-json-invalid: '+e.message
 end
 def compare_before(actual,reference)
  raise 'probe-types-before-mismatch' unless actual.fetch('types')==reference.fetch('types')
  true
 end
end
