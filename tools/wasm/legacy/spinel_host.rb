# tools/wasm/spinel_host.rb -- the Ruby ergonomics over the host bridge
# (R003 §2-4 layer 1, E014).  Plain Spinel, no magic: every line below is
# ordinary Ruby over the six `ffi_func` declarations at the top, and those are
# the real interface.  Nothing here is compiled specially and nothing here is
# required -- a program may declare the ffi_funcs itself and call them raw.
#
#   spinel-wasm app.rb --host-api           # adds tools/wasm to the -I roots
#
#   require "spinel_host"
#   r = SpinelHost.fetch("https://example.com/")
#   puts r.status                           # 200 (404 and 500 are answers too)
#   puts r["content-type"]
#   puts r.body.bytesize
#
#   SpinelHost::KV.put("MY_KV", "k", "v")
#   SpinelHost::KV.get("MY_KV", "k")        # "v", or nil for a miss
#
# R2 (object storage) and D1 (SQL) are separate requires, so a program that
# does not use them does not carry them (E055):
#
#   require "spinel_host_r2"
#   SpinelHost::R2.put("BUCKET", "logo.png", png, content_type: "image/png")
#
#   require "spinel_host_d1"
#   SpinelHost::D1.prepare("DB", "SELECT title FROM posts WHERE id = ?").int(id).first
#
# Only reachable when the module is built with --host-api AND the host supplies
# the imports.  Otherwise every call raises NotImplementedError, which is
# catchable (`rescue NotImplementedError`, or `rescue ScriptError` for the
# parent class -- NOT `rescue => e`, which is StandardError).  Use
# SpinelHost.available? to ask without raising.
module SpinelHost
  # ---- the raw surface -------------------------------------------------------
  # This block is the entire contract.  Paste it into a program instead of
  # requiring this file if you would rather not carry the wrapper.
  #
  #   sp_host_fetch(url, method, body, body_len, headers, backend) -> HTTP status
  #        body_len <= 0 means "no request body"; otherwise the body is sent
  #        byte-exact (it may contain NUL, which is why the length is passed).
  #        `headers` is a "Name: value\n" block, "" for none.
  #        `backend` is the Fastly backend name, "" for none (see .fetch).
  #   sp_host_res_body()      -> the staged response body, byte-exact (:binstr)
  #   sp_host_res_headers()   -> the staged response headers as such a block
  #   sp_host_kv_get(ns, key) -> 1 value staged / 0 miss
  #   sp_host_kv_put(ns, key, value, value_len) -> 0
  #   sp_host_config_get(store, key) -> 1 value staged / 0 miss  (Fastly only)
  #   sp_host_available()     -> 1 / 0, never raises
  ffi_func :sp_host_fetch,       [:str, :str, :str, :int, :str, :str], :int
  ffi_func :sp_host_res_body,    [], :binstr
  ffi_func :sp_host_res_headers, [], :str
  ffi_func :sp_host_kv_get,      [:str, :str], :int
  ffi_func :sp_host_kv_put,      [:str, :str, :str, :int], :int
  ffi_func :sp_host_config_get,  [:str, :str], :int
  ffi_func :sp_host_available,   [], :int


  # A response is whatever the other end said, including a 404 or a 503.  Only
  # a failure to *reach* the other end raises (IOError) -- "the server answered
  # 500" is information, not an exception (R003 §3-1: an observable answer is
  # an answer).
  class Response
    attr_reader :status, :body, :headers

    def initialize(status, body, headers)
      @status = status
      @body = body
      @headers = headers
    end

    # Header lookup is case-insensitive; keys are stored lower-cased.
    def [](name)
      @headers[name.to_s.downcase]
    end

    def ok?
      @status >= 200 && @status < 300
    end

    def content_type
      @headers["content-type"]
    end

    def to_s
      @body
    end
  end

  # Is there a host API behind this build?  False when the program was built
  # without --host-api-capable hosting, or when the host supplies no
  # `spinel_host` imports.  Never raises, so it is safe as a guard.
  def self.available?
    SpinelHost.sp_host_available == 1
  end

  # "Name: value\n" per line -- the same block shape E013's SPINEL_CGI_HEADERS
  # already speaks.  Not JSON: `require "json"` pulls a native object file with
  # no wasm32 build, so a Ruby program on this target cannot parse JSON, and an
  # API that hands it JSON would be an API it cannot use.
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

  # SpinelHost.fetch(url, method: "GET", body: nil, headers: {}, backend: nil)
  #   -> Response
  #
  # Buffered, both directions: the request body is sent whole and the response
  # body is read whole before this returns.  There is no streaming here (and
  # none in layer 0 either -- see the E013/E014 limits).
  #
  # `backend:` is the one place the two platforms differ, and the difference is
  # deliberately visible rather than smoothed over (R008 D-3, decided by E058):
  #
  #   Workers   the URL is the destination.  backend: is accepted and ignored.
  #   Fastly    every outbound request names a backend from the service
  #             configuration; a URL alone reaches nothing.  Omitting backend:
  #             is an ArgumentError at the call, BEFORE any traffic.
  #
  # It raises rather than picking a default because the alternative failure is
  # the worst kind this target keeps designing out: the program asks for
  # https://api.example.com, the request goes somewhere else, and a 200 comes
  # back to say it worked.  Writing `backend: "origin"` unconditionally is
  # correct on both platforms, which is what makes one .rb portable.
  def self.fetch(url, method: "GET", body: nil, headers: nil, backend: nil)
    payload = body.nil? ? "" : body.to_s
    status = SpinelHost.sp_host_fetch(url.to_s, method.to_s, payload,
                                      payload.bytesize, format_headers(headers),
                                      backend.nil? ? "" : backend.to_s)
    # Sequenced into locals on purpose: as two arguments of one call, C leaves
    # their evaluation unsequenced.  (The C side also gives the body and the
    # headers separate buffers, so this is belt and braces.)
    payload_body = SpinelHost.sp_host_res_body
    payload_head = SpinelHost.sp_host_res_headers
    Response.new(status, payload_body, parse_headers(payload_head))
  end

  # Convenience wrappers.  `get` and `post` exist because they are what a
  # program actually writes; everything else goes through fetch.
  def self.get(url, headers: nil, backend: nil)
    fetch(url, method: "GET", headers: headers, backend: backend)
  end

  def self.post(url, body, headers: nil, backend: nil)
    fetch(url, method: "POST", body: body, headers: headers, backend: backend)
  end

  # Diagnostics, portably.  $stderr is the one output channel both platforms
  # route somewhere a human can read: Workers turns it into console.error (and
  # into the 500 body when the program fails), Fastly sends it to the log
  # endpoint (and E058's platform layer also makes it the 500 body).  There is
  # no host import behind this and there does not need to be.
  def self.log(message)
    $stderr.write("#{message}\n")
    nil
  end

  # The platform's own name for itself.  ENV is where both platforms put their
  # request variables (E013's CGI contract), and Fastly additionally seeds
  # FASTLY_HOSTNAME / _POP / _REGION / _SERVICE_ID / _SERVICE_VERSION /
  # _TRACE_ID / _CUSTOMER_ID / _CACHE_GENERATION / _IS_STAGING.  A program that
  # wants to branch on the platform should branch on THIS, not on the presence
  # of a variable that might simply be unset.
  def self.platform
    s = ENV["SERVER_SOFTWARE"].to_s          # "spinel-wasm/workers" | ".../fastly"
    i = s.index("/")
    i.nil? ? "unknown" : s[(i + 1)..-1].to_s
  end

  # KV, as the binding exemplar (R003 §5 Phase iv generalises this shape to
  # R2 / D1).  This module is IDENTICAL on both platforms -- the Ruby, the
  # `sp_host_kv_*` symbols and the nil/"" rule are shared; only what is behind
  # them differs (E058):
  #
  #   Workers   the *binding* name from wrangler.toml, and the worker must
  #             also list it in SPINEL_HOST_KV.
  #   Fastly    the KV Store name from fastly.toml's [local_server.kv_stores]
  #             (locally) or from the service configuration.
  #
  # Either way a store is reachable only when the deployment says so, and
  # asking for one that is not produces an ArgumentError naming it -- never a
  # silent nil, which would be indistinguishable from an empty store.
  module KV
    # nil for a miss, a String (possibly "") for a hit.  Never "" for a miss:
    # collapsing absent onto empty is the failure R003 §3-1 forbids.
    def self.get(namespace, key)
      return nil if SpinelHost.sp_host_kv_get(namespace.to_s, key.to_s) == 0
      SpinelHost.sp_host_res_body
    end

    def self.put(namespace, key, value)
      v = value.to_s
      SpinelHost.sp_host_kv_put(namespace.to_s, key.to_s, v, v.bytesize)
      true
    end

    def self.key?(namespace, key)
      SpinelHost.sp_host_kv_get(namespace.to_s, key.to_s) == 1
    end
  end

  # Fastly's Config Store -- the place a Fastly service keeps what a worker
  # keeps in wrangler.toml's `vars`.  Fastly-specific on purpose (R008 D-3):
  # Workers has no counterpart, because there the vars are already in ENV, and
  # on Workers every method here raises NotImplementedError rather than
  # answering nil.  Read-only from the guest on both counts -- a Config Store
  # is written through the API/CLI, never from a request.
  #
  # Note what is NOT here: nothing copies a Config Store into ENV.  R003 §3-1
  # forbids flattening a binding namespace into the environment, because that
  # is exactly where "there is no such key" and "the key is empty" stop being
  # different answers.  `get` returns nil for the former and "" for the latter.
  module Config
    def self.get(store, key)
      return nil if SpinelHost.sp_host_config_get(store.to_s, key.to_s) == 0
      SpinelHost.sp_host_res_body
    end

    def self.key?(store, key)
      SpinelHost.sp_host_config_get(store.to_s, key.to_s) == 1
    end
  end
end
