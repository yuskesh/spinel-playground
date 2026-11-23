/* tools/app/ring/wait_map.h -- the wait from a put to its get between the
 * FRDM-IMXRT1186's cores (decision 0027 stage 2, Stage 2's choices), in the
 * consumer's cycles.
 *
 * THE CLOCKS. The system counter is stopped on this board (SYS_CTR's CNTCR
 * is 0, read 2026-10-26; only reading it is approved), so each core's own
 * cycle counter is used: DWT CYCCNT, which a channel unit reads directly, a
 * load and no call, so that its stack evidence stays its own frame (owner,
 * 2026-10-26). Both cores run from the 24 MHz RC oscillator (RC24M): their
 * ratio is fixed by the builds' CYCLES_PER_SECOND (792 MHz on the M7, 240 MHz
 * on the M33, 33/10), while the absolute rate carries the RC oscillator's
 * error, so a figure in ns is as exact as RC24M.
 *
 * THE ALIGNMENT, by the consumer's glue. One round trip is the consumer's t0
 * and t1 around the producer's answer t (its own counter). It is placed at
 * the midpoint, (t0 + t1) / 2, with an error of (t1 - t0) / 2; of the
 * rounds, the one with the shortest trip is kept (spc_wait_round). The
 * consumer's counter is extended to 64 bits by the glue, which also writes,
 * every few milliseconds, a fresh reference pair -- its counter now and the
 * producer's counter it predicts for now -- into spc_wait_ref, the other of
 * the two slots first and the selector last.
 *
 * THE WAIT, in the consumer's get (spc_wait_of): from the newest pair, the
 * producer's counter now; the stamp's distance behind it, signed (within the
 * alignment's error a stamp may lie just ahead); that distance in consumer
 * cycles. Integer arithmetic, 32 by 32 multiplies into 64 bits and shifts,
 * and no division, so the unit calls no helper. A wait is right while it is
 * shorter than half a wrap of the producer's counter (2.7 s at 792 MHz) and
 * while the pair is younger than one wrap of the consumer's (17.9 s at
 * 240 MHz). */
#ifndef SPC_WAIT_MAP_H
#define SPC_WAIT_MAP_H
#include <stdint.h>

/* the reference the get reads; k_prod is the producer's cycles per consumer
 * cycle in 16.16, k_cons the consumer's per producer cycle in 0.32; valid is
 * 1 once an alignment was made */
struct spc_wait_ref {
	uint32_t sel, valid, k_prod, k_cons;
	uint32_t a_cons[2], a_prod[2];
};
extern volatile struct spc_wait_ref spc_wait_ref;

/* the consumer cycles from a put stamped `stamp` to the consumer's `now`;
 * 0 when there is no alignment, or the stamp is not behind */
static inline uint32_t spc_wait_of(volatile struct spc_wait_ref *r, uint32_t now, uint32_t stamp)
{
	uint32_t s, d, pred;
	int32_t w;

	if (r->valid == 0u) {
		return 0u;
	}
	s = r->sel & 1u;
	d = now - r->a_cons[s];
	pred = r->a_prod[s] + (uint32_t)(((uint64_t)d * r->k_prod) >> 16);
	w = (int32_t)(pred - stamp);
	if (w <= 0) {
		return 0u;
	}
	return (uint32_t)(((uint64_t)(uint32_t)w * r->k_cons) >> 32);
}

/* the histogram's bucket: the wait's binary order, 0 for 0 or 1 cycle, 31
 * at most (32 buckets of powers of two consumer cycles) */
static inline uint32_t spc_wait_bucket(uint32_t cycles)
{
	return cycles <= 1u ? 0u : 31u - (uint32_t)__builtin_clz(cycles);
}

/* ---- the glue's side: 64-bit, on the consumer's start-up and watch paths */
struct spc_wait_map {
	uint64_t ref_consumer; /* the consumer's time at the kept round's midpoint */
	uint32_t ref_producer; /* the producer's counter there */
	uint32_t err;          /* half the kept round trip, consumer cycles; 0xFFFFFFFF: no round */
};

/* one round: keeps it when it is the shortest so far */
static inline void spc_wait_round(struct spc_wait_map *m, uint64_t t0, uint64_t t1, uint32_t producer)
{
	uint64_t half = (t1 - t0) / 2u;

	if (t1 < t0 || half >= 0xFFFFFFFFu) {
		return;
	}
	if (m->err == 0xFFFFFFFFu || half < m->err) {
		m->ref_consumer = t0 + half;
		m->ref_producer = producer;
		m->err = (uint32_t)half;
	}
}

/* the producer's counter the alignment predicts at the consumer's `now`;
 * num/den is the producer's cycles per consumer cycle, reduced */
static inline uint32_t spc_wait_predict(const struct spc_wait_map *m, uint64_t now, uint32_t num, uint32_t den)
{
	int64_t d = (int64_t)(now - m->ref_consumer);

	return m->ref_producer + (uint32_t)(d / (int64_t)den * (int64_t)num + d % (int64_t)den * (int64_t)num / (int64_t)den);
}

/* a fresh reference pair for the get: the other slot first, the selector
 * last */
static inline void spc_wait_publish(volatile struct spc_wait_ref *r, const struct spc_wait_map *m, uint64_t now, uint32_t num, uint32_t den)
{
	uint32_t s = (r->sel & 1u) ^ 1u;

	r->a_cons[s] = (uint32_t)now;
	r->a_prod[s] = spc_wait_predict(m, now, num, den);
	r->sel = s;
}
#endif
