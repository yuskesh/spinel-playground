#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "json"
require "open3"
require "zlib"
abort "usage: check-real-xdpcount.rb BUILD FACTS OUTPUT ORACLE" unless ARGV.size == 4
build, input, root, oracle = ARGV.map { |path| File.expand_path(path) }
abort "E006 output exists" if File.exist?(root)
FileUtils.mkdir_p(File.join(root, "commands"))
tool = File.join(build, "bin/spinel-mlir")
normalizer = File.join(build, "bin/spinel-ir-normalize")
compiler = File.join(build, "bpf-mlir/bin/ebpf-compile")
raise "E006 wrong accepted facts hash" unless Digest::SHA256.file(input).hexdigest == "ef1ff1804c52b4626b6c503c43c7da380d3f488f40ee27f6def1986cbe849153"
original = File.binread(input)
Zlib::GzipWriter.open(File.join(root, "actual-v2.mlir.gz")) { |gz| gz.write(original) }
inputs = [input, __FILE__, tool, normalizer, compiler, *Dir.glob(File.join(oracle, "xdpcount.*"))]
File.write(File.join(root, "inputs.json"), JSON.pretty_generate(inputs.map { |p| {path: p, sha256: Digest::SHA256.file(p).hexdigest} }) + "\n")
$root, $command = root, 0
def execute(*args)
  stdout, stderr, status = Open3.capture3(*args)
  path = File.join($root, "commands", format("%02d", $command))
  $command += 1
  File.binwrite(path + ".stdout", stdout)
  File.binwrite(path + ".stderr", stderr)
  File.write(path + ".json", JSON.pretty_generate({argv: args, cwd: Dir.pwd, exit: status.exitstatus, signal: status.termsig}) + "\n")
  [stdout, stderr, status]
end
def success(*args)
  stdout, stderr, status = execute(*args)
  raise "E006 command failed #{args.inspect}: #{stderr}" unless status.success?
  stdout.b
end
def same(left, right, name)
  raise "E006 #{name} differs" unless left == right
end
summary = {complete: false, positive_runs: 0, controls: []}
begin
  2.times do |iteration|
    output = File.join(root, "run#{iteration}")
    stdout, stderr, status = execute(tool, "--emit-dir", output, input)
    raise "E006 actual emit failed: #{stderr}" unless status.success? && stdout.empty? && stderr.empty?
    %w[schema.json maps.json].each do |suffix|
      same(File.binread(File.join(output, "xdpcount." + suffix)), File.binread(File.join(oracle, "xdpcount." + suffix)), suffix)
    end
    same(success(normalizer, File.join(output, "xdpcount.mlir")),
         success(normalizer, File.join(oracle, "xdpcount.mlir")), "IR structure")
    %w[auto off].each do |mode|
      %w[candidate oracle].each do |arm|
        source = File.join(arm == "candidate" ? output : oracle, "xdpcount.mlir")
        success(compiler, source, "--schema", File.join(oracle, "xdpcount.schema.json"),
                "--line-info=" + mode, "-o", File.join(output, arm + "-" + mode + ".o"))
      end
      same(File.binread(File.join(output, "candidate-" + mode + ".o")),
           File.binread(File.join(output, "oracle-" + mode + ".o")), "ELF " + mode)
    end
    summary[:positive_runs] += 1
  end
  %w[xdpcount.mlir xdpcount.schema.json xdpcount.maps.json candidate-auto.o candidate-off.o].each do |name|
    same(File.binread(File.join(root, "run0", name)), File.binread(File.join(root, "run1", name)), "reproduce " + name)
  end
  atomic = original.lines.find { |line| line.include?('"spinel_facts.evidence"') && line.include?('name = "atomic_add"') && line.include?('callee = "ArrayMap#atomic_add"') }
  raise "E006 missing atomic observation" unless atomic
  missing = original.sub(atomic, "")
  callee = original.sub(atomic, atomic.sub('callee = "ArrayMap#atomic_add"', 'callee = "ArrayMap#update"'))
  request = original.sub('requested_arg_types = ["obj_BPF::XdpMd"]', 'requested_arg_types = ["obj_BPF::SkBuff"]')
  phase, changed = 0, 0
  shape = original.lines.map do |line|
    phase += 1 if line.include?('"spinel_facts.table"')
    if phase == 2 && line.include?('"spinel_facts.node"') && line.include?("id = 2148 : i64,")
      changed += 1
      line.sub('"value" = "1"', '"value" = "0"').sub('backend_decimal = "1"', 'backend_decimal = "0"')
    else
      line
    end
  end.join
  raise "E006 shape mutation not unique" unless changed == 1
  controls = [
    ["request", request, "xdpcount.rb:5:1: rejected SB001 (UnsupportedConstruct): E006 XDP analysis root requires obj_BPF::XdpMd\n"],
    ["missing", missing, "xdpcount.rb:6:3: rejected SB001 (UnsupportedConstruct): E001 requires one direct call evidence with the same name\n"],
    ["callee", callee, "xdpcount.rb:6:3: rejected SB001 (UnsupportedConstruct): E006 call evidence callee differs from the selected BPF operation\n"],
    ["shape", shape, "xdpcount.rb:6:24: rejected SB001 (UnsupportedConstruct): analyzed node shape differs from pristine (E001 cannot prove identity)\n"]
  ]
  controls.each do |name, contents, expected|
    raise "E006 control is unchanged #{name}" if contents == original
    path = File.join(root, name + ".mlir")
    File.binwrite(path, contents)
    output = File.join(root, name + "-output")
    stdout, stderr, status = execute(tool, "--emit-dir", output, path)
    Zlib::GzipWriter.open(path + ".gz") { |gz| gz.write(contents) }
    File.unlink(path)
    File.binwrite(File.join(root, name + ".expected"), expected)
    raise "E006 wrong named refusal #{name}: #{stderr}" unless status.exitstatus == 1 && status.termsig.nil? && stdout.empty? && stderr.b == expected.b && !File.exist?(output)
    summary[:controls] << {name: name, exit: status.exitstatus, stderr_sha256: Digest::SHA256.hexdigest(stderr)}
  end
  summary[:complete] = true
  puts "E006 actual facts: raw schema/maps, IR structure, auto/off ELF, two outputs and four named controls GREEN"
rescue StandardError => error
  summary[:error] = error.message
  warn error.message
ensure
  File.write(File.join(root, "summary.json"), JSON.pretty_generate(summary) + "\n")
end
exit(summary[:complete] ? 0 : 1)
