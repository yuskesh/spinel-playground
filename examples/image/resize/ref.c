/* examples/image/resize -- the reference implementation and the measuring tools.
 *
 * This is **not part of the surface**. It is scaffolding for checking that app.rb declares
 * with `ffi_func` and calls itself. It comes from the predecessor's experiment reference
 * (e072_ref.c), with only what the exhibit needs (route (b) = banded taps) taken out.
 *
 * It is compiled with `-ffp-contract=off` (build.sh). The reference decides its own
 * rounding. Where FMA is wanted it is written **out loud** as `fmaf`: "did the device
 * contract?" is one of the 2 things this sample measures, and a reference that happened
 * to contract could not answer that question.
 *
 * The coordinate convention is **half-pixel**:
 *
 *     s = (j + 0.5) * (n_in / n_out) - 0.5,   clamped to [0, n_in - 1]
 *
 * That is, the same as jax.image.resize / PIL / OpenCV / torch(align_corners=False).
 * Unless the scale is 1, align-corners gives a different answer at every pixel, so this is
 * **a decision about semantics**. It is written in 3 places (the generator, the declaration
 * and here), not inferred.
 */
#include <math.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --------------------------------------------------------------- weights */
/* The same f64 formula the host (Ruby) computes. Returns 2 tap positions and weights. */
static void tap_f64(int nin, int nout, int j, int *i0, int *i1, double *w0,
                    double *w1) {
  double s = ((double)j + 0.5) * (double)nin / (double)nout - 0.5;
  double lim = (double)(nin - 1);
  if (s < 0.0) s = 0.0;
  if (s > lim) s = lim;
  double fl = floor(s);
  int a0 = (int)fl;
  if (a0 > nin - 1) a0 = nin - 1;
  if (a0 < 0) a0 = 0;
  int a1 = a0 + 1;
  if (a1 > nin - 1) a1 = nin - 1;
  *i0 = a0;
  *i1 = a1;
  *w1 = s - fl;
  *w0 = 1.0 - *w1;
}

/* The form after the upload has rounded to f32 once. */
static void tap_up(int nin, int nout, int j, int *i0, int *i1, float *w0,
                   float *w1) {
  int a0, a1;
  double d0, d1;
  tap_f64(nin, nout, j, &a0, &a1, &d0, &d1);
  *i0 = a0;
  *i1 = a1;
  *w0 = (float)d0;
  *w1 = (float)d1;
}

/* Output to check the Ruby side's weight construction against (idx and wgt as (nout, 2)).
 * The aim is to compare 2 independent implementations of the same formula. */
void sp_img_taps(int nin, int nout, const double *idx, const double *wgt) {
  double *ix = (double *)idx;
  double *wg = (double *)wgt;
  for (int j = 0; j < nout; j++) {
    int a0, a1;
    float w0, w1;
    tap_up(nin, nout, j, &a0, &a1, &w0, &w1);
    ix[j * 2] = (double)a0;
    ix[j * 2 + 1] = (double)a1;
    wg[j * 2] = (double)w0;
    wg[j * 2 + 1] = (double)w1;
  }
}

/* The 3 spellings a 2-term weighted sum can take in f32. On an op carrying
 * `fastmath<contract>`, `w0*v0 + w1*v1` may stay 2 products and 1 sum, or either
 * product may be contracted into the sum. The 3 differ by 1 ulp, and the backend chooses
 * one per expression. **Enumerating them** turns "the device differed" into
 * "the device contracted here". */
static float acc2(int mode, float w0, float v0, float w1, float v1) {
  if (mode == 1) return fmaf(w1, v1, w0 * v0);
  if (mode == 2) return fmaf(w0, v0, w1 * v1);
  return w0 * v0 + w1 * v1;
}

/* Resampling with banded taps (route (b)). Axis 0 first, axis 1 second: the same order as the declaration.
 * The intermediate is materialized as an f32 tensor, so the reference rounds to f32 too.
 * `out` gets the f32 values **before quantization**, widened to double. */
void sp_img_ref(int mode, const char *src, int ih, int iw, int oh, int ow,
                const double *out) {
  double *o = (double *)out;
  const unsigned char *s = (const unsigned char *)src;
  int *y0 = (int *)malloc((size_t)oh * sizeof(int));
  int *y1 = (int *)malloc((size_t)oh * sizeof(int));
  float *wy0 = (float *)malloc((size_t)oh * sizeof(float));
  float *wy1 = (float *)malloc((size_t)oh * sizeof(float));
  int *x0 = (int *)malloc((size_t)ow * sizeof(int));
  int *x1 = (int *)malloc((size_t)ow * sizeof(int));
  float *wx0 = (float *)malloc((size_t)ow * sizeof(float));
  float *wx1 = (float *)malloc((size_t)ow * sizeof(float));
  if (!y0 || !y1 || !wy0 || !wy1 || !x0 || !x1 || !wx0 || !wx1) {
    fprintf(stderr, "sp_img_ref: out of memory\n");
    return;
  }
  for (int i = 0; i < oh; i++) tap_up(ih, oh, i, &y0[i], &y1[i], &wy0[i], &wy1[i]);
  for (int j = 0; j < ow; j++) tap_up(iw, ow, j, &x0[j], &x1[j], &wx0[j], &wx1[j]);

  for (int i = 0; i < oh; i++)
    for (int j = 0; j < ow; j++) {
      float v00 = (float)s[((size_t)y0[i] * iw) + x0[j]];
      float v01 = (float)s[((size_t)y0[i] * iw) + x1[j]];
      float v10 = (float)s[((size_t)y1[i] * iw) + x0[j]];
      float v11 = (float)s[((size_t)y1[i] * iw) + x1[j]];
      float c0 = acc2(mode, wy0[i], v00, wy1[i], v10);
      float c1 = acc2(mode, wy0[i], v01, wy1[i], v11);
      o[((size_t)i * ow) + j] = (double)acc2(mode, wx0[j], c0, wx1[j], c1);
    }
  free(y0); free(y1); free(wy0); free(wy1);
  free(x0); free(x1); free(wx0); free(wx1);
}

/* ------------------------------------------------------------ quantizer */
/* mode 0 = half-to-even (the default of `quant:`), 1 = half-up. */
static float quant1(int mode, float v) {
  float q = (mode == 1) ? floorf(v + 0.5f) : nearbyintf(v); /* FE_TONEAREST */
  q = q < 0.0f ? 0.0f : q;
  q = q > 255.0f ? 255.0f : q;
  return q;
}

/* out[]: 0 ties, 1 split (the count where half-even and half-up disagree), 2 min_margin,
 *        3 sat_hi, 4 sat_lo */
void sp_img_ties(const double *v, const double *out, size_t n) {
  double *o = (double *)out;
  int64_t ties = 0, split = 0, sat_hi = 0, sat_lo = 0;
  double minmargin = 1.0;
  for (size_t i = 0; i < n; i++) {
    float x = (float)v[i];
    if (x >= 255.0f) sat_hi++;
    if (x <= 0.0f) sat_lo++;
    x = x < 0.0f ? 0.0f : (x > 255.0f ? 255.0f : x);
    float fl = floorf(x);
    float fr = x - fl;
    double m = fabs((double)fr - 0.5);
    if (fr == 0.5f) ties++;
    else if (m < minmargin) minmargin = m;
    if (quant1(0, x) != quant1(1, x)) split++;
  }
  o[0] = (double)ties;   o[1] = (double)split;  o[2] = minmargin;
  o[3] = (double)sat_hi; o[4] = (double)sat_lo;
}

/* Checking against the enumerated set. Counts which of the 3 ways of contracting the
 * device's bytes match. Only when `unexplained` (pixels matching none of them) is not 0
 * is there an unexplained difference.
 *   out[]: 0 nd_vs_plain, 1 m_plain, 2 m_fma1, 3 m_fma2, 4 unexplained */
void sp_img_enumerate(const char *got, const double *r0, const double *r1,
                      const double *r2, const double *out, size_t n) {
  const unsigned char *g = (const unsigned char *)got;
  double *o = (double *)out;
  int64_t nd = 0, m0 = 0, m1 = 0, m2 = 0, un = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char q0 = (unsigned char)quant1(0, (float)r0[i]);
    unsigned char q1 = (unsigned char)quant1(0, (float)r1[i]);
    unsigned char q2 = (unsigned char)quant1(0, (float)r2[i]);
    if (g[i] == q0) m0++; else nd++;
    if (g[i] == q1) m1++;
    if (g[i] == q2) m2++;
    if (g[i] != q0 && g[i] != q1 && g[i] != q2) un++;
  }
  o[0] = (double)nd; o[1] = (double)m0; o[2] = (double)m1;
  o[3] = (double)m2; o[4] = (double)un;
}

/* The columns of "the differences can be explained". Whether a pixel differing from the plain
 * reference sat on a rounding boundary (at_tie), within 2^-10 of it (near), or neither (far).
 *   out[]: 0 nd, 1 nd_at_tie, 2 nd_near, 3 nd_far */
void sp_img_diff_where(const char *got, const double *v, const double *out,
                       size_t n) {
  const unsigned char *g = (const unsigned char *)got;
  double *o = (double *)out;
  int64_t nd = 0, at_tie = 0, nearq = 0, far = 0;
  for (size_t i = 0; i < n; i++) {
    float x = (float)v[i];
    if (g[i] == (unsigned char)quant1(0, x)) continue;
    nd++;
    float cx = x < 0.0f ? 0.0f : (x > 255.0f ? 255.0f : x);
    float fr = cx - floorf(cx);
    if (fr == 0.5f) { at_tie++; continue; }
    if (fabs((double)fr - 0.5) < 1.0 / 1024.0) { nearq++; continue; }
    far++;
  }
  o[0] = (double)nd; o[1] = (double)at_tie; o[2] = (double)nearq;
  o[3] = (double)far;
}

/* Counts the disagreements between the array Ruby (f64) built and the array C rounded to f32.
 * Applied to the tap **positions** it checks "did the 2 implementations choose the same
 * positions" (0 is required); applied to the **weights** it measures "can those weights be
 * represented exactly in f32": 0 means dyadic (the upload's rounding does nothing), otherwise not. */
int64_t sp_img_wdiff(const double *a, const double *b, size_t n) {
  int64_t d = 0;
  for (size_t i = 0; i < n; i++) if (a[i] != b[i]) d++;
  return d;
}

/* Partition of unity: how far the sum of the weights at each output position is from 1,
 * at most. */
double sp_img_partition(const double *wgt, int nout) {
  double worst = 0.0;
  for (int j = 0; j < nout; j++) {
    double s = wgt[j * 2] + wgt[j * 2 + 1];
    double d = fabs(s - 1.0);
    if (d > worst) worst = d;
  }
  return worst;
}

/* FNV-1a reduced to 63 bits. The same function as the predecessor's measurements used,
 * so the README's expected values compare directly with its recorded rows. */
int64_t sp_img_hash_str(const char *s, size_t n) {
  uint64_t hh = 1469598103934665603ull;
  for (size_t i = 0; i < n; i++) {
    hh ^= (unsigned char)s[i];
    hh *= 1099511628211ull;
  }
  return (int64_t)(hh & 0x7fffffffffffffffull);
}

void sp_img_write_pgm(const char *path, const char *px, int h, int w) {
  FILE *f = fopen(path, "wb");
  if (!f) { fprintf(stderr, "sp_img_write_pgm: cannot open %s\n", path); return; }
  fprintf(f, "P5\n%d %d\n255\n", w, h);
  fwrite(px, 1, (size_t)h * w, f);
  fclose(f);
}
