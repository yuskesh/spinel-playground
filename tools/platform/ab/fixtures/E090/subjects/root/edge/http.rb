# spinel-tier: arena
# E090 stand-in for the future tools/wasm/edge/http.rb (P008 Phase 2).
# A deterministic probe, NOT a real fetch: the E090 gates measure the tier /
# menu machinery, not the host bridge (that is E014/E058's measured ground).
module Edge
  module HTTP
    def self.probe
      "edge-http-ok"
    end
  end
end
