/* E082 -- the independent oracle for the rules kernels.
 *
 * Discipline (E066: a differential oracle is blind to a shared mistake):
 * nothing here calls the registered rule functions or reads their source.
 * The derivatives are written from the MATHEMATICS of the two kernels,
 * and a central finite difference of the actual linked primal (spg_val_*)
 * is the third, implementation-free leg.
 *
 *   lut_loss(x, tab):  L = sum lut(tab, x_i)^2
 *       dL/dx_i = 2 lut(x_i) (tab[c+1] - tab[c]) on the open cell, 0 clamped
 *   clamp_loss(x):     v = .25 + 1.5 c01((x-.25)/1.5),  L = sum v^2/2
 *       dL/dx_i = v_i        on (0.25, 1.75), 0 outside
 *       d2L/dx_i^2 = 1       on (0.25, 1.75), 0 outside  (H is diagonal)
 *
 * Output: e082_rules_analytic.tsv (one row per component = one gate row).
 */
#include <stdio.h>
#include <math.h>
#include <string.h>

extern double spg_val_lut_loss(const double *, long long, long long,
                               const double *, long long, long long);
extern double spg_grad_lut_loss(const double *, long long, long long,
                                const double *, long long, long long,
                                double *);
extern double spg_val_clamp_loss(const double *, long long, long long);
extern double spg_grad_clamp_loss(const double *, long long, long long,
                                  double *);
extern double spg_jvp_clamp_loss(const double *, long long, long long,
                                 const double *);
extern double spg_hvp_clamp_loss(const double *, long long, long long,
                                 const double *, double *, double *);

static double relerr(double got, double ref)
{
    double den = fabs(ref) > 1.0 ? fabs(ref) : 1.0;
    return fabs(got - ref) / den;
}

/* the mathematics of the unit-grid clamped linear interpolation */
static double lut_val(const double *tab, long long n, double u)
{
    if (u <= 0.0) return tab[0];
    if (u >= (double)(n - 1)) return tab[n - 1];
    long long i = (long long)u;
    if (i > n - 2) i = n - 2;
    return tab[i] + (u - (double)i) * (tab[i + 1] - tab[i]);
}

static double lut_slope(const double *tab, long long n, double u)
{
    if (u <= 0.0 || u >= (double)(n - 1)) return 0.0;
    long long i = (long long)u;
    if (i > n - 2) i = n - 2;
    return tab[i + 1] - tab[i];
}

static int rows = 0, fail = 0;
static double worst = 0.0;

static void row(const char *gate, const char *tgt, int p, int k,
                double got, double ref, double tol)
{
    double r = relerr(got, ref);
    if (r > worst) worst = r;
    if (!(r < tol)) fail++;
    rows++;
    printf("%s\t%s\t%d\t%d\t%.17g\t%.17g\t%.3e\t%s\n", gate, tgt, p, k,
           got, ref, r, r < tol ? "OK" : "MISMATCH");
}

int main(void)
{
    printf("gate\ttarget\tprobe\tk\tgot\tref\trel\tverdict\n");

    /* ---- lut_loss --------------------------------------------------- */
    {
        const double probes[2][3] = {{0.5, 1.5, 2.2}, {0.25, 2.75, 1.1}};
        const double tabs[2][4] = {{0.0, 1.0, 4.0, 9.0},
                                   {2.0, -1.0, 3.0, 0.5}};
        for (int p = 0; p < 2; p++) {
            double x[3], g[3];
            memcpy(x, probes[p], sizeof x);
            const double *tab = tabs[p];
            spg_grad_lut_loss(x, 3, 3, tab, 4, 4, g);
            for (int k = 0; k < 3; k++) {
                /* analytic */
                double ref = 2.0 * lut_val(tab, 4, x[k]) *
                             lut_slope(tab, 4, x[k]);
                row("RAN", "lut_loss", p, k, g[k], ref, 1e-12);
                /* finite difference of the linked primal */
                double h = 1e-6, s = x[k];
                x[k] = s + h;
                double fp = spg_val_lut_loss(x, 3, 3, tab, 4, 4);
                x[k] = s - h;
                double fm = spg_val_lut_loss(x, 3, 3, tab, 4, 4);
                x[k] = s;
                row("RFD", "lut_loss", p, k, g[k], (fp - fm) / (2 * h), 1e-6);
            }
        }
    }

    /* ---- clamp_loss ------------------------------------------------- */
    {
        const double probes[2][4] = {{0.3, -0.4, 1.9, 0.75},
                                     {0.6, 0.2, -1.0, 2.5}};
        for (int p = 0; p < 2; p++) {
            double x[4], g[4], hv[4], gg[4];
            memcpy(x, probes[p], sizeof x);
            spg_grad_clamp_loss(x, 4, 4, g);
            for (int k = 0; k < 4; k++) {
                int inside = (x[k] > 0.25 && x[k] < 1.75);
                double u = (x[k] - 0.25) / 1.5;
                double c = u < 0.0 ? 0.0 : (u > 1.0 ? 1.0 : u);
                double v = 0.25 + 1.5 * c;
                double ref = inside ? v : 0.0;
                row("RAN", "clamp_loss", p, k, g[k], ref, 1e-12);
                /* Hessian column k: e_k on the diagonal, 0 elsewhere */
                double dir[4] = {0, 0, 0, 0};
                dir[k] = 1.0;
                double ret = spg_hvp_clamp_loss(x, 4, 4, dir, gg, hv);
                for (int i = 0; i < 4; i++)
                    row("RH", "clamp_loss", p, k * 10 + i, hv[i],
                        (i == k && inside) ? 1.0 : 0.0, 1e-12);
                row("RDOT", "clamp_loss", p, k, ret, ref, 1e-12);
                /* jvp along e_k is the k-th gradient component */
                row("RJVP", "clamp_loss", p, k,
                    spg_jvp_clamp_loss(x, 4, 4, dir), ref, 1e-12);
            }
        }
    }
    printf("#\trows=%d\tfail=%d\tworst_rel=%.3e\n", rows, fail, worst);
    return fail ? 1 : 0;
}
