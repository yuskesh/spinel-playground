# spinel-tier: arena
# E090 stand-in (see http.rb).  Used by the reject corpus: edge/kv's supplying
# set is {workers} until the KV attribution contract exists (P008 Phase 4).
module Edge
  module KV
    def self.probe
      "edge-kv-ok"
    end
  end
end
