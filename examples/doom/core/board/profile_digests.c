/* examples/doom/core/board/profile_digests.c — profile.rb's frame digests,
 * counted.
 *
 * The provider of profile.rb's `Frame.fnv`: what frame_digests.c's
 * `Frame.digests` writes (included below, unchanged), the 33 bytes of the two
 * FNV-1a 64 digests, view then full, that app.rb's line carries. A short
 * `out`, or a `view_bytes` past the screen, leaves `out` unwritten.
 *
 * spc_profile_tics counts the tics whose digests have been taken, one per
 * tic. Only the PC sampler of `spinel-core-app build --pcsample`
 * (tools/app/templates/pcsample_timer.c.erb) reads it, to stop after the
 * first N tics; the loop never does.
 */
#include "frame_digests.c"

volatile uint32_t spc_profile_tics;

void spc_app_frame_fnv(const uint8_t *screen, uint32_t screen_len, uint32_t view_bytes, uint8_t *out, uint32_t out_len)
{
	if (out_len < 33u || view_bytes > screen_len)
		return;
	spc_app_frame_digests(screen, screen_len, view_bytes, out, out_len);
	spc_profile_tics += 1u;
}
