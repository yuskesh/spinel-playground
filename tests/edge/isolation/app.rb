# tests/edge/isolation/app.rb -- prints everything a request hands the module,
# so a leak from an earlier request shows in the output.
body = $stdin.read
puts "argv=#{ARGV.inspect}"
puts "stdin=#{body.inspect}"
puts "env ISO_A=#{ENV["ISO_A"].inspect}"
puts "env ISO_B=#{ENV["ISO_B"].inspect}"
puts "env_size=#{ENV.keys.size}"
# Ruby state: on an instance that carried state from one request into the
# next these would count 2 on the second request.
$seen = ($seen || 0) + 1
SEEN_PATHS = {} unless defined?(SEEN_PATHS)
SEEN_PATHS[ARGV[0]] = true
puts "seen=#{$seen} paths=#{SEEN_PATHS.size}"
if ARGV[0] == "/first"
  $stderr.puts "first-stderr"
  puts "F" * 6000
  exit 3
end
