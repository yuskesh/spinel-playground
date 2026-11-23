/* tools/grad/rules -- Enzyme registrations for the differentiable runtime
 * primitives (E082).  APPENDED by spinel-gradgen to the pinned generated C
 * whenever the module calls a registered primitive, so the registration
 * globals, the extern declarations and the call sites share ONE module
 * (Enzyme is a module pass).  Requires `preserve-nvvm` ahead of `enzyme` in
 * the opt pipeline -- the registration globals are lowered to
 * !enzyme_gradient / !enzyme_derivative metadata by that pass and are inert
 * without it (E082 measured exactly that: without preserve-nvvm the build
 * dies with "No augmented forward pass found").
 *
 * SIGNATURE CONVENTION (measured against Enzyme v0.0.290, E082):
 *   - reverse rule = {primal, augmented forward, gradient} in a global named
 *     __enzyme_register_gradient_<primal>.
 *   - the augmented forward and the gradient take the DEFAULT-TYPE shape:
 *     every pointer-sized argument (pointers AND long long) is passed as a
 *     (value, shadow) PAIR; float scalars are passed once; the gradient gets
 *     the adjoint of the return appended and RETURNS the adjoint of the one
 *     active float scalar.
 *   - a primitive must therefore carry EXACTLY ONE active double argument.
 *     Mixed constant/active scalars resolve against call-site activity and
 *     one registered signature cannot serve two call sites (assertion
 *     failures in AdjointGenerator.h:6277 / EnzymeLogic.cpp:4209, measured).
 *   - forward rule = {primal, derivative} in __enzyme_register_derivative_*.
 *     Enzyme v0.0.290 refuses a forward registration at any call site with a
 *     CONSTANT argument (EnzymeLogic.cpp:4903 `hasconstant`), so only
 *     all-active-signature primitives (spg_clamp01) carry one; spg_lut1
 *     (const table, integer length) structurally cannot, and gradgen refuses
 *     jvp:/hvp: on targets that reach it (obstacle `norulefwd`).
 *
 * The ledger of what is registered, with the chosen kink conventions, is
 * rules.tsv next to this file.  Keep the three in sync -- gradgen's RULES
 * table is generated from rules.tsv at run time, so a primitive missing from
 * the ledger is refused even if registered here.
 */

/* `pure` is load-bearing: the generated TU declares these with no attributes,
 * so every call is a may-write-anything clobber to LLVM -- which (a) blocks
 * DSE from removing the no-op sp_gc_nroots save/restore pair the elision
 * pass leaves behind, and (b) would do the same inside the adjoint.  The
 * redeclaration merges the attribute across the whole TU.  All three
 * primitives genuinely are pure (read-only on their pointer arguments,
 * no observable side effects -- the RIMPL gate keeps the implementations
 * self-contained). */
extern double spg_clamp01(double u) __attribute__((pure));
/* Spinel Extended: int64_t, as the pinned compiler declares it (see spinel-gradgen). */
extern double spg_lut1(const double *tab, int64_t n, double u) __attribute__((pure));
extern double spg_mystery(double u) __attribute__((pure));

/* The FFI marshalling accessor the generated C wraps around a :float_array
 * argument lives in libspinel_rt (vendor/spinel/lib/sp_array.c:588) and is
 * therefore OPAQUE to Enzyme, which then demands an augmented forward pass
 * for it ("No augmented forward pass found for sp_FloatArray_ffi_data",
 * measured E082).  Giving the module a WEAK copy of the one-line body lets
 * Enzyme differentiate the projection natively -- shadow propagation through
 * `a->data` is exact, active table or not -- and the strong library symbol
 * still wins at link time, so no duplicate-symbol hazard.  This is the same
 * "use vendor's real typedef by appending" bargain the gradgen shim makes:
 * if the accessor's semantics ever change, this copy is one line to re-sync
 * and the G3 differential gate is what would catch the drift. */
__attribute__((weak)) const double *sp_FloatArray_ffi_data(sp_FloatArray *a)
{
    return a ? (const double *)a->data : (const double *)0;
}

/* ---- spg_clamp01: reverse -------------------------------------------------
 * Kink convention (recorded in rules.tsv): the derivative is 1 on the OPEN
 * interval (0,1) and 0 outside it AND at the boundary points themselves.
 * A probe point sitting exactly on 0.0 or 1.0 will therefore disagree with a
 * central finite difference (which reports the two-arm average 0.5) -- same
 * relu-kink discipline as grad_def probes, the writer avoids the kink. */
double spg_clamp01_aug(double u)
{
    return spg_clamp01(u);
}

double spg_clamp01_rev(double u, double d_out)
{
    return (u > 0.0 && u < 1.0) ? d_out : 0.0;
}

void *__enzyme_register_gradient_spg_clamp01[3] = {
    (void *)spg_clamp01,
    (void *)spg_clamp01_aug,
    (void *)spg_clamp01_rev,
};

/* ---- spg_clamp01: forward (all-active signature, so this one is usable) --
 * A forward rule for a value-returning primal returns the PAIR
 * {value, tangent}: when the call site uses the primal value Enzyme consumes
 * the rule's return directly and extracts both fields (measured E082 -- a
 * plain-double return crashes CreateExtractValue), and when it does not, the
 * fixderivative_ wrapper extracts field 1. */
typedef struct {
    double val;
    double tan;
} spg_dual;

spg_dual spg_clamp01_fwd(double u, double d_u)
{
    spg_dual r;
    r.val = spg_clamp01(u);
    r.tan = (u > 0.0 && u < 1.0) ? d_u : 0.0;
    return r;
}

void *__enzyme_register_derivative_spg_clamp01[2] = {
    (void *)spg_clamp01,
    (void *)spg_clamp01_fwd,
};

/* ---- spg_lut1: reverse ----------------------------------------------------
 * d/du lut(u) = tab[i+1] - tab[i] on the open cell (i, i+1); 0 outside the
 * clamped range and at the clamp boundaries.  At an interior NODE u == i the
 * convention is the RIGHT cell's slope (i = (long long)u lands there), which
 * matches what Enzyme would produce from the implementation body.  d_tab is
 * accumulated too, so the rule stays correct if a caller ever makes the
 * table active. */
double spg_lut1_aug(const double *tab, double *d_tab, long long n,
                    long long d_n, double u)
{
    return spg_lut1(tab, n, u);
}

double spg_lut1_rev(const double *tab, double *d_tab, long long n,
                    long long d_n, double u, double d_out)
{
    long long i;
    double t;
    /* When the table is CONSTANT at the call site Enzyme hands the PRIMAL
     * pointer in the shadow slot (measured E082: the cached augmented pair
     * carries tab twice) -- accumulating into it would corrupt the table the
     * remaining reverse iterations still read.  A distinct pointer is a real
     * shadow; the same pointer (or null) means "no shadow storage". */
    int tab_active = (d_tab != 0) && (d_tab != tab);
    (void)d_n;
    if (n < 2) return 0.0;
    if (u <= 0.0 || u >= (double)(n - 1)) {
        /* clamped: flat.  The clamped VALUE still pulls on the end nodes. */
        if (tab_active) {
            long long e = (u <= 0.0) ? 0 : (n - 1);
            d_tab[e] += d_out;
        }
        return 0.0;
    }
    i = (long long)u;
    if (i > n - 2) i = n - 2;
    t = u - (double)i;
    if (tab_active) {
        d_tab[i] += d_out * (1.0 - t);
        d_tab[i + 1] += d_out * t;
    }
    return d_out * (tab[i + 1] - tab[i]);
}

void *__enzyme_register_gradient_spg_lut1[3] = {
    (void *)spg_lut1,
    (void *)spg_lut1_aug,
    (void *)spg_lut1_rev,
};

/* spg_mystery: NO registration, ON PURPOSE.  See spinel_grad_rules_impl.c. */
