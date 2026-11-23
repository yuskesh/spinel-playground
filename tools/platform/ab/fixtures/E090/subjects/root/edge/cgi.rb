# spinel-tier: arena
# E090 stand-in for the future tools/wasm/edge/cgi.rb (P008 Phase 2).
# Pure Ruby over the raw E013 contract (ARGV/$stdin/ENV/$stdout) -- NO new
# hostcall (R016 T-3: edge/cgi is sugar; the raw contract stays legal).
module Edge
  module CGI
    def self.request_path
      ARGV[0].to_s
    end

    def self.request_query
      ARGV[1].to_s
    end

    def self.request_body
      $stdin.read.to_s
    end

    def self.respond(status, body)
      $stdout.write(body)
      if status == 200
        exit 0
      end
      exit 1
    end
  end
end
