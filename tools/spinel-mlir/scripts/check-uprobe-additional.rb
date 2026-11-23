#!/usr/bin/env ruby
# Additional positives are deliberately outside batch-compare's fixed 609.
require 'json'
require 'fileutils'
require 'open3'
abort 'usage: check-uprobe-additional GO_CAPTURE CANDIDATE FRESH_REPORT' unless ARGV.size==3
oracle,candidate,out=ARGV.map { |p| File.expand_path(p) }
repo=File.expand_path('..',__dir__)
abort 'fresh output required' if File.exist?(out)
FileUtils.mkdir_p(out+'/oracle')
a=JSON.parse(File.read(oracle+'/manifest.json'))
a['cases']=a.fetch('cases').select { |c| %w[up_ints uret_ints].include?(c.fetch('id')) }
abort 'additional oracle coverage' unless a['cases'].size==2
a['cases'].each { |c| c['raw_dir']=File.expand_path(c.fetch('raw_dir'),oracle) }
File.write(out+'/oracle/manifest.json',JSON.pretty_generate(a)+"\n")
checks=[]
a['cases'].each do |c|
  id=c.fetch('id');stem=File.basename(c.fetch('source'),'.rb')
  ad=c.fetch('raw_dir');bd=candidate+'/cases/'+id
  [ad,bd].each do |dir|
    abort 'additional producer failure: '+id unless File.binread(dir+'/build.rc')=="0\n"
    %w[mlir schema.json maps.json auto.bpf.o off.bpf.o].each do |ext|
      abort 'additional empty artifact: '+id+'/'+ext unless File.size?(dir+'/'+stem+'.'+ext)
    end
  end
  forms=[ad,bd].map.with_index do |dir,i|
    so,se,s=Open3.capture3(candidate+'/tools/normalizer',dir+'/'+stem+'.mlir')
    File.binwrite(out+'/'+id+".#{i}.normal",so);File.binwrite(out+'/'+id+".#{i}.stderr",se)
    checks<<{id:id,check:'normalizer',side:i,rc:s.exitstatus,bytes:so.bytesize}
    abort 'STOP additional normalizer' unless s.success? && !so.empty?
    so
  end
  checks<<{id:id,check:'structure',equal:forms[0]==forms[1]}
  names=%W[#{stem}.domain.json #{stem}.mlir #{stem}.schema.json #{stem}.maps.json #{stem}.compile_warnings.txt #{stem}.bpf.o #{stem}_embed.S #{stem}_embed.o]
  warnings=File.binread(ad+'/build.stderr').lines.reject { |line| names.any? { |n| line=="spinelbpf: wrote #{ad}/#{n}\n".b } }.join
  File.binwrite(out+'/'+id+'.oracle-warnings',warnings)
  checks<<{id:id,check:'warnings',equal:warnings==File.binread(bd+'/build.stderr')}
end
so,se,s=Open3.capture3('ruby',repo+'/docs/experiments/results/E003/compare.rb',out+'/oracle',candidate,candidate+'/tools/compiler',out+'/raw-report')
File.binwrite(out+'/raw.stdout',so);File.binwrite(out+'/raw.stderr',se)
checks<<{check:'raw-comparison',rc:s.exitstatus}
File.write(out+'/checks.json',JSON.pretty_generate(checks)+"\n")
abort 'STOP additional comparison' unless s.success? && checks.none? { |r| r['equal']==false || r[:equal]==false }
puts JSON.generate({additional:2,structure:2,warnings:2,raw_rc:s.exitstatus})
