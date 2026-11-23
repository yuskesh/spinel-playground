require 'zlib'
require 'fileutils'
tool, fixture, kind, work = ARGV
abort 'usage: run-declarations TOOL FACTS_GZ KIND WORK' unless work
FileUtils.mkdir_p(work)
path = File.join(work, 'facts.mlir')
File.binwrite(path, Zlib::GzipReader.open(fixture, &:read))
system(tool, path, kind) or abort 'record declarations failed'
