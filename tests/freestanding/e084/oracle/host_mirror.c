/* E084 -- the HOST mirror of the kernel's Newton-CG, over the gradgen
 * products (spg_val_/spg_grad_/spg_hvp_sq_hinge_loss), printing THE SAME
 * STREAM as drv/e084_drv.c prints from the freestanding kernel.
 *
 * This file is the host differential's other half, and unlike the leg
 * drivers it DOES hold the loop and its arithmetic -- deliberately: the
 * question it answers is "does the E082-style host surface, walked by the
 * same algorithm with the same expressions in the same order, produce the
 * same bits as the loop that lives inside the freestanding kernel?"  Every
 * arithmetic statement below mirrors e084_kern.rb line for line (including
 * `0.0 - g[i]` and `tstep / 2.0`); where the bits split, the layer that
 * split them is the finding, not a bug (host clang compiles Spinel's C with
 * its own defaults -- fp-contract included -- and the whole point of the
 * layered table is to SEE which layer that touches first).
 *
 * Data: gen_row's LCG transcribed exactly (integer arithmetic, exact in
 * any correct C; the layered table's `primal` row is the cross-check).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* the gradgen FFI boundary (tools/grad/spinel-gradgen cdecl_args):
 * a float_array crosses as (const double *, long long), a scalar as
 * long long; grad appends the shadow, hvp appends dir/g/hv. */
extern double spg_val_sq_hinge_loss(const double *, long long, long long,
                                    const double *, long long, long long);
extern double spg_grad_sq_hinge_loss(const double *, long long, long long,
                                     const double *, long long, long long,
                                     double *);
extern double spg_hvp_sq_hinge_loss(const double *, long long, long long,
                                    const double *, long long, long long,
                                    const double *, double *, double *);

#define NROW 64
#define NW 5
#define NITER 12

static double g_data[NROW * 5];
static const double W0[NW] = { 0.2, -0.1, 0.3, 0.0, 0.5 };
static const double SYM_U[NW] = { 1.0, 0.5, -0.25, 2.0, -1.0 };
static const double SYM_V[NW] = { -0.5, 1.0, 0.75, -1.5, 0.25 };

static void put_bits(double d) {
  union { double d; unsigned long long u; } u;
  u.d = d;
  printf("%08x%08x", (unsigned)(u.u >> 32), (unsigned)(u.u & 0xffffffffu));
}
static void bits_line(const char *tag, int a, int b, double d) {
  if (b < 0) printf("%s %d ", tag, a);
  else       printf("%s %d %d ", tag, a, b);
  put_bits(d);
  printf("\n");
}

/* gen_row, transcribed (e084_kern.rb sA == e079_kern.rb sA) */
static void gen_row(double *dst, int k) {
  long long s = ((long long)k * 1103515245LL + 12345LL) % 2147483648LL;
  s = (s * 1103515245LL + 12345LL) % 2147483648LL;
  double a = (double)(s % 2000LL - 1000LL) / 1000.0;
  s = (s * 1103515245LL + 12345LL) % 2147483648LL;
  double b = (double)(s % 2000LL - 1000LL) / 1000.0;
  s = (s * 1103515245LL + 12345LL) % 2147483648LL;
  double c = (double)(s % 2000LL - 1000LL) / 1000.0;
  s = (s * 1103515245LL + 12345LL) % 2147483648LL;
  double d = (double)(s % 2000LL - 1000LL) / 1000.0;
  dst[0] = a; dst[1] = b; dst[2] = c; dst[3] = d;
  double z = 1.5 * a + 0.8 * b - 1.2 * c + 0.4 * d + 0.6 * a * b - 0.3;
  dst[4] = (z > 0.0) ? 1.0 : -1.0;
}

static double hgrad(const double *w, double *g) {          /* grad extern */
  return spg_grad_sq_hinge_loss(g_data, NROW * 5, NROW * 5, w, NW, NW, g);
}
static double hhvp(const double *w, const double *dir, double *g, double *hv) {
  return spg_hvp_sq_hinge_loss(g_data, NROW * 5, NROW * 5, w, NW, NW,
                               dir, g, hv);
}
static double hval(const double *w) {
  return spg_val_sq_hinge_loss(g_data, NROW * 5, NROW * 5, w, NW, NW);
}

/* newton_calibrate, mirrored line for line from e084_kern.rb sN2 */
static int newton_calibrate(double *w, double *g, double *gs, double *hv,
                            double *p, double *r, double *d, double *y,
                            int iters, double gtol2) {
  if (!(iters > 0 && gtol2 >= 0.0)) return -1;
  int stepped = 0;
  int it = 0;
  while (it < iters) {
    double f = hgrad(w, g);
    double gg = 0.0;
    for (int i = 0; i < NW; i++) gg = gg + g[i] * g[i];
    if (gg > gtol2) {
      for (int i = 0; i < NW; i++) { p[i] = 0.0; r[i] = 0.0 - g[i]; d[i] = r[i]; }
      double rs = 0.0;
      for (int i = 0; i < NW; i++) rs = rs + r[i] * r[i];
      int cg = 0, cgdone = 0;
      while (cg < 20 && cgdone == 0) {
        hhvp(w, d, gs, hv);
        double dh = 0.0;
        for (int i = 0; i < NW; i++) dh = dh + d[i] * hv[i];
        double a = rs / dh;
        for (int i = 0; i < NW; i++) { p[i] = p[i] + a * d[i]; r[i] = r[i] - a * hv[i]; }
        double rs2 = 0.0;
        for (int i = 0; i < NW; i++) rs2 = rs2 + r[i] * r[i];
        if (rs2 < 1.5e-28) cgdone = 1;
        else {
          double bb = rs2 / rs;
          for (int i = 0; i < NW; i++) d[i] = r[i] + bb * d[i];
          rs = rs2;
        }
        cg += 1;
      }
      double tstep = 1.0;
      int ls = 0, lsdone = 0;
      while (ls < 8 && lsdone == 0) {
        for (int i = 0; i < NW; i++) y[i] = w[i] + tstep * p[i];
        double fy = hgrad(y, gs);   /* the kernel probes f(y) via grad_loss */
        if (fy < f) {
          for (int i = 0; i < NW; i++) w[i] = y[i];
          lsdone = 1;
        } else {
          tstep = tstep / 2.0;
        }
        ls += 1;
      }
      stepped += 1;
      it += 1;
    } else {
      it = iters;
    }
  }
  return stepped;
}

int main(void) {
  int i, j, t;
  double w[NW], g[NW], gs[NW], hv[NW], p[NW], r[NW], d[NW], y[NW], dir[NW];
  for (i = 0; i < NROW; i++) gen_row(g_data + i * 5, i);
  memcpy(w, W0, sizeof w);

  printf("#kern 84\n#rows %d\n#iters %d\n#nw %d\n", NROW, NITER, NW);

  for (j = 0; j < NW; j++) {
    for (i = 0; i < NW; i++) dir[i] = (i == j) ? 1.0 : 0.0;
    bits_line("Vr", j, -1, hhvp(w, dir, gs, hv));
    for (i = 0; i < NW; i++) bits_line("V", j, i, hv[i]);
  }
  for (i = 0; i < NW; i++) bits_line("G0", i, -1, gs[i]);
  hhvp(w, SYM_U, gs, hv);
  for (i = 0; i < NW; i++) bits_line("U", i, -1, hv[i]);
  hhvp(w, SYM_V, gs, hv);
  for (i = 0; i < NW; i++) bits_line("Z", i, -1, hv[i]);

  bits_line("L", 0, -1, hval(w));
  {
    hgrad(w, gs);
    double n2 = 0.0;
    for (i = 0; i < NW; i++) n2 = n2 + gs[i] * gs[i];
    bits_line("N", 0, -1, n2);
  }
  for (t = 1; t <= NITER; t++) {
    int ok = newton_calibrate(w, g, gs, hv, p, r, d, y, 1, 1.0e-14);
    printf("K %d %d\n", t, ok);
    bits_line("L", t, -1, hval(w));
    hgrad(w, gs);
    double n2 = 0.0;
    for (i = 0; i < NW; i++) n2 = n2 + gs[i] * gs[i];
    bits_line("N", t, -1, n2);
    for (i = 0; i < NW; i++) bits_line("S", t, i, w[i]);
  }

  double w2[NW];
  memcpy(w2, W0, sizeof w2);
  printf("B %d\n", newton_calibrate(w2, g, gs, hv, p, r, d, y, NITER, 1.0e-14));
  for (i = 0; i < NW; i++) bits_line("F", 0, i, w2[i]);

  printf("#final");
  for (i = 0; i < NW; i++) { printf(" "); put_bits(w[i]); }
  printf("\n#done\n");
  return 0;
}
