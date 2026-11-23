# frozen_string_literal: true
require 'open3'
require 'tmpdir'
require 'fileutils'
root = File.expand_path('../..', __dir__)
llvm = ENV.fetch('LLVM_PREFIX', '/opt/llvm-23.1.1')
kernel = ENV.fetch('KERNEL', File.join(root, 'tools/mlir/native/build/bin/spinel-core-kernel'))
reader = ENV.fetch('SPINEL_TYPEDUMP', File.join(root, 'tools/contract/build/spinel-typedump'))
clang = ENV.fetch('CLANG', File.join(llvm, 'bin/clang'))
linker = ENV.fetch('WASM_LD', File.join(llvm, 'bin/wasm-ld'))
# Decision 0019's CORE application width controls (no reference implementation).
checks = 0
Dir.mktmpdir('spinel-app-width-') do |dir|
  # A table of decision 0019's shape that lists body64.rb by content: the
  # listed source builds at 64 bits on wasm32, so 2**30 + 2**30 does not fail.
  planted = File.join(dir, 'planted')
  FileUtils.mkdir_p([File.join(planted, 'tools/core'), File.join(planted, 'x')])
  FileUtils.cp(File.join(__dir__, 'fixtures/int-width/body64.rb'), File.join(planted, 'x/body64.rb'))
  listed = File.join(planted, 'tools/core/int64-allow.tsv')
  File.write(listed, "x/body64.rb\ta control's 64-bit body\n")
  [ ['body.rb', 1073741824, '2:1073741824'],
    ['body.rb', 21, '0:21'],
    ['body64.rb', 1073741824, '0:1073741824', '--int64-allow', listed] ].each do |file, input, expected, *extra|
    source = File.join(__dir__, 'fixtures/int-width', file)
    contract = File.join(dir, "#{file}.contract")
    File.write(contract, "core-contract 2\nroot #{file}\nentry tick\ncontext thread\nresult none\nparam state buffer i32 inout count const 1\n")
    object = File.join(dir, "#{file}.o")
    log, rc = Open3.capture2e(kernel, contract, '--root', File.dirname(source), '--clang', clang,
                             '--typedump', reader, '--layout', 'ptr32-i64-32long', '--int-width=32', *extra,
                             '-o', object, '--', '--target=wasm32-unknown-unknown')
    abort log unless rc.success?
    wasm = File.join(dir, "#{file}.wasm")
    log, rc = Open3.capture2e(linker, '--no-entry', '--export=spinel_core_tick', '--export-memory', object, '-o', wasm)
    abort log unless rc.success?
    js = <<~'JS'
      const fs = require('fs');
      WebAssembly.instantiate(fs.readFileSync(process.argv[1])).then(({instance}) => {
        const state = new Int32Array(instance.exports.memory.buffer, 4096, 1);
        state[0] = Number(process.argv[2]);
        const status = instance.exports.spinel_core_tick(4096);
        console.log(`${status}:${state[0]}`);
      }).catch(e => { console.error(e); process.exitCode = 1; });
    JS
    out, err, rc = Open3.capture3(ENV.fetch('NODE', 'node'), '-e', js, wasm, input.to_s)
    abort "FAIL #{file}: #{out}#{err}" unless rc.success? && err.empty? && out.strip == expected
    checks += 1
    puts "  pass #{file}#{extra.empty? ? '' : ' (listed)'}: helper arithmetic and buffer state #{expected}"
  end
  # Decision 0019, revised 2026-10-21: a 32-bit target has no int64 body, and
  # the refusal names the declaration.
  contract = File.join(dir, 'body64.contract')
  File.write(contract, "core-contract 2\nroot body64.rb\nentry tick\ncontext thread\nresult none\nparam state buffer i32 inout count const 1\n")
  object = File.join(dir, 'body64.wasm32.o')
  log, rc = Open3.capture2e(kernel, contract, '--root', File.join(__dir__, 'fixtures/int-width'), '--clang', clang,
                           '--typedump', reader, '--layout', 'ptr32-i64-32long', '--int-width=32',
                           '-o', object, '--', '--target=wasm32-unknown-unknown')
  abort "FAIL body64.rb was not refused at its declaration:\n#{log}" unless !rc.success? && !File.exist?(object) &&
                                                                           log.include?('body64.rb:1: int-width-int64-refused') &&
                                                                           log.include?('tools/core/int64-allow.tsv does not list this source')
  checks += 1
  puts '  pass body64.rb: unlisted, an int64 body for a 32-bit target is refused at its declaration, naming the table'
  # A constant past i32 in a 32-bit body is refused, and the refusal names the
  # body's 32 bits, not 64; the same source builds for the 64-bit host.
  contract = File.join(dir, 'wide-constant.contract')
  File.write(contract, "core-contract 2\nroot wide-constant.rb\nentry tick\ncontext thread\nresult none\nparam state buffer i32 inout count const 1\n")
  log, rc = Open3.capture2e(kernel, contract, '--root', File.join(__dir__, 'fixtures/int-width'), '--clang', clang,
                           '--typedump', reader, '--layout', 'ptr32-i64-32long', '--int-width=32',
                           '-o', File.join(dir, 'wide-constant.o'), '--', '--target=wasm32-unknown-unknown')
  abort "FAIL wide-constant.rb at 32 bits:\n#{log}" unless !rc.success? &&
                                                          log.include?('integer-representation: ST_SGN is outside signed 32 bits') &&
                                                          !log.include?('64 bits')
  log, rc = Open3.capture2e(kernel, contract, '--root', File.join(__dir__, 'fixtures/int-width'), '--clang', clang,
                           '--typedump', reader, '-o', File.join(dir, 'wide-constant.host.o'))
  abort "FAIL wide-constant.rb on the 64-bit host:\n#{log}" unless rc.success?
  checks += 1
  puts '  pass wide-constant.rb: 0x80000000 is outside signed 32 bits in a 32-bit body, and builds on the 64-bit host'
  # On the 64-bit host the declaration changes nothing: both sources build,
  # and 2**30 + 2**30 does not fail.
  %w[body64.rb body.rb].each do |file|
    contract = File.join(dir, "host-#{file}.contract")
    File.write(contract, "core-contract 2\nroot #{file}\nentry tick\ncontext thread\nresult none\nparam state buffer i32 inout count const 1\n")
    object = File.join(dir, "host-#{file}.o")
    header = File.join(dir, "host-#{file}.h")
    log, rc = Open3.capture2e(kernel, contract, '--root', File.join(__dir__, 'fixtures/int-width'), '--clang', clang,
                             '--typedump', reader, '-o', object, '--header', header)
    abort log unless rc.success?
    driver = File.join(dir, "host-#{file}.c")
    File.write(driver, "#include <stdio.h>\n#include \"#{header}\"\nint main(void) { int32_t state = 1073741824; int status = (int)spinel_core_tick(&state); printf(\"%d:%d\\n\", status, (int)state); return 0; }\n")
    exe = File.join(dir, "host-#{file}")
    log, rc = Open3.capture2e(clang, driver, object, '-o', exe)
    abort log unless rc.success?
    out, rc = Open3.capture2e(exe)
    abort "FAIL #{file} on the host: #{out}" unless rc.success? && out.strip == '0:1073741824'
    checks += 1
    puts "  pass #{file} on the 64-bit host: 0:1073741824"
  end
end
puts "int-width: #{checks} checked, #{checks} pass, 0 fail"
