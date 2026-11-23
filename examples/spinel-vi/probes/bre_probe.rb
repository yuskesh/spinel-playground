# spinel-tier: full
# E097/E104 POSIX BRE seam corpus.  The expected TSV is hand-derived from the
# POSIX BRE byte contract, rather than reusing editor search state.
module ViTerm
  ffi_cflags "-Iexamples/spinel-vi/shim -Iexamples/spinel-vi/vendor/termbox2"
end
require_relative "../lib/terminal"

def probe(name, pattern, text, offset)
  rc = ViTerm.sp_vi_bre_find(pattern, text, offset)
  error = rc == -1 && ViTerm.sp_vi_bre_error.bytesize > 0 ? "set" : ""
  puts "#{name}\trc=#{rc}\tstart=#{ViTerm.sp_vi_bre_start}\tend=#{ViTerm.sp_vi_bre_end}\terror=#{error}"
end

corpus = "cat\nfoo\nfoo\nbbb"
probe("literal_first", "foo", corpus, 0)
probe("literal_second", "foo", corpus, 7)
probe("literal_eof", "foo", corpus, 11)
probe("capture", "b\\(c\\)", "abc", 0)
probe("zero_0", "a*", "bbb", 0)
probe("zero_1", "a*", "bbb", 1)
probe("zero_2", "a*", "bbb", 2)
probe("zero_3", "a*", "bbb", 3)
probe("invalid", "[", "abc", 0)
