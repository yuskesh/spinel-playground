/* edge-twin -- the DEVICE half of the twin.
 *
 * Boots Zephyr, runs the shared kernel over a synthetic sensor stream, and
 * writes one audit-log line per reading to the console.  Redirect the console
 * to a file and you have a log the edge can replay.
 *
 * WHAT IS AND IS NOT IN THIS FILE.  Not one arithmetic operation of the
 * measurement is here: the mean, the variance, the verdict and the digest all
 * come out of `kern.o`, which spinel-mlirgen compiled from examples/edge-twin/
 * kern.rb -- the same file the worker's kern.wasm was compiled from.  What is
 * here is the loop, the print format and the trap policy, i.e. exactly the
 * things that are allowed to differ between a microcontroller and a CDN.
 *
 * THE PROTOTYPES ARE NOT WRITTEN HERE either.  `--emit-header` wrote
 * spinel_freestanding.h from the same declarations it compiled, so the C side
 * and the wasm side cannot be given different signatures by a typo.
 *
 * ---------------------------------------------------------------------------
 * THE TRAP POLICY IS THE PRODUCT'S, NOT THE COMPILER'S
 *
 * P003 decision record D-2 makes `spinel_trap` the platform's: the generator
 * emits a call to a noreturn symbol and `llvm.unreachable` behind it, and what
 * happens next is a deployment decision.  On a sensor node the honest answer is
 * that the device has produced a reading it cannot process and must not keep
 * signing an audit log about, so it stops -- `k_panic()`, and the watchdog or
 * the operator takes it from there.  The SAME hook on the worker (index.mjs)
 * turns into a 422 and the isolate serves the next request.  Neither policy is
 * in kern.rb, which is the whole point.
 *
 * Build with -DEDGE_TWIN_TRAP_PROBE=1 to see it: that build feeds the kernel one
 * reading outside the declared domain and nothing after the trap runs.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <stdint.h>

#include "spinel_freestanding.h"

/* The run parameters.  They are printed into the log header so that a replay
 * uses the values this device actually used rather than the verifier's
 * defaults -- an audit log has to be self-describing or "the edge agrees" only
 * means "the edge was configured the same way". */
#ifndef ET_SEED
#define ET_SEED   1
#endif
#ifndef ET_K
#define ET_K      3
#endif
#ifndef ET_MEAN0
#define ET_MEAN0  25000
#endif
#ifndef ET_N
#define ET_N      1024
#endif
#ifndef ET_NBOUND
#define ET_NBOUND 24
#endif

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
	printk("E067\t#trap\tcode=%d\ta=%lld\tb=%lld\t%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
}

int main(void)
{
	int64_t mean_q, var_q, s;
	int32_t hi, lo, x, v, i;
	int32_t nok = 0, nwarn = 0, nalarm = 0;

	printk("E067\t#edge-twin\t1\t%u\t%d\t%d\t%d\t%d\t%d\n",
	       (unsigned)spinel_kern_version(), (int)ET_SEED, (int)ET_K,
	       (int)ET_MEAN0, (int)ET_N, (int)ET_NBOUND);

#ifdef EDGE_TWIN_TRAP_PROBE
	/* One reading on each side of the boundary the declared domain draws.
	 * The first returns; the second must not, and the line after it must
	 * never appear in the log. */
	printk("E067\t#probe\tverdict(0,0,11863283,3)\t%d\n",
	       (int)spinel_verdict(0, 0, 11863283, 3));
	printk("E067\t#probe\tverdict(0,0,11863284,3)\t%d\n",
	       (int)spinel_verdict(0, 0, 11863284, 3));
	printk("E067\t#UNREACHABLE\t0\n");
#else
	/* The initial state, spelled out because the caller owns it: a
	 * freestanding boundary returns one integer, so there is no state
	 * object anywhere -- see kern.rb's header. */
	mean_q = spinel_seed_mean(ET_MEAN0);
	var_q = 0;
	hi = 0;
	lo = 0;
	s = ET_SEED;

	for (i = 0; i < ET_N + ET_NBOUND; i++) {
		int64_t nvar;
		int32_t nhi, nlo;

		if (i < ET_N) {
			s = spinel_prng_next(s);
			x = spinel_sample_of(s);
		} else {
			x = spinel_bound_sample(i - ET_N);
		}

		/* The update order is part of the contract (kern.rb):
		 * everything reads the PREVIOUS state. */
		v = spinel_verdict(mean_q, var_q, x, ET_K);
		nhi = spinel_digest_hi(hi, lo, x, v);
		nlo = spinel_digest_lo(hi, lo, x, v);
		nvar = spinel_ewma_var(var_q, mean_q, x);
		mean_q = spinel_ewma_mean(mean_q, x);
		var_q = nvar;
		hi = nhi;
		lo = nlo;

		if (v == 0) {
			nok++;
		} else if (v == 1) {
			nwarn++;
		} else {
			nalarm++;
		}

		printk("E067\t%d\t%d\t%d\t%lld\t%lld\t%d\t%d\n",
		       (int)i, (int)x, (int)v, (long long)mean_q,
		       (long long)var_q, (int)hi, (int)lo);
	}

	printk("E067\t#final\t%d\t%d\t%d\t%d\t%d\n",
	       (int)hi, (int)lo, (int)nok, (int)nwarn, (int)nalarm);
#endif
	return 0;
}
