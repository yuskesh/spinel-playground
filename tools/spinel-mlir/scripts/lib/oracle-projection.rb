require 'json'
require 'digest'
require 'fileutils'
require_relative 'capture-inventory'

# Data-only extraction of E071 project-inputs.rb's canonical raw projection.
# No tools execute here; seal-release-corpus remains the contract writer.
module OracleProjection
  module_function
  def write(full, inventory_path, ids, corpus, out)
    raise 'projection-output-exists' if File.exist?(out)
    raise 'projection-ID-set' unless ids.is_a?(Array) && !ids.empty? &&
      ids.all? { |id| id.is_a?(String) && !id.empty? } && ids.uniq.size == ids.size
    raise 'projection-corpus-name' unless corpus.is_a?(String) && corpus.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    meta = JSON.parse(File.binread(full+'/manifest.json'))
    input = JSON.parse(File.binread(inventory_path))
    records = meta.fetch('cases'); inputs = input.fetch('cases')
    raise 'projection-manifest-shape' unless records.is_a?(Array) && inputs.is_a?(Array)
    keys = %w[id kind source source_sha256]
    [records, inputs].each do |rows|
      raise 'projection-row-shape' unless rows.all? { |r| r.is_a?(Hash) && keys.all? { |k| r[k].is_a?(String) && !r[k].empty? } }
      raise 'projection-duplicate-ID' unless rows.map { |r| r.fetch('id') }.uniq.size == rows.size
    end
    raise 'projection-input-identity' unless input.fetch('oracle_commit') == meta.fetch('commit') &&
      records.map { |r| r.slice(*keys) } == inputs.map { |r| r.slice(*keys) }
    raise 'projection-unknown-ID' unless (ids-records.map { |r| r.fetch('id') }).empty?
    hashes = JSON.parse(File.binread(full+'/sha256.json'))
    raise 'projection-inventory-shape' unless hashes.is_a?(Hash) && hashes.all? { |p,h| p.is_a?(String) && h.is_a?(String) && h.match?(/\A[0-9a-f]{64}\z/) }
    paths = Dir[full+'/**/*'].select { |p| File.file?(p) }.map { |p| p.delete_prefix(full+'/') }-['sha256.json']
    raise 'projection-inventory-set' unless paths.sort == hashes.keys.sort
    hashes.each { |p,h| raise 'projection-inventory-hash' unless Digest::SHA256.file(full+'/'+p).hexdigest == h }
    rows = records.select { |r| ids.include?(r.fetch('id')) }
    raise 'projection-selected-set' unless rows.size == ids.size
    rows.each do |r|
      relative = r.fetch('raw_dir')
      raise 'projection-raw-dir' unless relative == r.fetch('kind')+'/'+r.fetch('id') && %w[positive negative].include?(r.fetch('kind'))
      source = full+'/'+relative+'/'+File.basename(r.fetch('source'))
      raise 'projection-source-hash' unless Digest::SHA256.file(source).hexdigest == r.fetch('source_sha256')
    end
    FileUtils.mkdir_p(out)
    rows.each do |r|
      from = full+'/'+r.fetch('raw_dir'); to = out+'/'+r.fetch('raw_dir')
      FileUtils.mkdir_p(File.dirname(to)); FileUtils.cp_r(from,to)
    end
    File.write(out+'/manifest.json',JSON.pretty_generate(meta.merge('corpus'=>corpus,'cases'=>rows))+"\n")
    CaptureInventory.write(out)
    input.merge('cases'=>inputs.select { |r| ids.include?(r.fetch('id')) })
  end
  # Preserve measure-union's actual candidate rows/dirs for subset comparisons.
  # This never re-runs the producer/consumer or rewrites result/status fields.
  def candidate(full, ids, out)
    raise 'projection-output-exists' if File.exist?(out)
    raise 'projection-ID-set' unless ids.is_a?(Array) && !ids.empty? &&
      ids.all? { |id| id.is_a?(String) && !id.empty? } && ids.uniq.size == ids.size
    meta = JSON.parse(File.binread(full+'/candidate.json'))
    records = meta.fetch('cases')
    raise 'projection-candidate-shape' unless meta.fetch('version') == 2 && records.is_a?(Array) &&
      records.all? { |r| r.is_a?(Hash) && %w[id source source_sha256 dir].all? { |k| r[k].is_a?(String) && !r[k].empty? } && r['producer_rc'].is_a?(Integer) }
    raise 'projection-duplicate-ID' unless records.map { |r| r.fetch('id') }.uniq.size == records.size
    raise 'projection-unknown-ID' unless (ids-records.map { |r| r.fetch('id') }).empty?
    rows = records.select { |r| ids.include?(r.fetch('id')) }
    rows.each do |r|
      raise 'projection-candidate-dir' unless r.fetch('dir') == 'cases/'+r.fetch('id') &&
        File.directory?(full+'/'+r.fetch('dir')) &&
        File.realpath(full+'/'+r.fetch('dir')).start_with?(File.realpath(full)+'/')
    end
    FileUtils.mkdir_p(out)
    rows.each do |r|
      FileUtils.mkdir_p(File.dirname(out+'/'+r.fetch('dir')))
      FileUtils.cp_r(full+'/'+r.fetch('dir'),out+'/'+r.fetch('dir'))
    end
    File.write(out+'/candidate.json',JSON.pretty_generate(meta.merge('cases'=>rows))+"\n")
    rows
  end

end
