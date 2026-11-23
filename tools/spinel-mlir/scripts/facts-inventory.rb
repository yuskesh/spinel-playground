# Canonical M1/M2 generic-attribute reader; refuses unrecognized input.
require 'strscan'
require 'json'
class FactsAttrs
  def initialize(text); @s=StringScanner.new(text); end
  def ws; @s.skip(/\s*/); end
  def take(text); ws; raise "expected #{text} at #{@s.peek(60)}" unless @s.scan(Regexp.new(Regexp.escape(text))); end
  def string
    ws
    raw=@s.scan(/"(?:[^"\\]|\\[0-9A-Fa-f]{2})*"/) or raise 'bad MLIR string'
    raw[1...-1].gsub(/\\([0-9A-Fa-f]{2})/){[$1.to_i(16)].pack('C')}.force_encoding(Encoding::UTF_8)
  end
  def value
    ws
    case @s.peek(1)
    when '"'; string
    when '{'
      take('{'); out={}; ws
      until @s.peek(1)=='}'
        ws
        key=@s.peek(1)=='"' ? string : @s.scan(/[A-Za-z_][\w.]*/)
        raise 'missing/duplicate key' if !key || out.key?(key)
        take('='); out[key]=value; ws
        break if @s.peek(1)=='}'
        take(',')
      end
      take('}'); out
    when '['
      take('['); out=[]; ws
      until @s.peek(1)==']'
        out<<value; ws; break if @s.peek(1)==']'; take(',')
      end
      take(']'); out
    else
      if n=@s.scan(/-?\d+/)
        ws; @s.scan(/:\s*i\d+/); n.to_i
      elsif b=@s.scan(/true|false/); b=='true'
      elsif t=@s.scan(/![A-Za-z_][\w.]*/); t
      else; raise "unknown attribute #{@s.peek(60)}"
      end
    end
  end
end
module FactsInventory
  def self.read(path)
    header=nil; nodes={}; types=Hash.new{|h,k|h[k]=[]}; evidence=Hash.new{|h,k|h[k]=[]}
    tables={}; table=nil; diagnostics=[]; sources={}; splices=[]
    File.foreach(path) do |line|
      if line.start_with?('module attributes ')
        header=FactsAttrs.new(line.delete_prefix('module attributes ')).value
      elsif line.include?('"spinel_facts.table"() ({')
        raise 'nested table' if table; table={}
      elsif line.include?('}) {phase = ')
        phase=line[/phase = "([^"]+)"/,1] or raise 'missing phase'
        raise 'duplicate/missing table' if !table || tables.key?(phase)
        tables[phase]=table; table=nil
      elsif line =~ /"spinel_facts\.(node|type|evidence|diagnostic)"\(\) (\{.*)/
        kind=$1; attrs=FactsAttrs.new($2).value
        if kind=='node'
          raise 'node outside table or duplicate' if !table || table.key?(attrs.fetch('id'))
          table[attrs.fetch('id')]=attrs
        elsif kind=='type'; types[attrs.fetch('node_id')]<<attrs
        elsif kind=='evidence'; evidence[attrs.fetch('node_id')]<<attrs
        else; diagnostics<<attrs
        end
      elsif line =~ /"spinel_facts.source"\(\) (\{.*)/
        attrs=FactsAttrs.new($1).value
        sources[attrs.fetch('file_id')]=attrs
      elsif line =~ /"spinel_facts.splice"\(\) (\{.*)/
        attrs=FactsAttrs.new($1).value
        fid=attrs.fetch('file_id'); before=attrs.fetch('before_line')
        raise 'invalid splice source' unless fid.is_a?(Integer) && fid>=0 && sources.key?(fid)
        raise 'invalid splice before_line' unless before.is_a?(Integer) && before>=1
        raise 'invalid splice path' unless attrs.fetch('path').is_a?(String) && !attrs['path'].empty?
        raise 'invalid splice origin' unless %w[set io_buffer enumerable builtin_extra enumerator].include?(attrs.fetch('origin'))
        splices<<attrs
      elsif line.strip=='}' || line.strip.empty?
        next
      else
        raise "unknown facts line #{line.byteslice(0,100)}"
      end
    end
    raise 'missing header/unfinished table' unless header && !table
    nodes=tables.fetch('analyzed',{})
    roots=header.fetch('spinel_facts.analysis_roots',[])
    selected={}; unresolved=[]; queue=roots.filter_map{|r|r['def_node_id']}; defs=[]
    defs_by_name=nodes.values.select{|n|n['kind']=='DefNode'}.group_by{|n|n.fetch('strings')['name']}
    until queue.empty?
      id=queue.pop; next if selected.key?(id)
      n=nodes[id]; raise "missing selected node #{id}" unless n
      selected[id]=n
      kind=n.fetch('kind')
      if %w[DefNode ClassNode ModuleNode SingletonClassNode].include?(kind)
        next unless queue_root=roots.any?{|r|r['def_node_id']==id} || defs.include?(id)
      end
      n.fetch('refs').each_value{|x|queue<<x if x>=0}
      n.fetch('arrays').each_value{|xs|xs.each{|x|queue<<x if x>=0}}
      next unless kind=='CallNode'
      evidence[id].each do |e|
        callee=e['callee']; next unless callee
        # Only literal top-level method targets; class dispatch is not guessed.
        candidates=defs_by_name.fetch(callee,[]).select{|d|d.fetch('refs').fetch('receiver',-1)<0}
        if candidates.length==1
          did=candidates.first.fetch('id'); defs<<did; queue<<did
        elsif callee !~ /[#.]/
          unresolved<<{node_id:id,callee:callee,candidates:candidates.length}
        end
      end
    end
    fields={}
    tables.each do |phase,ns|
      fields[phase]=ns.values.group_by{|n|n.fetch('kind')}.transform_values do |xs|
        {count:xs.length,fields:%w[strings integers refs arrays].to_h{|key|[key,xs.flat_map{|n|n.fetch(key).keys}.uniq.sort]}}
      end
    end
    observations=selected.values.sort_by{|n|n.fetch('id')}.map do |n|
      id=n.fetch('id'); {node_id:id,kind:n.fetch('kind'),name:n.fetch('strings')['name'],file_id:n.fetch('file_id'),span:n.fetch('span'),
        type_kinds:types[id].map{|x|x.fetch('kind')},evidence:evidence[id],missing_type:types[id].empty?,
        missing_evidence:n['kind']=='CallNode' && evidence[id].empty?}
    end
    {status:header.fetch('spinel_facts.status'),version:header.fetch('spinel_facts.version'),roots:roots,
      tables:fields,selected_nodes:observations,unresolved_helper_edges:unresolved,diagnostics:diagnostics,
      selected_count:observations.length,missing_type:observations.count{|n|n[:missing_type]},
      missing_call_evidence:observations.count{|n|n[:missing_evidence]}}
  end
end
if $PROGRAM_NAME==__FILE__
  puts JSON.generate(FactsInventory.read(ARGV.fetch(0)))
end
