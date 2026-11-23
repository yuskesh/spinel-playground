require 'json'
require 'digest'
module CorpusContract
  module_function
  def verify(path, manifest, records)
    contract=JSON.parse(File.binread(path))
    raise 'corpus-contract-version' unless contract['version']==1
    profiles=JSON.parse(File.binread(File.join(__dir__,'corpus-contracts.json')))
    profile=profiles.fetch(contract['corpus']) { raise 'corpus-unknown-name' }
    positive=profile.fetch('positive_ids');negative=profile.fetch('negative_ids')
    raise 'corpus-table-ID-set' unless [positive,negative].all?{|ids|ids.is_a?(Array)&&ids.all?{|id|id.is_a?(String)}&&ids.uniq.size==ids.size} && (positive&negative).empty?
    hash=Digest::SHA256.file(manifest).hexdigest
    raise 'corpus-oracle-hash' unless contract.fetch('oracle_manifest_sha256')==hash && profile.fetch('oracle_manifest_sha256')==hash
    total=positive.size+negative.size
    raise 'corpus-count' unless contract['positive']==positive.size && contract['negative']==negative.size && records.size==total
    raise 'corpus-id-set' unless records.select{|r|r['kind']=='positive'}.map{|r|r.fetch('id')}.sort==positive.sort && records.select{|r|r['kind']=='negative'}.map{|r|r.fetch('id')}.sort==negative.sort
    keys=%w[id source source_sha256]
    wanted=contract.fetch('cases').map{|r|r.slice(*keys)}.sort_by{|r|r.fetch('id')}
    actual=records.map{|r|r.slice(*keys)}.sort_by{|r|r.fetch('id')}
    raise 'corpus-source-set' unless wanted==actual && wanted.map{|r|r['id']}.uniq.size==total
    contract
  end
end
