# P012 S6: decoder マイクロベンチ (E442)
#   ./s6_decode_bench tests/payload_bench.bin 1000
require_relative "../lib/decoder"

path  = ARGV.length >= 1 ? ARGV[0] : "tests/payload_bench.bin"
iters = ARGV.length >= 2 ? ARGV[1].to_i : 1000

payload = File.binread(path)
t0 = Time.now.to_f
total = 0
i = 0
while i < iters
  d = OtlpLogsDecoder.new
  total += d.decode(payload)
  i += 1
end
dt = Time.now.to_f - t0
puts "payload=#{payload.length}B iters=#{iters} records=#{total}"
puts "sec=#{dt} rec_per_s=#{(total / dt).to_i} MB_per_s=#{(payload.length * iters / dt / 1000000 * 100).to_i / 100.0}"
