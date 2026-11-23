#!/usr/bin/env ruby
require 'json'
require 'digest'
root = File.expand_path('../..', __dir__)
base = File.join(root, 'docs/experiments/results/E003/capture/negative')
names = %w[key_2p32 value32_2p32 op_plus rmw_distinct_keys_overflow p2_key_range]
File.open(File.join(__dir__, 'diagnostics.tsv'), 'wb') do |out|
  names.each do |name|
    path = File.join(base, "internal_frontend_testdata_neg_#{name}", "#{name}.domain.json")
    doc = JSON.parse(File.binread(path))
    raise "missing singleton rejected diagnostic: #{name}" unless doc['diagnostics'].length == 1 && doc['diagnostics'][0]['verdict'] == 'rejected'
    d = doc['diagnostics'][0]
    out.write([name, d['code'], d['message'], d['pos']['file'], d['pos']['line'], d['pos']['col'], Digest::SHA256.file(path).hexdigest].join("\t") + "\n")
  end
end
