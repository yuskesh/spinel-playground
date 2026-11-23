# examples/r2-d1 -- an asset store. One Ruby program uses R2 (bytes) and D1 (an
# SQL index) together.
#
#   GET  /                 the upload form and the list (a SELECT on D1)
#   POST /upload?name=..&type=..   the request body is the file's contents as they are
#                          -> put into R2, one row inserted into D1
#   GET  /a/<id>           returns the bytes from R2 **as they are** (an image shows in the browser)
#   POST /a/<id>/delete    deletes from both R2 and D1
#   GET  /orphans          checks R2's list against D1's index
#
# Combining the two is not decoration. **R2 holds the bytes; D1 holds the facts
#   about the bytes.** Only R2 can "return one png", and only D1 can do "the 10
#   largest" or "search by name". The KV version (examples/mvc-blog) kept its
#   index in a string of its own because KV has no way to be queried. Here the
#   index becomes SQL.
#
# Values are **always passed as placeholders**. Cloudflare::D1 has no method
#   that takes SQL and values together, so the route of building SQL by string
#   concatenation does not exist in the first place.
require "cloudflare/r2"
require "cloudflare/d1"

BUCKET = ENV["SPINEL_HOST_R2"].to_s.split(",")[0].to_s.strip
DB = ENV["SPINEL_HOST_D1"].to_s.split(",")[0].to_s.strip
MAX_UPLOAD = 1024 * 1024

# ---- small helpers -----------------------------------------------------------
def h(s)
  s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;")
end

# A query string into a Hash{String=>String}. Each key keeps one value (the last wins).
def parse_query(raw)
  out = {}
  raw.to_s.split("&").each do |pair|
    next if pair.empty?
    i = pair.index("=")
    if i.nil?
      out[url_decode(pair)] = ""
    else
      out[url_decode(pair[0, i])] = url_decode(pair[(i + 1), pair.length - i - 1])
    end
  end
  out
end

def url_decode(s)
  out = ""
  str = s.to_s.gsub("+", " ")
  i = 0
  while i < str.bytesize
    b = str.getbyte(i)
    if b == 37 && i + 2 < str.bytesize   # '%'
      hexs = str[(i + 1), 2].to_s
      out += hexs.to_i(16).chr
      i += 3
    else
      out += b.chr
      i += 1
    end
  end
  out
end

def respond(status, content_type, body)
  $stdout.write("Status: " + status.to_s + "\n")
  $stdout.write("Content-Type: " + content_type + "\n")
  $stdout.write("\n")
  $stdout.write(body)
end

def redirect(to)
  $stdout.write("Status: 303\nLocation: " + to + "\n\n")
end

def human(n)
  return n.to_s + " B" if n < 1024
  return (n / 1024).to_s + " KB" if n < 1024 * 1024
  (n / (1024 * 1024)).to_s + " MB"
end

# ---- schema ------------------------------------------------------------------
# This runs on every request, but with IF NOT EXISTS it does nothing after the first.
# In production, running a migration once at deploy time is better (see the README).
def ensure_schema
  Cloudflare::D1.exec(DB,
    "CREATE TABLE IF NOT EXISTS assets (" +
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
    "name TEXT NOT NULL, " +
    "content_type TEXT NOT NULL, " +
    "size INTEGER NOT NULL, " +
    "created_at INTEGER NOT NULL, " +
    "r2_key TEXT NOT NULL UNIQUE)")
end

def r2_key_for(id)
  "assets/" + id.to_s
end

# ---- pages -------------------------------------------------------------------
def page_index
  rows = Cloudflare::D1.exec(DB,
    "SELECT id, name, content_type, size, created_at FROM assets ORDER BY id DESC LIMIT 100")
  total = Cloudflare::D1.exec(DB,
    "SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM assets").first

  body = "<!doctype html><html lang=\"ja\"><head><meta charset=\"utf-8\">"
  body += "<title>Spinel Asset Vault (R2 + D1)</title>"
  body += "<style>body{font-family:system-ui,sans-serif;max-width:52rem;margin:2rem auto;padding:0 1rem;line-height:1.6}"
  body += "table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:.4rem;text-align:left}"
  body += "code{background:#f4f4f4;padding:.1rem .3rem;border-radius:3px}"
  body += ".m{color:#666;font-size:.9rem}</style></head><body>"
  body += "<h1>Asset Vault</h1>"
  body += "<p class=\"m\">Ruby (Spinel &rarr; wasm32) on Cloudflare Workers. "
  body += "bytes in <b>R2</b> (<code>" + h(BUCKET) + "</code>), index in <b>D1</b> (<code>" + h(DB) + "</code>).</p>"

  body += "<h2>Upload</h2>"
  body += "<p><input type=\"file\" id=\"f\"> <button id=\"go\">upload</button> <span id=\"s\" class=\"m\"></span></p>"
  # POST the raw body. Instead of parsing multipart/form-data, the body is
  # "the file itself": a form this target's Ruby can write in a few lines, and
  # a plain demonstration of byte transparency.
  body += "<script>document.getElementById('go').onclick=async()=>{" +
          "const f=document.getElementById('f').files[0];if(!f)return;" +
          "document.getElementById('s').textContent='uploading '+f.size+' bytes...';" +
          "const q='?name='+encodeURIComponent(f.name)+'&type='+encodeURIComponent(f.type||'application/octet-stream');" +
          "const r=await fetch('/upload'+q,{method:'POST',body:f});" +
          "document.getElementById('s').textContent=r.ok?'ok':('failed: '+await r.text());" +
          "if(r.ok)location.reload();};</script>"

  body += "<h2>Objects <span class=\"m\">(" + total.int("n").to_s + " rows, "
  body += human(total.int("bytes")) + ")</span></h2>"
  if rows.empty?
    body += "<p class=\"m\">nothing here yet.</p>"
  else
    body += "<table><tr><th>id</th><th>name</th><th>type</th><th>size</th><th></th></tr>"
    rows.each_row do |row|
      id = row.int("id")
      body += "<tr><td>" + id.to_s + "</td>"
      body += "<td><a href=\"/a/" + id.to_s + "\">" + h(row.str("name")) + "</a></td>"
      body += "<td class=\"m\">" + h(row.str("content_type")) + "</td>"
      body += "<td>" + human(row.int("size")) + "</td>"
      body += "<td><form method=\"post\" action=\"/a/" + id.to_s + "/delete\">"
      body += "<button>delete</button></form></td></tr>"
    end
    body += "</table>"
  end
  body += "<p class=\"m\"><a href=\"/orphans\">consistency check</a> &mdash; R2 list vs the D1 index</p>"
  body += "</body></html>"
  respond(200, "text/html; charset=utf-8", body)
end

# Upload. **There are 3 steps, and each can fail.**
# Make a row in D1 -> put the contents in R2 -> write the R2 key back into the row.
# This bridge has no D1 transactions (v0), so if R2 fails we write the
# **compensation** that deletes the row ourselves. Stating the missing feature
# here is more honest than hiding it.
def do_upload(query, body)
  name = query["name"].to_s
  name = "unnamed" if name.empty?
  content_type = query["type"].to_s
  content_type = "application/octet-stream" if content_type.empty?

  if body.bytesize == 0
    respond(400, "text/plain; charset=utf-8", "empty body\n")
    return
  end
  if body.bytesize > MAX_UPLOAD
    respond(413, "text/plain; charset=utf-8",
            "too large: " + body.bytesize.to_s + " > " + MAX_UPLOAD.to_s + "\n")
    return
  end

  result = Cloudflare::D1.prepare(DB,
    "INSERT INTO assets (name, content_type, size, created_at, r2_key) VALUES (?, ?, ?, ?, ?)")
    .text(name).text(content_type).int(body.bytesize).int(Time.now.to_i).text("pending").all
  id = result.last_row_id
  key = r2_key_for(id)

  begin
    Cloudflare::R2.put(BUCKET, key, body, content_type: content_type)
  rescue IOError => e
    Cloudflare::D1.prepare(DB, "DELETE FROM assets WHERE id = ?").int(id).run
    respond(502, "text/plain; charset=utf-8", "R2 refused the object: " + e.message + "\n")
    return
  end

  Cloudflare::D1.prepare(DB, "UPDATE assets SET r2_key = ? WHERE id = ?").text(key).int(id).run
  redirect("/")
end

# Download. **This is the demonstration of byte transparency.** The bytes from R2
# go to $stdout untouched, and worker.mjs makes them the Response as they are.
def do_show(id)
  row = Cloudflare::D1.prepare(DB,
    "SELECT name, content_type, r2_key FROM assets WHERE id = ?").int(id).first
  if row.nil?
    respond(404, "text/plain; charset=utf-8", "no such asset\n")
    return
  end
  bytes = Cloudflare::R2.get(BUCKET, row.str("r2_key"))
  if bytes.nil?
    # In the index but no contents. An inconsistency we can state only because
    # "absent" and "empty" are told apart.
    respond(410, "text/plain; charset=utf-8",
            "the index has this row but R2 does not have the object\n")
    return
  end
  # `.to_s` is not decoration. **When bytes are passed to `IO#write`, the value's
  #   inferred type must be `String`.** `bytes` is `String | nil`
  #   (= TY_POLY), so passed as it is, `respond`'s third argument becomes poly and
  #   `$stdout.write` gives an answer **cut at the first NUL**: no exception is
  #   raised, and a 67-byte PNG comes back as 8 bytes. It happens the same way on
  #   native and on wasm, so it is not specific to this target but a property of
  #   Spinel's poly route for `IO#write` (measured; a "quietly wrong answer").
  respond(200, row.str("content_type"), bytes.to_s)
end

def do_delete(id)
  row = Cloudflare::D1.prepare(DB, "SELECT r2_key FROM assets WHERE id = ?").int(id).first
  unless row.nil?
    # R2's delete is idempotent, so deleting it first breaks nothing even if the row stays.
    Cloudflare::R2.delete(BUCKET, row.str("r2_key"))
    Cloudflare::D1.prepare(DB, "DELETE FROM assets WHERE id = ?").int(id).run
  end
  redirect("/")
end

# Check R2's contents against D1's index. **R2.list returns one page at a time**, so
# paging is the caller's job (a hidden loop = a hidden subrequest).
def do_orphans
  out = "R2 objects (prefix assets/)\n"
  seen_keys = []
  cursor = ""
  pages = 0
  loop do
    page = Cloudflare::R2.list(BUCKET, prefix: "assets/", limit: 200, cursor: cursor)
    i = 0
    while i < page.objects.length
      o = page.objects[i]
      seen_keys << o.key
      out += "  " + o.key + "  " + o.size.to_s + " B  " + o.content_type + "\n"
      i += 1
    end
    pages += 1
    break unless page.truncated?
    cursor = page.cursor
    break if pages >= 10
  end
  out += "  (" + seen_keys.length.to_s + " objects in " + pages.to_s + " page(s))\n\n"

  out += "D1 index\n"
  indexed = []
  rows = Cloudflare::D1.exec(DB, "SELECT id, r2_key, size FROM assets ORDER BY id")
  rows.each_row do |row|
    indexed << row.str("r2_key")
    out += "  " + row.str("r2_key") + "  " + row.int("size").to_s + " B\n"
  end
  out += "  (" + indexed.length.to_s + " rows)\n\n"

  out += "in R2 but not in the index:\n"
  n = 0
  i = 0
  while i < seen_keys.length
    unless indexed.include?(seen_keys[i])
      out += "  " + seen_keys[i] + "\n"
      n += 1
    end
    i += 1
  end
  out += "  (none)\n" if n == 0

  out += "in the index but not in R2:\n"
  n = 0
  i = 0
  while i < indexed.length
    unless seen_keys.include?(indexed[i])
      out += "  " + indexed[i] + "\n"
      n += 1
    end
    i += 1
  end
  out += "  (none)\n" if n == 0
  respond(200, "text/plain; charset=utf-8", out)
end

# ---- one request = one process -----------------------------------------------
path = ARGV[0].to_s
query = parse_query(ARGV[1])
method = ENV["REQUEST_METHOD"].to_s

if ENV["SPINEL_CGI_HEADERS"].to_s != "1"
  $stderr.puts "r2-d1: SPINEL_CGI_HEADERS is not 1 -- statuses and redirects come back as body text."
end

begin
  if BUCKET.empty? || DB.empty?
    respond(500, "text/plain; charset=utf-8",
            "no bucket or database is reachable.\n" +
            "wrangler.toml must bind them AND name them in " +
            "SPINEL_HOST_R2 / SPINEL_HOST_D1 (reachability is an explicit decision).\n")
  else
    ensure_schema
    if path == "/" || path.empty?
      page_index
    elsif path == "/upload" && method == "POST"
      do_upload(query, $stdin.read.to_s)
    elsif path == "/orphans"
      do_orphans
    elsif path.start_with?("/a/") && path.end_with?("/delete") && method == "POST"
      do_delete(path[3, path.length - 10].to_i)
    elsif path.start_with?("/a/")
      do_show(path[3, path.length - 3].to_i)
    else
      respond(404, "text/plain; charset=utf-8", "not found: " + path + "\n")
    end
  end
rescue NotImplementedError => e
  # Raised by the raise policy (a feature this target does not have).
  # It is not a StandardError, so `rescue => e` does not catch it.
  respond(501, "text/plain; charset=utf-8", "501 Not Implemented\n" + e.message + "\n")
rescue ArgumentError => e
  # A usage error: an SQL error, a binding mismatch, an unopened binding name.
  respond(400, "text/plain; charset=utf-8", "400 Bad Request\n" + e.message + "\n")
rescue IOError => e
  # It did not arrive / it was too large.
  respond(502, "text/plain; charset=utf-8", "502 Bad Gateway\n" + e.message + "\n")
rescue => e
  respond(500, "text/plain; charset=utf-8", "500 Internal Server Error\n" + e.message + "\n")
end
