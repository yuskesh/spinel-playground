/* E083 driver -- the C leg, used unchanged by native / Cortex-M33 / RV32.
 *
 * Compare it with E079's e079_drv.c, because the difference IS the result:
 * E079's driver held the SGD loop (grad, step, grad, step ... forty times),
 * because the kernel could not call the adjoint and could not pass a buffer
 * inward.  This driver holds NO loop over steps.  It calls
 *
 *     spinel_calibrate(data, nd, w, g, nw, steps, lr)
 *
 * and the loop -- extern call to the Enzyme adjoint included -- runs inside
 * the freestanding kernel, on whatever target this file happens to be
 * compiled for.  What remains here is instrumentation: chunked replay (forty
 * calls with steps=1, printing the weights after each, so the trajectory can
 * be compared bit-for-bit against E079's stored stream), one whole-loop call
 * (steps=40, which must land on the same weights -- loop-in-kernel equals
 * composition-of-chunks), the refused learning rates, and printing.
 *
 * Every double is printed as 16 hex digits of its IEEE bit pattern (E079's
 * discipline: the byte is the claim).  The driver contains no arithmetic on
 * the quantities under test.
 */
#include "spinel_freestanding.h"

#ifndef E083_PRINT
#error "define E083_PRINT(...) to printf or printk"
#endif

#define NROW 64
#define NW 5
#define NSTEP 40

static double g_data[NROW * 5];
static double g_row[5];
static double g_w[NW];      /* the chunked-replay weights                  */
static double g_w2[NW];     /* the whole-loop weights                      */
static double g_g[NW];      /* the gradient scratch the kernel hands the   */
static double g_g2[NW];     /*   extern (:inout -- the extern assigns it)  */
static double g_scratch[NW];

/* Same initial weights and refused rates as E079 (drv/e079_drv.c). */
static const double W0[NW] = { 0.2, -0.1, 0.3, 0.0, 0.5 };

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
  E083_PRINT("%08x%08x", (unsigned)(u.u >> 32), (unsigned)(u.u & 0xffffffffu));
}

static void bits_line(const char *tag, int a, int b, double d) {
  if (b < 0) E083_PRINT("%s %d ", tag, a);
  else       E083_PRINT("%s %d %d ", tag, a, b);
  put_bits(d);
  E083_PRINT("\n");
}

int e083_main(void) {
  int r, t, i, k;

  E083_PRINT("#kern %d\n", (int)spinel_kern_version());
  E083_PRINT("#rows %d\n", NROW);
  E083_PRINT("#steps %d\n", NSTEP);
  E083_PRINT("#nw %d\n", NW);

  /* ---- A. the samples.  Generated, not received (E067 s1). ------------- */
  for (r = 0; r < NROW; r++) {
    spinel_gen_row(g_row, 5, r);
    for (i = 0; i < 5; i++) g_data[r * 5 + i] = g_row[i];
  }
  for (i = 0; i < NW; i++) g_w[i] = W0[i];

#ifdef E083_TRAP
  /* The runtime half of D-10: a length that would license the extern beyond
   * the buffer the kernel itself was handed is trap code 4 BEFORE the call.
   * The probe below must not return; the UNREACHED line must not print. */
  E083_PRINT("#trapprobe %d\n", (int)E083_TRAP);
  bits_line("T", 0, -1,
            spinel_grad_probe(g_data, NROW * 5, g_w, g_g, NW, E083_TRAP));
  E083_PRINT("UNREACHED\n");
  return 1;
#endif

  /* ---- B. chunked replay: forty steps=1 calls --------------------------- */
  /* `L t` is the loss AFTER t steps (E079's convention, same entry).  The
   * kernel-held loop is re-entered each time with the caller-owned w and g,
   * so the composition of forty 1-step calls is E079's forty driver-side
   * rounds -- row for row, bit for bit, against E079's stored stream. */
  bits_line("L", 0, -1, spinel_sq_hinge_loss(g_data, NROW * 5, g_w, NW));
  for (t = 1; t <= NSTEP; t++) {
    int ok = spinel_calibrate(g_data, NROW * 5, g_w, g_g, NW, 1, 0.1);
    E083_PRINT("K %d %d\n", t, ok);
    bits_line("L", t, -1, spinel_sq_hinge_loss(g_data, NROW * 5, g_w, NW));
    for (i = 0; i < NW; i++) bits_line("S", t, i, g_w[i]);
  }

  /* ---- C. the whole loop in ONE kernel call ----------------------------- */
  /* Fresh weights, steps=40.  The F rows must equal the S 40 rows above:
   * "the loop lives in the kernel" and "forty single steps" are the same
   * computation, and the gate checks that as data rather than assuming it. */
  for (i = 0; i < NW; i++) g_w2[i] = W0[i];
  {
    int ok = spinel_calibrate(g_data, NROW * 5, g_w2, g_g2, NW, NSTEP, 0.1);
    E083_PRINT("B %d\n", ok);
  }
  for (i = 0; i < NW; i++) bits_line("F", 0, i, g_w2[i]);

  /* ---- D. the learning rates that are refused --------------------------- */
  /* Whole-loop form, on a COPY: a refused calibrate call must write NOTHING
   * to either buffer, even with steps=40 on the table. */
  for (k = 0; k < 5; k++) {
    double zero = 0.0;
    int ok;
    for (i = 0; i < NW; i++) g_scratch[i] = g_w[i];
    ok = spinel_calibrate(g_data, NROW * 5, g_scratch, g_g2, NW, NSTEP,
                          lr_case(k, zero));
    E083_PRINT("A %d %d\n", k, ok);
    for (i = 0; i < NW; i++) bits_line("W", k, i, g_scratch[i]);
  }

  /* ---- E. the length-check control -------------------------------------- */
  /* grad_probe with extra=0 is in range: it returns the adjoint's own primal
   * value at the calibrated weights -- one more number all four legs must
   * agree on, computed through the extern boundary. */
  for (i = 0; i < NW; i++) g_scratch[i] = g_w[i];
  bits_line("P", 0, -1,
            spinel_grad_probe(g_data, NROW * 5, g_scratch, g_g2, NW, 0));

  E083_PRINT("#final");
  for (i = 0; i < NW; i++) { E083_PRINT(" "); put_bits(g_w[i]); }
  E083_PRINT("\n");
  E083_PRINT("#done\n");
  return 0;
}
