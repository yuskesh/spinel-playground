# P012 S2 前半: decoder のオフライン検証 (E438)
#
# tests/payload_logs.textproto を protoc --encode した .bin を食わせ、
# 既知の期待値 (2 resource / 3 records) と突き合わせる。
#
#   sh scripts/gen-test-payload.sh
#   /work/third_party/spinel/bin/spinel s2_decode_check.rb
#   ./s2_decode_check tests/payload_logs.bin

require_relative "../lib/decoder"

def die(msg)
  puts "S2-decode FAIL: " + msg
  exit 1
end

path = ARGV.length >= 1 ? ARGV[0] : "tests/payload_logs.bin"
payload = File.binread(path)
die("payload is empty: " + path) if payload.length == 0

d = OtlpLogsDecoder.new
n = d.decode(payload)

puts "payload bytes: #{payload.length}"
puts "decoded records: #{n} (errors=#{d.errors})"
i = 0
while i < n
  puts "  ts=#{d.ts[i]} sev=#{d.severity[i]}(#{d.severity_text[i]}) svc=#{d.service[i]} body=#{d.body[i]}"
  i += 1
end

# 期待値 (tests/payload_logs.textproto と一致させること)
die("expected 3 records, got #{n}") unless n == 3
die("decode errors: #{d.errors}") unless d.errors == 0
die("r0 mismatch") unless d.ts[0] == 1700000001000000000 && d.severity[0] == 9 &&
                          d.service[0] == "api" && d.body[0] == "request ok"
die("r1 mismatch") unless d.ts[1] == 1700000002000000000 && d.severity[1] == 17 &&
                          d.severity_text[1] == "ERROR" && d.service[1] == "api" &&
                          d.body[1] == "connection timeout"
die("r2 mismatch") unless d.ts[2] == 1700000003000000000 && d.severity[2] == 21 &&
                          d.service[2] == "checkout" && d.body[2] == "payment failed"
puts "S2-decode OK"
