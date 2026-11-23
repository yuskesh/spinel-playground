# P012 Phase 2: Thread (M:N) scaling ベンチ (E443)
#
# decode (allocation-heavy な実 workload) を N thread に分け、SPINEL_WORKERS との
# 組み合わせで scaling を測る。チェックリスト ⚠「Thread 成熟度」の実測。
#   SPINEL_WORKERS=4 ./s7_thread_bench tests/payload_bench.bin 4 500

require_relative "../lib/decoder"

path     = ARGV.length >= 1 ? ARGV[0] : "tests/payload_bench.bin"
nthreads = ARGV.length >= 2 ? ARGV[1].to_i : 4
iters    = ARGV.length >= 3 ? ARGV[2].to_i : 500

payload = File.binread(path)

t0 = Time.now.to_f
ths = []
k = 0
while k < nthreads
  ths << Thread.new do
    local_total = 0
    local_err = 0
    j = 0
    while j < iters
      d = OtlpLogsDecoder.new
      local_total += d.decode(payload)
      local_err += d.errors
      j += 1
    end
    [local_total, local_err]
  end
  k += 1
end

total = 0
errs = 0
ths.each do |t|
  r = t.value
  total += r[0]
  errs += r[1]
end
dt = Time.now.to_f - t0

if errs > 0
  puts "E443 FAIL: decode errors=#{errs} under threads (race?)"
  exit 1
end
puts "threads=#{nthreads} iters_each=#{iters} records=#{total} sec=#{(dt * 1000).to_i / 1000.0} rec_per_s=#{(total / dt).to_i}"
