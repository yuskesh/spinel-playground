require 'json';require 'open3';require 'fileutils';require 'digest'
tool,fixture,out=ARGV;raise 'fresh' if File.exist?(out);FileUtils.mkdir_p(out)
good=JSON.parse(File.read(fixture));raise 'empty synthetic control absent' unless good['nodes'].any?{|n|n['file'].empty?&&n['span'].empty?}
rows=[]
[['synthetic-empty',->(j){} ,0],['source-empty',->(j){j['nodes'].find{|n|n['file']==j['file']}['span']=[]},2],['invalid-ref',->(j){j['nodes'][0]['refs']['bad']=9_999_999},2]].each do |name,change,expected|
  j=Marshal.load(Marshal.dump(good));change.call(j);p=out+'/'+name+'.json';File.write(p,JSON.generate(j)+"\n");o,e,s=Open3.capture3(tool,p);File.binwrite(out+'/'+name+'.stdout',o);File.binwrite(out+'/'+name+'.stderr',e);rows<<{name:name,rc:s.exitstatus,signal:s.termsig,binary_sha256:Digest::SHA256.file(tool).hexdigest,fixture_sha256:Digest::SHA256.file(p).hexdigest};File.write(out+'/ledger.json',JSON.pretty_generate(rows)+"\n");raise 'entry control failed '+name unless s.exitstatus==expected&&!s.termsig&&(expected==0 ? e.empty? : e.start_with?('typing-probe-calibration:'))
end
puts 'PASS synthetic-empty / source-empty rejection / invalid reference rejection'
