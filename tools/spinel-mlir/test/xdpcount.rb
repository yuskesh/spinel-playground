require "fileutils"
require "open3"
require "json"
build, src = ARGV
tool = File.join(build, "bin/spinel-mlir")
normalizer = File.join(build, "bin/spinel-ir-normalize")
compiler = File.join(build, "bpf-mlir/bin/ebpf-compile")
root = File.join(build, "xdpcount-test")
FileUtils.rm_rf(root)
FileUtils.mkdir_p(root)
$command_root = File.join(root, "commands")
FileUtils.mkdir_p($command_root)
$command_id = 0
def run(*args)
  out, err, status = Open3.capture3(*args)
  tag = File.join($command_root, format("%02d", $command_id))
  $command_id += 1
  File.binwrite(tag + ".stdout", out)
  File.binwrite(tag + ".stderr", err)
  File.write(tag + ".json", JSON.pretty_generate({argv: args, exit: status.exitstatus, signal: status.termsig}) + "\n")
  abort "E001 xdpcount: #{args.first} rc=#{status.exitstatus}: #{err}" unless status.success?
  out.b
end
def equal(a, b, label)
  abort "E001 xdpcount: #{label} bytes differ" unless a == b
end
oracle = File.join(src, "Oracle")
input = File.join(src, "Inputs/xdpcount.spinel.mlir")
2.times do |iteration|
  dir = File.join(root, "run#{iteration}")
  run(tool, "--emit-dir", dir, input)
  %w[schema.json maps.json].each do |suffix|
    equal(File.binread(File.join(dir, "xdpcount.#{suffix}")),
          File.binread(File.join(oracle, "xdpcount.#{suffix}")), suffix)
  end
  equal(run(normalizer, File.join(dir, "xdpcount.mlir")),
        run(normalizer, File.join(oracle, "xdpcount.mlir")), "IR structure")
  run(File.join(build, "bpf-mlir/bin/ebpf-schema-test"), "--canonical", File.join(dir, "xdpcount.schema.json"))
  %w[auto off].each do |mode|
    %w[candidate oracle].each do |arm|
      mlir = File.join(arm == "candidate" ? dir : oracle, "xdpcount.mlir")
      output = File.join(dir, "#{arm}-#{mode}.o")
      run(compiler, mlir, "--schema", File.join(oracle, "xdpcount.schema.json"), "--line-info=#{mode}", "-o", output)
    end
    equal(File.binread(File.join(dir, "candidate-#{mode}.o")),
          File.binread(File.join(dir, "oracle-#{mode}.o")), "ELF #{mode}")
  end
end
%w[xdpcount.mlir xdpcount.schema.json xdpcount.maps.json candidate-auto.o candidate-off.o].each do |file|
  equal(File.binread(File.join(root, "run0", file)),
        File.binread(File.join(root, "run1", file)), "reproduce #{file}")
end
puts "E001 xdpcount: raw schema/maps, IR structure, auto/off ELF and reproducibility GREEN"
