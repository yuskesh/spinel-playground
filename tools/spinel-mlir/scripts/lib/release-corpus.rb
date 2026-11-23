require 'json'
require 'digest'
require 'open3'

# Exact E003 source glob, plus a separate bcc corpus. No output comparison here.
module ReleaseCorpus
  module_function
  def sha(path); Digest::SHA256.file(path).hexdigest; end
  def inventory(clone, pin, corpus)
    raise 'release-pin-format' unless pin.match?(/\A[0-9a-f]{40}\z/)
    head, status = Open3.capture2('git', '-C', clone, 'rev-parse', 'HEAD')
    raise 'release-pin-mismatch' unless status.success? && head.strip == pin
    changes, status = Open3.capture2('git', '-C', clone, 'status', '--porcelain', '--untracked-files=no')
    raise 'release-source-dirty' unless status.success? && changes.empty?
    positive = if corpus == 'p002'
      Dir[clone+'/internal/frontend/testdata/pos/*.rb'].sort + Dir[clone+'/cmd/spinelbpf/testdata/table/*.rb'].sort +
        %w[pkt/t_pkt rec/t_rec ring/ringio ring/t_ring ring/mc hash/t_hash hash/hstatus hash/hashio hash/mc percpu/percpuio].map { |s| clone+'/cmd/spinelbpf/testdata/'+s+'.rb' } + Dir[clone+'/examples/*/*.rb'].sort
    elsif %w[kernel-path-probe kernel-path-restored kernel-path-mixed].include?(corpus)
      []
    elsif corpus == 'kernel-path-addr'
      %w[internal/frontend/testdata/pos/trace_kpath_sock.rb internal/frontend/testdata/pos/trace_kpath_three.rb
         internal/frontend/testdata/pos/trace_kaddr_request.rb examples/bcc/tcpretrans/tcpretrans.rb
         examples/bcc/biosnoop/biosnoop.rb].map { |name| clone+'/'+name }
    elsif corpus == 'tp-array'
      %w[internal/frontend/testdata/pos/trace_tp_array_ring.rb internal/frontend/testdata/pos/trace_tp_array_borrow.rb
         examples/bcc/tcpconnect/tcpconnect.rb examples/bcc/tcpaccept/tcpaccept.rb].map { |name| clone+'/'+name }
    elsif %w[uprobe-wave3 uprobe-wave3-fixtures].include?(corpus)
      rows = JSON.parse(File.binread(File.expand_path('../../docs/researches/results/R015/inputs.json', __dir__))).fetch('cases')
      rows.select { |r|r['kind']=='positive' && (corpus=='uprobe-wave3' || r.fetch('source').start_with?('internal/')) }.map { |r|clone+'/'+r.fetch('source') }.sort
    elsif corpus == 'kernel-path-aux-v080'
      []
    elsif corpus == 'uprobe-targets'
      %w[up_ints uret_ints].map { |name| clone+'/internal/frontend/testdata/uprobe/'+name+'.rb' }
    elsif corpus == 'bcc'
      Dir[clone+'/examples/bcc/*/*.rb'].sort
    else
      raise 'release-corpus-name'
    end
    negative = if corpus == 'p002'
      Dir[clone+'/internal/frontend/testdata/neg/*.rb', clone+'/internal/frontend/testdata/uprobe/neg_*.rb'].sort
    elsif corpus == 'uprobe-wave3'
      JSON.parse(File.binread(File.expand_path('../../docs/researches/results/R015/inputs.json', __dir__))).fetch('cases').select { |r|r['kind']=='negative' }.map { |r|clone+'/'+r.fetch('source') }.sort
    elsif corpus == 'kernel-path-addr'
      Dir[clone+'/internal/frontend/testdata/neg/{kps,kpu,kad}_*.rb'].sort
    elsif corpus == 'tp-array'
      Dir[clone+'/internal/frontend/testdata/neg/tpa_*.rb'].sort
    else []
    end
    tracked, status = Open3.capture2('git', '-C', clone, 'ls-files', '*.rb')
    raise 'release-source-index' unless status.success?
    tracked = tracked.lines.map(&:strip)
    rows = [['positive',positive],['negative',negative]].flat_map do |kind, paths|
      paths.map do |path|
        raise 'release-source-missing' unless File.file?(path)
        rel = path.delete_prefix(clone+'/')
        raise 'release-source-untracked' unless tracked.include?(rel)
        {'id'=>rel.delete_suffix('.rb').tr('/','_'), 'kind'=>kind, 'source'=>rel, 'source_sha256'=>sha(path)}
      end
    end
    if corpus == 'p002'
      hook = File.binread(clone+'/cmd/spinelbpf/e010_test.go').match(/const hookProgram = `([^`]+)`/m)&.captures&.first
      raise 'release-hook-missing' unless hook
      rows << {'id'=>'derived_table_t_hook', 'kind'=>'negative', 'source'=>'derived/table/t_hook.rb', 'source_sha256'=>Digest::SHA256.hexdigest(hook), 'derived_content'=>hook}
    end
    if %w[kernel-path-probe kernel-path-restored kernel-path-mixed].include?(corpus)
      fixture={'kernel-path-probe'=>'kpath_port_probe','kernel-path-restored'=>'under','kernel-path-mixed'=>'under_unused'}.fetch(corpus)
      content=File.binread(File.expand_path('../../test/Inputs/E079/'+fixture+'.rb',__dir__)).force_encoding(Encoding::UTF_8)
      raise 'release-derived-encoding' unless content.valid_encoding?
      rows << {'id'=>'derived_kernel-path_'+fixture,'kind'=>'negative','source'=>'derived/kernel-path/'+fixture+'.rb',
               'source_sha256'=>Digest::SHA256.hexdigest(content),'derived_content'=>content,'derived_refusal_code'=>'SB010'}
    end
    if corpus == 'kernel-path-addr'
      %w[local arithmetic comparison].each do |name|
        content = File.binread(File.expand_path('../../test/Inputs/E079/kpath_'+name+'.rb', __dir__)).force_encoding(Encoding::UTF_8)
        raise 'release-derived-encoding' unless content.valid_encoding?
        source = 'derived/kernel-path/kpath_'+name+'.rb'
        rows << {'id'=>source.delete_suffix('.rb').tr('/','_'), 'kind'=>'positive', 'source'=>source,
                 'source_sha256'=>Digest::SHA256.hexdigest(content), 'derived_content'=>content}
      end
    end
    if corpus == 'kernel-path-aux-v080'
      %w[kpath_local kpath_arithmetic kpath_comparison kpath_port_probe under under_unused].each do |name|
        content=File.binread(File.expand_path('../../test/Inputs/E079/'+name+'.rb',__dir__)).force_encoding(Encoding::UTF_8)
        raise 'release-derived-encoding' unless content.valid_encoding?
        rows << {'id'=>'derived_kernel-path_'+name, 'kind'=>%w[kpath_local kpath_arithmetic kpath_comparison].include?(name) ? 'positive' : 'negative',
                 'source'=>'derived/kernel-path/'+name+'.rb','source_sha256'=>Digest::SHA256.hexdigest(content),'derived_content'=>content}
        rows.last['derived_refusal_code']='SB010' if rows.last['kind']=='negative'
      end
    end
    raise 'release-duplicate-ID' unless rows.map { |r| r.fetch('id') }.uniq.size == rows.size
    {'version'=>1, 'oracle_commit'=>pin, 'corpus'=>corpus, 'cases'=>rows}
  end

  def validate(manifest, clone, profiles, name)
    raise 'release-inventory-version' unless manifest.fetch('version') == 1
    rows = manifest.fetch('cases')
    actual = inventory(clone, manifest.fetch('oracle_commit'), manifest.fetch('corpus'))
    raise 'release-source-set' unless rows == actual.fetch('cases')
    profile = profiles.fetch(name) { raise 'capture-unknown-corpus' }
    %w[positive negative].each do |kind|
      raise 'release-profile-ID-set' unless rows.select { |r| r['kind']==kind }.map { |r| r.fetch('id') }.sort == profile.fetch(kind+'_ids').sort
    end
    actual
  end
end
