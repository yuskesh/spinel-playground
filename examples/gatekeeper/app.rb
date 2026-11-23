# examples/gatekeeper/app.rb -- THE BODY (full Ruby, wasm32-wasip1).
#
# This is an ordinary Spinel program on the E013 CGI contract: ARGV[0] is the
# path, ARGV[1] the query string, the request body is on $stdin, the response
# body is whatever it writes to $stdout, and with SPINEL_CGI_HEADERS=1 it may
# emit a header block first.  Nothing in here knows it is behind a gatekeeper.
#
# WHAT IT USES THAT THE KERNEL CANNOT HAVE: classes, arrays, hashes, string
# building, `sort_by`, blocks, exceptions -- every one of which allocates.  That
# is the placement rule from the other side: this is the work that WANTS a
# heap, so it belongs in the 245 KB module, and it only ever runs for a request
# that has already been admitted.
#
# The gatekeeper's verdicts arrive the same way everything else does -- as CGI
# request variables, because the router put them on the request as headers:
#
#   HTTP_X_GATE_UID       identity the gate keyed on
#   HTTP_X_GATE_VARIANT   A/B bucket from spinel_bucket_hrw
#   HTTP_X_GATE_SCORE     bot score from spinel_bot_score
#   HTTP_X_GATE_TOKENS    milli-tokens left after this request
#   HTTP_X_GATE_KERN      the kernel's ABI version
#
# `warn` writes to $stderr, which worker.mjs mirrors to console.error and which
# therefore lands in the wrangler log.  That line is this experiment's
# out-of-band witness that the full Ruby module RAN: a request the gatekeeper
# shed can never produce one.

# NOT `require "json"`: the stdlib json extension is a native FFI object and
# there is no wasm32 build of it, so spinel-wasm refuses the program by name
# (E009's rule -- an unavailable capability is a compile-time error, never a
# silent stub).  Twenty lines of Ruby is the honest replacement, and writing
# them uses exactly the machinery this side of the split exists for: recursion
# over Hash and Array, string building, `gsub`.
def json_escape(s)
  out = s.to_s.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")
  out = out.gsub("\n", "\\n").gsub("\r", "\\r").gsub("\t", "\\t")
  out
end

def json_gen(v)
  case v
  when Hash
    "{" + v.map { |k, val| "\"#{json_escape(k)}\":#{json_gen(val)}" }.join(",") + "}"
  when Array
    "[" + v.map { |e| json_gen(e) }.join(",") + "]"
  when String  then "\"#{json_escape(v)}\""
  when Integer then v.to_s
  when true    then "true"
  when false   then "false"
  when nil     then "null"
  else "\"#{json_escape(v.to_s)}\""
  end
end

APP_VERSION = "1.0.0"
KERN_ABI_EXPECTED = 1

CATALOG = [
  { "id" => 1, "name" => "sandstone",  "tier" => "free", "price_cents" => 0 },
  { "id" => 2, "name" => "limestone",  "tier" => "free", "price_cents" => 0 },
  { "id" => 3, "name" => "granite",    "tier" => "pro",  "price_cents" => 1200 },
  { "id" => 4, "name" => "basalt",     "tier" => "pro",  "price_cents" => 1800 },
  { "id" => 5, "name" => "obsidian",   "tier" => "pro",  "price_cents" => 4200 },
]

class Gate
  attr_reader :uid, :variant, :score, :tokens, :kern

  # ENV is read HERE rather than passed in: `ENV` cannot flow as a value in
  # Spinel (it is modelled as a call receiver only), so the reads happen at the
  # use site.  That refusal is a compile-time one, which is the house style.
  def initialize
    @uid     = ENV["HTTP_X_GATE_UID"].to_s
    @variant = (ENV["HTTP_X_GATE_VARIANT"] || "-1").to_i
    @score   = (ENV["HTTP_X_GATE_SCORE"] || "-1").to_i
    @tokens  = (ENV["HTTP_X_GATE_TOKENS"] || "-1").to_i
    @kern    = (ENV["HTTP_X_GATE_KERN"] || "0").to_i
  end

  # The body refuses to answer if it was reached without a gate verdict, or
  # with one produced by a kernel it was not built against.  Deploying half the
  # artifact is a 500, not a quiet degradation.
  def problem
    return "no gatekeeper verdict on this request" if @variant < 0
    return "kernel ABI #{@kern}, expected #{KERN_ABI_EXPECTED}" if @kern != KERN_ABI_EXPECTED
    nil
  end

  # The A/B split the bucket is FOR.  Bucket 0 is the control arm.
  def arm
    @variant.zero? ? "control" : "variant-#{@variant}"
  end

  def to_h
    { "uid" => @uid, "bucket" => @variant, "arm" => arm,
      "bot_score" => @score, "tokens_left_mt" => @tokens, "kern_abi" => @kern }
  end
end

# A digest with no dependencies, so /api/echo can prove the bytes arrived
# intact without pulling in anything native.
def cheap_digest(s)
  h = 0
  s.each_byte { |b| h = (h * 31 + b) % 1_000_003 }
  h
end

def respond(status, obj)
  body = json_gen(obj)
  puts "Status: #{status}"
  puts "Content-Type: application/json; charset=utf-8"
  puts "X-App-Version: #{APP_VERSION}"
  puts
  $stdout.write(body)
end

path  = ARGV[0].to_s
query = ARGV[1].to_s

params = {}
query.split("&").each do |pair|
  next if pair.empty?
  k, v = pair.split("=", 2)
  params[k] = v.to_s
end

gate = Gate.new
warn "gatekeeper-app-ran path=#{path} uid=#{gate.uid} bucket=#{gate.variant}"

bad = gate.problem
if bad
  respond(500, { "error" => "misconfigured", "detail" => bad })
  exit 0
end

case path
when "/api/me"
  respond(200, { "ok" => true, "gate" => gate.to_h,
                 "method" => ENV["REQUEST_METHOD"].to_s,
                 "app_version" => APP_VERSION })

when "/api/items"
  # The A/B arm actually does something: the control arm sees the catalog in
  # id order, the variant arms see it cheapest-first.  Whichever a client sees,
  # it must see the SAME one from every PoP -- which is what makes the bucket
  # decision worth putting in a deterministic kernel.
  tier  = params["tier"].to_s
  items = CATALOG.dup
  items = items.select { |i| i["tier"] == tier } unless tier.empty?
  items = items.sort_by { |i| i["price_cents"] } unless gate.variant.zero?
  respond(200, { "ok" => true, "arm" => gate.arm, "count" => items.size,
                 "items" => items })

when "/api/echo"
  body = $stdin.read.to_s
  respond(200, { "ok" => true, "bytes" => body.bytesize,
                 "sha_like" => cheap_digest(body),
                 "content_type" => ENV["CONTENT_TYPE"].to_s })

when "/api/config"
  respond(200, { "ok" => true, "app_version" => APP_VERSION,
                 "kern_abi" => gate.kern, "catalog_size" => CATALOG.size,
                 "arms" => ["control", "variant-1", "variant-2", "variant-3"] })

else
  m = /\A\/api\/items\/(\d+)\z/.match(path)
  if m
    id   = m[1].to_i
    item = CATALOG.find { |i| i["id"] == id }
    if item
      respond(200, { "ok" => true, "item" => item, "arm" => gate.arm })
    else
      respond(404, { "ok" => false, "error" => "no such item", "id" => id })
    end
  else
    respond(404, { "ok" => false, "error" => "no route",
                   "path" => path,
                   "routes" => ["/api/me", "/api/items", "/api/items/:id",
                                "/api/echo", "/api/config"] })
  end
end
