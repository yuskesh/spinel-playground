/* E084 -- the analytic oracle for the FREESTANDING hvp product.
 *
 * E078 s5.2's discipline, E082's analytic_check.c one lane over: the
 * closed-form gradient and Hessian of the squared hinge are written from
 * the mathematics (the loss is (1/R) sum [t_r>0] t_r^2 with
 * t_r = 1 - y_r (w.x_r + b); its gradient is -(2/R) sum [t>0] t y xt and
 * its Hessian is (2/R) sum [t>0] xt xt^T with xt = (x, 1)), and NOTHING
 * here touches Enzyme, gradfs or the kernel generator -- this file links
 * the two generated OBJECTS and interrogates their exports.
 *
 * Gates (one TSV row each):
 *   hcol.j.i   hv[i] of unit direction e_j == H[i][j]         (25 rows)
 *   gvec.i     the g the hvp assigns  == analytic gradient    (5 rows)
 *   gxr.i      the g the hvp assigns  == the REVERSE product's g (5 rows,
 *              bitwise -- two AD paths through one object)
 *   gdot.j     the return value       == g . e_j              (5 rows)
 *   gsym       u.Hv == v.Hu           (1 row)
 *   probe.k    all of the above at a SECOND point (mid-calibration weights)
 *              -- the Hessian of a hinge is piecewise constant in w, so a
 *              second active set is a different matrix (36 rows)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

extern int32_t spinel_gen_row(double *, int32_t, int32_t);
extern double spinel_sq_hinge_loss(const double *, int32_t, const double *, int32_t);
extern double spinel_grad_sq_hinge_loss(const double *, int32_t, const double *,
                                        double *, int32_t);
extern double spinel_hvp_sq_hinge_loss(const double *, int32_t, const double *,
                                       const double *, double *, double *, int32_t);
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail) {
  fprintf(stderr, "TRAP code=%d\n", (int)code);
  exit(3);
}

#define NR 64
#define NW 5
static double data[NR * 5];

static void analytic(const double *w, double g[NW], double H[NW][NW]) {
  int r, i, j;
  for (i = 0; i < NW; i++) { g[i] = 0.0; for (j = 0; j < NW; j++) H[i][j] = 0.0; }
  for (r = 0; r < NR; r++) {
    const double *b = data + r * 5;
    double xt[NW] = { b[0], b[1], b[2], b[3], 1.0 };
    double z = w[0]*b[0] + w[1]*b[1] + w[2]*b[2] + w[3]*b[3] + w[4];
    double t = 1.0 - b[4] * z;
    if (t > 0.0) {
      for (i = 0; i < NW; i++) {
        g[i] += -2.0 * t * b[4] * xt[i] / NR;
        for (j = 0; j < NW; j++) H[i][j] += 2.0 * xt[i] * xt[j] / NR;
      }
    }
  }
}

static double relerr(double a, double b) {
  double d = fabs(a - b), m = fabs(b);
  return d / (m > 1e-12 ? m : 1.0);
}

static int nfail = 0;
static double worst = 0.0;
static void row(const char *id, double got, double want, double tol) {
  double e = relerr(got, want);
  if (e > worst) worst = e;
  int ok = e <= tol;
  if (!ok) nfail++;
  printf("%s\t%.17g\t%.17g\t%.3e\t%s\n", id, got, want, e, ok ? "PASS" : "FAIL");
}

static void check_point(const char *tag, const double *w) {
  double g[NW], H[NW][NW], gg[NW], hv[NW], dir[NW], gr[NW];
  double gu[NW], hu[NW], hvv[NW];
  char id[64];
  int i, j;
  analytic(w, g, H);
  for (j = 0; j < NW; j++) {
    for (i = 0; i < NW; i++) dir[i] = (i == j) ? 1.0 : 0.0;
    double ret = spinel_hvp_sq_hinge_loss(data, NR * 5, w, dir, gg, hv, NW);
    for (i = 0; i < NW; i++) {
      snprintf(id, sizeof id, "hcol.%s.%d.%d", tag, j, i);
      row(id, hv[i], H[i][j], 1e-12);
    }
    double gd = 0.0;
    for (i = 0; i < NW; i++) gd += gg[i] * dir[i];
    snprintf(id, sizeof id, "gdot.%s.%d", tag, j);
    row(id, ret, gd, 1e-12);
  }
  for (i = 0; i < NW; i++) {
    snprintf(id, sizeof id, "gvec.%s.%d", tag, i);
    row(id, gg[i], g[i], 1e-12);
  }
  /* two AD paths through one object: hvp's g vs the reverse product's g */
  spinel_grad_sq_hinge_loss(data, NR * 5, w, gr, NW);
  for (i = 0; i < NW; i++) {
    snprintf(id, sizeof id, "gxr.%s.%d", tag, i);
    row(id, gg[i], gr[i], 1e-14);
    if (memcmp(&gg[i], &gr[i], 8) != 0)
      printf("#gxr.%s.%d\tNOT-BITWISE\n", tag, i);
  }
  /* symmetry: u.Hv == v.Hu, dots taken here from the returned vectors */
  double u[NW] = { 1.0, 0.5, -0.25, 2.0, -1.0 };
  double v[NW] = { -0.5, 1.0, 0.75, -1.5, 0.25 };
  spinel_hvp_sq_hinge_loss(data, NR * 5, w, u, gu, hu, NW);
  spinel_hvp_sq_hinge_loss(data, NR * 5, w, v, gu, hvv, NW);
  double uhv = 0.0, vhu = 0.0;
  for (i = 0; i < NW; i++) { uhv += u[i] * hvv[i]; vhu += v[i] * hu[i]; }
  snprintf(id, sizeof id, "gsym.%s", tag);
  row(id, uhv, vhu, 1e-12);
}

int main(void) {
  int r, i;
  double rowbuf[5];
  for (r = 0; r < NR; r++) {
    spinel_gen_row(rowbuf, 5, r);
    for (i = 0; i < 5; i++) data[r * 5 + i] = rowbuf[i];
  }
  printf("id\tgot\twant\trelerr\tverdict\n");
  double w0[NW] = { 0.2, -0.1, 0.3, 0.0, 0.5 };
  check_point("w0", w0);
  /* a second point with a different active set: two plain SGD steps of the
   * E079 recipe, taken here from the reverse product (which returns the
   * primal and assigns the gradient) -- still nothing but the objects */
  double w1[NW], gr[NW];
  memcpy(w1, w0, sizeof w1);
  for (r = 0; r < 2; r++) {
    spinel_grad_sq_hinge_loss(data, NR * 5, w1, gr, NW);
    for (i = 0; i < NW; i++) w1[i] -= 0.1 * gr[i];
  }
  check_point("w1", w1);
  printf("#summary\tworst_rel=%.3e\tfails=%d\t%s\n", worst, nfail,
         nfail == 0 ? "ALL-PASS" : "RED");
  return nfail == 0 ? 0 : 1;
}
