require_relative 'facts-inventory'
class RootFacts
  attr_reader :header,:nodes,:types,:evidence
  def initialize(path)
    @nodes={};@types=Hash.new{|h,k|h[k]=[]};@evidence=Hash.new{|h,k|h[k]=[]};table=nil
    File.foreach(path) do |line|
      if line.start_with?('module attributes ')
        @header=FactsAttrs.new(line.delete_prefix('module attributes ')).value
      elsif line.include?('"spinel_facts.table"() ({');table={}
      elsif line.include?('}) {phase = ')
        @nodes=table if line.include?('phase = "analyzed"');table=nil
      elsif line =~ /"spinel_facts\.(node|type|evidence)"\(\) (\{.*)/
        kind=$1;attr=FactsAttrs.new($2).value
        case kind
        when 'node';raise 'node outside table' unless table;table[attr.fetch('id')]=attr
        when 'type';@types[attr.fetch('node_id')]<<attr.reject{|k,_|k=='node_id'}
        when 'evidence';@evidence[attr.fetch('node_id')]<<attr.reject{|k,_|k=='node_id'}
        end
      end
    end
    raise 'not success facts' unless @header && @header['spinel_facts.status']=='success' && !@nodes.empty?
  end
  def root(name)
    roots=@header.fetch('spinel_facts.analysis_roots').select{|r|r.fetch('method')==name}
    raise "nonunique root #{name}" unless roots.length==1
    roots.first
  end
end
def compare_root_facts(a,b,name)
  left=a.root(name);right=b.root(name);differences=[]
  %w[method requested_arg_types resolved_arg_types].each do |key|
    differences<<{kind:'root',method:name,field:key,left:left[key],right:right[key]} if left[key]!=right[key]
  end
  queue=[[left.fetch('def_node_id'),right.fetch('def_node_id'),true]];mapped={};reverse={}
  until queue.empty?
    li,ri,root=queue.pop
    if mapped.key?(li)
      differences<<{kind:'sharing',left_id:li,right_id:ri} if mapped[li]!=ri
      next
    end
    if reverse.key?(ri) && reverse[ri]!=li
      differences<<{kind:'sharing',left_id:li,right_id:ri};next
    end
    mapped[li]=ri;reverse[ri]=li
    ln=a.nodes[li];rn=b.nodes[ri]
    unless ln && rn;differences<<{kind:'node-missing',left_id:li,right_id:ri};next;end
    core=lambda{|n|n.reject{|k,_|%w[id refs arrays].include?(k)}}
    location={method:name,left_id:li,right_id:ri,node_kind:ln['kind'],name:ln.fetch('strings')['name'],file_id:ln['file_id'],span:ln['span']}
    if core.call(ln)!=core.call(rn)
      differences<<location.merge(kind:'node-shape',left:core.call(ln),right:core.call(rn));next
    end
    differences<<location.merge(kind:'type',left:a.types[li],right:b.types[ri]) if a.types[li]!=b.types[ri]
    differences<<location.merge(kind:'evidence',left:a.evidence[li],right:b.evidence[ri]) if a.evidence[li]!=b.evidence[ri]
    next if !root && %w[DefNode ClassNode ModuleNode SingletonClassNode].include?(ln['kind'])
    %w[refs arrays].each do |key|
      l=ln.fetch(key);r=rn.fetch(key)
      if l.keys.sort!=r.keys.sort
        differences<<location.merge(kind:'field-set',field:key,left:l.keys,right:r.keys);next
      end
      l.each do |field,lv|
        rv=r.fetch(field);ls=key=='refs' ? [lv] : lv;rs=key=='refs' ? [rv] : rv
        if ls.length!=rs.length
          differences<<location.merge(kind:'edge-arity',field:field,left:ls.length,right:rs.length);next
        end
        ls.zip(rs).each do |lc,rc|
          if lc<0 || rc<0
            differences<<location.merge(kind:'edge-presence',field:field,left:lc,right:rc) if lc!=rc
          else;queue<<[lc,rc,false]
          end
        end
      end
    end
  end
  {method:name,paired_nodes:mapped.length,differences:differences}
end
