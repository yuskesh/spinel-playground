/* tools/app/templates/recorder.c -- copied verbatim into the staging by
 * spinel-core-app build: the recorder of a verification build (decision 0014
 * §10 (a)); its sizes come from the generated recorder.h.
 *
 * Every record is appended inside one critical section: PRIMASK is saved,
 * set and restored, so nested sections restore correctly and every
 * configurable-priority exception -- Zephyr's zero-latency ones included --
 * is masked; entering and leaving are compiler barriers (asm volatile with
 * a memory clobber), so no recorded access moves across the section. The
 * global sequence number is taken inside the section: on this single core,
 * with nothing that touches a recorded object able to run meanwhile, it is
 * the order in which the operations took effect. Nothing inside blocks: the
 * append writes into a fixed ring per context and never waits; a full ring
 * sets the context's overflow flag instead, and verification then fails.
 *
 * The rings are drained by the transport thread over the UART as frames on
 * the trace channel (transport_uart.c, SPC_TRACE_CHANNEL); the drainer's
 * reads happen outside the section, against the producers' published
 * indices. The hooks the kernel's --record-cross lowering calls
 * (spc_record_load/store) find the state by the element's address in the
 * table main.c registers. */
#include <stdint.h>
#include "recorder.h"

struct spc_rec_ring {
	uint8_t buf[SPC_REC_RING];
	volatile uint32_t head; /* bytes written, by the producer */
	volatile uint32_t tail; /* bytes drained, by the transport thread */
	volatile uint8_t overflow;
};
static struct spc_rec_ring spc_rec_rings[SPC_REC_CONTEXTS];
static uint32_t spc_rec_seq;
uint32_t spc_rec_dropped; /* records the rings could not hold, all contexts */
uint32_t spc_rec_unregistered; /* accesses at an address no registered state holds: a recorder fault */

/* the current context and entry, for records written from CORE code, which
 * knows neither: set by the dispatchers around each invocation and by the
 * interrupt handlers around their dispatch (saved and restored, so a
 * preempting handler leaves the thread's values as they were) */
volatile uint8_t spc_rec_ctx = 0u;
volatile uint8_t spc_rec_entry = SPC_NO_ENTRY;

void spc_rec_write(uint8_t ctx, uint8_t entry, uint16_t kind, const uint8_t *body, uint32_t len)
{
	struct spc_rec_ring *r;
	uint32_t primask = spc_rec_section_enter();
	uint32_t seq = spc_rec_seq++;
	uint32_t used, need, i;
	uint8_t hdr[SPC_REC_HEADER_LEN];

	if (ctx >= SPC_REC_CONTEXTS) {
		ctx = SPC_REC_CONTEXTS - 1u;
	}
	r = &spc_rec_rings[ctx];
	used = r->head - r->tail;
	need = SPC_REC_HEADER_LEN + len;
	if (SPC_REC_RING - used < need || len > SPC_REC_BODY_MAX) {
		r->overflow = 1u;
		spc_rec_dropped += 1u;
		spc_rec_section_leave(primask);
		return;
	}
	hdr[0] = 'S'; hdr[1] = 'P'; hdr[2] = 'T'; hdr[3] = 'R';
	spc_rec_put16(hdr + 4, (uint16_t)SPC_TRACE_VERSION);
	spc_rec_put16(hdr + 6, kind);
	spc_rec_put32(hdr + 8, len);
	spc_rec_put32(hdr + 12, seq);
	hdr[16] = ctx;
	hdr[17] = entry;
	hdr[18] = 0u; hdr[19] = 0u;
	for (i = 0; i < SPC_REC_HEADER_LEN; i++) {
		r->buf[(r->head + i) % SPC_REC_RING] = hdr[i];
	}
	for (i = 0; i < len; i++) {
		r->buf[(r->head + SPC_REC_HEADER_LEN + i) % SPC_REC_RING] = body[i];
	}
	r->head += need;
	spc_rec_section_leave(primask);
}

void spc_rec_oversize(uint8_t ctx)
{
	uint32_t primask = spc_rec_section_enter();

	spc_rec_rings[ctx < SPC_REC_CONTEXTS ? ctx : 0].overflow = 1u;
	spc_rec_dropped += 1u;
	spc_rec_section_leave(primask);
}

void spc_tr_XCALL(uint8_t ctx, uint8_t entry, uint16_t ext, uint8_t argc, const struct spc_rec_arg *args)
{
	uint8_t body[SPC_REC_BODY_MAX];
	uint32_t p = 0;

	spc_rec_put16(body + p, ext); p += 2;
	spc_rec_put8(body + p, argc); p += 1;
	for (uint8_t k = 0; k < argc; k++) {
		spc_rec_put8(body + p, args[k].tag); p += 1;
		if (args[k].tag == 0u) {
			spc_rec_put64(body + p, (uint64_t)args[k].scalar); p += 8;
		} else {
			if (p + 4u + args[k].len > SPC_REC_BODY_MAX) {
				spc_rec_oversize(ctx);
				return;
			}
			spc_rec_put32(body + p, args[k].len); p += 4;
			for (uint32_t i = 0; i < args[k].len; i++) { body[p + i] = args[k].buf[i]; }
			p += args[k].len;
		}
	}
	spc_rec_write(ctx, entry, SPC_TK_XCALL, body, p);
}

/* ---- the hooks of the kernel's --record-cross lowering: the state is
 * found by the element's address in the table main.c fills */
struct spc_rec_state { const uint8_t *base; uint32_t count; uint8_t width; uint8_t id; };
static struct spc_rec_state spc_rec_states[SPC_REC_STATES];
static uint8_t spc_rec_state_count;

void spc_rec_register_state(uint8_t id, const void *base, uint32_t count, uint8_t width)
{
	if (spc_rec_state_count < SPC_REC_STATES) {
		spc_rec_states[spc_rec_state_count].base = (const uint8_t *)base;
		spc_rec_states[spc_rec_state_count].count = count;
		spc_rec_states[spc_rec_state_count].width = width;
		spc_rec_states[spc_rec_state_count].id = id;
		spc_rec_state_count++;
	}
}

static int spc_rec_find(const void *addr, uint32_t width, uint8_t *state, uint32_t *index)
{
	const uint8_t *a = (const uint8_t *)addr;

	for (uint8_t i = 0; i < spc_rec_state_count; i++) {
		const struct spc_rec_state *s = &spc_rec_states[i];
		uint32_t span = s->count * s->width;

		if (a >= s->base && a < s->base + span && s->width == width) {
			*state = s->id;
			*index = (uint32_t)(a - s->base) / width;
			return 1;
		}
	}
	return 0;
}

/* the access and its record inside one section (0014 §10 (a)): the
 * kernel's --record-cross lowering calls these in place of the atomic
 * load and store of a cross-context element */
int64_t spc_record_load(const void *addr, uint32_t width, uint32_t is_signed)
{
	uint8_t state; uint32_t index;
	int64_t value;
	uint32_t primask = spc_rec_section_enter();

	switch (width) {
	case 1: value = is_signed ? (int64_t)*(const volatile int8_t *)addr : (int64_t)*(const volatile uint8_t *)addr; break;
	case 2: value = is_signed ? (int64_t)*(const volatile int16_t *)addr : (int64_t)*(const volatile uint16_t *)addr; break;
	case 4: value = is_signed ? (int64_t)*(const volatile int32_t *)addr : (int64_t)*(const volatile uint32_t *)addr; break;
	default: value = *(const volatile int64_t *)addr; break;
	}
	if (spc_rec_find(addr, width, &state, &index)) {
		spc_tr_LOAD(spc_rec_ctx, spc_rec_entry, state, index, value);
	} else {
		spc_rec_unregistered += 1u; /* an address no registered state holds: printed with the end line */
	}
	spc_rec_section_leave(primask);
	return value;
}

void spc_record_store(const void *addr, uint32_t width, int64_t value)
{
	uint8_t state; uint32_t index;
	uint32_t primask = spc_rec_section_enter();

	switch (width) {
	case 1: *(volatile uint8_t *)addr = (uint8_t)value; break;
	case 2: *(volatile uint16_t *)addr = (uint16_t)value; break;
	case 4: *(volatile uint32_t *)addr = (uint32_t)value; break;
	default: *(volatile int64_t *)addr = value; break;
	}
	if (spc_rec_find(addr, width, &state, &index)) {
		spc_tr_STORE(spc_rec_ctx, spc_rec_entry, state, index, value);
	} else {
		spc_rec_unregistered += 1u;
	}
	spc_rec_section_leave(primask);
}

/* ---- the drainer's side (the transport thread): up to `max` bytes of one
 * ring into `out`; the overflow flag is read and cleared with the bytes so
 * the OVERFLOW record follows what was kept */
uint32_t spc_rec_drain(uint8_t ctx, uint8_t *out, uint32_t max, uint8_t *overflowed)
{
	struct spc_rec_ring *r = &spc_rec_rings[ctx];
	uint32_t head = r->head; /* one read: the producer only ever grows it */
	uint32_t n = head - r->tail;
	uint32_t i;

	if (n > max) {
		n = max;
	}
	for (i = 0; i < n; i++) {
		out[i] = r->buf[(r->tail + i) % SPC_REC_RING];
	}
	r->tail += n;
	{
		/* one read: a producer setting the flag between two reads would be
		 * cleared here without ever being reported */
		uint8_t of = r->overflow;

		*overflowed = of;
		if (of && n == 0u) {
			r->overflow = 0u; /* reported once, after the ring is empty */
		}
	}
	return n;
}

uint32_t spc_rec_pending(void)
{
	uint32_t n = 0;

	for (uint8_t c = 0; c < SPC_REC_CONTEXTS; c++) {
		n += spc_rec_rings[c].head - spc_rec_rings[c].tail;
	}
	return n;
}

uint32_t spc_rec_sequence(void)
{
	return spc_rec_seq;
}
