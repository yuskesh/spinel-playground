# E039: gunzip a saved facts fixture and run spinel-output-str-test on it.
require 'zlib'
require 'fileutils'
tool, mode, fixture, oracle, work, source_dir = ARGV
abort 'usage: output-str-run TOOL positive|negative FACTS_GZ ORACLE WORK [SOURCE_DIR]' unless work
FileUtils.mkdir_p(work)
path = File.join(work, 'facts.mlir')
File.binwrite(path, Zlib::GzipReader.open(fixture, &:read))
system(tool, mode, path, oracle, *source_dir) or abort 'output_str test failed'
