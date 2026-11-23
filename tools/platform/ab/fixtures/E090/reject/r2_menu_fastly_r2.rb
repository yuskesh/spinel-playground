# s6 r2: menu violation -- a vendor capability built against the other
# platform's profile.  No tier comment (= full, so the tier check passes and
# the MENU is what refuses).  Expected via
#   spinel-wasm r2_menu_fastly_r2.rb --profile tools/platform/profiles/fastly-full.yaml -I ../subjects/root:
# REJECT menu-violation naming cloudflare/r2, platform fastly, supplied by workers.
require "cloudflare/r2"
puts Cloudflare::R2.probe
