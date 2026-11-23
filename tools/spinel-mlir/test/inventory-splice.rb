require 'tmpdir'
require 'fileutils'
require File.expand_path(ARGV.fetch(0))
Dir.mktmpdir('inventory-splice-',ARGV.fetch(1)) do |dir|
  source='  "spinel_facts.source"() {file_id = 0 : i64, path = "input.rb", text = "x"} : () -> ()'
  splice='  "spinel_facts.splice"() {before_line = 1 : i64, file_id = 0 : i64, origin = "enumerator", path = "enumerator.rb"} : () -> ()'
  header='module attributes {spinel_facts.status = "success", spinel_facts.version = 1 : i64} {'
  cases=[
    ['valid-splice',[source,splice],nil],
    ['missing-source',[splice],'invalid splice source'],
    ['zero-line',[source,splice.sub('before_line = 1','before_line = 0')],'invalid splice before_line'],
    ['unknown-origin',[source,splice.sub('origin = "enumerator"','origin = "foreign"')],'invalid splice origin'],
    ['empty-path',[source,splice.sub('path = "enumerator.rb"','path = ""')],'invalid splice path'],
    ['unknown-op',[source,splice.sub('spinel_facts.splice','spinel_facts.foreign')],'unknown facts line']
  ]
  cases.each do |name,body,want|
    path=File.join(dir,name+'.mlir')
    File.write(path,([header]+body+['}']).join("\n")+"\n")
    error=nil
    begin; FactsInventory.read(path); rescue StandardError=>e; error=e.message; end
    abort "FAIL #{name}: #{error.inspect}" unless want ? error&.start_with?(want) : error.nil?
    puts "PASS #{name}"
  end
end
