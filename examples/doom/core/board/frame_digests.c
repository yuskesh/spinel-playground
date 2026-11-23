/* examples/doom/core/board/frame_digests.c — a frame's digests, as hex.
 *
 * The provider of the board application's `Frame.digests` (decision 0021:
 * each frame's digest is computed by a core_extern with a C provider, since a
 * CORE helper at 32-bit width refuses the additions and products modulo 2^32
 * and 2^64 these need). It reads `screen` and writes into `out`, as one line
 * of 33 bytes:
 *
 *   the FNV-1a 64 of the first `view_bytes` bytes, 16 hex digits, a space,
 *   the FNV-1a 64 of the whole screen, 16 hex digits.
 *
 * They are the digests bin/doom.rb -frames writes and
 * tests/doom-core/fixtures/screens records (view, then full), so a board
 * frame compares with the recording directly. The board computes no SHA-256
 * (0021, the owner's decision of 2026-10-21). An `out` shorter than 33
 * bytes, or a `view_bytes` past the screen, leaves `out` unwritten.
 *
 * No Zephyr call, no allocation, no call back into CORE: one pass over the
 * input per digest, with the state in the frame.
 */
#include <stdint.h>

static void fnv_hex(const uint8_t *p, uint32_t n, uint8_t *out)
{
	static const char hex[] = "0123456789abcdef";
	uint64_t h = 0xcbf29ce484222325u;
	for (uint32_t i = 0; i < n; i++) {
		h ^= p[i];
		h *= 0x100000001b3u;
	}
	for (unsigned i = 0; i < 16; i++)
		out[i] = (uint8_t)hex[(h >> (60u - 4u * i)) & 15u];
}

void spc_app_frame_digests(const uint8_t *screen, uint32_t screen_len, uint32_t view_bytes, uint8_t *out, uint32_t out_len)
{
	if (out_len < 33u || view_bytes > screen_len)
		return;
	fnv_hex(screen, view_bytes, out);
	out[16] = ' ';
	fnv_hex(screen, screen_len, out + 17);
}
