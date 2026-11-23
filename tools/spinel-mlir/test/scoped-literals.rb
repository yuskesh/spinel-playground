require "fileutils"
require "open3"
build, src = ARGV
tool = File.join(build, "bin/spinel-mlir")
normalizer = File.join(build, "bin/spinel-ir-normalize")
compiler = File.join(build, "bpf-mlir/bin/ebpf-compile")
root = File.join(build, "scoped-literals-test")
FileUtils.rm_rf(root)
FileUtils.mkdir_p(root)
def run(*args)
  out, err, status = Open3.capture3(*args)
  abort "E006 command failed: #{args.inspect}: #{err}" unless status.success?
  out.b
end
base = File.binread(File.join(src, "Inputs/xdpcount.spinel.mlir"))
absolute = base.gsub("xdpcount.rb", "/virtual/E006/xdpcount.rb")
input = File.join(root, "absolute.mlir")
File.binwrite(input, absolute)
outdir = File.join(root, "absolute-output")
run(tool, "--emit-dir", outdir, input)
oracle = File.join(src, "Oracle")
%w[schema.json maps.json].each do |suffix|
  abort "E006 absolute #{suffix}" unless File.binread(File.join(outdir, "xdpcount." + suffix)) == File.binread(File.join(oracle, "xdpcount." + suffix))
end
abort "E006 absolute IR" unless run(normalizer, File.join(outdir, "xdpcount.mlir")) == run(normalizer, File.join(oracle, "xdpcount.mlir"))
%w[auto off].each do |mode|
  candidate = File.join(root, "absolute-" + mode + ".o")
  reference = File.join(root, "oracle-" + mode + ".o")
  [ [outdir, candidate], [oracle, reference] ].each do |dir, output|
    run(compiler, File.join(dir, "xdpcount.mlir"), "--schema", File.join(oracle, "xdpcount.schema.json"), "--line-info=" + mode, "-o", output)
  end
  abort "E006 absolute ELF" unless File.binread(candidate) == File.binread(reference)
end
# Add a second real declaration to each table and to the top-level body.
extra = base.lines.map do |line|
  line = line.sub("[2 : i64, 10 : i64, 34 : i64]", "[2 : i64, 1000 : i64, 10 : i64, 34 : i64]")
  if line.include?('"spinel_facts.node"') && line.include?("id = 2 : i64,")
    line + line.sub("id = 2 : i64,", "id = 1000 : i64,")
  else
    line
  end
end.join
ambiguous = File.join(root, "ambiguous.mlir")
File.binwrite(ambiguous, extra)
output = File.join(root, "ambiguous-output")
stdout, stderr, status = Open3.capture3(tool, "--emit-dir", output, ambiguous)
File.binwrite(File.join(root, "ambiguous.stderr"), stderr)
abort "E006 ambiguous map" if status.success? || !stdout.empty? || File.exist?(output) ||
  stderr != "xdpcount.rb:3:1: rejected SB013 (MapDeclShape): constant Counts is assigned twice\n"
puts "E006 scope: absolute facts unchanged; relative IR/JSON/ELF match; ambiguous declaration named refusal"
