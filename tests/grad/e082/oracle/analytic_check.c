/* E082 -- the ANALYTIC differential oracle for the promoted HVP surface.
 *
 * Independence discipline (E066: a differential oracle is blind to a shared
 * mistake): this file never calls Enzyme and never reads the rule sources.
 * The Hessian of `cubic` is written out from the calculus,
 *
 *     f(x) = sum x_i^3 + 2 sum x_i x_{i+1} + exp(x0 x1)
 *     H[i][i]   = 6 x_i                (+ exp terms in the (0,1) corner)
 *     H[i][i+1] = H[i+1][i] = 2        (+ exp terms in the (0,1) corner)
 *     d2/dx0dx0 exp = x1^2 e,  d2/dx0dx1 exp = (1 + x0 x1) e,
 *     d2/dx1dx1 exp = x0^2 e
 *
 * and the product surface's spg_hvp_cubic is asked for the Hessian
 * COLUMN BY COLUMN (unit directions), which also happens to be the exact
 * usage a Newton/L-BFGS caller has.  E078 s5.2 measured this same identity
 * from the out-of-surface shim at rel 0.000e+00; the promotion must not
 * move it.
 *
 * Output: e082_hvp_analytic.tsv (one row per Hessian entry = one gate row).
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

extern double spg_hvp_cubic(const double *x, long long nx, long long n,
                            const double *dir, double *g, double *hv);
extern double spg_grad_cubic(const double *x, long long nx, long long n,
                             double *g);
extern double spg_jvp_cubic(const double *x, long long nx, long long n,
                            const double *dir);

#define N 4

static void analytic_hessian(const double *x, double H[N][N])
{
    memset(H, 0, sizeof(double) * N * N);
    for (int i = 0; i < N; i++)
        H[i][i] = 6.0 * x[i];
    for (int i = 0; i < N - 1; i++) {
        H[i][i + 1] += 2.0;
        H[i + 1][i] += 2.0;
    }
    double e = exp(x[0] * x[1]);
    H[0][0] += x[1] * x[1] * e;
    H[1][1] += x[0] * x[0] * e;
    H[0][1] += (1.0 + x[0] * x[1]) * e;
    H[1][0] += (1.0 + x[0] * x[1]) * e;
}

static void analytic_grad(const double *x, double g[N])
{
    for (int i = 0; i < N; i++)
        g[i] = 3.0 * x[i] * x[i];
    for (int i = 0; i < N - 1; i++) {
        g[i] += 2.0 * x[i + 1];
        g[i + 1] += 2.0 * x[i];
    }
    double e = exp(x[0] * x[1]);
    g[0] += x[1] * e;
    g[1] += x[0] * e;
}

static double relerr(double got, double ref)
{
    double den = fabs(ref) > 1.0 ? fabs(ref) : 1.0;
    return fabs(got - ref) / den;
}

int main(void)
{
    const double probes[2][N] = {{0.7, -1.3, 0.4, 2.1},
                                 {0.25, 0.5, -0.75, 1.0}};
    double worst_h = 0.0, worst_g = 0.0, worst_sym = 0.0, worst_jvp = 0.0;
    int fail = 0, rows = 0;

    printf("probe\ti\tj\thvp\tanalytic\trel\tverdict\n");
    for (int p = 0; p < 2; p++) {
        const double *x = probes[p];
        double H[N][N], ga[N], g[N], hv[N], Hcols[N][N];
        analytic_hessian(x, H);
        analytic_grad(x, ga);

        for (int j = 0; j < N; j++) {
            double dir[N] = {0, 0, 0, 0};
            dir[j] = 1.0;
            double ret = spg_hvp_cubic(x, N, N, dir, g, hv);
            for (int i = 0; i < N; i++) {
                Hcols[i][j] = hv[i];
                double r = relerr(hv[i], H[i][j]);
                if (r > worst_h) worst_h = r;
                if (!(r < 1e-10)) fail++;
                rows++;
                printf("%d\t%d\t%d\t%.17g\t%.17g\t%.3e\t%s\n", p, i, j,
                       hv[i], H[i][j], r, r < 1e-10 ? "OK" : "MISMATCH");
            }
            /* the returned scalar is grad . e_j = g[j] */
            double r = relerr(ret, ga[j]);
            if (r > worst_g) worst_g = r;
            if (!(r < 1e-10)) fail++;
            /* jvp along the same unit direction must agree */
            double jv = spg_jvp_cubic(x, N, N, dir);
            r = relerr(jv, ga[j]);
            if (r > worst_jvp) worst_jvp = r;
            if (!(r < 1e-10)) fail++;
        }
        /* the gradient the hvp writes out, against calculus */
        for (int i = 0; i < N; i++) {
            double r = relerr(g[i], ga[i]);
            if (r > worst_g) worst_g = r;
            if (!(r < 1e-10)) fail++;
        }
        /* symmetry of the RECONSTRUCTED Hessian */
        for (int i = 0; i < N; i++)
            for (int j = i + 1; j < N; j++) {
                double s = fabs(Hcols[i][j] - Hcols[j][i]);
                if (s > worst_sym) worst_sym = s;
            }
    }
    printf("#\trows=%d\tfail=%d\tworst_rel_vs_analytic=%.3e\t"
           "worst_grad_rel=%.3e\tworst_jvp_rel=%.3e\tworst_symmetry_abs=%.3e\n",
           rows, fail, worst_h, worst_g, worst_jvp, worst_sym);
    return fail ? 1 : 0;
}
