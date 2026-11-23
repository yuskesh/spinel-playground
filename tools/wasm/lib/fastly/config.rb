# tools/wasm/lib/fastly/config.rb -- Fastly's Config Store from Ruby
# (E058; renamed from SpinelHost::Config by E091).  Opt-in:
#
#   require "fastly/config"
#   Fastly::Config.get("spinel", "SPINEL_CGI_HEADERS")   # "1", "" or nil
#
# The Config Store is the place a Fastly service keeps what a worker keeps in
# wrangler.toml's `vars`.  Vendor-specific on purpose (R008 D-3): Workers has
# no counterpart, because there the vars are already in ENV, and on Workers
# every method here raises NotImplementedError rather than answering nil.
# Read-only from the guest on both counts -- a Config Store is written through
# the API/CLI, never from a request.
#
# ★ Note what is NOT here: nothing copies a Config Store into ENV.  R003 §3-1
#   forbids flattening a binding namespace into the environment, because that
#   is exactly where "there is no such key" and "the key is empty" stop being
#   different answers.  `get` returns nil for the former and "" for the latter.
#
# ★ NAMING (E091 decision record draft, unconfirmed).  R016 T-4 names vendor
#   capabilities after the vendor, so the Config Store is `fastly/config`.
#   P008 Phase 4.5 floats a future family-level `edge/config` + `edge/secret`
#   for credentials (R014's promotion candidates); if that lands with an
#   attribution contract covering both platforms, this file's seat moves the
#   way edge/kv's may -- by editing the ledger and the require line, not by
#   changing what the bytes do.
require "edge/bridge"

module Fastly
  # sp_host_config_get(store, key) -> 1 value staged / 0 miss  (Fastly only)
  ffi_func :sp_host_config_get, [:str, :str], :int

  module Config
    def self.get(store, key)
      return nil if Fastly.sp_host_config_get(store.to_s, key.to_s) == 0
      Edge::Bridge.sp_host_res_body
    end

    def self.key?(store, key)
      Fastly.sp_host_config_get(store.to_s, key.to_s) == 1
    end
  end
end
