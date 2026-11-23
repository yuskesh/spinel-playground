# spinel-tier: arena
# E090 stand-in (see edge/http.rb).
module Fastly
  module ERL
    def self.probe
      "fastly-erl-ok"
    end
  end
end
