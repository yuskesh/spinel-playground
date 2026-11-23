# tools/wasm/lib/edge/kv.rb -- the key/value store of the edge family
# (R016 T-3/T-4 `edge/kv`; the Ruby is E014's SpinelHost::KV, renamed by E091
# and otherwise untouched).
#
#   require "edge/kv"
#   Edge::KV.put("MY_KV", "k", "v")
#   Edge::KV.get("MY_KV", "k")        # "v", or nil for a miss
#
# This module is IDENTICAL on both platforms -- the Ruby, the `sp_host_kv_*`
# imports and the nil/"" rule are shared; only what is behind them differs
# (E058):
#
#   Workers   the *binding* name from wrangler.toml, and the worker must also
#             list it in SPINEL_HOST_KV.
#   Fastly    the KV Store name from fastly.toml's [local_server.kv_stores]
#             (locally) or from the service configuration.
#
# Either way a store is reachable only when the deployment says so, and asking
# for one that is not produces an ArgumentError naming it -- never a silent
# nil, which would be indistinguishable from an empty store.
#
# ★ THE LEDGER SAYS {workers, fastly} (R017, confirmed 2026-08-20).  The
#   attribution contract behind that entry is R017 §6.2 -- the load-bearing
#   clauses for a caller of this file:
#     * put's true means ACCEPTED, not VISIBLE: no platform promises that the
#       next get -- anywhere, even here -- sees the new value (both products
#       are eventually consistent, and Workers caches misses too).
#     * get never lies: nil is a miss, "" is a hit, bytes come back verbatim.
#     * keys up to 512 UTF-8 bytes avoiding Fastly's forbidden set (#;?^| and
#       control chars, not "."/".."), values up to 25MB, at most 1 write/s per
#       key, are portable; outside that envelope the platform answers with its
#       own loud error (E094 gates freeze the local halves of this envelope).
require "edge/bridge"

module Edge
  module KV
    # nil for a miss, a String (possibly "") for a hit.  Never "" for a miss:
    # collapsing absent onto empty is the failure R003 §3-1 forbids.
    def self.get(namespace, key)
      return nil if Edge::Bridge.sp_host_kv_get(namespace.to_s, key.to_s) == 0
      Edge::Bridge.sp_host_res_body
    end

    def self.put(namespace, key, value)
      v = value.to_s
      Edge::Bridge.sp_host_kv_put(namespace.to_s, key.to_s, v, v.bytesize)
      true
    end

    def self.key?(namespace, key)
      Edge::Bridge.sp_host_kv_get(namespace.to_s, key.to_s) == 1
    end

    def self.available?
      Edge.available?
    end
  end
end
