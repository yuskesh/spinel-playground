# spinel-tier: full
module ViTerm
  ffi_cflags "-Iexamples/spinel-vi/shim -Iexamples/spinel-vi/vendor/termbox2"
end
require_relative "../lib/terminal"
require_relative "../lib/file_store"
begin
  text = SpinelVi::FileStore.load(ARGV[0])
  if ARGV.length == 2 && ARGV[1] == "--bytes"
    out = "bytes="
    i = 0
    while i < text.bytesize
      out += "," if i > 0
      out += text.getbyte(i).to_s
      i += 1
    end
    puts out
  else
    puts "text=#{text.inspect}"
  end
rescue RuntimeError => error
  puts "error=#{error.message}"
end
