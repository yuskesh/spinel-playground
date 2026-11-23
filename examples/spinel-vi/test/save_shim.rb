# spinel-tier: full
module ViTerm
  ffi_cflags "-Iexamples/spinel-vi/shim -Iexamples/spinel-vi/vendor/termbox2"
end
require_relative "../lib/terminal"
require_relative "../lib/file_store"

payload = if ARGV.length == 3 && ARGV[2] == "--payload-file"
            File.binread(ARGV[1])
          else
            ARGV[1]
          end
rc = SpinelVi::FileStore.save(ARGV[0], payload)
puts "rc=#{rc} error=#{SpinelVi::FileStore.error}"
