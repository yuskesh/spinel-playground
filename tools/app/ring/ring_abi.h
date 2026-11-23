/* tools/app/ring/ring_abi.h -- the OCRAM message ring between the
 * FRDM-IMXRT1186's cores, ABI version 5: the outbound ring of decision 0024's
 * amendment (item 1: the M7 puts, the M33 takes), since decision 0025 an
 * inbound ring beside it (the M33 puts, the M7 takes), since decision 0027
 * the pair words and the channel table of a pair's declared channels, and
 * since decision 0028 a fifth line per channel, the drift's estimate (line
 * E), and the doorbell's words in use; since 0028's follow-ups (owner,
 * 2026-10-29) a sixth line per channel, the drift rounds' t1 bounds (line
 * F), and the longest wait's message number in line C. Version 3 kept
 * version 2's lines 0 to 11 where they were and appended; versions 4 and 5
 * keep lines 0 to 15 and move the channels' lines; no version is
 * compatible with another: both images come from one build.
 * Shared by both images of the ring test
 * (tools/doom/ocram-ring/README.md), the DOOM application's udp: channel
 * and the M33 network firmware (tools/app/launcher); the ring ABI's version
 * is not the wire format's.
 *
 * THE REGION. The first 128 KB of OCRAM2: 0x2050_0000 in the M7's view,
 * 0x3050_0000 in the M33's (the `memory` node's ranges in Zephyr's
 * nxp_rt118x_cm7.dtsi and nxp_rt118x_cm33.dtsi). Both images keep it out of
 * their link (build.sh checks the final maps). It is Normal non-cacheable on
 * both, from Zephyr's own tables for all of OCRAM2, and neither image adds
 * a region: the M33's from nxp_rt118x_cm33.dtsi (ocram2's
 * ATTR_MPU_RAM_NOCACHE), the M7's from the board's
 * boards/nxp/frdm_imxrt1186/cm7/mpu_regions.c (its "OCRAM2" entry,
 * REGION_RAM_NOCACHE_ATTR). Each image reads its MPU at start and checks it
 * (README.md). Non-cacheable is not shareable here
 * (REGION_RAM_NOCACHE_ATTR is Non-shareable on both architectures), so the
 * order between the cores comes from full-system barriers, spc_ring_dmb()
 * below, not from the attribute.
 *
 * THE LAYOUT. Words are u32, little-endian; each line is 32 bytes and has
 * one writer.
 *   line 0  (M33, at initialisation)  magic, abi_version, depth, slot_stride,
 *                                     max_len, ring_offset, init_index
 *   line 1  (M33)                     boot_id, consumer_state; boot_id is
 *                                     the wire's per-boot id (0024's
 *                                     Clarification), 0 until the M33
 *                                     writes it once, a barrier before the
 *                                     store; the M7 loads it, never waits
 *   line 2  (M7)                      head: messages ever published
 *   line 3  (M33)                     tail: messages ever taken
 *   line 4  (M7)                      producer_state, attempted, accepted,
 *                                     refused
 *   lines 5-7                         the test's own words (not ABI)
 *   line 8  (M33, at initialisation)  the inbound ring's depth, slot_stride,
 *                                     max_len, ring_offset, init_index;
 *                                     depth 0 when there is no inbound ring
 *   line 9  (M33)                     in_head: inbound messages ever put
 *   line 10 (M7)                      in_tail: inbound messages ever taken,
 *                                     in_consumer_state
 *   line 11 (M33, before it releases  the pair words of decision 0027: a
 *            the M7; the M7 clears)   magic, then the pair id and the
 *                                     companion's id, each 64 bits as
 *                                     two words, high first; 0 when the
 *                                     M33 is no Spinel companion. The one
 *                                     exception to one writer a line: the
 *                                     M7 clears the magic once it has read
 *                                     it, so that a later boot whose M33
 *                                     writes no pair words never reads
 *                                     them as its own
 *   line 12 (M33, at initialisation)  the channel table (since version 3):
 *                                     magic SPCH, n_channels, first_line
 *                                     (16), header_bytes, slots_end, the
 *                                     layout digest's two words
 *   line 13 (M33)                     m33_state, m33_reason, m33_mpu (the
 *                                     region's attribute byte as found),
 *                                     and three words of the clocks' sync
 *   line 14 (M7)                      m7_state, m7_reason, m7_detail,
 *                                     m7_mpu, two words of the clocks'
 *                                     sync, pair_seen
 *   line 15 (M7)                      the M7's session id, as bytes
 *   lines 16 + 6i to 21 + 6i          channel i of the table, in name order:
 *     D (M33, at initialisation)      the contract digest's first 64 bits,
 *                                     flags, depth, stride, msg_bytes,
 *                                     offset, init_index
 *     P (the producer)                head, producer_state, attempted,
 *                                     accepted, refused, rung
 *     C (the consumer)                tail, consumer_state, fault, waiting,
 *                                     taken, woken (version 4: the
 *                                     doorbell's wake-ups the consumer took),
 *                                     lat_max_at (version 5: the number of
 *                                     the message whose wait is lat_max,
 *                                     in tail's running count: the value
 *                                     of tail when that message was
 *                                     taken, as each get takes one
 *                                     message; 0, and meaningless, while
 *                                     lat_n is 0)
 *     M (the consumer)                the wait from put to get, in the
 *                                     consumer's cycles (tools/app/ring/
 *                                     wait_map.h): lat_n, lat_min,
 *                                     lat_max, lat_sum (two words),
 *                                     sync_err (0xFFFFFFFF: not aligned),
 *                                     poll_max, drift
 *     E (the consumer, version 4)     the drift's estimate (decision 0028,
 *                                     Q5): of the drift rounds, n, the
 *                                     shortest trip, its departure and its
 *                                     round, the last round's trip,
 *                                     departure and round, and the longest
 *                                     trip; trips and departures in the
 *                                     consumer's cycles, a departure signed
 *                                     (the producer's counter ahead of the
 *                                     alignment's prediction is positive),
 *                                     a round its number, one a second
 *                                     since the alignment
 *     F (the consumer, the M33        the drift rounds' t1 bounds (version 5,
 *        alone, version 5)           0028's follow-ups): timeouts (the
 *                                     rounds no answer came to within
 *                                     5 ms), then g of the round with the
 *                                     shortest trip, of the last round, and
 *                                     the largest g; words 4 to 7 are 0, and
 *                                     a reader refuses them otherwise. g is
 *                                     the consumer's cycles from its read
 *                                     before the one that saw the answer to
 *                                     t1: the M7 stamps, a barrier, stores
 *                                     s7_seq, with interrupts locked; the
 *                                     M33 loads s7_seq, a barrier, then
 *                                     reads t1. So the stamp lies within
 *                                     g before t1, and the departure from
 *                                     t1 is a one-sided bound: the true one
 *                                     is in [dev - trip/2, dev - trip/2 + g]
 *   slot i at ring_offset + i * slot_stride: len (u32), then the payload;
 *   each ring has its own slots, the outbound ring's from line 0, the
 *   inbound ring's from line 8, and the two never overlap; a table
 *   channel's slot is len (u32, always msg_bytes), stamp (u32, the
 *   producer's clock at its put), then the message, its slots after the
 *   table's header_bytes, the channels in table order
 * flags: bits 0-7 from (1 the M7, 2 the M33), 8-15 to, 16-23 kind (1: typed,
 * fixed length), 24-31 notify, 0 for polling. notify names the doorbell
 * (decision 0028): bits 24-25 the MU (1 MU1, 2 MU2), bits 26-27 its
 * general-purpose interrupt, the n of GIRn, bits 28-31 0. rung and waiting
 * are the doorbell's: both 0 at the start, a reader that finds either other
 * than 0 then refuses the channel, and they stay 0 while notify is 0.
 *
 * THE DOORBELL (decision 0028), for a channel whose notify is not 0. The
 * consumer, finding the ring empty, stores waiting = 1, a barrier, and
 * reads head again; it takes a message that came meanwhile, and stores
 * waiting = 0 when it takes one. The producer, after storing head, a
 * barrier, reads waiting; when it is 1 it rings: it reads its own side's
 * GCR and, when GIRn is 0, writes GIRn alone (1 << n; the RM: verify the
 * field is 0 before writing 1), and counts rung. A ring that finds GIRn
 * still 1 is not repeated: the consumer has not taken the last one, and
 * takes every message when it does. A put that missed waiting = 1 came
 * before the consumer's second read of head, which sees it, so no wake-up
 * is lost. The doorbell only wakes: the data path is the ring's.
 * head and tail are running counts, u32, and depth is a power of two, so the
 * slot of message n is n & (depth - 1) and head - tail is the occupancy across
 * the counts' wrap at 2^32. head - tail == depth is full; head - tail > depth
 * cannot happen and is a fault.
 *
 * PUBLICATION. A put reads tail, then a barrier (acquire); refuses when full;
 * writes the payload and len into the slot; a barrier (release); then stores
 * head + 1. A take reads head, a barrier (acquire), checks len <= max_len,
 * copies the slot, and only when it is done with the slot a barrier (release)
 * and stores tail + 1. Each index is one aligned u32 load or store.
 *
 * INITIALISATION, by the M33 alone, before it releases the M7 (a SYS_INIT at
 * PRE_KERNEL_1; second_core_boot runs at PRE_KERNEL_2): magic first set to 0,
 * then the geometry, head = tail = init_index and the states (for the inbound
 * ring too: its geometry, in_head = in_tail = its init_index), a barrier, and
 * magic last. The M7 reads magic, a barrier, then checks the geometry
 * (spc_ring_geometry_ok) and refuses the ring when anything is off.
 *
 * RESET. Only a start of the whole chip (power-on, or a system reset of both
 * cores) is supported: both cores are then stopped before the M33 initialises
 * the ring. An M33 reset alone is not known to stop a running M7 (Zephyr's
 * Prepare_CM7 sets the M7's vector table and releases it, and stops nothing),
 * and an M7 restart alone is outside this ABI; neither is a recovery this
 * ring promises. */
#ifndef SPC_RING_ABI_H
#define SPC_RING_ABI_H
#include <stdint.h>

#define SPC_RING_MAGIC 0x47525053u /* "SPRG" */
#define SPC_RING_ABI_VERSION 5u
#define SPC_RING_BYTES (128u * 1024u)
/* the region in each core's view; a host harness (tests/app/udp.sh) defines
 * them first, to a region of its own */
#ifndef SPC_RING_M7_BASE
#define SPC_RING_M7_BASE 0x20500000u
#endif
#ifndef SPC_RING_M33_BASE
#define SPC_RING_M33_BASE 0x30500000u
#endif

/* word offsets */
#define SPC_RING_W_MAGIC 0u
#define SPC_RING_W_VERSION 1u
#define SPC_RING_W_DEPTH 2u
#define SPC_RING_W_STRIDE 3u
#define SPC_RING_W_MAX_LEN 4u
#define SPC_RING_W_OFFSET 5u
#define SPC_RING_W_INIT_INDEX 6u
#define SPC_RING_W_BOOT_ID 8u        /* line 1 */
#define SPC_RING_W_CONSUMER_STATE 9u
#define SPC_RING_W_HEAD 16u          /* line 2 */
#define SPC_RING_W_TAIL 24u          /* line 3 */
#define SPC_RING_W_PRODUCER_STATE 32u /* line 4 */
#define SPC_RING_W_ATTEMPTED 33u
#define SPC_RING_W_ACCEPTED 34u
#define SPC_RING_W_REFUSED 35u
/* the inbound ring (version 2) */
#define SPC_RING_W_IN_DEPTH 64u      /* line 8 */
#define SPC_RING_W_IN_STRIDE 65u
#define SPC_RING_W_IN_MAX_LEN 66u
#define SPC_RING_W_IN_OFFSET 67u
#define SPC_RING_W_IN_INIT_INDEX 68u
#define SPC_RING_W_IN_HEAD 72u       /* line 9 */
#define SPC_RING_W_IN_TAIL 80u       /* line 10 */
#define SPC_RING_W_IN_CONSUMER_STATE 81u
/* line 11, the pair words (decision 0027) */
#define SPC_RING_W_PAIR_MAGIC 88u    /* line 11 */
#define SPC_RING_W_PAIR_HI 89u
#define SPC_RING_W_PAIR_LO 90u
#define SPC_RING_W_COMPANION_HI 91u
#define SPC_RING_W_COMPANION_LO 92u
#define SPC_PAIR_MAGIC 0x52505053u /* "SPPR" */
/* line 12, the channel table (version 3) */
#define SPC_RING_W_CHAN_MAGIC 96u
#define SPC_RING_W_N_CHANNELS 97u
#define SPC_RING_W_FIRST_LINE 98u
#define SPC_RING_W_HEADER_BYTES 99u
#define SPC_RING_W_SLOTS_END 100u
#define SPC_RING_W_LAYOUT_HI 101u
#define SPC_RING_W_LAYOUT_LO 102u
#define SPC_CHAN_MAGIC 0x48435053u /* "SPCH" */
#define SPC_CHAN_FIRST_LINE 16u
/* line 13 (M33) */
#define SPC_RING_W_M33_STATE 104u
#define SPC_RING_W_M33_REASON 105u
#define SPC_RING_W_M33_MPU 106u
#define SPC_RING_W_S33_SEQ 107u
#define SPC_RING_W_S33_T0 108u        /* the kept round's t0 and t1, the consumer's counter */
#define SPC_RING_W_S33_T1 109u
#define SPC_SYNC_DONE 0xFFFFFFFFu     /* s33_seq once the start's exchange is over */
/* line 14 (M7) */
#define SPC_RING_W_M7_STATE 112u
#define SPC_RING_W_M7_REASON 113u
#define SPC_RING_W_M7_DETAIL 114u
#define SPC_RING_W_M7_MPU 115u
#define SPC_RING_W_S7_SEQ 116u
#define SPC_RING_W_S7_T 117u
#define SPC_RING_W_PAIR_SEEN 118u
/* line 15 (M7): the session id's bytes */
#define SPC_RING_W_M7_SESSION 120u
#define SPC_RING_HEADER_BYTES 512u   /* lines 0-15, the header without channels */

/* channel i's six lines, as word offsets: D, P, C, M, E, F */
#define SPC_CH_LINES 6u
#define SPC_CH_D(i) ((SPC_CHAN_FIRST_LINE + SPC_CH_LINES * (i)) * 8u)
#define SPC_CH_P(i) (SPC_CH_D(i) + 8u)
#define SPC_CH_C(i) (SPC_CH_D(i) + 16u)
#define SPC_CH_M(i) (SPC_CH_D(i) + 24u)
#define SPC_CH_E(i) (SPC_CH_D(i) + 32u)
#define SPC_CH_F(i) (SPC_CH_D(i) + 40u)
/* in D */
#define SPC_CH_D_DIGEST_HI 0u
#define SPC_CH_D_DIGEST_LO 1u
#define SPC_CH_D_FLAGS 2u
#define SPC_CH_D_DEPTH 3u
#define SPC_CH_D_STRIDE 4u
#define SPC_CH_D_MSG_BYTES 5u
#define SPC_CH_D_OFFSET 6u
#define SPC_CH_D_INIT_INDEX 7u
/* in P */
#define SPC_CH_P_HEAD 0u
#define SPC_CH_P_STATE 1u
#define SPC_CH_P_ATTEMPTED 2u
#define SPC_CH_P_ACCEPTED 3u
#define SPC_CH_P_REFUSED 4u
#define SPC_CH_P_RUNG 5u
/* in C */
#define SPC_CH_C_TAIL 0u
#define SPC_CH_C_STATE 1u
#define SPC_CH_C_FAULT 2u
#define SPC_CH_C_WAITING 3u
#define SPC_CH_C_TAKEN 4u
#define SPC_CH_C_WOKEN 5u             /* version 4 (decision 0028) */
#define SPC_CH_C_LAT_MAX_AT 6u        /* version 5: the number of the message whose wait is lat_max */
/* in M */
#define SPC_CH_M_LAT_N 0u
#define SPC_CH_M_LAT_MIN 1u
#define SPC_CH_M_LAT_MAX 2u
#define SPC_CH_M_LAT_SUM_LO 3u
#define SPC_CH_M_LAT_SUM_HI 4u
#define SPC_CH_M_SYNC_ERR 5u
#define SPC_CH_M_POLL_MAX 6u
#define SPC_CH_M_DRIFT 7u             /* the largest departure from the alignment past a round's own error */
/* in E (version 4) */
#define SPC_CH_E_N 0u
#define SPC_CH_E_TRIP_MIN 1u
#define SPC_CH_E_DEV_AT_MIN 2u
#define SPC_CH_E_ROUND_AT_MIN 3u
#define SPC_CH_E_TRIP_LAST 4u
#define SPC_CH_E_DEV_LAST 5u
#define SPC_CH_E_ROUND_LAST 6u
#define SPC_CH_E_TRIP_MAX 7u
/* in F (version 5; the M33 alone writes it) */
#define SPC_CH_F_TIMEOUTS 0u
#define SPC_CH_F_G_AT_MIN 1u
#define SPC_CH_F_G_LAST 2u
#define SPC_CH_F_G_MAX 3u
#define SPC_CH_F_SPARE 4u            /* words 4 to 7: 0 */
#define SPC_CH_SLOT_WORDS 2u         /* len and stamp, before the message */
#define SPC_CH_FLAGS(from, to) ((uint32_t)(from) | ((uint32_t)(to) << 8) | (1u << 16))
/* the notify byte of a doorbell on MU mu's general-purpose interrupt gi */
#define SPC_CH_NOTIFY(mu, gi) (((uint32_t)(mu) | ((uint32_t)(gi) << 2)) << 24)
#define SPC_MU_GCR 0x114u            /* the General-Purpose Control register, GIRn at bit n (RM §37.7) */
#define SPC_CORE_M7 1u
#define SPC_CORE_M33 2u
#define SPC_CH_FAULT_OCCUPANCY 1u    /* head - tail above depth */
#define SPC_CH_FAULT_LEN 2u          /* len is not msg_bytes */
#define SPC_M33_INIT 0u
#define SPC_M33_RUNNING 1u
#define SPC_M33_REFUSED 2u
#define SPC_M7_STARTING 0u
#define SPC_M7_READY 1u
#define SPC_M7_REFUSED 2u
#define SPC_M7_FATAL 3u

#define SPC_RING_CONSUMER_STOPPED 0u
#define SPC_RING_CONSUMER_TAKING 1u
#define SPC_RING_CONSUMER_FAULT 3u
#define SPC_RING_CONSUMER_REFUSED 4u
#define SPC_RING_PRODUCER_STARTING 0u
#define SPC_RING_PRODUCER_PUTTING 1u
#define SPC_RING_PRODUCER_DONE 2u
#define SPC_RING_PRODUCER_REFUSED 4u

/* a full-system data memory barrier with a compiler memory clobber, as
 * CMSIS's __DMB */
static inline void spc_ring_dmb(void)
{
#if defined(SPC_RING_HOST)
	__atomic_thread_fence(__ATOMIC_SEQ_CST); /* a host harness (tests/app/udp.sh) */
#else
	__asm__ volatile("dmb 0xF" ::: "memory");
#endif
}

static inline uint32_t spc_ring_load(volatile uint32_t *w, uint32_t i)
{
	return w[i];
}

static inline void spc_ring_store(volatile uint32_t *w, uint32_t i, uint32_t v)
{
	w[i] = v;
}

/* the geometry a reader accepts: depth a power of two in 1 .. 2^30, the slot
 * holding its length word and max_len bytes, the slots 32-byte aligned after
 * the header and inside the region, each step checked so that nothing
 * overflows */
static inline int spc_ring_geometry_ok(uint32_t depth, uint32_t stride, uint32_t max_len, uint32_t offset)
{
	if (depth == 0u || (depth & (depth - 1u)) != 0u || depth >= (1u << 31)) {
		return 0;
	}
	if (max_len == 0u || max_len > SPC_RING_BYTES || stride < 4u + max_len || (stride & 31u) != 0u) {
		return 0;
	}
	if (offset < SPC_RING_HEADER_BYTES || (offset & 31u) != 0u || offset > SPC_RING_BYTES) {
		return 0;
	}
	if (stride > (SPC_RING_BYTES - offset) / depth) {
		return 0;
	}
	return 1;
}

static inline volatile uint8_t *spc_ring_slot(volatile uint32_t *w, uint32_t offset, uint32_t stride, uint32_t depth, uint32_t n)
{
	return (volatile uint8_t *)w + offset + (n & (depth - 1u)) * stride;
}
#endif
