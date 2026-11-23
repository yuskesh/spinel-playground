/* examples/image/filter -- the reference implementation and the measuring tools.
 *
 * This is **not part of the surface**. It is scaffolding for checking that app.rb declares
 * with `ffi_func` and calls itself; neither tools/tensor nor spinel-mlirgen knows this file exists.
 * It comes from the predecessor's experiment reference (e069_ref.c), with only what the exhibit
 * needs taken out (coefficients, boundary handling, rounding and tie counting unchanged, byte for byte).
 *
 * The reference being f32 is deliberate. Several measurements found the same thing:
 * an f64 oracle disagrees with a **correct** f32 kernel exactly on the pixels where the
 * f32 value landed on a rounding boundary and the f64 value did not. Every `float` here is
 * deliberate, and the build line has `-ffp-contract=off` (if the reference contracted to
 * FMA on its own, "did the device contract?" could no longer be asked).
 *
 * The coefficients are **the same decimal literals** as the declarations. The reference being
 * f32 is not enough; it must be **the same** f32.
 */
#include <math.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- windows */
/* KEEP IN SYNC WITH kernels.rb. */
#define S_G3 ((float)0.0625) /* 1/16 -- dyadic, so the convolution is exact */

static const float W_G3[9] = {1, 2, 1, 2, 4, 2, 1, 2, 1};
static const float W_GX[9] = {-1, 0, 1, -2, 0, 2, -1, 0, 1};
static const float W_GY[9] = {-1, -2, -1, 0, 0, 0, 1, 2, 1};

/* border: :zero only. Outside the frame is 0; clamp / reflect are other values of the
 * declaration. */
static int inside(int i, int n) { return i >= 0 && i < n; }

static float conv_u8(const unsigned char *s, int h, int w, const float *wgt,
                     float scale, int y, int x) {
  float acc = 0.0f;
  for (int dy = 0; dy < 3; dy++) {
    for (int dx = 0; dx < 3; dx++) {
      int iy = y + dy - 1, ix = x + dx - 1;
      float v = (inside(iy, h) && inside(ix, w))
                    ? (float)s[(size_t)iy * w + ix]
                    : 0.0f;
      acc += (wgt[dy * 3 + dx] * scale) * v;
    }
  }
  return acc;
}

static float conv_f32(const float *pl, int h, int w, const float *wgt, int y,
                      int x) {
  float acc = 0.0f;
  for (int dy = 0; dy < 3; dy++) {
    for (int dx = 0; dx < 3; dx++) {
      int iy = y + dy - 1, ix = x + dx - 1;
      float v = (inside(iy, h) && inside(ix, w)) ? pl[(size_t)iy * w + ix]
                                                : 0.0f;
      acc += wgt[dy * 3 + dx] * v;
    }
  }
  return acc;
}

/* The pipeline itself. blur(3x3 gaussian /16) -> sobel L1 -> tail.
 *
 * kind 0 = gain tail (`* p`), kind 1 = threshold tail (`(>= p) * 255`),
 * kind 2 = no tail (the gradient itself, **before** the threshold: where threshold ties are counted).
 * `out` gets the f32 values **before quantization**, widened to double (widening is exact).
 * Quantization is kept apart because the rounding contract is a declaration attribute
 * (`quant:`), not part of the pipeline; kept apart, its cost can be measured. */
void sp_img_ref(int kind, double p, const char *src, int h, int w,
                const double *out) {
  const unsigned char *s = (const unsigned char *)src;
  double *o = (double *)out;
  const float pf = (float)p;
  size_t n = (size_t)h * w;
  float *mid = (float *)malloc(n * sizeof(float));
  if (!mid) { fprintf(stderr, "sp_img_ref: out of memory\n"); return; }

  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++)
      mid[(size_t)y * w + x] = conv_u8(s, h, w, W_G3, S_G3, y, x);

  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      float gx = conv_f32(mid, h, w, W_GX, y, x);
      float gy = conv_f32(mid, h, w, W_GY, y, x);
      float r = fabsf(gx) + fabsf(gy);
      if (kind == 1) r = (r >= pf) ? 255.0f : 0.0f;
      else if (kind == 0) r = r * pf;
      o[(size_t)y * w + x] = (double)r;
    }
  free(mid);
}

/* ------------------------------------------------------------ quantizer */
/* mode 0 = half-to-even (the default of `quant:`), 1 = half-up.
 * Both clamp to [0, 255]. */
static float quant1(int mode, float v) {
  float q = (mode == 1) ? floorf(v + 0.5f) : nearbyintf(v); /* FE_TONEAREST */
  q = q < 0.0f ? 0.0f : q;
  q = q > 255.0f ? 255.0f : q;
  return q;
}

void sp_img_quant(int mode, const double *v, const double *out, size_t n) {
  double *o = (double *)out;
  for (size_t i = 0; i < n; i++) o[i] = (double)quant1(mode, (float)v[i]);
}

/* The margin distribution. The columns that put a quantity on the headroom of
 * "it was pixel-exact" (the numeric contract).
 *   out[]: 0 ties, 1 split (pixels where half-even and half-up disagree),
 *          2 min_margin, 3 sat_hi, 4 sat_lo */
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
  o[0] = (double)ties;  o[1] = (double)split; o[2] = minmargin;
  o[3] = (double)sat_hi; o[4] = (double)sat_lo;
}

/* A threshold is a quantizer too (it just has only one boundary). When the tail is threshold,
 * sp_img_ties is vacuous (the output is 0 or 255), so the tie question moves here.
 *   out[]: 0 pixels exactly at t, 1 within 1 ulp of t, 2 pixels above the threshold */
void sp_img_thr_ties(const double *v, double t, const double *out, size_t n) {
  double *o = (double *)out;
  int64_t ties = 0, near = 0, above = 0;
  const float tf = (float)t;
  for (size_t i = 0; i < n; i++) {
    float x = (float)v[i];
    if (x >= tf) above++;
    if (x == tf) { ties++; continue; }
    int32_t xi, ti;
    float a = x, b = tf;
    memcpy(&xi, &a, 4);
    memcpy(&ti, &b, 4);
    if (fabs((double)xi - (double)ti) <= 1.0) near++;
  }
  o[0] = (double)ties; o[1] = (double)near; o[2] = (double)above;
}

/* The columns of "the differences can be explained" (the nd_at_tie discipline).
 * Compares the bytes the device produced with the reference quantized half-even, and splits
 * the differing pixels into those on a rounding boundary (at_tie), within 2^-10 (near),
 * and the rest (far). **An explanation is needed only when far is not 0.**
 *   out[]: 0 nd, 1 nd_at_tie, 2 nd_near, 3 nd_far */
void sp_img_diff_where(const char *got, const double *v, const double *out,
                       size_t n) {
  const unsigned char *g = (const unsigned char *)got;
  double *o = (double *)out;
  int64_t nd = 0, at_tie = 0, nearq = 0, far = 0;
  for (size_t i = 0; i < n; i++) {
    float x = (float)v[i];
    unsigned char q = (unsigned char)quant1(0, x);
    if (g[i] == q) continue;
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

/* The same columns when the tail is threshold. What decides the byte is **the value before
 * the threshold**, so the question is whether a differing pixel sits **exactly on the threshold**, not on a rounding boundary. */
void sp_img_diff_where_thr(const char *got, const double *v, const double *pre,
                           double t, const double *out, size_t n) {
  const unsigned char *g = (const unsigned char *)got;
  double *o = (double *)out;
  int64_t nd = 0, at_tie = 0, far = 0;
  const float tf = (float)t;
  for (size_t i = 0; i < n; i++) {
    unsigned char q = (unsigned char)quant1(0, (float)v[i]);
    if (g[i] == q) continue;
    nd++;
    if ((float)pre[i] == tf) at_tie++; else far++;
  }
  o[0] = (double)nd; o[1] = (double)at_tie; o[2] = 0.0; o[3] = (double)far;
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

int64_t sp_img_hash_q(const double *v, size_t n) {
  uint64_t hh = 1469598103934665603ull;
  for (size_t i = 0; i < n; i++) {
    hh ^= (unsigned char)quant1(0, (float)v[i]);
    hh *= 1099511628211ull;
  }
  return (int64_t)(hh & 0x7fffffffffffffffull);
}

/* Writes the output as PGM. Passes the String that `to_bytes` returned as it is
 * (not being cut at a 0x00 pixel is why `:binstr` is used). */
void sp_img_write_pgm(const char *path, const char *px, int h, int w) {
  FILE *f = fopen(path, "wb");
  if (!f) { fprintf(stderr, "sp_img_write_pgm: cannot open %s\n", path); return; }
  fprintf(f, "P5\n%d %d\n255\n", w, h);
  fwrite(px, 1, (size_t)h * w, f);
  fclose(f);
}
