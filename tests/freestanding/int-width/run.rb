# frozen_string_literal: true
# Decision 0019's observable target-width controls; no reference implementation.
require 'open3'
require 'tmpdir'
require 'fileutils'
root = File.expand_path('../../..', __dir__)
llvm = ENV.fetch('LLVM_PREFIX', '/opt/llvm-23.1.1')
emitter = ENV.fetch('MLIRGEN', File.join(root, 'tools/mlir/native/build/bin/spinel-fs-emit'))
reader = ENV.fetch('SPINEL_TYPEDUMP', File.join(root, 'tools/contract/build/spinel-typedump'))
linker = ENV.fetch('WASM_LD', File.join(llvm, 'bin/wasm-ld'))
node = ENV.fetch('NODE', 'node')
checks = 0
check = lambda do |label, holds|
  abort "FAIL #{label}" unless holds
  checks += 1
  puts "pass #{label}"
end
Dir.mktmpdir('spinel-int-width-') do |dir|
  text = File.read(File.join(root, 'tools/freestanding/profiles/wasm32-worker.yaml'))
  text = text.sub(/int_width: i(?:32|64)-internal/, 'int_width: i32-internal')
  profile = File.join(dir, 'target32.yaml')
  wrong = File.join(dir, 'mismatch.yaml')
  File.write(profile, text)
  File.write(wrong, text.sub('int_width: i32-internal', 'int_width: i64-internal'))
  compile = lambda do |stem, src, target, *extra|
    object = File.join(dir, "#{stem}.o")
    out, err, rc = Open3.capture3(emitter, File.join(__dir__, 'fixtures', src), '--freestanding',
                                '--profile', target, '--typedump', reader, '-o', object, *extra)
    [object, out + err, rc]
  end
  javascript = <<~'JS'
    const fs = require('fs');
    const probe = async () => {
      let code = 0;
      const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[1]), {
        env: {spinel_trap(c) { code = c; throw new Error('kernel trap'); }}
      });
      let value;
      try { value = instance.exports.spinel_width_probe(1073741824); }
      catch (e) { if (!code) throw e; }
      console.log(code ? `trap ${code}` : `value ${value}`);
    };
    probe().catch(e => { console.error(e); process.exitCode = 1; });
  JS
  # A table of decision 0019's shape that lists width64.rb, by content: its
  # copy is listed, so the fixture builds at 64 bits on wasm32.
  planted = File.join(dir, 'planted')
  FileUtils.mkdir_p(File.join(planted, 'tools/core'))
  FileUtils.mkdir_p(File.join(planted, 'x'))
  FileUtils.cp(File.join(__dir__, 'fixtures/width64.rb'), File.join(planted, 'x/width64.rb'))
  listed = File.join(planted, 'tools/core/int64-allow.tsv')
  File.write(listed, "# planted\nx/width64.rb\ta control's 64-bit body\n")
  {['width.rb'] => 'trap 1', ['width64.rb', '--int64-allow', listed] => 'value 1073741824'}.each do |(src, *extra), expected|
    stem = File.basename(src, '.rb')
    object, log, rc = compile.call(stem, src, profile, *extra)
    abort log unless rc.success?
    wasm = File.join(dir, "#{stem}.wasm")
    log, rc = Open3.capture2e(linker, '--no-entry', '--allow-undefined',
                             '--export=spinel_width_probe', object, '-o', wasm)
    abort log unless rc.success?
    out, err, rc = Open3.capture3(node, '-e', javascript, wasm)
    check.call("#{stem}: #{expected}", rc.success? && err.empty? && out.strip == expected)
  end
  # Decision 0019, revised 2026-10-21: a 32-bit target has no 64-bit body.
  object, log, rc = compile.call('unlisted64', 'width64.rb', profile)
  check.call('an unlisted int64 body is refused on a 32-bit target, naming the file, the line and the table',
             !rc.success? && !File.exist?(object) && log.include?('int-width-int64-refused') &&
             log.include?('width64.rb:1:') && log.include?('tools/core/int64-allow.tsv does not list this source'))
  # A table row naming a file that does not exist is the table's error, and
  # it refuses even the source the table lists.
  broken = File.join(planted, 'tools/core/broken.tsv')
  File.write(broken, "x/width64.rb\ta control's 64-bit body\nx/gone.rb\tno such file\n")
  object, log, rc = compile.call('broken', 'width64.rb', profile, '--int64-allow', broken)
  check.call('a table row naming a missing file refuses every source, naming the row',
             !rc.success? && !File.exist?(object) && log.include?('int64-allow-table') &&
             log.include?('broken.tsv:2: x/gone.rb does not exist'))
  # The repository's table: two columns, each file present, declaring int64.
  table = File.join(root, 'tools/core/int64-allow.tsv')
  rows = File.readlines(table, chomp: true).reject { |l| l.empty? || l.start_with?('#') }.map { |l| l.split("\t", -1) }
  check.call("tools/core/int64-allow.tsv: #{rows.size} rows of a path and a reason, each file declaring int64",
             rows.all? { |r| r.size == 2 && !r[1].strip.empty? && File.file?(File.join(root, r[0])) &&
                               File.foreach(File.join(root, r[0])).first&.chomp == '# spinel: int64' } &&
             rows.map(&:first).uniq.size == rows.size)
  # On a 64-bit target the declaration changes nothing: the same source builds
  # and 2**30 + 2**30 does not trap.
  host = { 'Linux-x86_64' => File.join(root, 'tools/freestanding/profiles/x86_64-linux-host.yaml'),
           'Darwin-arm64' => File.join(root, 'tests/freestanding/e079/arm64-host.yaml') }
  uname = "#{`uname -s`.strip}-#{`uname -m`.strip}"
  abort "FAIL no 64-bit host profile for #{uname}" unless host[uname]
  driver = File.join(dir, 'host.c')
  File.write(driver, <<~C)
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    int32_t spinel_width_probe(int32_t);
    void spinel_trap(int32_t code, int64_t a, int64_t b, const char *d) { (void)a; (void)b; (void)d; printf("trap %d\\n", (int)code); exit(0); }
    int main(void) { printf("value %d\\n", (int)spinel_width_probe(1073741824)); return 0; }
  C
  %w[width64.rb width.rb].each do |src|
    stem = "host-#{File.basename(src, '.rb')}"
    object, log, rc = compile.call(stem, src, host[uname])
    abort log unless rc.success?
    exe = File.join(dir, stem)
    log, rc = Open3.capture2e(File.join(llvm, 'bin/clang'), driver, object, '-o', exe)
    abort log unless rc.success?
    out, rc = Open3.capture2e(exe)
    check.call("#{src} on the 64-bit host: value 1073741824", rc.success? && out.strip == 'value 1073741824')
  end
  object, log, rc = compile.call('mismatch', 'width.rb', wrong)
  check.call('profile/triple width mismatch is refused', !rc.success? && !File.exist?(object) && log.include?('int-width-mismatch'))
  object, log, rc = compile.call('literal', 'literal.rb', profile)
  check.call('out-of-i32 literal is refused', !rc.success? && !File.exist?(object) && log.match?(/bigint|bignum|outside.*32/i))
end
puts "target integer width: #{checks} pass, 0 fail"
