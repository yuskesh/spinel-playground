#!/usr/bin/env ruby
# C++ parses/normalizes structure; this driver compares its complete outputs.
require 'open3'
unless ARGV.size == 3
  warn 'usage: compare-mlir.rb NORMALIZER LEFT.mlir RIGHT.mlir'
  exit 2
end
normalizer,left,right=ARGV
forms=[]
[left,right].each_with_index do |path,index|
  begin
    stdout,stderr,status=Open3.capture3(normalizer,path)
  rescue SystemCallError => error
    warn "structural-tool-io: #{error.message}"
    exit 2
  end
  unless status.success?
    warn "structural-input-failed: #{index==0 ? 'left' : 'right'} rc=#{status.exitstatus}"
    warn stderr
    exit 2
  end
  if stdout.empty?
    warn 'structural-empty-normal-form'
    exit 2
  end
  forms<<stdout
end
if forms[0]==forms[1]
  puts 'structural-equal'
  exit 0
end
warn 'structural-different'
exit 1
