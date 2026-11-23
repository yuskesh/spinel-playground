# Localize only the optional inspection source path, not the checked AST/callee.
require 'zlib';require 'fileutils'
tool,fixture,source,work=ARGV;abort 'arguments' unless work
FileUtils.mkdir_p(work);facts=work+'/facts.mlir';File.binwrite(facts,Zlib::GzipReader.open(fixture,&:read))
system(tool,facts,source) or abort 'user buffer unit failed'
