/* E079 driver -- the C leg, used unchanged by native / Cortex-M33 / RV32.
 *
 * It prints ONE stream of lines that contains no decimal floats: every double
 * is 16 hex digits of its IEEE bit pattern.  That is deliberate.  E077 s4 had
 * to compare Float cells by parsing both sides, because Ruby's shortest
 * round-trip, C's %.17g and JS's Number#toString are three renderings of the
 * same double; the claim "the four legs agree" was therefore about VALUES and
 * not about bytes.  A gradient is the thing this experiment is trying to ship
 * across a network, so here the byte IS the claim: the four legs must produce
 * the same stream, and a sha256 over it means what it looks like it means.
 *
 * The driver contains no arithmetic on the quantities under test.  It holds
 * the SGD loop (see E079 s3: a freestanding kernel cannot call the Enzyme
 * adjoint, so the step-to-step loop lives here), it counts confusion cells,
 * and it prints.  Every number it prints came out of a kernel entry.
 */
#include "spinel_freestanding.h"
#include "spinel_grad.h"

#ifndef E079_PRINT
#error "define E079_PRINT(...) to printf or printk"
#endif

#define NROW 64
#define NW 5
#define NSTEP 40

static double g_data[NROW * 5];
static double g_row[5];
static double g_w[NW];
static double g_g[NW];
static double g_scratch[NW];

/* The initial weights: a scorer that is not absurd but is badly biased
 * towards saying "bot" (a positive bias term with small feature weights), so
 * the interesting number afterwards is the FALSE POSITIVE count -- the same
 * quantity E076 demo B reported for the host calibration. */
static const double W0[NW] = { 0.2, -0.1, 0.3, 0.0, 0.5 };

/* Three probe points for the gradient.  P2 is close to the generator's own
 * rule, i.e. the place where a squared hinge is most nearly saturated: that
 * is where G4 (the gradient is not identically zero) earns its keep. */
static const double PROBE[3][NW] = {
  { 0.2, -0.1,  0.3, 0.0,  0.5 },
  { 0.0,  0.0,  0.0, 0.0,  0.0 },
  { 1.5,  0.8, -1.2, 0.4, -0.3 },
};

/* The four learning rates a calibration loop can be handed by accident, plus
 * one that is fine.  NaN is built without libm: 0.0/0.0 is a NaN on every
 * IEEE target and the compiler is not allowed to fold it into something
 * else at -O2 without -ffast-math (which no profile sets). */
static double lr_case(int i, double zero) {
  switch (i) {
    case 0: return zero;                 /* 0.0   -- no step at all      */
    case 1: return -0.1;                 /* <0    -- ascent as descent   */
    case 2: return 2.0;                  /* >1    -- diverges here       */
    case 3: return zero / zero;          /* NaN   -- poisons everything  */
    default: return 0.1;                 /* the control                  */
  }
}

static void put_bits(double d) {
  union { double d; unsigned long long u; } u;
  u.d = d;
  /* two halves rather than %016llx: Zephyr's minimal printk is not required
   * to carry the ll length modifier, and a silently truncated hex digit would
   * be a difference the four-way gate blames on the kernel. */
  E079_PRINT("%08x%08x", (unsigned)(u.u >> 32), (unsigned)(u.u & 0xffffffffu));
}

static void bits_line(const char *tag, int a, int b, double d) {
  if (b < 0) E079_PRINT("%s %d ", tag, a);
  else       E079_PRINT("%s %d %d ", tag, a, b);
  put_bits(d);
  E079_PRINT("\n");
}

/* Load the weights the EDGE shipped, if this image was built with them.
 * weights_shipped.h is generated from the wasm32 runner's `#final` line, so
 * "the device applies what the edge computed" is an actual artefact crossing
 * an actual boundary, not a claim about two copies of the same program. */
#ifdef E079_SHIPPED
#include "weights_shipped.h"
#endif

int e079_main(void) {
  int r, t, i, p, k;
  int c[4];

  E079_PRINT("#kern %d\n", (int)spinel_kern_version());
  E079_PRINT("#rows %d\n", NROW);
  E079_PRINT("#steps %d\n", NSTEP);
  E079_PRINT("#nw %d\n", NW);

  /* ---- A. the samples.  Generated, not received (E067 s1). ------------- */
  for (r = 0; r < NROW; r++) {
    spinel_gen_row(g_row, 5, r);
    for (i = 0; i < 5; i++) g_data[r * 5 + i] = g_row[i];
  }

  for (i = 0; i < NW; i++) g_w[i] = W0[i];

  /* ---- B. phase 0: what the device decides BEFORE calibration --------- */
  c[0] = c[1] = c[2] = c[3] = 0;
  for (r = 0; r < NROW; r++) {
    int o = spinel_outcome(&g_data[r * 5], 5, g_w, NW);
    E079_PRINT("V0 %d %d\n", r, o);
    c[o]++;
  }
  E079_PRINT("C0 %d %d %d %d\n", c[0], c[1], c[2], c[3]);

  /* ---- C. the gradient itself, at three probe points ------------------ */
  for (p = 0; p < 3; p++) {
    for (i = 0; i < NW; i++) g_scratch[i] = PROBE[p][i];
    double L = spinel_grad_sq_hinge_loss(g_data, NROW * 5, g_scratch, g_g, NW);
    bits_line("P", p, -1, L);
    for (i = 0; i < NW; i++) bits_line("G", p, i, g_g[i]);
  }

  /* ---- D. the calibration loop ---------------------------------------- */
  /* `L t` is the loss AFTER t steps, so L 0 is the starting loss and L 40 is
   * the loss of the weights that get shipped.  The gradient call returns the
   * loss at the OLD weights, which is a different number; printing that one
   * under the same name would make the trajectory look one step stale. */
  bits_line("L", 0, -1, spinel_sq_hinge_loss(g_data, NROW * 5, g_w, NW));
  for (t = 1; t <= NSTEP; t++) {
    spinel_grad_sq_hinge_loss(g_data, NROW * 5, g_w, g_g, NW);
    int ok = spinel_sgd_step(g_w, g_g, NW, 0.1);
    E079_PRINT("K %d %d\n", t, ok);
    bits_line("L", t, -1, spinel_sq_hinge_loss(g_data, NROW * 5, g_w, NW));
    for (i = 0; i < NW; i++) bits_line("S", t, i, g_w[i]);
  }

  /* ---- E. the learning rates that are refused ------------------------- */
  /* Run on a COPY: the point of the guard is that a refused step writes
   * nothing, and the way to show that is to compare the copy afterwards. */
  for (k = 0; k < 5; k++) {
    double zero = 0.0;
    for (i = 0; i < NW; i++) g_scratch[i] = g_w[i];
    spinel_grad_sq_hinge_loss(g_data, NROW * 5, g_scratch, g_g, NW);
    int ok = spinel_sgd_step(g_scratch, g_g, NW, lr_case(k, zero));
    E079_PRINT("A %d %d\n", k, ok);
    for (i = 0; i < NW; i++) bits_line("W", k, i, g_scratch[i]);
  }

  /* ---- F. phase 1: what the device decides AFTER calibration ---------- */
  c[0] = c[1] = c[2] = c[3] = 0;
  for (r = 0; r < NROW; r++) {
    int o = spinel_outcome(&g_data[r * 5], 5, g_w, NW);
    E079_PRINT("V1 %d %d\n", r, o);
    c[o]++;
  }
  E079_PRINT("C1 %d %d %d %d\n", c[0], c[1], c[2], c[3]);

  E079_PRINT("#final");
  for (i = 0; i < NW; i++) { E079_PRINT(" "); put_bits(g_w[i]); }
  E079_PRINT("\n");

  /* ---- G. the shipped weights (device only, E079 s5) ------------------ */
  /* Same entries, same samples, weights that arrived from the edge instead of
   * from this image's own calibration.  If the two agree the loop is closed. */
#ifdef E079_SHIPPED
  {
    const unsigned long long *sw = E079_SHIPPED_BITS;
    for (i = 0; i < NW; i++) {
      union { double d; unsigned long long u; } u;
      u.u = sw[i];
      g_scratch[i] = u.d;
    }
    c[0] = c[1] = c[2] = c[3] = 0;
    for (r = 0; r < NROW; r++) {
      int o = spinel_outcome(&g_data[r * 5], 5, g_scratch, NW);
      E079_PRINT("X1 %d %d\n", r, o);
      c[o]++;
    }
    E079_PRINT("Y1 %d %d %d %d\n", c[0], c[1], c[2], c[3]);
    E079_PRINT("#shipped");
    for (i = 0; i < NW; i++) { E079_PRINT(" "); put_bits(g_scratch[i]); }
    E079_PRINT("\n");
  }
#endif

  E079_PRINT("#done\n");
  return 0;
}
