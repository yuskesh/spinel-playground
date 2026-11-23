# examples/r2d1.rb -- R2 (object storage) and D1 (SQL) from Ruby (E055).
#
# Build:  spinel-wasm examples/r2d1.rb --emit-worker DIR --host-api
# Bind:   wrangler.toml needs [[r2_buckets]] / [[d1_databases]] AND the names
#         listed in SPINEL_HOST_R2 / SPINEL_HOST_D1 -- being bound is not the
#         same as being reachable.
#
#   GET /r2   put a binary blob, read it back, list, delete
#   GET /d1   create a table, insert with typed binds, read with typed accessors
#
# `wrangler dev --local` emulates both bindings on disk: no Cloudflare account
# and no network are needed to run this.
require "cloudflare/r2"
require "cloudflare/d1"

BUCKET = ENV["SPINEL_HOST_R2"].to_s.split(",")[0].to_s.strip
DB = ENV["SPINEL_HOST_D1"].to_s.split(",")[0].to_s.strip

path = ARGV[0].to_s

if path == "/d1"
  if DB.empty?
    puts "no D1 database is reachable; bind one and name it in SPINEL_HOST_D1"
    exit 1
  end
  Cloudflare::D1.exec(DB, "CREATE TABLE IF NOT EXISTS notes (" +
                          "id INTEGER PRIMARY KEY, body TEXT NOT NULL, score REAL)")
  # ★ Values NEVER go into the SQL string.  There is no method here that takes
  #   a statement and a value together, so there is nothing to interpolate.
  n = Cloudflare::D1.prepare(DB, "INSERT INTO notes (body, score) VALUES (?, ?)")
                    .text("hello from Ruby").float(1.5).run
  puts "inserted #{n} row"
  res = Cloudflare::D1.exec(DB, "SELECT id, body, score FROM notes ORDER BY id DESC LIMIT 5")
  puts "#{res.size} row(s):"
  # ★ Typed accessors, not row["id"]: the inferred type is what decides whether
  #   a value stays a machine word (R001 §1.5).  The schema already said what
  #   each column is.
  res.each_row do |row|
    puts "  #{row.int("id")}  #{row.str("body")}  #{row.float("score")}"
  end
else
  if BUCKET.empty?
    puts "no R2 bucket is reachable; bind one and name it in SPINEL_HOST_R2"
    exit 1
  end
  # A NUL and two bytes that are not valid UTF-8: anything that decodes and
  # re-encodes on the way through changes the length.
  blob = 0.chr + 255.chr + 254.chr + "A"
  Cloudflare::R2.put(BUCKET, "probe/blob", blob, content_type: "application/octet-stream")
  back = Cloudflare::R2.get(BUCKET, "probe/blob")
  puts "round trip: #{back.to_s.bytesize} bytes, identical=#{back.to_s == blob}"

  info = Cloudflare::R2.head(BUCKET, "probe/blob")
  puts "head: size=#{info.nil? ? "nil" : info.size} type=#{info.nil? ? "nil" : info.content_type}"

  # A miss is nil, never "" -- "absent" and "empty" stay distinguishable.
  puts "missing key -> #{Cloudflare::R2.get(BUCKET, "probe/nope").inspect}"

  page = Cloudflare::R2.list(BUCKET, prefix: "probe/")
  puts "list: #{page.size} object(s) #{page.keys.join(", ")} truncated=#{page.truncated?}"

  Cloudflare::R2.delete(BUCKET, "probe/blob")
  puts "after delete: key? = #{Cloudflare::R2.key?(BUCKET, "probe/blob")}"
end
