# tests/app/fixtures/channel/bytes.rb -- the byte helpers under CRuby, on the
# same fixed table as the `fill` entry: prints the 32 bytes as hex, the
# reference the native and the thumbv8m builds must reproduce.
$LOAD_PATH.unshift(File.expand_path("../../../../tools/app/lib", __dir__))
require "spinel/core"
require "spinel/net"
load File.expand_path("app.rb", __dir__)
bytes = Core::Buffer.u8(32)
tag = Core::Buffer.u8(4)
fill(bytes, tag)
puts bytes.map { |b| format("%02x", b) }.join
