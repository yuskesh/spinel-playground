#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: check-packet-diagnostic-mutation MEASURE MUTATION_TOOL FRESH_OUT' unless ARGV.size==3
measure,tool,out=ARGV.map { |p|File.expand_path(p) }
id='internal_frontend_testdata_neg_flow_extra_arg'
abort 'fresh output required' if File.exist?(out)
input=JSON.parse(File.read(measure+'/plan.json')).find { |r|r.fetch('id')==id }
abort 'facts hash' unless Digest::SHA256.file(input.fetch('facts')).hexdigest==input.fetch('sha256')
FileUtils.mkdir_p(out)
FileUtils.cp(tool,out+'/mutation')
pin=Digest::SHA256.file(tool).hexdigest
abort 'tool changed' unless Digest::SHA256.file(out+'/mutation').hexdigest==pin
command=[out+'/mutation','--emit-dir',out+'/artifacts',input.fetch('facts')]
so,se,s=Open3.capture3(*command)
File.binwrite(out+'/stdout',so);File.binwrite(out+'/stderr',se)
baseline=File.binread(measure+'/cases/'+id+'/build.stderr')
differences=baseline.bytes.zip(se.bytes).each_index.select { |i|baseline.getbyte(i)!=se.getbyte(i) }
result={id:id,command:command,tool_sha256:pin,rc:s.exitstatus,signal:s.termsig,
        stdout_bytes:so.bytesize,artifact_count:Dir[out+'/artifacts/*'].size,
        baseline_bytes:baseline.bytesize,mutation_bytes:se.bytesize,
        difference_offsets:differences,baseline_sb008:baseline.include?('rejected SB008'),
        mutation_sb008:se.include?('rejected SB008')}
File.write(out+'/ledger.json',JSON.pretty_generate(result)+"\n")
abort 'STOP diagnostic mutation' unless s.exitstatus==1 && !s.termsig && so.empty? && result[:artifact_count]==0 &&
  baseline.bytesize==se.bytesize && differences.size==1 && result[:baseline_sb008] && result[:mutation_sb008] &&
  baseline.getbyte(differences[0])==')'.ord && se.getbyte(differences[0])=='!'.ord
puts JSON.generate(result)
