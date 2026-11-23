#!/bin/sh
# The mutable FFI seam must keep the original screen and zone handles.
# This inspects generated C only; it requires neither Metal nor a CPU oracle.
set -eu
raster_repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPINEL=${SPINEL:-$raster_repo/vendor/spinel/bin/spinel}
RUBY=${RUBY:-ruby}
raster_borrow_tmp=$(mktemp -d "${TMPDIR:-/tmp}/raster-string-borrow.XXXXXX")
trap 'rm -rf "$raster_borrow_tmp"' EXIT HUP INT TERM
cd "$raster_repo"
RASTER_GPU=1 "$SPINEL" examples/doom/bin/doom.rb -S > "$raster_borrow_tmp/doom.c"
"$RUBY" - "$raster_borrow_tmp/doom.c" <<'RB'
c = File.read(ARGV.fetch(0))
def body(c, name)
  c[/^static[^\n]*\b#{Regexp.escape(name)}\([^;\n]*\) \{\n(.*?)^\}/m, 1] || abort("FAIL missing definition #{name}")
end
frame = body(c, 'sp_GpuRaster_frame')
draw = body(c, 'sp_GpuRaster_draw')
abort 'FAIL snapshot in GPU frame' if frame.match?(/\bsp_strbuf_read(?:_pub)?\s*\(/)
abort 'FAIL frame does not borrow both original handles' unless frame.scan(/\bsp_String_cstr_mut\s*\(/).length == 2
abort 'FAIL screen snapshot before frame' if draw.match?(/\bsp_strbuf_read(?:_pub)?\s*\(lv_scr\)/)
abort 'FAIL missing handle transfer to frame' unless draw.match?(/sp_String \* _t\d+ = lv_scr;/) && draw.include?('sp_GpuRaster_frame(')
puts 'raster string borrow: 4 passed, 0 failed'
RB
