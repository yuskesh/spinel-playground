# 共有: HTTP/1.x の読み書き (ingestd / queryd で複製されていたものを E451 で一本化)
#
# モデルは M003ka/M003ev と同じ「1 呼び出し = 1 リクエスト」:
#   head = http_read_head(fd)      # nil なら接続終了 (EOF)
#   body = http_read_body(fd, head.clen)
#   http_respond(fd, "200 OK", "application/json", body, head.keep)
# keepalive の判断 (HTTP/1.1 既定 persistent / 1.0 は Connection ヘッダ) も head が持つ。

class HttpHead
  attr_reader :line, :clen, :keep, :encoding

  def initialize(line, clen, keep, encoding)
    @line = line
    @clen = clen
    @keep = keep
    @encoding = encoding   # Content-Encoding ("" = identity)、E452
  end
end

# リクエスト行 + ヘッダを読む。接続が閉じていれば nil。
def http_read_head(fd)
  line = Net.sp_net_read_line(fd)
  return nil if line.length == 0
  clen = 0
  keep = false
  encoding = ""
  loop do
    h = Net.sp_net_read_line(fd)
    break if h == ""
    hl = h.downcase
    clen = h[15..-1].strip.to_i if hl.start_with?("content-length:")
    keep = true if hl == "connection: keep-alive"
    encoding = hl[17..-1].strip if hl.start_with?("content-encoding:")
  end
  keep = true if line.end_with?("HTTP/1.1")
  HttpHead.new(line, clen, keep, encoding)
end

# Content-Length ぶんの body を binary-safe に読む (足りなければ得られた分を返す —
# 長さ検証は呼び手の責務。E438: 不一致は 400 で loud に)。
def http_read_body(fd, clen)
  body = ""
  while body.length < clen
    chunk = Net.sp_net_rl_recv_some(fd, clen - body.length)
    break if chunk.length == 0
    body = body + chunk
  end
  body
end

def http_respond(fd, status, ctype, body, keep)
  txt = "HTTP/1.1 #{status}\r\n" \
        "Content-Type: #{ctype}\r\n" \
        "Content-Length: #{body.length}\r\n"
  txt = txt + "Connection: Keep-Alive\r\n" if keep
  Net.sp_net_write_str(fd, txt + "\r\n" + body)
end

def http_json(fd, status, json, keep)
  http_respond(fd, status, "application/json", json, keep)
end

def http_json_error(fd, status, msg, keep)
  http_json(fd, status, "{\"error\":\"" + json_escape(msg) + "\"}", keep)
end

def json_escape(s)
  out = ""
  i = 0
  while i < s.length
    c = s[i]
    if c == "\"" || c == "\\"
      out = out + "\\" + c
    elsif c == "\n"
      out = out + "\\n"
    elsif c == "\r"
      out = out + "\\r"
    elsif c == "\t"
      out = out + "\\t"
    else
      out = out + c
    end
    i += 1
  end
  out
end

# ---- TLS 変種 (E453): 同じ意味論を TLS.otls_* で。plain 側と対で保守する ----

def https_read_head(fd)
  line = TLS.otls_read_line(fd)
  return nil if line.length == 0
  clen = 0
  keep = false
  encoding = ""
  loop do
    h = TLS.otls_read_line(fd)
    break if h == ""
    hl = h.downcase
    clen = h[15..-1].strip.to_i if hl.start_with?("content-length:")
    keep = true if hl == "connection: keep-alive"
    encoding = hl[17..-1].strip if hl.start_with?("content-encoding:")
  end
  keep = true if line.end_with?("HTTP/1.1")
  HttpHead.new(line, clen, keep, encoding)
end

def https_read_body(fd, clen)
  body = ""
  while body.length < clen
    chunk = TLS.otls_recv_some(fd, clen - body.length)
    break if chunk.length == 0
    body = body + chunk
  end
  body
end

def https_respond(fd, status, ctype, body, keep)
  txt = "HTTP/1.1 #{status}\r\n" \
        "Content-Type: #{ctype}\r\n" \
        "Content-Length: #{body.length}\r\n"
  txt = txt + "Connection: Keep-Alive\r\n" if keep
  txt = txt + "\r\n" + body
  TLS.otls_write_bytes(fd, txt, txt.length)
end

def https_json(fd, status, json, keep)
  https_respond(fd, status, "application/json", json, keep)
end

def https_json_error(fd, status, msg, keep)
  https_json(fd, status, "{\"error\":\"" + json_escape(msg) + "\"}", keep)
end
