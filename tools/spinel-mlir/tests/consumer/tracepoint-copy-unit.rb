require 'zlib';require 'tmpdir';require 'open3'
tool,fixture,kind_fixture=ARGV;raise 'usage: tracepoint-copy-unit TOOL GZIP_FACTS' unless fixture&&kind_fixture
Dir.mktmpdir('spinel-tp-copy-') do |dir|
 facts=dir+'/facts.mlir';File.binwrite(facts,Zlib::GzipReader.open(fixture,&:read));kind=dir+'/kind.mlir';File.binwrite(kind,Zlib::GzipReader.open(kind_fixture,&:read));o,e,s=Open3.capture3(tool,facts,kind);$stdout.write(o);$stderr.write(e);exit(s.exitstatus||2) unless s.success?
end
puts 'tracepoint copy unit GREEN'
