# examples/echo.rb -- the shape of a Workers-targeted Spinel program.
#
# There is no Spinel-side Workers API.  A request arrives as ARGV + $stdin and
# the response is whatever the program writes to $stdout; exit status 0 means
# 200, anything else means 500 with $stderr as the body.  That is the whole
# contract (R003 §2-4 layer 0).
#
#   ARGV[0]  path           "/echo"
#   ARGV[1]  query string   "a=1&b=2"   ("" when there is none)
#   $stdin   request body   (verbatim bytes; empty for GET/HEAD)
#   ENV      wrangler vars/secrets + CGI request variables (REQUEST_METHOD,
#            CONTENT_TYPE, HTTP_*, ...)

path  = ARGV[0].to_s
query = ARGV[1].to_s

params = {}
query.split("&").each do |pair|
  next if pair.empty?
  k, v = pair.split("=", 2)
  params[k] = v.to_s
end

case path
when "/echo"
  # Byte-exact: $stdout.write, not puts -- no trailing newline is added and no
  # transcoding happens anywhere between here and the Response body.
  $stdout.write($stdin.read.to_s)

when "/info"
  body = $stdin.read.to_s
  puts "path=#{path}"
  puts "query=#{query}"
  puts "params=#{params.sort.map { |k, v| "#{k}:#{v}" }.join(",")}"
  puts "method=#{ENV["REQUEST_METHOD"]}"
  puts "content_type=#{ENV["CONTENT_TYPE"].inspect}"
  puts "body_bytes=#{body.bytesize}"

when "/fail"
  # exit status != 0 -> 500, and $stderr becomes the response body.
  warn "deliberate failure from #{path}"
  exit 3

else
  # A 404 needs SPINEL_CGI_HEADERS=1; without it every successful run is a 200.
  # Uncomment the two lines below (and set the var in wrangler.toml) to use it.
  # puts "Status: 404"
  # puts
  puts "no route for #{path.inspect} (try /echo, /info, /fail)"
end
