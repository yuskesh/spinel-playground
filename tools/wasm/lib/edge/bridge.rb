# tools/wasm/lib/edge/bridge.rb -- the raw host bridge, and the only place the
# `sp_host_*` thunks are declared for the edge family (R016 T-4, E091;
# previously the top of tools/wasm/spinel_host.rb, E014/E058).
#
# ★ THE RUBY NAME AND THE ABI NAME ARE SEPARATE THINGS.  The Ruby surface moved
#   to Edge::/Cloudflare::/Fastly:: in E091.  The wasm import module name is
#   still `spinel_host` and every import in it still has the name it had in
#   E014, because that is an ABI and the byte-identity assets of E014/E055/E058
#   are built on it (the plan: "the wasm import module name spinel_host stays
#   as it is, as an ABI").  results/E091/run_gates.sh pins it.
#
# This file is required by edge/http, edge/kv, cloudflare/*, fastly/config --
# it is the shared transport, not a capability, and it is not in the ledger
# (tools/platform/menus.yaml): nothing declares `require "edge/bridge"` as a
# capability, it comes with whichever capability was asked for.
#
# It is also the documented seat for calling a thunk raw:
#
#   Edge::Bridge.sp_host_res_body        # the staged response body, verbatim
#
# A program may equally declare the ffi_funcs itself and skip this file: the
# block below is the entire contract.
#
#   sp_host_fetch(url, method, body, body_len, headers, backend) -> HTTP status
#        body_len <= 0 means "no request body"; otherwise the body is sent
#        byte-exact (it may contain NUL, which is why the length is passed).
#        `headers` is a "Name: value\n" block, "" for none.
#        `backend` is the Fastly backend name, "" for none (see Edge::HTTP).
#   sp_host_res_body()      -> the staged response body, byte-exact (:binstr)
#   sp_host_res_headers()   -> the staged response headers as such a block
#   sp_host_kv_get(ns, key) -> 1 value staged / 0 miss
#   sp_host_kv_put(ns, key, value, value_len) -> 0
#   sp_host_available()     -> 1 / 0, never raises
module Edge
  module Bridge
    ffi_func :sp_host_fetch,       [:str, :str, :str, :int, :str, :str], :int
    ffi_func :sp_host_res_body,    [], :binstr
    ffi_func :sp_host_res_headers, [], :str
    ffi_func :sp_host_kv_get,      [:str, :str], :int
    ffi_func :sp_host_kv_put,      [:str, :str, :str, :int], :int
    ffi_func :sp_host_available,   [], :int

    # "Name: value\n" per line -- the same block shape E013's SPINEL_CGI_HEADERS
    # already speaks.  Not JSON: `require "json"` pulls a native object file with
    # no wasm32 build, so a Ruby program on this target cannot parse JSON, and an
    # API that hands it JSON would be an API it cannot use.
    #
    # ★ Call this with a Hash{String => String} and nothing else.  E055 measured
    #   what a second call site with a nilable value type does: the Hash widens
    #   to Hash{String => TY_POLY}, the shared function miscompiles on wasm32,
    #   and the first `.bytesize` on its result traps with `memory access out of
    #   bounds` -- in every caller, including ones that had worked since E014.
    #   Cloudflare::R2.put builds its one-line metadata block by concatenation
    #   for exactly this reason.
    def self.format_headers(headers)
      return "" if headers.nil?

      out = ""
      headers.each do |k, v|
        name = k.to_s.strip
        next if name.empty?
        value = v.to_s.gsub("\r", " ").gsub("\n", " ")
        out += "#{name}: #{value}\n"
      end
      out
    end

    def self.parse_headers(blob)
      out = {}
      return out if blob.nil?

      blob.split("\n").each do |line|
        next if line.empty?
        i = line.index(":")
        next if i.nil? || i <= 0
        out[line[0, i].strip.downcase] = line[(i + 1)..-1].to_s.strip
      end
      out
    end
  end

  # Is there a host bridge behind this build?  False when the program was built
  # without --host-api, or when the host supplies no `spinel_host` imports.
  # Never raises, so it is safe as a guard -- and it is asked at the FAMILY
  # level because there is one bridge under all of Edge::HTTP, Edge::KV and the
  # vendor bindings that ride it.
  #
  # The build-time question ("is this capability on the platform's menu?") is a
  # different one and is answered by tools/platform/spinel-capcheck against
  # tools/platform/menus.yaml (R016 T-3).  This is its run-time shadow.
  def self.available?
    Edge::Bridge.sp_host_available == 1
  end
end
