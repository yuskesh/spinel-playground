/* SPDX-License-Identifier: GPL-2.0
 *
 * amp_ring_devmem_test.c — P009 T2: the A-core half of the AMP transport, on a
 * real board, against a real reserved-memory carveout.
 *
 *   amp_ring_devmem_test <phys_base> [n_records] [capacity]
 *
 * The ring ABI already has a host test (run_amp_ring.sh) that exercises it in
 * ordinary malloc'd memory. What that cannot tell you is whether the same ABI
 * survives the mapping it will actually live in: a `no-map` reserved region,
 * reached through /dev/mem, on a kernel built with CONFIG_STRICT_DEVMEM. Those
 * are the parts that differ per board, and they are the parts P009 is testing.
 *
 * Deliberately does NOT involve the M-core. Separating transport from execution
 * is the same decomposition P007 S3 used on the other board: if the ring, the
 * mapping and the wrap-around are already proven from the A-core side, then a
 * failure after the firmware lands is a firmware failure, not a mystery.
 *
 * Static-linked: the board runs glibc 2.39 and the build container 2.41, and
 * this needs no NSS, no dlopen and no libbpf -- so a static binary is the whole
 * toolchain story, and `scp` is the whole deployment story.
 *
 * TRAP, measured here: /dev/mem opened with O_SYNC gives a Device mapping, and
 * glibc's aarch64 memset() switches to `DC ZVA` above a size threshold -- which
 * is architecturally not allowed on Device memory and takes a bus error. On this
 * board the boundary is between 128 and 256 bytes: a small memset works, so a
 * test written against a small buffer passes and the same code faults later with
 * a bigger one. Everything below therefore clears the region with an aligned
 * word loop. (src/runtime/amp/a55_stage.c already warned that memcpy's wide and
 * unaligned stores fault here; this is the same family, in its size-dependent
 * form, which is the harder one to notice.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>

#include "spnl/amp_ring.h"

static int fails;
#define CHECK(cond, ...) do { \
    if (cond) { printf("  ok: "); printf(__VA_ARGS__); printf("\n"); } \
    else { printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } \
} while (0)

/* Clear a Device-mapped region without memset: see the trap note above. */
static void devmem_clear(volatile uint32_t *p, size_t bytes) {
    for (size_t i = 0; i < bytes / 4; i++) p[i] = 0;
}

int main(int argc, char **argv) {
    /* Unbuffered: a bus error loses everything still sitting in the buffer, and
     * "no output at all" is the least useful way to learn where a fault was. */
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 2) {
        fprintf(stderr, "usage: %s <phys_base> [n_records] [capacity]\n", argv[0]);
        return 2;
    }
    unsigned long long base = strtoull(argv[1], NULL, 0);
    uint32_t n_rec = (argc > 2) ? (uint32_t)strtoul(argv[2], NULL, 0) : 64;
    uint32_t cap   = (argc > 3) ? (uint32_t)strtoul(argv[3], NULL, 0) : 16;

    /* O_SYNC asks for an uncached mapping. On the M-core side of this contract
     * the producer flushes explicitly; here the point is that the A-core must
     * not be reading a cached copy of a region another core writes. */
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { fprintf(stderr, "open /dev/mem: %s\n", strerror(errno)); return 2; }

    size_t span = sizeof(struct amp_ring) + (size_t)cap * sizeof(struct amp_ring_rec);
    size_t map_bytes = (span + 0xfff) & ~(size_t)0xfff;
    void *p = mmap(NULL, map_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)base);
    if (p == MAP_FAILED) { fprintf(stderr, "mmap 0x%llx: %s\n", base, strerror(errno)); return 2; }
    printf("[t2] mapped 0x%llx (%zu bytes, cap=%u, rec=%zu B)\n",
           base, map_bytes, cap, sizeof(struct amp_ring_rec));

    struct amp_ring *r = (struct amp_ring *)p;

    printf("[t2] ring init + round trip\n");
    amp_ring_init(r, cap);
    CHECK(r->magic == AMP_RING_MAGIC, "magic reads back as ARNG through /dev/mem");
    CHECK(r->capacity == cap && r->rec_size == sizeof(struct amp_ring_rec),
          "geometry survives the mapping (capacity=%u rec_size=%u)", r->capacity, r->rec_size);

    /* Write more records than the ring holds, draining as a real consumer does.
     *
     * The ring drops the NEWEST when full rather than clobbering unread records,
     * so a producer that outruns its consumer loses data by design -- which means
     * "wrote N, read N" only holds if something advances `cons`. Doing that here
     * is what makes the wrap a real test: indices keep climbing while the slots
     * are reused, and a producer and consumer that disagree about the modulus
     * lose records silently rather than loudly. */
    uint32_t written = 0, read = 0, dropped = 0;
    int order_ok = 1, value_ok = 1, ts_ok = 1;
    uint64_t prev_ts = 0;
    for (uint32_t i = 1; i <= n_rec; i++) {
        if (amp_ring_emit(r, 1000ull * i, (int64_t)i * 7)) written++;
        else dropped++;
        /* drain everything available, one record behind the producer */
        while (r->cons != r->prod) {
            const struct amp_ring_rec *rec = &amp_ring_slots(r)[r->cons % r->capacity];
            read++;
            if (rec->value != (int64_t)read * 7) value_ok = 0;
            if (rec->hdr.timestamp != 1000ull * read) order_ok = 0;
            if (read > 1 && rec->hdr.timestamp <= prev_ts) ts_ok = 0;
            prev_ts = rec->hdr.timestamp;
            r->cons = r->cons + 1;
        }
    }
    CHECK(written == n_rec && dropped == 0,
          "with a consumer keeping up, no record is dropped (%u written, %u dropped)",
          written, dropped);
    CHECK(read == n_rec, "every record written was read back (%u / %u)", read, n_rec);
    CHECK(order_ok && value_ok, "values and timestamps arrive in producer order");
    CHECK(ts_ok, "timestamps strictly increase across the wrap");
    CHECK(n_rec > cap && r->prod > cap,
          "the indices wrapped the slots %u times (prod=%u, capacity=%u)",
          r->prod / cap, r->prod, cap);

    /* Drop-on-full, exercised deliberately. This is the `ring_full` case a
     * consumer must be able to tell apart from the others, and the property that
     * matters is that a full ring refuses the newest record instead of
     * overwriting one the consumer has not read yet. */
    printf("[t2] drop-on-full\n");
    uint32_t prod_before = r->prod;
    uint32_t accepted = 0;
    for (uint32_t i = 0; i < cap + 8; i++) accepted += (uint32_t)amp_ring_emit(r, 7777, -1);
    CHECK(accepted == cap, "a full ring accepts exactly `capacity` more (%u) and refuses the rest",
          accepted);
    CHECK(r->prod == prod_before + cap, "the producer index stops at the boundary (%u)", r->prod);
    {
        const struct amp_ring_rec *oldest = &amp_ring_slots(r)[r->cons % r->capacity];
        CHECK(oldest->value == -1 && oldest->hdr.timestamp == 7777,
              "the oldest unread record is intact -- refused, not clobbered");
    }
    r->cons = r->prod;   /* drain, so the region is left quiescent */

    /* A second mapping of the same physical page must see the first one's
     * writes. Two processes on the A-core is the weak version of the real
     * question (the M-core writes, this reads), but it does establish that the
     * mapping is shared rather than a private copy -- which MAP_PRIVATE or a
     * missing O_SYNC would silently turn it into. */
    void *q = mmap(NULL, map_bytes, PROT_READ, MAP_SHARED, fd, (off_t)base);
    if (q == MAP_FAILED) { CHECK(0, "second mapping: %s", strerror(errno)); }
    else {
        const struct amp_ring *r2 = (const struct amp_ring *)q;
        CHECK(r2->magic == AMP_RING_MAGIC && r2->prod == r->prod,
              "a second independent mapping sees the same ring (prod=%u)", r2->prod);
        munmap(q, map_bytes);
    }

    /* Leave the region as we found it: this is a shared carveout and a stale
     * ARNG header would make the next reader think a producer is live. */
    devmem_clear((volatile uint32_t *)p, map_bytes);
    munmap(p, map_bytes);
    close(fd);

    if (fails) { printf("FAIL: amp ring over /dev/mem (%d)\n", fails); return 1; }
    printf("PASS: amp ring over /dev/mem at 0x%llx\n", base);
    return 0;
}
