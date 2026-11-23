require 'json';require 'digest';require 'fileutils'
repo,source,out=ARGV;require repo+'/scripts/lib/oracle-projection'
abort 'fresh candidate control' if File.exist?(out);FileUtils.mkdir_p(out)
original=JSON.parse(File.binread(source+'/candidate.json'));selected=original.fetch('cases').first(3);ids=selected.map{|r|r.fetch('id')}
actual=OracleProjection.candidate(source,ids,out+'/actual')
abort 'candidate actual rows changed' unless actual==selected && JSON.parse(File.binread(out+'/actual/candidate.json'))==original.merge('cases'=>selected)
files=[]
selected.each do |r|
 from=source+'/'+r.fetch('dir');to=out+'/actual/'+r.fetch('dir')
 a=Dir[from+'/**/*'].select{|p|File.file?(p)}.to_h{|p|[p.delete_prefix(from+'/'),Digest::SHA256.file(p).hexdigest]}
 b=Dir[to+'/**/*'].select{|p|File.file?(p)}.to_h{|p|[p.delete_prefix(to+'/'),Digest::SHA256.file(p).hexdigest]}
 abort 'candidate raw bytes changed' unless a==b
 files.concat(a.keys)
end
controls=[]
{'empty'=>[],'duplicate'=>ids+[ids.first],'unknown'=>ids+['missing_candidate_id']}.each do |name,list|
 begin
  OracleProjection.candidate(source,list,out+'/'+name);abort 'control unexpectedly accepted'
 rescue RuntimeError => e
  abort 'failed control created output' if File.exist?(out+'/'+name)
  controls<<{'case'=>name,'error'=>e.message,'output_created'=>false}
 end
end
File.write(out+'/summary.json',JSON.pretty_generate({'reference_candidate_sha256'=>Digest::SHA256.file(source+'/candidate.json').hexdigest,'cases'=>3,'raw_files'=>files.size,'byte_differences'=>0,'result_fields_unchanged'=>true,'controls'=>controls,'consumer_runs'=>0,'Go_runs'=>0})+"\n")
puts File.binread(out+'/summary.json')
