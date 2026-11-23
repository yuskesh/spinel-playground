/* tools/doom/ocram-ring/test_words.h -- the ring test's own words, lines 5
 * to 7 of the region (not part of ring_abi.h's ABI), and the test's message
 * patterns, shared by both images.
 *
 * MESSAGES. A message's len counts every byte of it. The first SHORT_COUNT
 * messages are the short ones: message c (0-based) is c + 1 bytes, byte i
 * being 0x50 + c + i. After them every message is a normal one, at least 8
 * bytes: seq (u32, the producer's attempt number among normal messages, from
 * 0), refused (u32, the producer's refusals among normal attempts before
 * this one), then byte i (8 <= i < len) = (seq * 7 + i) mod 256. The length
 * of seq 0 is the maximum, 1292; of seq s > 0 it is 8 + (s * 37) mod 1285,
 * so every length from 8 to 1292 comes round. Comparisons of seq and refused
 * are u32 differences, so their wrap is no special case. */
#ifndef SPC_RING_TEST_WORDS_H
#define SPC_RING_TEST_WORDS_H
#include <stdint.h>

#define SPC_TEST_DEPTH 64u
#define SPC_TEST_STRIDE 1312u      /* 41 x 32, for 4 + 1292 bytes */
#define SPC_TEST_MAX_LEN 1292u
#define SPC_TEST_OFFSET 512u       /* after the header (version 3, lines 0-15), which holds the test's lines */
#define SPC_TEST_INIT_INDEX 0xFFFFFF00u /* the counts cross 2^32 after 256 messages */
#define SPC_TEST_BOOT_ID 0x00000001u    /* a placeholder written at initialisation: the
                                         * DOOM firmware writes 0 there and the wire id after DHCP */
#define SPC_TEST_SHORT_COUNT 7u
#define SPC_TEST_PUT_MS 3000u      /* how long the M7 puts normal messages */
#define SPC_TEST_PAUSE_AT 5000u    /* the M33 stops taking after this many normal messages */
#define SPC_TEST_PAUSE_MS 200u
#define SPC_TEST_TIMEOUT_MS 10000u /* no progress for this long is a failure */

/* line 5 (M33): the report; status is written last */
#define SPC_TW_STATUS 40u          /* 0 none yet, 1 pass, 2 fail */
#define SPC_TW_TAKEN_NORMAL 41u
#define SPC_TW_TAKEN_SHORT 42u
#define SPC_TW_ERRORS 43u
#define SPC_TW_FIRST_ERROR_KIND 44u
#define SPC_TW_FIRST_ERROR_AT 45u  /* the taken count when it happened */
#define SPC_TW_MAX_OCCUPANCY 46u
#define SPC_TW_PAUSED_MS 47u
/* line 6 (M33) */
#define SPC_TW_M33_PROBE 48u       /* written before the M7 is released */
#define SPC_TW_M7_PROBE_SEEN 49u   /* the M7's probe as the M33 read it */
#define SPC_TW_MPU_RBAR 50u        /* the M33's MPU region covering the ring */
#define SPC_TW_MPU_RLAR 51u
#define SPC_TW_MPU_ATTR 52u        /* its MAIR attribute byte */
#define SPC_TW_FINAL_HEAD 53u
#define SPC_TW_FINAL_TAIL 54u
/* line 7 (M7) */
#define SPC_TW_M7_PROBE 56u

#define SPC_TEST_M33_PROBE 0x5A5A1234u
#define SPC_TEST_M7_PROBE 0xA5A5EDCBu

/* error kinds */
#define SPC_TE_LEN 1u        /* a len of 0 or above max_len: a fault, taking stops */
#define SPC_TE_CONTENT 2u    /* a byte, or a normal message's length, not its pattern */
#define SPC_TE_SEQ 3u        /* a gap in seq that is not the refusals between */
#define SPC_TE_OCCUPANCY 4u  /* head - tail above depth: a fault, taking stops */
#define SPC_TE_END 5u        /* the end's counts do not close */
#define SPC_TE_SHORT 6u      /* a short message not its pattern */
#define SPC_TE_TIMEOUT 7u    /* the producer made no progress */
#define SPC_TE_PROBE 8u      /* the M7's probe word was not seen */

static inline uint32_t spc_test_len(uint32_t seq)
{
	return seq == 0u ? 1292u : 8u + (seq * 37u) % 1285u;
}

static inline uint8_t spc_test_byte(uint32_t seq, uint32_t i)
{
	return (uint8_t)(seq * 7u + i);
}

static inline uint8_t spc_test_short_byte(uint32_t c, uint32_t i)
{
	return (uint8_t)(0x50u + c + i);
}
#endif
