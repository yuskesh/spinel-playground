/* tools/grad/rules -- implementations of the differentiable runtime
 * primitives (E082).
 *
 * THIS FILE IS NEVER SHOWN TO ENZYME.  It is compiled to an ordinary object
 * (rules_impl.o) and linked into the final program / gate driver, exactly the
 * way libspinel_rt is.  What Enzyme sees instead is the EXTERN DECLARATION
 * plus the registered rule (spinel_grad_rules_enzyme.c): the function is
 * opaque on purpose, because that is the shape every future `sp_*` runtime
 * registration will have, and because it makes the control experiment honest
 * (remove the registration and the build MUST fail loud -- see the reject
 * corpus, obstacle `norule`).
 *
 * DISCIPLINE.  Nothing in this file may allocate or call anything that can.
 * gradgen's G2 audit accepts an allocation-frontier chain whose terminal is a
 * registered primitive ON THE STRENGTH OF THIS PROPERTY, and the RIMPL gate
 * (nm -u over rules_impl.o) re-checks it structurally on every run: the only
 * undefined symbols this object may have are none at all.
 */

/* clamp to [0,1].  The boundary CONVENTION (which side the kink belongs to)
 * is what the registered derivative rule fixes; the value itself is the
 * ordinary clamp. */
double spg_clamp01(double u)
{
    if (u < 0.0) return 0.0;
    if (u > 1.0) return 1.0;
    return u;
}

/* Piecewise-linear table lookup on the UNIT INDEX GRID, clamped at both ends:
 * u in [0, n-1], node i sits at u == i.  There is deliberately no (x0, dx)
 * pair here: Enzyme v0.0.290 resolves a registered rule against the CALL
 * SITE's activity, and a scalar argument that is inactive at one call site
 * and active at another cannot be served by one registered signature (E082
 * measured the assertion failures).  Mapping x -> (x - x0) / dx is ordinary
 * differentiable Ruby and stays on the caller's side of the boundary. */
double spg_lut1(const double *tab, long long n, double u)
{
    long long i;
    double t;
    if (n < 2) return (n == 1) ? tab[0] : 0.0;
    if (u < 0.0) u = 0.0;
    if (u > (double)(n - 1)) u = (double)(n - 1);
    i = (long long)u;
    if (i > n - 2) i = n - 2;
    t = u - (double)i;
    return tab[i] + t * (tab[i + 1] - tab[i]);
}

/* The CONTROL.  A primitive with NO registered rule, kept so the reject
 * corpus can demonstrate, on every run, that an un-registered runtime
 * function is refused at compile time with its name in the message --
 * rather than silently differentiated as zero. */
double spg_mystery(double u)
{
    return (u < 0.5) ? u * u : 0.25 + 0.7 * (u - 0.5);
}
