require 'zlib'
require 'fileutils'
tool, fixture, work, predicates = ARGV
abort 'usage: run TOOL FACTS_GZ WORK' unless work
FileUtils.mkdir_p(work)
path = File.join(work, 'facts.mlir')
File.binwrite(path, Zlib::GzipReader.open(fixture, &:read))
args = [tool, path]
if predicates
  predicate_path = File.join(work, 'predicates.mlir')
  File.binwrite(predicate_path, Zlib::GzipReader.open(predicates, &:read))
  args << predicate_path
end
system(*args) or abort 'consumer hooks failed'
