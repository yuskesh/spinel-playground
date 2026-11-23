/* E084 driver -- the C leg, used unchanged by native / Cortex-M33 / RV32.
 *
 * Compare it with E083's e083_drv.c: same discipline (no arithmetic on the
 * quantities under test, every double printed as 16 hex digits of its IEEE
 * bit pattern), one difference of substance -- the loop this driver does NOT
 * hold is a NEWTON-CG loop.  spinel_newton_calibrate runs outer Newton
 * iterations, an inner conjugate-gradient solve (H p = -g through the hvp
 * extern), and a damped line search, all inside the freestanding kernel;
 * the extern calls inside it reach spinel_grad_sq_hinge_loss AND
 * spinel_hvp_sq_hinge_loss, both supplied by the spinel-gradfs --grads-only
 * object at link time (D-10's standard wiring, second symbol).
 *
 * The stream:
 *   V/Vr/G0   the HVP unit block -- H's five columns (hv), the gradient (g)
 *             and the directional value (ret) at W0, straight through the
 *             linked hvp export.  The four legs must agree on H itself
 *             before any trajectory is compared; the symmetry and
 *             analytic-Hessian gates read these rows.
 *   U/T       H.u and H.v for two fixed non-unit directions (the checker
 *             computes u.Hv and v.Hu from the printed bits; the driver
 *             prints, it does not dot).
 *   K/L/N/S   chunked replay: twelve iters=1 calls; after each, the loss
 *             (kernel entry), ||grad||^2 (kernel entry grad_norm2) and the
 *             five weights.
 *   B/F       the whole Newton run in ONE kernel call (iters=12) from fresh
 *             weights -- must land bit-identically on the S 12 rows.
 *   A/W       the refused iters/gtol2 (write NOTHING), plus the control.
 *   P         the hvp length-check control (extra=0).
 */
#include "spinel_freestanding.h"
#include "spinel_grad.h"   /* the gradfs product header: grad + hvp prototypes */

#ifndef E084_PRINT
#error "define E084_PRINT(...) to printf or printk"
#endif

#define NROW 64
#define NW 5
#define NITER 12

static double g_data[NROW * 5];
static double g_row[5];
static double g_w[NW];      /* the chunked-replay weights                  */
static double g_w2[NW];     /* the whole-run weights                       */
static double g_g[NW];      /* gradient      (grad extern assigns)         */
static double g_gs[NW];     /* grad scratch  (hvp's g out / f(y) probes)   */
static double g_hv[NW];     /* H.d           (hvp extern assigns)          */
static double g_p[NW];      /* CG solution                                 */
static double g_r[NW];      /* CG residual                                 */
static double g_d[NW];      /* CG direction                                */
static double g_y[NW];      /* line-search trial point                     */
static double g_dir[NW];    /* the driver-owned probe direction            */
static double g_scratch[NW];

/* Same initial weights as E079/E083 (drv/e079_drv.c). */
static const double W0[NW] = { 0.2, -0.1, 0.3, 0.0, 0.5 };

/* Two fixed directions for the symmetry rows (printed, never dotted here). */
static const double SYM_U[NW] = { 1.0, 0.5, -0.25, 2.0, -1.0 };
static const double SYM_V[NW] = { -0.5, 1.0, 0.75, -1.5, 0.25 };

static double gtol_case(int i, double zero) {
  switch (i) {
    case 3: return zero / zero;          /* NaN gtol2: >= 0.0 is false   */
    default: return 1.0e-14;             /* ||grad|| <= 1e-7, squared    */
  }
}
static int iters_case(int i) {
  switch (i) {
    case 0: return 0;                    /* no iterations at all         */
    case 1: return -3;                   /* negative                     */
    default: return NITER;
  }
}

static void put_bits(double d) {
  union { double d; unsigned long long u; } u;
  u.d = d;
  E084_PRINT("%08x%08x", (unsigned)(u.u >> 32), (unsigned)(u.u & 0xffffffffu));
}

static void bits_line(const char *tag, int a, int b, double d) {
  if (b < 0) E084_PRINT("%s %d ", tag, a);
  else       E084_PRINT("%s %d %d ", tag, a, b);
  put_bits(d);
  E084_PRINT("\n");
}

int e084_main(void) {
  int r, t, i, j, k;

  E084_PRINT("#kern %d\n", (int)spinel_kern_version());
  E084_PRINT("#rows %d\n", NROW);
  E084_PRINT("#iters %d\n", NITER);
  E084_PRINT("#nw %d\n", NW);

  /* ---- A. the samples.  Generated, not received (E067 s1). ------------- */
  for (r = 0; r < NROW; r++) {
    spinel_gen_row(g_row, 5, r);
    for (i = 0; i < 5; i++) g_data[r * 5 + i] = g_row[i];
  }
  for (i = 0; i < NW; i++) g_w[i] = W0[i];

#ifdef E084_TRAP
  /* The runtime half of D-10, against the NEW extern: a length that would
   * license the hvp beyond the kernel's own buffers is trap code 4 BEFORE
   * the call.  The probe must not return; UNREACHED must not print. */
  E084_PRINT("#trapprobe %d\n", (int)E084_TRAP);
  for (i = 0; i < NW; i++) g_dir[i] = (i == 0) ? 1.0 : 0.0;
  bits_line("T", 0, -1,
            spinel_hvp_probe(g_data, NROW * 5, g_w, g_dir, g_gs, g_hv,
                             NW, E084_TRAP));
  E084_PRINT("UNREACHED\n");
  return 1;
#endif

  /* ---- B. the HVP unit block at W0 -------------------------------------- */
  for (j = 0; j < NW; j++) {
    for (i = 0; i < NW; i++) g_dir[i] = (i == j) ? 1.0 : 0.0;
    bits_line("Vr", j, -1,
              spinel_hvp_sq_hinge_loss(g_data, NROW * 5, g_w, g_dir,
                                       g_gs, g_hv, NW));
    for (i = 0; i < NW; i++) bits_line("V", j, i, g_hv[i]);
  }
  for (i = 0; i < NW; i++) bits_line("G0", i, -1, g_gs[i]);
  for (i = 0; i < NW; i++) g_dir[i] = SYM_U[i];
  spinel_hvp_sq_hinge_loss(g_data, NROW * 5, g_w, g_dir, g_gs, g_hv, NW);
  for (i = 0; i < NW; i++) bits_line("U", i, -1, g_hv[i]);
  for (i = 0; i < NW; i++) g_dir[i] = SYM_V[i];
  spinel_hvp_sq_hinge_loss(g_data, NROW * 5, g_w, g_dir, g_gs, g_hv, NW);
  for (i = 0; i < NW; i++) bits_line("Z", i, -1, g_hv[i]);

  /* ---- C. chunked replay: twelve iters=1 calls -------------------------- */
  bits_line("L", 0, -1, spinel_sq_hinge_loss(g_data, NROW * 5, g_w, NW));
  bits_line("N", 0, -1, spinel_grad_norm2(g_data, NROW * 5, g_w, g_gs, NW));
  for (t = 1; t <= NITER; t++) {
    int ok = spinel_newton_calibrate(g_data, NROW * 5, g_w, g_g, g_gs, g_hv,
                                     g_p, g_r, g_d, g_y, NW, 1, 1.0e-14);
    E084_PRINT("K %d %d\n", t, ok);
    bits_line("L", t, -1, spinel_sq_hinge_loss(g_data, NROW * 5, g_w, NW));
    bits_line("N", t, -1, spinel_grad_norm2(g_data, NROW * 5, g_w, g_gs, NW));
    for (i = 0; i < NW; i++) bits_line("S", t, i, g_w[i]);
  }

  /* ---- D. the whole Newton run in ONE kernel call ------------------------ */
  for (i = 0; i < NW; i++) g_w2[i] = W0[i];
  {
    int ok = spinel_newton_calibrate(g_data, NROW * 5, g_w2, g_g, g_gs, g_hv,
                                     g_p, g_r, g_d, g_y, NW, NITER, 1.0e-14);
    E084_PRINT("B %d\n", ok);
  }
  for (i = 0; i < NW; i++) bits_line("F", 0, i, g_w2[i]);

  /* ---- E. the refused iters/gtol2 ---------------------------------------- */
  for (k = 0; k < 5; k++) {
    double zero = 0.0;
    int ok;
    /* the refusals start from the CONVERGED weights (a refused call writes
     * nothing, compared bitwise); the k=4 control starts from W0 so that
     * acceptance is OBSERVABLE -- it must retrace the whole run (rc == B,
     * W 4 rows == F rows). */
    for (i = 0; i < NW; i++) g_scratch[i] = (k == 4) ? W0[i] : g_w[i];
    ok = spinel_newton_calibrate(g_data, NROW * 5, g_scratch, g_g, g_gs, g_hv,
                                 g_p, g_r, g_d, g_y, NW,
                                 (k == 2) ? NITER : iters_case(k),
                                 (k == 2) ? -1.0 : gtol_case(k, zero));
    E084_PRINT("A %d %d\n", k, ok);
    for (i = 0; i < NW; i++) bits_line("W", k, i, g_scratch[i]);
  }

  /* ---- F. the hvp length-check control ----------------------------------- */
  for (i = 0; i < NW; i++) g_scratch[i] = g_w[i];
  for (i = 0; i < NW; i++) g_dir[i] = (i == 0) ? 1.0 : 0.0;
  bits_line("P", 0, -1,
            spinel_hvp_probe(g_data, NROW * 5, g_scratch, g_dir, g_gs, g_hv,
                             NW, 0));

  E084_PRINT("#final");
  for (i = 0; i < NW; i++) { E084_PRINT(" "); put_bits(g_w[i]); }
  E084_PRINT("\n");
  E084_PRINT("#done\n");
  return 0;
}
