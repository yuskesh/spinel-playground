require 'json';require 'digest';require 'fileutils'
repo,full,inventory,reference,out=ARGV
require repo+'/scripts/lib/oracle-projection'
abort 'fresh control' if File.exist?(out);FileUtils.mkdir_p(out)
ids=JSON.parse(File.binread(reference+'/manifest.json')).fetch('cases').map{|r|r.fetch('id')}
returned=OracleProjection.write(full,inventory,ids,'s5-argv',out+'/actual')
files=->(root){Dir[root+'/**/*'].select{|p|File.file?(p)}.to_h{|p|[p.delete_prefix(root+'/'),Digest::SHA256.file(p).hexdigest]}}
abort 'E071 existing projection bytes differ' unless files.call(reference)==files.call(out+'/actual')
control=[]
{'duplicate'=>ids+[ids.first],'unknown'=>ids+['unknown_projection_id'],'empty'=>[]}.each do |name,selected|
 begin
   OracleProjection.write(full,inventory,selected,'s5-argv',out+'/'+name)
   abort 'control accepted '+name
 rescue RuntimeError => e
   abort 'control wrote output '+name if File.exist?(out+'/'+name)
   control<<{'case'=>name,'error'=>e.message,'output_created'=>false}
 end
end
bad=JSON.parse(File.binread(inventory));bad.fetch('cases').first['source_sha256']='0'*64
File.write(out+'/bad-input.json',JSON.pretty_generate(bad)+"\n")
begin
 OracleProjection.write(full,out+'/bad-input.json',ids,'s5-argv',out+'/bad-source')
 abort 'source mismatch accepted'
rescue RuntimeError => e
 abort 'source mismatch wrote output' if File.exist?(out+'/bad-source')
 control<<{'case'=>'input-source-mismatch','error'=>e.message,'output_created'=>false}
end
File.write(out+'/summary.json',JSON.pretty_generate({'reference'=>reference,'cases'=>ids.size,'files'=>files.call(reference).size,'byte_differences'=>0,'returned_input_rows'=>returned.fetch('cases').size,'negative_controls'=>control,'Go_runs'=>0,'consumer_runs'=>0,'M3_runs'=>0})+"\n")
puts File.binread(out+'/summary.json')
