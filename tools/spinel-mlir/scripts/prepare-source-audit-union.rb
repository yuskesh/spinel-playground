#!/usr/bin/env ruby
# E046 archive materialization adapted for E052; no product is executed here.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'zlib'
abort 'usage: prepare-source-audit-union SUPPLY_LEDGER PIPELINE_EXEC FRESH_OUT' unless ARGV.size == 3
supply, pipeline_path, out = ARGV.map { |p| File.expand_path(p) }
repo = File.expand_path('..', __dir__)
abort 'fresh output required' if File.exist?(out)
sha = ->(p) { Digest::SHA256.file(p).hexdigest }
ledger = JSON.parse(File.read(repo + '/docs/union/ledger.json'))
rows = ledger.fetch('cases')
abort 'ledger count/duplicates' unless rows.size == ledger.fetch('total') && rows.map { |r| r.fetch('id') }.uniq.size == rows.size
abort 'accepted source pipeline requires explicit materialization support' if rows.any? { |r| r['facts'].nil? }
FileUtils.mkdir_p(out + '/archives')
plan = []; audit = []
rows.group_by { |r| r.fetch('facts').fetch('primary_locator').fetch('archive_path') }.each_with_index do |(archive, cases), index|
  path = repo + '/' + archive
  hash = sha.call(path)
  locs = cases.map { |r| r.fetch('facts').fetch('primary_locator') }
  abort 'archive hash: ' + archive unless locs.all? { |l| l.fetch('archive_sha256') == hash }
  members = locs.map { |l| l.fetch('member') }.uniq
  abort 'unsafe archive member' if members.any? { |m| m.start_with?('/') || m.split('/').include?('..') }
  dir = out + '/archives/' + index.to_s
  FileUtils.mkdir_p(dir)
  so, se, status = Open3.capture3('/usr/bin/tar', '-xzf', path, '-C', dir, '--', *members)
  File.binwrite(dir + '/tar.stdout', so); File.binwrite(dir + '/tar.stderr', se)
  abort 'archive extract: ' + archive unless status.success?
  cases.each do |row|
    facts = row.fetch('facts'); loc = facts.fetch('primary_locator'); member = dir + '/' + loc.fetch('member')
    abort 'member hash' unless sha.call(member) == loc.fetch('member_sha256')
    raw = case loc.fetch('member_encoding')
          when 'identity' then File.binread(member)
          when 'gzip' then Zlib::GzipReader.open(member, &:read)
          else abort 'unknown encoding'
          end
    abort 'facts hash' unless Digest::SHA256.hexdigest(raw) == facts.fetch('sha256')
    target = out + '/facts/' + row.fetch('id') + '.mlir'
    FileUtils.mkdir_p(File.dirname(target)); File.binwrite(target, raw)
    plan << { id: row.fetch('id'), facts: target, sha256: facts.fetch('sha256') }
    audit << { id: row.fetch('id'), archive: archive, member: loc.fetch('member'), sha256: facts.fetch('sha256') }
  end
end
by_id = plan.to_h { |r| [r.fetch(:id), r] }
additional = JSON.parse(File.read(supply))
abort 'supply count' unless additional.size == 18
overlap = []
additional.each do |row|
  abort 'supply contract' unless row.fetch('rc') == 0 && row.fetch('verify_rc') == 0 && !row['signal'] && !row['verify_signal'] && sha.call(row.fetch('facts')) == row.fetch('sha256')
  id = row.fetch('id')
  overlap << id if by_id.key?(id)
  by_id[id] ||= { id: id, facts: row.fetch('facts'), sha256: row.fetch('sha256') }
end
pipeline = JSON.parse(File.read(pipeline_path))
producer = pipeline.fetch('producer')
builtins = File.expand_path('../builtins', File.dirname(producer))
source = File.dirname(pipeline_path) + '/' + File.basename(pipeline.fetch('source'))
execution = { 'kind' => 'source_pipeline', 'source' => source, 'source_sha256' => pipeline.fetch('source_sha256'),
              'producer' => producer, 'producer_sha256' => pipeline.fetch('producer_sha256'), 'library' => pipeline.fetch('library'),
              'library_sha256' => pipeline.fetch('library_sha256'), 'builtins' => builtins,
              'builtins_sha256' => Dir[builtins + '/**/*'].select { |p| File.file?(p) }.sort.to_h { |p| [p.delete_prefix(builtins + '/'), sha.call(p)] }, 'roots' => pipeline.fetch('roots') }
id = 'internal_frontend_testdata_neg_require_relative'
abort 'source pipeline already accepted; explicit locator migration needed' if by_id.key?(id)
by_id[id] = { id: id, facts: nil, execution: execution }
require_relative 'lib/source-pipeline-union'
SourcePipelineUnion.verify(JSON.parse(JSON.generate(by_id.fetch(id))))
File.write(out + '/plan.json', JSON.pretty_generate(by_id.values.sort_by { |r| r.fetch(:id) }) + "\n")
File.write(out + '/materialization.json', JSON.pretty_generate(audit) + "\n")
prediction = { baseline: rows.size, selection: 19, overlap: overlap, expected_matched: by_id.size, expected_unsupported: 609 - by_id.size,
               expected_different: 0, expected_error: 0, expected_exit: by_id.size == 609 ? 0 : 3,
               consumer: by_id.size - 1, source_pipeline: 1 }
File.write(out + '/prediction.json', JSON.pretty_generate(prediction) + "\n")
puts JSON.generate(prediction)
