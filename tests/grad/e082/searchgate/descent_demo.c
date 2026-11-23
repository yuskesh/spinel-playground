/* E082 -- three searchers, one objective, and the gates that tell them apart.
 *
 * The objective is the REAL product surface: lut_loss from ../rules
 * (spg_val_lut_loss / spg_grad_lut_loss, Enzyme through a registered custom
 * rule).  Three searchers minimise it from the same starts:
 *
 *   correct     gradient descent with backtracking line search.  Trace rows
 *               carry accepted flags and the directional derivative of every
 *               accepted step.  Expected: S1/S2 green, S3 beats the random
 *               control.
 *   anchor      E078 s6's defect, transplanted: the REPORTED objective is
 *               re-anchored every step (f(x) minus a baseline re-derived
 *               from the current iterate), so the report is structurally
 *               non-monotone while the searcher still prints "converged".
 *               Expected: S1 RED -- and the point is that its final
 *               "success" line is indistinguishable from the correct one.
 *   bestsofar   a random walk that REPORTS min-so-far.  S1 is structurally
 *               green (a running minimum cannot increase): the gate E078
 *               shipped would bless it.  Its accepted steps have
 *               non-negative directional derivatives (S2 RED) and it cannot
 *               beat the budget-matched random control (S3 RED).  This is
 *               why S1 alone was never enough (E078 Honest boundary).
 *
 * Everything is deterministic: one LCG, fixed seeds, fixed starts.
 * Usage: descent_demo <correct|anchor|bestsofar|control> > trace.tsv
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

extern double spg_val_lut_loss(const double *, long long, long long,
                               const double *, long long, long long);
extern double spg_grad_lut_loss(const double *, long long, long long,
                                const double *, long long, long long,
                                double *);

#define N 3
static const double TAB[4] = {0.0, 1.0, 4.0, 9.0};
static const double STARTS[3][N] = {{0.6, 1.4, 2.3},
                                    {2.6, 0.4, 1.7},
                                    {1.2, 2.9, 0.2}};

static unsigned long lcg_s = 12345;
static double lcg(void)
{
    lcg_s = (lcg_s * 1103515245UL + 12345UL) & 0x7fffffffUL;
    return (double)lcg_s / 2147483648.0;
}

static double f(const double *x)
{
    return spg_val_lut_loss(x, N, N, TAB, 4, 4);
}

static void g(const double *x, double *gr)
{
    spg_grad_lut_loss(x, N, N, TAB, 4, 4, gr);
}

static void clamp_dom(double *x)
{
    for (int i = 0; i < N; i++) {
        if (x[i] < 0.0) x[i] = 0.0;
        if (x[i] > 3.0) x[i] = 3.0;
    }
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "correct";

    if (!strcmp(mode, "control")) {
        /* budget-matched random search: 3 runs x 60 evaluations */
        printf("run\tstep\tobjective\n");
        for (int r = 0; r < 3; r++) {
            double best = 1e300;
            for (int s = 0; s < 60; s++) {
                double x[N];
                for (int i = 0; i < N; i++) x[i] = 3.0 * lcg();
                double v = f(x);
                if (v < best) best = v;
                printf("%d\t%d\t%.17g\n", r, s, best);
            }
        }
        return 0;
    }

    printf("run\tstep\tobjective\taccepted\tdirderiv\n");
    for (int r = 0; r < 3; r++) {
        double x[N], gr[N];
        memcpy(x, STARTS[r], sizeof x);
        int step = 0;

        if (!strcmp(mode, "correct")) {
            for (int it = 0; it < 20 && step < 60; it++) {
                double fx = f(x);
                g(x, gr);
                double t = 0.5, dd = 0.0;
                for (int i = 0; i < N; i++) dd -= gr[i] * gr[i];
                if (it == 0)
                    printf("%d\t%d\t%.17g\t1\t0.0\n", r, step++, fx);
                int done = 0;
                for (int bt = 0; bt < 8 && step < 60; bt++) {
                    double y[N];
                    for (int i = 0; i < N; i++) y[i] = x[i] - t * gr[i];
                    clamp_dom(y);
                    double fy = f(y);
                    if (fy < fx) {   /* strict: a converged descent STOPS
                                      * rather than emitting no-op steps
                                      * (whose dirderiv 0 would read as a
                                      * non-descending accepted step) */
                        memcpy(x, y, sizeof x);
                        printf("%d\t%d\t%.17g\t1\t%.17g\n", r, step++, fy,
                               t * dd);
                        done = 1;
                        break;
                    }
                    /* rejected probe: in the trace, exempt from S1/S2 */
                    printf("%d\t%d\t%.17g\t0\t%.17g\n", r, step++, fy, t * dd);
                    t *= 0.5;
                }
                if (!done) break;
            }
            fprintf(stderr, "run %d converged, f=%.6g\n", r, f(x));
        } else if (!strcmp(mode, "anchor")) {
            /* E078 s6's defect, faithfully: the searcher re-derives its
             * target every step -- here, the objective it REPORTS is the
             * distance of f(x) to the NEAREST of several levels, re-picked
             * each step.  A re-anchored distance is structurally
             * non-negative and bounces every time the descent crosses a
             * level, so the report cannot be compared across steps -- and
             * isn't.  The DESCENT itself is fine (real gradient, real
             * steps, honest dirderiv): S1 is what catches it, and only S1. */
            /* a tie-proximity search on the lut grid, E078's defect
             * verbatim: the coordinate under search (the one currently
             * closest to a cell midpoint) is RE-DERIVED every step.  The
             * reported objective -- distance of that coordinate to its
             * midpoint -- is therefore structurally non-negative, bounces
             * whenever a fixed step overshoots the midpoint or the argmin
             * switches coordinate, and never contradicts anything.  Each
             * step still honestly descends ITS OWN objective (dirderiv
             * -0.2 < 0): S1 is what catches this, and only S1. */
            for (int it = 0; it < 40; it++) {
                int j = 0;
                double dj = 1e300;
                for (int i = 0; i < N; i++) {
                    double mid = floor(x[i]) + 0.5;
                    double d = fabs(x[i] - mid);
                    if (d < dj) { dj = d; j = i; }
                }
                printf("%d\t%d\t%.17g\t1\t%.17g\n", r, it, dj, -0.2);
                double mid = floor(x[j]) + 0.5;
                x[j] -= 0.2 * (x[j] >= mid ? 1.0 : -1.0);
            }
            fprintf(stderr, "run %d converged, f=%.6g\n", r, f(x));
        } else if (!strcmp(mode, "bestsofar")) {
            /* random walk reporting min-so-far: S1 structurally green */
            double best = f(x);
            double fprev = best;
            for (int it = 0; it < 20; it++) {
                double y[N];
                for (int i = 0; i < N; i++)
                    y[i] = x[i] + 0.6 * (lcg() - 0.5);
                clamp_dom(y);
                double fy = f(y);
                g(x, gr);
                double dd = 0.0;
                for (int i = 0; i < N; i++) dd += gr[i] * (y[i] - x[i]);
                memcpy(x, y, sizeof x);
                if (fy < best) best = fy;
                /* reports BEST, walks anywhere; dirderiv recorded honestly */
                printf("%d\t%d\t%.17g\t1\t%.17g\n", r, it, best, dd);
                fprev = fy;
            }
            (void)fprev;
            fprintf(stderr, "run %d converged, f=%.6g\n", r, best);
        }
    }
    return 0;
}
