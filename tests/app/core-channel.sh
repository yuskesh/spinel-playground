#!/bin/sh
# tests/app/core-channel.sh -- decision 0027 stage 2: the `.channel` contract
# file between the FRDM-IMXRT1186's cores (tools/app/lib/core_app/core_channel.rb).
#
#   [RUBY=ruby] sh tests/app/core-channel.sh
#
# What is checked, and against what:
#
#   1. The console contract of 0027's first user (`tic u32`, `len u8`,
#      `text u8 x 119`, depth 16) reads: offsets 0, 4 and 5, a 124-byte
#      message, a 160-byte slot (8 + 124 rounded up to 32), the digest the
#      sha256 of the file's bytes, and a comment edit moves the digest. The
#      region of that one channel is a 704-byte header (lines 0-15 and the
#      channel's six, ABI version 5) and 16 slots: 3,264 bytes.
#   2. Each refusal of the file, one planted contract each (the console
#      contract with one line changed, written here), refused with its own
#      code and only that code: the version line, an unknown, repeated or
#      misplaced keyword, a missing one, a core that is not the pair's, from
#      equal to to, a depth that is not a power of two or is above 1024,
#      i64 and u64, floating point, a pointer, `offset`, another type, a
#      count below 1, unnamed padding, a bad or repeated field name, and a
#      message no slot holds.
#   3. The region of a pair's contracts: channels in name order after the
#      header; a set that does not fit is refused with its byte figures
#      (depth 1024 of the console: 1,024 x 160 = 163,840 B), and more than 64
#      channels are refused.
#   4. The application's `channel :console, contract: FILE`: the channel's
#      size and depth are the contract's and its direction is left to the
#      build. Refused, each by its code: a contract outside the repository
#      (planted here, beside the planted application), one that cannot be
#      read, one of another name, other keywords beside `contract:`, a
#      direction, and an i16 array (fixtures/build/rt1186/controls/i16s.channel;
#      the application tool has no i16 state, owner 2026-10-26).
#   5. The host simulator generated for it: 16 puts queued and the 17th
#      refused, each call counted; a len outside u8 is ARGUMENT; a get copies
#      the oldest message out field by field.
#   6. The generated put and get (channel_core.c.erb), compiled for the host
#      with fixtures/build/rt1186/channel_harness.c over a region of its own,
#      the descriptor written as the companion writes it. 0027's control 5:
#      a consumer that never checks its end leaves the producer ready, which
#      fills the ring, 16 accepted and the rest refused, each counted, the
#      consumer STOPPED. Both ends checked: 40 messages put and got, every
#      field as it went in, the counts closed. The kept failing input: a put
#      that never publishes its head leaves nothing to take. With an
#      alignment (the harness's waits) every wait is counted in line M and the
#      get's histogram; without one, none is. The longest wait's message
#      (version 5, line C's lat_max_at): with message 27 held 1,000 cycles
#      longer, line C names 27 and lat_max is its wait. Skipped, named,
#      without CLANG or LLVM_PREFIX.
#   7. The doorbell of decision 0028: the same units generated with notify
#      0x01 (MU1's GIR0), compiled with fixtures/build/rt1186/
#      doorbell_harness.c, a host word in place of the producer's GCR. An
#      empty get stores waiting = 1; a put then rings once (GIR0 set, rung
#      1) and not again while GIR0 is set; once the host clears it, the get
#      takes both and stores waiting = 0, the next empty get waiting = 1,
#      and a put rings again. The control: the put of
#      --mutate-doorbell-unrung never sets GIR0, rung stays 0, and every
#      message is still taken. A descriptor whose notify differs is refused
#      by the check, naming the flags word. Skipped as 6 is.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY=${RUBY:-ruby}
W=$(mktemp -d "${TMPDIR:-/tmp}/app-core-channel.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT INT TERM
T0=$(date +%s)

CC_CLANG="${CLANG:-${LLVM_PREFIX:+$LLVM_PREFIX/bin/clang}}" CC_ROOT="$ROOT" "$RUBY" -I"$ROOT/tools/app/lib" -rdigest -rcore_app/core_channel - "$W" <<'RUBY'
W = ARGV[0]
CC = CoreApp::CoreChannel
$pass = 0
$fail = 0
def ok(what, got, want)
  if got == want
    puts "  pass #{what}"
    $pass += 1
  else
    puts "  FAIL #{what} (got #{got.inspect}, want #{want.inspect})"
    $fail += 1
  end
end

BASE = <<~C
  core-channel 1
  # the console relay of decision 0027
  channel console
  from cm7
  to cm33
  depth 16
  field tic u32
  field len u8
  field text u8 count 119
C
def plant(name, text)
  path = File.join(W, "#{name}.channel")
  File.write(path, text)
  path
end
# the base contract with one line replaced (`from => to`), or one appended
def variant(name, from = nil, to = nil, append: nil)
  t = BASE.dup
  if from
    raise "#{name}: #{from.inspect} not in the base" unless t.include?(from)

    t = t.sub(from) { to }
  end
  t += "#{append}\n" if append
  plant(name, t)
end

puts "core-channel: 1. the console contract"
path = plant("console", BASE)
c, d = CC.parse(path)
ok("the console contract reads with no diagnostic", d.map(&:to_s), [])
ok("its fields are at 0, 4 and 5, the text an array of 119", c.fields.map { |f| [f.name, f.type, f.offset, f.count, f.array] },
   [["tic", "u32", 0, 1, false], ["len", "u8", 4, 1, false], ["text", "u8", 5, 119, true]])
ok("the message is 124 bytes and its slot 160 (8 + 124, rounded up to 32)", [c.msg_bytes, c.stride], [124, 160])
ok("from cm7, to cm33, depth 16, named console", [c.from, c.to, c.depth, c.name, c.module_name], ["cm7", "cm33", 16, "console", "Console"])
ok("the digest is the sha256 of the file's bytes", c.digest, Digest::SHA256.file(path).hexdigest)
c2, = CC.parse(variant("console-comment", "# the console relay of decision 0027", "# another comment"))
ok("a comment edit moves the digest, and nothing else", [c2.digest != c.digest, c2.msg_bytes, c2.fields.map(&:offset)], [true, 124, [0, 4, 5]])
l, e = CC.layout([c])
ok("one channel: a 704-byte header, its slots after it, 3,264 bytes in all", [e, l.header_bytes, l.offset("console"), l.slots_end], [[], 704, 704, 3264])

puts "core-channel: 2. refusals, one planted contract each"
cases = {
  "version" => [variant("version", "core-channel 1", "core-channel 2"), "channel-version", "the first line must be"],
  "unknown" => [variant("unknown", "depth 16", "depth 16\nwidth 4"), "channel-field", "unknown keyword \"width\""],
  "twice" => [variant("twice", "to cm33", "to cm33\nto cm33"), "channel-field", "to appears twice"],
  "late" => [variant("late", "depth 16\n", "", append: "depth 16"), "channel-field", "depth must come before the fields"],
  "missing" => [variant("missing", "depth 16\n", ""), "channel-field", "the contract names no depth"],
  "no-field" => [plant("no-field", BASE.lines.grep_v(/\Afield /).join), "channel-field", "the contract names no field"],
  "core" => [variant("core", "to cm33", "to cm4"), "channel-core", "cm4 is not a core of this board's pair (cm7, cm33)"],
  "same-core" => [variant("same-core", "to cm33", "to cm7"), "channel-core", "from and to are both cm7"],
  "depth" => [variant("depth", "depth 16", "depth 12"), "channel-depth", "depth 12 is not a power of two in 1..1024"],
  "depth-big" => [variant("depth-big", "depth 16", "depth 2048"), "channel-depth", "depth 2048 is not a power of two"],
  "i64" => [variant("i64", append: "field big i64"), "channel-type-int64", "field big: i64 is refused on 32-bit targets"],
  "u64" => [variant("u64", append: "field big u64"), "channel-type-int64", "field big: u64 is refused"],
  "f32" => [variant("f32", append: "field ratio f32"), "channel-type-float", "field ratio: f32: no floating point in a message"],
  "double" => [variant("double", append: "field ratio double"), "channel-type-float", "no floating point"],
  "ptr" => [variant("ptr", append: "field p ptr"), "channel-type-pointer", "field p: ptr: a message holds no pointer or address"],
  "star" => [variant("star", append: "field p u8*"), "channel-type-pointer", "field p: u8*:"],
  "offset" => [variant("offset", append: "field o offset"), "channel-type-offset", "field o: offset: in stage 2"],
  "string" => [variant("string", append: "field s string"), "channel-type", "field s: string is not a message type"],
  "count" => [variant("count", "count 119", "count 0"), "channel-count", "field text: count is an integer of at least 1"],
  "padding" => [variant("padding", append: "field pad u8\nfield after u32"), "channel-padding", "field after (u32) falls at offset 125, which is not 4-aligned; name the 3 padding byte(s)"],
  "name" => [variant("name", "field len u8", "field Len u8"), "channel-field-name", "\"Len\" is not a field name"],
  "keyword" => [variant("keyword", "field len u8", "field int u8"), "channel-field-name", "\"int\" is not a field name"],
  "dup-field" => [variant("dup-field", append: "field tic u8"), "channel-field-name", "field tic is named twice"],
  "too-big" => [variant("too-big", "count 119", "count 130500"), "channel-size", "a slot holds at most #{CC.msg_bytes_max}"],
}
cases.each do |n, (p, code, text)|
  r, ds = CC.parse(p)
  ok("#{n}: refused with #{code} alone, naming it", [r, ds.map(&:code).uniq, ds.any? { |x| x.detail.include?(text) }], [nil, [code], true])
end
ok("each refusal names the file and its line", CC.parse(cases["f32"][0])[1].map { |x| x.to_s[/\A[^:]+:\d+/] }, ["#{cases["f32"][0]}:10"])

puts "core-channel: 3. the pair's region"
mk = ->(name, depth) { CC.parse(plant("r-#{name}", BASE.sub("channel console", "channel #{name}").sub("depth 16", "depth #{depth}")))[0] }
a = mk.("zeta", 4)
b = mk.("alpha", 8)
l, e = CC.layout([a, b])
ok("two channels: a 896-byte header, then alpha's 8 slots, then zeta's 4", [e, l.header_bytes, l.index("alpha"), l.offset("alpha"), l.index("zeta"), l.offset("zeta"), l.slots_end],
   [[], 896, 0, 896, 1, 896 + 8 * 160, 896 + 12 * 160])
l, e = CC.layout([mk.("console", 1024)])
ok("depth 1024 of the console does not fit, refused with its figures", [l, e], [nil, ["the channels need 164544 bytes (header 704, console 1024 x 160 = 163840); the region is 131072"]])
l, e = CC.layout((0..64).map { |i| mk.("c#{i}", 1) })
ok("65 channels are refused", [l, e], [nil, ["65 channels; the header describes at most 64"]])

puts "core-channel: 4. the application's declaration"
require "core_app/declarations"
FIXC = File.join(ENV.fetch("CC_ROOT"), "tests/app/fixtures/build/rt1186")
def app_with(name, decl)
  path = File.join(W, "#{name}.rb")
  File.write(path, "require \"spinel/core\"\nstate :line, :u8, 119\n#{decl}\nevery_ms 100, :tick\n\ndef tick(line)\n  0\nend\n")
  path
end
def read_app(path)
  [CoreApp::Declarations.read(path), []]
rescue CoreApp::Declarations::Refused => e
  [nil, e.diagnostics]
end
console = File.join(FIXC, "channels/console.channel")
a, ds = read_app(app_with("ok", "channel :console, contract: #{console.inspect}"))
c = a&.channels&.first
ok("a contract channel reads: its size and depth the contract's, its direction left to the build", [ds, c&.size, c&.depth, c&.direction, c&.contract&.msg_bytes],
   [[], 124, 16, nil, 124])
{
  "outside" => ["channel :console, contract: \"console.channel\"", "channel-contract", "is outside the repository"],
  "unreadable" => ["channel :console, contract: #{File.join(FIXC, "channels/none.channel").inspect}", "channel-contract", "cannot read"],
  "other-name" => ["channel :relay, contract: #{console.inspect}", "channel-name", "the application names channel :relay; the contract is channel console"],
  "keywords" => ["channel :console, contract: #{console.inspect}, depth: 4", "declaration", "a contract channel takes its size and depth from the contract"],
  "direction" => ["channel :console, :out, contract: #{console.inspect}", "declaration", "takes the name alone"],
  "i16-array" => ["channel :console, contract: #{File.join(FIXC, "controls/i16s.channel").inspect}", "channel-type", "field samples: i16 arrays need i16 state"],
}.each do |n, (decl, code, text)|
  if n == "outside"
    File.write(File.join(W, "console.channel"), File.read(console))
  end
  r, ds = read_app(app_with(n, decl))
  ok("#{n}: refused with #{code}, naming it", [r, ds.map(&:code).uniq, ds.any? { |x| x.detail.include?(text) }], [nil, [code], true])
end

puts "core-channel: 5. the host simulator"
require "core_app/channels"
require "core_app/checked"
a, = read_app(app_with("sim", "channel :console, contract: #{console.inspect}"))
ch = a.channels.first
ch.direction = "out"
src = CoreApp::Channels.host_source(a)
ok("the generated simulator is the typed one, its put taking the fields", src.include?("CoreChannelSim.new(\"console\", \"out\", 16, [[\"tic\", \"u32\", nil], [\"len\", \"u8\", nil], [\"text\", \"u8\", 119]])") &&
   src.include?("def self.put(tic, len, text) = SIM.put(tic, len, text)"), true)
eval(src) # rubocop:disable Security/Eval -- the generated module, as the host runner loads it
sim = Console::SIM
text = CoreApp::Buffer.new("text", "u8", 119)
"hi\n".bytes.each_with_index { |b, i| text[i] = b }
puts_ok = (0...17).map { |t| Console.put(t, 3, text) }
ok("16 puts are queued and the 17th refused, each counted", [puts_ok.count(1), puts_ok.last, sim.attempted, sim.accepted, sim.refused], [16, 0, 17, 16, 1])
ok("a len outside u8 is ARGUMENT, the guard's", (begin; Console.put(0, 256, text); :none; rescue CoreApp::Checked::Failure => e; e.message; end), "argument")
rt = CoreApp::Buffer.new("rx_tic", "u32", 1)
rl = CoreApp::Buffer.new("rx_len", "u8", 1)
rx = CoreApp::Buffer.new("rx_text", "u8", 119)
got = sim.get(rt, rl, rx)
ok("the oldest message comes out field by field", [got, rt.cells[0], rl.cells[0], rx.cells[0, 3].pack("C*"), sim.taken], [1, 0, 3, "hi\n", 1])

puts "core-channel: 6. the generated put and get, on a host region"
cc = ENV["CC_CLANG"].to_s
if cc.empty? || !File.executable?(cc)
  puts "  skip the generated C on the host (no CLANG or LLVM_PREFIX): 7 checks"
else
  harness = File.join(FIXC, "channel_harness.c")
  ends = %w[out in].to_h do |dir|
    a, = read_app(app_with("end-#{dir}", "channel :console, contract: #{console.inspect}"))
    ch = a.channels.first
    ch.direction = dir
    l, = CC.layout([ch.contract])
    ch.ring = [l.index("console"), l.offset("console")]
    d = File.join(W, "c-#{dir}")
    Dir.mkdir(d)
    CoreApp::Channels.contract_files(ch).each { |n, t| File.write(File.join(d, n), t) }
    k = ch.contract
    words = [k.digest[0, 8].to_i(16), k.digest[8, 8].to_i(16), 1 | (2 << 8) | (1 << 16), k.depth, k.stride, k.msg_bytes, l.offset("console"), 0]
    File.write(File.join(d, "d_words.h"), "static const uint32_t d_words[8] = { #{words.map { |x| format('0x%08xu', x) }.join(', ')} };\n")
    [dir, d]
  end
  base = ["-std=c11", "-DSPC_RING_HOST", "-DSPC_RING_M7_BASE=((uintptr_t)spc_host_region)", "-DSPC_RING_M33_BASE=((uintptr_t)spc_host_region)",
          "-include", "stdint.h", "-I#{File.join(ENV.fetch('CC_ROOT'), 'tools/app')}"]
  File.write(File.join(W, "region.h"), "extern uint32_t spc_host_region[];\n")
  base += ["-include", File.join(W, "region.h")]
  # ring_abi.h's lines against core_channel.rb's: the byte after channel n-1's
  # line F is header_bytes(n), and line F's spare words start at word 4
  File.write(File.join(W, "lines.c"), "#include <stdio.h>\n#include \"ring/ring_abi.h\"\n" \
             "int main(void) { printf(\"%u %u %u %u %u\\n\", SPC_RING_ABI_VERSION, (SPC_CH_F(0u) + 8u) * 4u, (SPC_CH_F(1u) + 8u) * 4u, SPC_CH_F(0u) - SPC_CH_E(0u), SPC_CH_F_SPARE); return 0; }\n")
  lines = system(cc, *base, File.join(W, "lines.c"), "-o", File.join(W, "lines")) && IO.popen([File.join(W, "lines")], &:read).split.map(&:to_i)
  ok("ring_abi.h agrees with core_channel.rb: version 5, six lines a channel, line F after E with its spare words from word 4",
     lines, [5, CC.header_bytes(1), CC.header_bytes(2), 8, 4])
  bin = File.join(W, "harness")
  built = system(cc, *base, "-I#{ends['out']}", "-c", File.join(ends["out"], "channel_console_put.c"), "-o", "#{bin}-put.o") &&
          system(cc, *base, "-I#{ends['in']}", "-Dspc_channel_console_check=spc_channel_console_check_get", "-c",
                 File.join(ends["in"], "channel_console_get.c"), "-o", "#{bin}-get.o") &&
          system(cc, *base, "-I#{ends['out']}", harness, "#{bin}-put.o", "#{bin}-get.o", "-o", bin)
  ok("the producer's and the consumer's generated units build for the host, with the harness", built, true)
  if built
    stopped = IO.popen([bin, "stopped"], &:read)
    ok("control 5: the consumer never checks its end, the producer is ready and fills the ring: 16 accepted, the rest refused, each counted",
       stopped.lines.map(&:strip), ["stopped accepted-first-16 16 accepted-after 0",
                                    "stopped P head 16 attempted 20 accepted 16 refused 4 C tail 0 state 0 taken 0"])
    taking = IO.popen([bin, "taking"], &:read)
    ok("both ends checked: every field comes out as it went in, and the counts close", taking.lines.map(&:strip),
       ["taking fields ok", "taking P head 40 attempted 40 accepted 40 refused 0 C tail 40 state 1 taken 40", "waits n 0 min 0 max 0 sum 0 bucket3 0", "longest at 0"])
    waits = IO.popen([bin, "waits"], &:read)
    ok("with an alignment, every wait is counted in line M and the histogram: 40 of 13 cycles (decision 0027 §6)", waits.lines.grep(/^waits /).last.to_s.strip,
       "waits n 40 min 13 max 13 sum 520 bucket3 40")
    longest = IO.popen([bin, "longest"], &:read)
    ok("the longest wait's message (version 5): message 27, held 1,000 cycles longer, is the one line C names, and lat_max is its wait",
       longest.lines.grep(/^(waits|longest) /).map(&:strip), ["waits n 40 min 13 max 1013 sum 1520 bucket3 39", "longest at 27"])
    ok("  and the kept failing input: a put that never publishes its head leaves nothing to take",
       begin
         put = File.read(File.join(ends["out"], "channel_console_put.c"))
         bad = put.sub("\tspc_ring_store(SPC_W, SPC_CH_P(SPC_I) + SPC_CH_P_HEAD, spc_head);\n", "")
         File.write(File.join(ends["out"], "bad_put.c"), bad)
         bad != put && system(cc, *base, "-I#{ends['out']}", "-c", File.join(ends["out"], "bad_put.c"), "-o", "#{bin}-bad.o") &&
           system(cc, *base, "-I#{ends['out']}", harness, "#{bin}-bad.o", "#{bin}-get.o", "-o", "#{bin}-bad") &&
           IO.popen(["#{bin}-bad", "taking"], &:read).lines.first.to_s.strip
       end, "taking fields differ")
  end
end

puts "core-channel: 7. the doorbell of decision 0028, on a host region"
if cc.empty? || !File.executable?(cc)
  puts "  skip the doorbell's generated C on the host (no CLANG or LLVM_PREFIX): 4 checks"
else
  bell_run = lambda do |tag, unrung|
    units = %w[out in].to_h do |dir|
      a, = read_app(app_with("bell-#{tag}-#{dir}", "channel :console, contract: #{console.inspect}"))
      ch = a.channels.first
      ch.direction = dir
      l, = CC.layout([ch.contract])
      ch.ring = [l.index("console"), l.offset("console")]
      ch.doorbell = { notify: 0x01, want: 0x01, gi: 0, gcr: 0x4423_0114, unrung: dir == "out" && unrung }
      d = File.join(W, "b-#{tag}-#{dir}")
      Dir.mkdir(d)
      CoreApp::Channels.contract_files(ch).each { |n, t| File.write(File.join(d, n), t) }
      k = ch.contract
      words = [k.digest[0, 8].to_i(16), k.digest[8, 8].to_i(16), 1 | (2 << 8) | (1 << 16) | (0x01 << 24), k.depth, k.stride, k.msg_bytes, l.offset("console"), 0]
      File.write(File.join(d, "d_words.h"), "static const uint32_t d_words[8] = { #{words.map { |x| format('0x%08xu', x) }.join(', ')} };\n")
      [dir, d]
    end
    File.write(File.join(W, "bell-region.h"), "extern uint32_t spc_host_region[];\nextern volatile uint32_t spc_host_gcr;\n")
    bbase = ["-std=c11", "-DSPC_RING_HOST", "-DSPC_RING_M7_BASE=((uintptr_t)spc_host_region)", "-DSPC_RING_M33_BASE=((uintptr_t)spc_host_region)",
             "-DSPC_DOORBELL_GCR=(&spc_host_gcr)", "-include", "stdint.h", "-include", File.join(W, "bell-region.h"),
             "-I#{File.join(ENV.fetch('CC_ROOT'), 'tools/app')}"]
    bbin = File.join(W, "bell-#{tag}")
    ok = system(cc, *bbase, "-I#{units['out']}", "-c", File.join(units["out"], "channel_console_put.c"), "-o", "#{bbin}-put.o") &&
         system(cc, *bbase, "-I#{units['in']}", "-Dspc_channel_console_check=spc_channel_console_check_get", "-c",
                File.join(units["in"], "channel_console_get.c"), "-o", "#{bbin}-get.o") &&
         system(cc, *bbase, "-I#{units['out']}", File.join(FIXC, "doorbell_harness.c"), "#{bbin}-put.o", "#{bbin}-get.o", "-o", bbin)
    ok ? bbin : nil
  end
  bin = bell_run.("ring", false)
  ubin = bell_run.("unrung", true)
  ok("the doorbell's units build for the host, with its harness, rung and unrung", [!bin.nil?, !ubin.nil?], [true, true])
  if bin && ubin
    ok("an empty get waits; a put rings once, not again while GIR0 is set; taking clears waiting, the next empty get sets it, and a put rings again",
       IO.popen([bin, "bell"], &:read).lines.map(&:strip),
       ["bell get-empty 0 waiting 1", "bell put rung 1 gcr 1", "bell put-pending rung 1 gcr 1",
        "bell take 1 waiting 0, 1, then empty 0 waiting 1", "bell put rung 2 gcr 1 taken 2"])
    ok("control --mutate-doorbell-unrung: the put never sets GIR0 and rung stays 0, and every message is still taken",
       IO.popen([ubin, "unrung"], &:read).lines.map(&:strip),
       ["unrung get-empty 0 waiting 1", "unrung put rung 0 gcr 0", "unrung put-pending rung 0 gcr 0",
        "unrung take 1 waiting 0, 1, then empty 0 waiting 1", "unrung put rung 0 gcr 0 taken 2"])
    ok("a descriptor whose notify differs is refused by the check, naming the flags word (word 130, plus 1)",
       IO.popen([bin, "notify"], &:read).strip, "notify check 131")
  end
end

puts "core-channel: #{$pass + $fail} checked, #{$pass} pass, #{$fail} fail"
exit($fail.zero? ? 0 : 1)
RUBY
rc=$?
echo "core-channel: $(( $(date +%s) - T0 )) s"
exit "$rc"
