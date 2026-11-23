# examples/hello-fastly/app.rb -- ONE program, two edge platforms.
#
# This file is the E058 claim in executable form: the same .rb, with no edit
# and no conditional compilation, built twice --
#
#   ./build.sh          # -> dist/ (Fastly) and dist-workers/ (Workers)
#
# -- answers requests on Fastly Compute (Viceroy) and on Cloudflare Workers
# (workerd), and /echo, /info and /kv come back BYTE FOR BYTE identical.
#
# It can do that because layer 0 is the same contract on both (E013):
#
#   ARGV[0] = path   ARGV[1] = query   $stdin = body   ENV = CGI variables
#   $stdout = response body   $stderr = diagnostics   exit(0) -> 200
#
# and because layer 1 (Edge:: / Cloudflare:: / Fastly::, R016 T-4 as migrated
# by E091) is the same Ruby surface on both, even though underneath it is
# JSPI-suspending JavaScript on Workers and synchronous hostcalls on Fastly.
#
# ★ THIS FILE READS THE RAW E013 CONTRACT ON PURPOSE.  edge/cgi (E091) is sugar
#   over exactly the ARGV/$stdin/ENV/$stdout lines below, and it is opt-in
#   precisely so that the raw contract stays legal -- this program is the
#   witness that the raw contract alone is enough, so it keeps using it.
#
# Where the platforms genuinely differ, this program does NOT hide it:
#
#   * Edge::HTTP takes backend:, which Fastly requires and Workers ignores.
#     Writing it unconditionally is correct on both.
#   * R2 / D1 exist on Workers and raise NotImplementedError on Fastly;
#     Config Store is the mirror image.  /errors prints what each one did.
#     That is also why this program is deliberately NOT menu-clean: it asks
#     each platform for what the other one has, in order to show the refusal.
require "edge/cgi"
require "edge/http"
require "edge/kv"
require "cloudflare/r2"
require "cloudflare/d1"
require "fastly/config"

path  = ARGV[0].to_s
query = ARGV[1].to_s

params = {}
query.split("&").each do |pair|
  next if pair.empty?
  k, v = pair.split("=", 2)
  params[k] = v.to_s
end

# Reachability is a deployment decision on both platforms, so both names come
# from the deployment when it says something and from a default when it does
# not.  Workers names its KV binding in SPINEL_HOST_KV (worker.mjs refuses any
# binding not listed there); Fastly declares the store in fastly.toml and hands
# the guest no environment variable at all, so the default is what applies.
kv_ns = ENV["SPINEL_HOST_KV"].to_s.split(",")[0].to_s.strip
kv_ns = "app_kv" if kv_ns.empty?

origin_url = ENV["ORIGIN_URL"].to_s
origin_url = "http://127.0.0.1:7899/probe" if origin_url.empty?
origin_backend = ENV["ORIGIN_BACKEND"].to_s
origin_backend = "origin" if origin_backend.empty?

# Every refusal below is caught and printed as `name | Class | message`, so the
# program keeps running and the whole taxonomy comes back in one response.
def try(label)
  yield
  # Three fields always, so the divergence table parses the same way
  # whether the call raised or not.
  puts "#{label} | (no exception) | -"
rescue NotImplementedError => e         # ScriptError, not StandardError
  puts "#{label} | NotImplementedError | #{e.message}"
rescue => e
  puts "#{label} | #{e.class} | #{e.message}"
end

case path
when "/echo"
  # Byte-exact: $stdout.write, not puts.  Nothing is appended and nothing is
  # transcoded between here and the response body, on either platform.
  $stdout.write($stdin.read.to_s)

when "/info"
  body = $stdin.read.to_s
  puts "path=#{path}"
  puts "query=#{query}"
  puts "params=#{params.sort.map { |k, v| "#{k}:#{v}" }.join(",")}"
  puts "method=#{ENV["REQUEST_METHOD"]}"
  puts "content_type=#{ENV["CONTENT_TYPE"].inspect}"
  puts "custom_header=#{ENV["HTTP_X_SPINEL_PROBE"].inspect}"
  puts "body_bytes=#{body.bytesize}"
  puts "host_api=#{Edge.available?}"
  # Deliberately no platform line: this route is the byte-identity witness.

when "/platform"
  # ...and this is where the difference is allowed to show.
  puts "platform=#{Edge::CGI.platform}"
  puts "server_software=#{ENV["SERVER_SOFTWARE"]}"
  puts "fastly_hostname=#{ENV["FASTLY_HOSTNAME"].inspect}"

when "/kv"
  key = params["k"].to_s
  key = "counter" if key.empty?
  before = Edge::KV.get(kv_ns, key)
  Edge::KV.put(kv_ns, key, "written-by-spinel")
  after = Edge::KV.get(kv_ns, key)
  miss = Edge::KV.get(kv_ns, "definitely-not-here")
  empty_key = "empty-#{key}"
  Edge::KV.put(kv_ns, empty_key, "")
  empty = Edge::KV.get(kv_ns, empty_key)
  puts "before.nil?=#{before.nil?}"
  puts "after=#{after.inspect}"
  # ★ The R008 §2.6 trap, from Ruby.  A Fastly KV miss reports itself by NOT
  #   writing the out parameter, and handle 0 is valid -- so a miss read
  #   through a zero-initialised handle would return the DOWNSTREAM REQUEST
  #   BODY and look like a hit.  nil here means the sentinel discipline held.
  puts "miss.nil?=#{miss.nil?}"
  puts "empty.nil?=#{empty.nil?}"
  puts "empty.bytesize=#{empty.to_s.bytesize}"

when "/fetch"
  # backend: is required on Fastly and ignored on Workers -- one spelling,
  # both platforms (R008 D-3).
  # The primitive, spelled out: Edge::HTTP.request(:verb, url, ...) is the one
  # call that maps 1:1 onto the sp_host_fetch thunk; get/post are
  # its sugar.
  r = Edge::HTTP.request(:get, origin_url, backend: origin_backend,
                         headers: { "X-Spinel-Probe" => "portable" })
  puts "status=#{r.status}"
  puts "ok=#{r.ok?}"
  puts "content_type=#{r.content_type.inspect}"
  puts "body_bytes=#{r.body.to_s.bytesize}"

when "/errors"
  # The whole refusal taxonomy, as catchable Ruby exceptions.  Nothing here
  # terminates the program: that is the point of raising instead of returning
  # a plausible wrong answer (R003 §3-1, E012).

  # First, before anything has been staged: an accessor used out of order.
  try("stage.before_anything") { Edge::Bridge.sp_host_res_body }

  try("fetch.no_backend")      { Edge::HTTP.get(origin_url) }
  try("fetch.empty_backend")   { Edge::HTTP.get(origin_url, backend: "") }
  try("fetch.unknown_backend") { Edge::HTTP.get(origin_url, backend: "no_such_backend") }
  try("fetch.empty_url")       { Edge::HTTP.get("", backend: origin_backend) }

  try("kv.unknown_store")      { Edge::KV.get("no_such_store", "k") }
  try("kv.empty_key")          { Edge::KV.get(kv_ns, "") }
  try("kv.put_unknown_store")  { Edge::KV.put("no_such_store", "k", "v") }
  try("kv.put_empty_key")      { Edge::KV.put(kv_ns, "", "v") }

  try("config.unknown_store")  { Fastly::Config.get("no_such_config", "k") }
  try("config.empty_key")      { Fastly::Config.get("spinel", "") }

  try("r2.get")                { Cloudflare::R2.get("VAULT", "k") }
  try("r2.put")                { Cloudflare::R2.put("VAULT", "k", "v") }
  try("d1.exec")               { Cloudflare::D1.exec("DB", "SELECT 1") }
  try("tbl.rows")              { Cloudflare::Table.sp_host_tbl_rows }

  # Two answers that are NOT exceptions, for contrast.
  puts "kv.miss | nil (not an exception) | #{Edge::KV.get(kv_ns, "nope").inspect}"
  puts "after = ok"

when "/fail"
  # exit != 0 -> 500, and $stderr is the response body.  Whatever the program
  # had already written to $stdout is DISCARDED (a half-written body is worse
  # than none) but its size is reported in x-spinel-stdout-bytes.
  $stdout.write("this must not reach the client")
  warn "deliberate failure from #{path}"
  exit 3

when "/raise"
  # An uncaught Ruby exception: Spinel prints it to $stderr and exits 1, so it
  # arrives as a 500 whose body is the Ruby message -- on both platforms.
  raise ArgumentError, "deliberate uncaught exception"

when "/rescue"
  # sjlj -> wasm exception handling.  This is the line that does not run at all
  # unless the module was built with the STANDARDIZED EH encoding: Wasmtime
  # (Fastly / Viceroy) refuses LLVM's legacy default outright (R008 §1).
  begin
    raise ArgumentError, "caught inside"
  rescue ArgumentError => e
    puts "rescued: #{e.message}"
  ensure
    puts "ensure ran"
  end
  puts "still running"
  puts "bigint=#{2**70}"
  puts "regexp=#{("spinel-2026" =~ /(\d+)/) ? $1 : "no"}"

when "/status"
  # Needs SPINEL_CGI_HEADERS = "1" (the `spinel` Config Store on Fastly, [vars]
  # on Workers).  Without it these two lines are just the first two lines of a
  # 200's body -- which is the safe failure, not a 500.
  code = params["code"].to_s
  code = "404" if code.empty?
  puts "Status: #{code}"
  puts "Content-Type: text/plain; charset=utf-8"
  puts
  puts "status route answered #{code}"

else
  puts "spinel on the edge -- routes:"
  puts "  /echo /info /platform /kv /fetch /errors /fail /raise /rescue /status"
end
