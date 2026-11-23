# Compare saved LSan allocations, retaining every size/count/source identity.
require 'json';require 'open3'
module ProducerLeakSet
 module_function
 def added_lines(patch)
  file=nil;line=nil;result=Hash.new{|h,k|h[k]=[]}
  File.foreach(patch){|s|if s.start_with?('+++ b/');file=s.delete_prefix('+++ b/').strip;elsif (m=s.match(/^@@ .* \+(\d+)/));line=m[1].to_i;elsif line&&s.start_with?('+');result[file]<<line;line+=1;elsif line&&s.start_with?(' ');line+=1;elsif s.start_with?('--- ')||s.start_with?('\\');else;raise 'non-additive allocation line map' if line&&s.start_with?('-');end};result
 end
 def parse(text,root,added={})
  total=text.match(/SUMMARY: AddressSanitizer: (\d+) byte\(s\) leaked in (\d+) allocation\(s\)\./)
  allocations=text.scan(/(?:Direct|Indirect) leak of .*?(?=\n\n)/m).map do |block|
   header=block.match(/\A(Direct|Indirect) leak of (\d+) byte\(s\) in (\d+) object\(s\)/) or raise 'allocation header'
   frame=block.lines.find{|l|l.match?(/#1 .* in /)} or raise 'allocation first source'
   m=frame.match(/ in (.*?) (\/\S+)\s*$/) or raise 'source frame'
   function=m[1];location=m[2];pos=location.match(/\A(.+?):(\d+)(?::(\d+))?\z/);path=pos ? pos[1] : location;line=pos&&pos[2].to_i;col=pos&&pos[3]&.to_i
   raise 'allocation outside pinned source '+path unless path.start_with?(root+'/')
   file=path.delete_prefix(root+'/');inserted=added.fetch(file,[])
   if line
    file='M4-new:'+file if inserted.include?(line)
    line-=inserted.count{|i|i<line}
   end
   {kind:header[1],bytes:header[2].to_i,objects:header[3].to_i,source:{function:function,file:file,line:line,col:col}}
  end
  raise 'allocation summary missing' if !allocations.empty?&&!total
  if total
   raise 'allocation counts' unless allocations.sum{|r|r[:bytes]}==total[1].to_i&&allocations.sum{|r|r[:objects]}==total[2].to_i
  end
  {bytes:total ? total[1].to_i : 0,objects:total ? total[2].to_i : 0,allocations:allocations.sort_by{|r|JSON.generate(r)}}
 end
end
