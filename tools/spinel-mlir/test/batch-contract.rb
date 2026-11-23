#!/usr/bin/env ruby
require 'json'
require 'fileutils'
require 'open3'
abort 'usage: batch-contract.rb REPO TOOLS FRESH_OUT' unless ARGV.size==3
repo,tools,out=ARGV.map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
FileUtils.mkdir_p("#{out}/empty-candidate")
File.write("#{out}/empty-candidate/candidate.json",JSON.pretty_generate({'version'=>2,'cases'=>[]})+"\n")
driver="#{repo}/scripts/batch-compare.rb"
require driver
abort 'invalid TSV escaping' unless BatchCompare.tsv_row(['x',"line1\nline2\t\\"])=="x\tline1\\nline2\\t\\\\"
stdout,stderr,status=Open3.capture3('ruby',driver,
 '--oracle',"#{repo}/docs/experiments/results/E003/capture",
 '--candidate',"#{out}/empty-candidate",'--groups',"#{repo}/docs/plan/P002_105_inputs.md",
 '--compiler',"#{tools}/compiler-saved",'--normalizer',"#{tools}/spinel-ir-normalize",'--report',"#{out}/empty-report")
File.binwrite("#{out}/empty.stdout",stdout);File.binwrite("#{out}/empty.stderr",stderr)
File.write("#{out}/empty.rc","#{status.exitstatus}\n")
abort "contract RED: empty candidate must exit3 (got #{status.exitstatus})" unless status.exitstatus==3
summary=JSON.parse(File.read("#{out}/empty-report/summary.json"))
abort 'empty candidate counted as success' unless summary['total']=={'matched'=>0,'different'=>0,'error'=>0,'unsupported'=>609}
abort 'invalid cases TSV header' unless File.foreach("#{out}/empty-report/cases.tsv").first=="group\tid\tstatus\treasons\n"
puts 'empty candidate: 609 named unsupported; exit3'
# E024: a v1 manifest (no positive build.stderr contract) is refused by name.
FileUtils.mkdir_p("#{out}/v1-candidate")
File.write("#{out}/v1-candidate/candidate.json",JSON.pretty_generate({'version'=>1,'cases'=>[]})+"\n")
stdout,stderr,status=Open3.capture3('ruby',driver,
 '--oracle',"#{repo}/docs/experiments/results/E003/capture",
 '--candidate',"#{out}/v1-candidate",'--groups',"#{repo}/docs/plan/P002_105_inputs.md",
 '--compiler',"#{tools}/compiler-saved",'--normalizer',"#{tools}/spinel-ir-normalize",'--report',"#{out}/v1-report")
File.binwrite("#{out}/v1.stdout",stdout);File.binwrite("#{out}/v1.stderr",stderr)
abort "contract RED: v1 candidate must exit2 (got #{status.exitstatus})" unless status.exitstatus==2
v1=JSON.parse(File.read("#{out}/v1-report/summary.json"))
abort 'v1 candidate not refused by name' unless v1['global_error'].to_s.start_with?('candidate-version-1')
puts 'v1 candidate: refused by name; exit2'
