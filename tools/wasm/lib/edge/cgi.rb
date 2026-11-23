# tools/wasm/lib/edge/cgi.rb -- the RECEIVE side of the edge family, as sugar
# over the raw E013 contract (R016 T-3's `edge/cgi` = (arena+, {workers,
# fastly} + invoker); new in E091).
#
#   require "edge/cgi"
#
#   req = Edge::CGI.request
#   req.path            # ARGV[0]        "/posts/7"
#   req.query           # ARGV[1]        "a=1&b=2"
#   req.params["a"]     # parsed query   "1"
#   req.body            # $stdin, read whole, byte-exact
#   req.verb            # ENV["REQUEST_METHOD"]
#   req.header("x-spinel-probe")   # ENV["HTTP_X_SPINEL_PROBE"]
#   req.headers         # every HTTP_* variable, lower-cased and dashed
#
#   Edge::CGI.respond(200, "hello\n")
#
# ★ NO NEW HOSTCALL.  Every line here reads ARGV / $stdin / ENV and writes
#   $stdout / $stderr -- the layer-0 contract E013 established and E058 proved
#   identical on both platforms.  That is deliberate (R016 T-3): the sugar must
#   not become a second, privileged way in, or the raw contract stops being the
#   thing that is portable.  READING THE RAW CONTRACT DIRECTLY STAYS LEGAL and
#   examples/hello-fastly keeps doing exactly that on purpose -- it is the
#   witness that the raw contract is enough.
#
# ★ WHO SUPPLIES IT.  On workers/fastly the platform itself guarantees the E013
#   encoding.  On native/node the raw mechanisms (ARGV/$stdin/ENV) are all the
#   platform gives, and "ARGV[0] is the path" is the INVOKER's discipline --
#   the launcher plays the role a web server plays for real CGI.  The ledger
#   writes that as "+ invoker" (R016 T-3); it is the same delegation E063 uses
#   for startup and linking.
module Edge
  module CGI
    # One request, read once.  The body is read in the constructor because that
    # is when a program means to take it: $stdin is a stream and reading it
    # twice answers "" the second time.
    class Request
      attr_reader :path, :query, :body

      def initialize(path, query, body)
        @path = path
        @query = query
        @body = body
      end

      # "a=1&b=2" -> { "a" => "1", "b" => "2" }.  A key with no `=` maps to "".
      # Percent-decoding is NOT done here: it is a lossy guess about what the
      # bytes meant, and a program that needs it can decode its own values.
      def params
        out = {}
        @query.split("&").each do |pair|
          next if pair.empty?
          i = pair.index("=")
          if i.nil?
            out[pair] = ""
          else
            out[pair[0, i]] = pair[(i + 1)..-1].to_s
          end
        end
        out
      end

      def verb
        ENV["REQUEST_METHOD"].to_s
      end

      def content_type
        ENV["CONTENT_TYPE"].to_s
      end

      # "x-spinel-probe" -> ENV["HTTP_X_SPINEL_PROBE"].  nil when the header was
      # not sent -- absent and empty stay different answers (R003 §3-1).
      def header(name)
        ENV["HTTP_" + name.to_s.upcase.gsub("-", "_")]
      end

      # Every HTTP_* variable, back in header spelling.  Built by enumeration,
      # so a program can log what it actually received.
      def headers
        out = {}
        ENV.each do |k, v|
          next unless k.start_with?("HTTP_")
          out[k[5..-1].to_s.downcase.gsub("_", "-")] = v.to_s
        end
        out
      end
    end

    def self.request
      Request.new(ARGV[0].to_s, ARGV[1].to_s, $stdin.read.to_s)
    end

    # The answer, and the end of the program: one process serves one request
    # (E013/E064).  exit 0 is a 200 on both platforms.
    #
    # ★ A status other than 200 is expressed with the CGI header block, which
    #   the platform only interprets when the DEPLOYMENT turned it on
    #   (SPINEL_CGI_HEADERS = "1": [vars] on Workers, the `spinel` Config Store
    #   on Fastly).  The guest cannot see that switch on Fastly, so this method
    #   cannot check it; with the switch off the header lines are simply the
    #   first lines of a 200 body.  That is the failure E058 chose deliberately
    #   -- a wrong-looking body rather than a 500 -- and it is why a program
    #   that needs statuses must say so in its deployment.
    def self.respond(status, body, content_type: nil)
      if status != 200 || !content_type.nil?
        $stdout.write("Status: #{status}\n")
        $stdout.write("Content-Type: #{content_type}\n") unless content_type.nil?
        $stdout.write("\n")
      end
      $stdout.write(body.to_s)
      exit 0
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

    # The platform's own name for itself, from the CGI variable that carries it.
    # ENV is where both platforms put their request variables (E013), and Fastly
    # additionally seeds FASTLY_HOSTNAME / _POP / _REGION / _SERVICE_ID /
    # _SERVICE_VERSION / _TRACE_ID / _CUSTOMER_ID / _CACHE_GENERATION /
    # _IS_STAGING.  A program that wants to branch on the platform should branch
    # on THIS, not on the presence of a variable that might simply be unset.
    def self.platform
      s = ENV["SERVER_SOFTWARE"].to_s        # "spinel-wasm/workers" | ".../fastly"
      i = s.index("/")
      i.nil? ? "unknown" : s[(i + 1)..-1].to_s
    end
  end
end
