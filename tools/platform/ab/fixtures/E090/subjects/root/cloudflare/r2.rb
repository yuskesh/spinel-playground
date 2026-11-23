# spinel-tier: arena
# E090 stand-in (see edge/http.rb).  Vendor capability: today supplied only
# through the Workers binding transport -- a fact of the ledger's menu, never
# of this file or of any code path (2026-08-19 user decision).
module Cloudflare
  module R2
    def self.probe
      "cloudflare-r2-ok"
    end
  end
end
