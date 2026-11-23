# P012 S2 後半: OTLP/HTTP logs receiver (E438)
#
# POST /v1/logs (application/x-protobuf) を受け、手書き decoder (otlp_logs_decode.rb)
# で内部 schema (列指向) に積む。S2 では永続化しない (S3 で Parquet へ)。
#
# ビルド (sp_net_rl_* は spinel-ebpf の externalized shim なので bin/spinel-ebpf を使う):
#   ruby /work/bin/spinel-ebpf compile examples/o11y_backend/s2_otlp_server.rb \
#        --native-only --build -o examples/o11y_backend/build
# 実行:
#   ./build/s2_otlp_server <port> <max_reqs>   # max_reqs=0 で無限、>0 なら自動終了 (テスト用)
# クライアント:
#   curl -sS -X POST --data-binary @tests/payload_logs.bin \
#        -H 'Content-Type: application/x-protobuf' http://127.0.0.1:4318/v1/logs

require_relative "../lib/decoder"

module Net
  ffi_func :sp_net_listen,       [:int, :int], :int
  ffi_func :sp_net_accept,       [:int],       :int     # TCP_NODELAY は upstream が自動設定
  ffi_func :sp_net_read_line,    [:int],       :str
  ffi_func :sp_net_write_str,    [:int, :str], :int
  ffi_func :sp_net_rl_recv_some, [:int, :int], :binstr  # read_line バッファ drain 済の NUL 安全読み (E187/E193)
  ffi_func :sp_net_rl_close,     [:int],       :int
end

def respond(fd, status, body)
  txt = "HTTP/1.1 #{status}\r\n" \
        "Content-Type: application/x-protobuf\r\n" \
        "Content-Length: #{body.length}\r\n" \
        "Connection: close\r\n\r\n" + body
  Net.sp_net_write_str(fd, txt)
end

port     = ARGV.length >= 1 ? ARGV[0].to_i : 4318
max_reqs = ARGV.length >= 2 ? ARGV[1].to_i : 0

lfd = Net.sp_net_listen(port, 64)
if lfd < 0
  puts "s2_otlp_server: listen failed on port #{port} (bind error — port in use?)"
  exit 1
end
puts "s2_otlp_server: listening on #{port} (max_reqs=#{max_reqs})"

store = OtlpLogsDecoder.new
served = 0

while max_reqs == 0 || served < max_reqs
  fd = Net.sp_net_accept(lfd)
  next if fd < 0

  req = Net.sp_net_read_line(fd)
  clen = 0
  while true
    h = Net.sp_net_read_line(fd)
    break if h == ""
    if h.downcase.start_with?("content-length:")
      clen = h[15..-1].strip.to_i
    end
  end

  body = ""
  while body.length < clen
    chunk = Net.sp_net_rl_recv_some(fd, clen - body.length)
    break if chunk.length == 0
    body = body + chunk
  end

  if req.start_with?("POST /v1/logs") && body.length == clen && clen > 0
    e0 = store.errors        # errors は累積カウンタ — このリクエスト分だけ差分で見る
    n = store.decode(body)
    if store.errors > e0
      # 壊れた protobuf: 部分取り込みを黙って成功にしない (fail loud)
      puts "reject: decode errors=#{store.errors - e0} after #{n} records"
      respond(fd, "400 Bad Request", "")
    else
      puts "ingest: +#{n} records (total=#{store.ts.length})"
      respond(fd, "200 OK", "")
    end
  elsif req.start_with?("GET /healthz")
    respond(fd, "200 OK", "")
  elsif req.start_with?("POST /v1/logs")
    puts "reject: body #{body.length}B != content-length #{clen}B"
    respond(fd, "400 Bad Request", "")
  else
    respond(fd, "404 Not Found", "")
  end
  Net.sp_net_rl_close(fd)
  served += 1
end

# テスト用の自動終了時に中身を検証できるよう最終状態を出す
puts "final: records=#{store.ts.length} services=#{store.service.uniq.length}"
i = 0
while i < store.ts.length
  puts "  ts=#{store.ts[i]} sev=#{store.severity[i]} svc=#{store.service[i]} body=#{store.body[i]}"
  i += 1
end
