require_relative '../../scripts/batch-compare'
require_relative '../../scripts/lib/byte-comparison'
id='derived_kernel-path_kpath_local';stem='kpath_local';origin='/capture/negative/'+id+'/'+stem+'.rb'
lines=BatchCompare.named_outputs(stem).map{|name|'spinelbpf: wrote '+File.dirname(origin)+'/'+name+"\n"}.join
warning="kpath_local.rb:3:1: conditional SB021 (Test): keep me\n"
raise 'origin named outputs' unless ByteComparison.equal?(BatchCompare.strip_named_wrote(lines+warning,id,stem,origin),warning)
raise 'default unchanged' unless ByteComparison.equal?(BatchCompare.strip_named_wrote(lines+warning,id,stem),lines+warning)
bad=[origin.sub(id,'another-id'),origin.sub(stem+'.rb','other.rb'),origin.sub('/negative/','/other/'),origin.sub('/capture/','/capture/../capture/')]
bad.each{|p|raise 'foreign origin stripped' unless ByteComparison.equal?(BatchCompare.strip_named_wrote(lines,id,stem,p),lines)}
extra='spinelbpf: wrote '+File.dirname(origin)+'/ninth-file.txt'+"\n"
raise 'extra line removed' unless ByteComparison.equal?(BatchCompare.strip_named_wrote(lines+extra,id,stem,origin),extra)
positive=lines.gsub('/negative/','/positive/')
raise 'default positive changed' unless BatchCompare.strip_named_wrote(positive+warning,id,stem)==warning
puts 'PASS exact original capture path / eight named files / warnings retained / default unchanged'
