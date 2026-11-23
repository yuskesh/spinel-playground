# examples/env.rb -- ENV on Workers.
#
# ENV is the ordinary Ruby ENV.  It is filled from WASI's environ_get, which
# worker.mjs populates from the Worker's `env`: every *string* value (vars from
# wrangler.toml and secrets alike) plus the CGI request variables.
#
# What is NOT in ENV: bindings.  A KV namespace, an R2 bucket, a D1 database, a
# Durable Object or a service binding is a JS object, not a string, so it is
# skipped rather than flattened into an empty string -- "absent" and "empty"
# must stay distinguishable (R003 §3-1).  Reaching a binding needs the explicit
# host bridge (R003 §2-4 layer 1), which is not part of this layer.

name = (ARGV[1].to_s.split("&").find { |p| p.start_with?("var=") } || "").sub("var=", "")
name = "GREETING" if name.empty?

puts "#{name}=#{ENV[name].inspect}"
puts "method=#{ENV["REQUEST_METHOD"]}"
puts "host=#{ENV["HTTP_HOST"]}"
puts "env_count=#{ENV.size}"
