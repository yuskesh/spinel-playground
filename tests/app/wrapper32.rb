# frozen_string_literal: true
#
# tests/app/wrapper32.rb -- decision 0022 §3: the entry wrapper's descriptor
# checks with 32-bit pointers, run.
#
#   KERNEL=... SPINEL_TYPEDUMP=... LLVM_PREFIX=... [NODE=node] ruby tests/app/wrapper32.rb
#
# Each fixture of tests/app/fixtures/cross/wrapper is built for wasm32, whose
# pointers are 32 bits, linked with wasm-ld and called from node with the
# arguments of tests/app/fixtures/cross/wrapper/cases.tsv. Addresses are plain
# numbers there, so a descriptor at the top of the 32-bit address space can be
# passed without any memory behind it; the fixtures never access an element,
# and every admitted case writes its result inside the module's memory.
#
# A case passes when the status is the table's, the result is the table's for
# `ok`, and for `argument` the result slot still holds the sentinel written
# before the call (when the slot is inside the memory). Ruby's
# arithmetic is the reference for nothing here: the expected statuses are
# decision 0007's and 0022's rules, written by hand.
require 'json'
require 'open3'
require 'tmpdir'

root = File.expand_path('../..', __dir__)
fix = File.join(__dir__, 'fixtures/cross/wrapper')
llvm = ENV.fetch('LLVM_PREFIX', '/opt/llvm-23.1.1')
kernel = ENV.fetch('KERNEL', File.join(root, 'tools/mlir/native/build/bin/spinel-core-kernel'))
reader = ENV.fetch('SPINEL_TYPEDUMP', File.join(root, 'tools/contract/build/spinel-typedump'))
clang = ENV.fetch('CLANG', File.join(llvm, 'bin/clang'))
linker = ENV.fetch('WASM_LD', File.join(File.dirname(clang), 'wasm-ld'))
node = ENV.fetch('NODE', 'node')
# The tools are asked first, so a linker or a node that cannot run stops the
# run with its own words rather than as a link or call failure of the first
# fixture.
{ 'wasm-ld' => [linker, '--version'], 'node' => [node, '--version'] }.each do |what, argv|
  out, st = begin
    Open3.capture2e(*argv)
  rescue SystemCallError => e
    [e.message, nil]
  end
  abort "wrapper32: #{what} (#{argv.first}) does not run: #{out.lines.first.to_s.strip}" unless st&.success?
end
RESULT_SLOT = 8192
STATUS = { 'ok' => 0, 'argument' => 1, 'bounds' => 3 }.freeze

cases = File.readlines(File.join(fix, 'cases.tsv')).reject { |l| l.start_with?('#') || l.strip.empty? }.map do |l|
  id, kern, args, status, result, why = l.chomp.split("\t")
  { id: id, kernel: kern, why: why, status: status, result: result,
    args: args.split(',').map { |a| a == 'R' ? RESULT_SLOT : Integer(a) } }
end
abort 'wrapper32: duplicate case id' unless cases.map { |c| c[:id] }.uniq.size == cases.size

# The contract gives each argument's kind (buffer pointer, u64 count) and the
# result's width; the runner reads them rather than restating them.
def signature(contract)
  lines = File.readlines(contract)
  # a buffer's pointer, a u64 count, or an i32 scalar (passed as a pointer is: 32 bits)
  params = lines.grep(/\Aparam /).map { |l| f = l.split; f[2] == 'buffer' ? :pointer : (f[3] == 'u64' ? :count : :scalar) }
  result = lines.grep(/\Aresult /).first.split[1]
  [params + [:pointer], result]
end

JS = <<~'JS'
  const fs = require('fs');
  const [wasmPath, exportName, resultBits, casesJson] = process.argv.slice(1);
  const cases = JSON.parse(casesJson);
  WebAssembly.instantiate(fs.readFileSync(wasmPath)).then(({instance}) => {
    const fn = instance.exports[exportName];
    const mem = new DataView(instance.exports.memory.buffer);
    const wide = resultBits === 'i64';
    const SENTINEL = 0x5a5a5a5an;
    for (const c of cases) {
      const r = c.args[c.args.length - 1];
      const inMem = r + (wide ? 8 : 4) <= mem.byteLength;
      if (inMem) { if (wide) mem.setBigInt64(r, SENTINEL, true); else mem.setInt32(r, Number(SENTINEL), true); }
      const args = c.args.map((a, i) => c.kinds[i] === 'count' ? BigInt.asUintN(64, BigInt(a)) : Number(BigInt.asUintN(32, BigInt(a))));
      let status;
      try { status = fn(...args); } catch (e) { console.log(`${c.id}\ttrap\t${e.message}`); continue; }
      let value = '-';
      if (inMem) value = wide ? mem.getBigInt64(r, true).toString() : String(mem.getInt32(r, true));
      console.log(`${c.id}\t${status}\t${value}\t${inMem ? 'slot' : 'no-slot'}`);
    }
  }).catch(e => { console.error(e); process.exitCode = 1; });
JS

pass = 0
fail = 0
Dir.mktmpdir('spinel-wrapper32-') do |dir|
  cases.group_by { |c| c[:kernel] }.each do |kern, cs|
    contract = File.join(fix, "#{kern}.contract")
    kinds, result = signature(contract)
    object = File.join(dir, "#{kern}.o")
    log, st = Open3.capture2e(kernel, contract, '--root', fix, '--clang', clang, '--typedump', reader,
                              '--layout', 'ptr32-i64-32long', '--int-width=32', '-o', object,
                              '--', '--target=wasm32-unknown-unknown')
    abort "wrapper32: #{kern} did not build:\n#{log}" unless st.success?
    wasm = File.join(dir, "#{kern}.wasm")
    log, st = Open3.capture2e(linker, '--no-entry', "--export=spinel_core_#{kern}", '--export-memory',
                              '--initial-memory=131072', '--max-memory=131072', object, '-o', wasm)
    abort "wrapper32: #{kern} did not link:\n#{log}" unless st.success?
    payload = cs.map do |c|
      abort "wrapper32: #{c[:id]} passes #{c[:args].size} arguments, #{kern} takes #{kinds.size}" unless c[:args].size == kinds.size
      { id: c[:id], kinds: kinds.map(&:to_s), args: c[:args].map(&:to_s) }
    end
    out, err, st = Open3.capture3(node, '-e', JS, wasm, "spinel_core_#{kern}", result, JSON.generate(payload))
    abort "wrapper32: node failed for #{kern}:\n#{err}" unless st.success? && err.empty?
    got = out.lines.to_h { |l| f = l.chomp.split("\t"); [f[0], f[1..]] }
    cs.each do |c|
      status, value, slot = got[c[:id]]
      want_status = STATUS.fetch(c[:status]).to_s
      ok = status == want_status &&
           (c[:status] == 'ok' ? value == c[:result] : (slot != 'slot' || value == 0x5a5a5a5a.to_s))
      if ok
        pass += 1
        puts "  pass #{c[:id]}: #{c[:why]}"
      else
        fail += 1
        puts "  FAIL #{c[:id]}: #{c[:why]} (got status #{status.inspect} value #{value.inspect}, want #{c[:status]} #{c[:result]})"
      end
    end
  end
  # Decision 0019, revised 2026-10-21: a 32-bit target has no int64 body. The
  # two fixtures that declare one are refused, at their declaration.
  %w[len_u8_64 unread_u8_64].each do |kern|
    log, st = Open3.capture2e(kernel, File.join(fix, "#{kern}.contract"), '--root', fix, '--clang', clang,
                              '--typedump', reader, '--layout', 'ptr32-i64-32long', '--int-width=32',
                              '-o', File.join(dir, "#{kern}.o"), '--', '--target=wasm32-unknown-unknown')
    if !st.success? && log.include?("#{kern}.rb:1: int-width-int64-refused") && !File.exist?(File.join(dir, "#{kern}.o"))
      pass += 1
      puts "  pass #{kern}: an int64 body with 32-bit pointers is refused at its declaration"
    else
      fail += 1
      puts "  FAIL #{kern}: an int64 body with 32-bit pointers was not refused at its declaration:\n#{log}"
    end
  end
end
puts "wrapper32: #{pass + fail} checked, #{pass} pass, #{fail} fail"
exit(fail.zero? ? 0 : 1)
