/* E457 (P013): Metal bridge shim — plain-C exports over the Objective-C Metal
 * API, so the spinel-compiled native side can drive the GPU through the FFI DSL
 * (same convention as the o11y backend's nghttp2/mbedTLS shims: the shim owns
 * the object-model idioms, the exported surface is C by value).
 *
 * The buffer model mirrors the gpu-metal codegen's contract: one buffer per
 * declared slot, element type from the gpu_buffer declaration ('f' = float32,
 * 'l' = int64, E459). Float slots cross the FFI as double; int slots have
 * their own :long lane (a double would corrupt values above 2^53).
 *
 * Every failure path prints WHY to stderr and returns nonzero — the Ruby side
 * treats a nonzero init/dispatch as fatal (ADR-003: loud, never silent).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

#define OGPU_MAX_BUFS 8

static id<MTLDevice>       g_dev;
static id<MTLCommandQueue> g_queue;
static id<MTLLibrary>      g_lib;
static id<MTLBuffer>       g_bufs[OGPU_MAX_BUFS];
static int                 g_is_int[OGPU_MAX_BUFS];   /* E459: 'l' slots (int64) */
static int                 g_is_atomic[OGPU_MAX_BUFS];   /* E469: 'a' slots (atomic int32) */
static long                g_nbufs;
static long                g_n;

/* Compile the .metal source at runtime and allocate one buffer per spec char:
 * 'f' = float32 (4B/elem), 'l' = int64 (8B/elem), 'a' = atomic int32 (4B/elem,
 * rides the integer FFI lane; values are 32-bit on the GPU side, so the host
 * must keep them below 2^31). The spec string is BAKED by
 * the generated host binding from the gpu_buffer declarations -- by hand you
 * could pass the wrong one, through the binding you cannot. Returns 0 on
 * success. */
int ogpu_init(const char *metal_path, const char *spec, long n) {
  long nbufs = spec ? (long)strlen(spec) : 0;
  if (nbufs < 1 || nbufs > OGPU_MAX_BUFS || n < 1) {
    fprintf(stderr, "ogpu_init: bad spec='%s' n=%ld\n", spec ? spec : "(null)", n);
    return 1;
  }
  for (long i = 0; i < nbufs; i++) {
    if (spec[i] != 'f' && spec[i] != 'l' && spec[i] != 'a') {
      fprintf(stderr, "ogpu_init: bad spec char '%c' (want f=float32, l=int64 or a=atomic int32)\n", spec[i]);
      return 1;
    }
    g_is_int[i] = (spec[i] == 'l');
    g_is_atomic[i] = (spec[i] == 'a');
  }
  g_dev = MTLCreateSystemDefaultDevice();
  if (!g_dev) { fprintf(stderr, "ogpu_init: no Metal device\n"); return 2; }
  g_queue = [g_dev newCommandQueue];

  NSError *err = nil;
  NSString *src = [NSString stringWithContentsOfFile:@(metal_path)
                                            encoding:NSUTF8StringEncoding
                                               error:&err];
  if (!src) {
    fprintf(stderr, "ogpu_init: cannot read %s: %s\n", metal_path,
            err.localizedDescription.UTF8String);
    return 3;
  }
  MTLCompileOptions *opts = [MTLCompileOptions new];
  if (@available(macOS 15.0, *)) opts.mathMode = MTLMathModeSafe;   /* IEEE ordering, matches the E456 harness */
  g_lib = [g_dev newLibraryWithSource:src options:opts error:&err];
  if (!g_lib) {
    fprintf(stderr, "ogpu_init: MSL compile failed: %s\n",
            err.localizedDescription.UTF8String);
    return 4;
  }
  g_nbufs = nbufs;
  g_n = n;
  for (long i = 0; i < nbufs; i++) {
    g_bufs[i] = [g_dev newBufferWithLength:(NSUInteger)(n * (g_is_int[i] ? 8 : 4))   /* atomic = 4B */
                                   options:MTLResourceStorageModeShared];
    if (!g_bufs[i]) { fprintf(stderr, "ogpu_init: buffer %ld alloc failed\n", i); return 5; }
  }
  return 0;
}

/* float32 path. The type guards are backstops -- the generated binding only
 * emits the matching call, but a hand-written caller is told, loudly. */
void ogpu_write(long slot, long i, double v) {
  if (slot < 0 || slot >= g_nbufs || i < 0 || i >= g_n) return;
  if (g_is_int[slot]) { fprintf(stderr, "ogpu_write: slot %ld is int64 -- use ogpu_write_i\n", slot); return; }
  ((float *)g_bufs[slot].contents)[i] = (float)v;
}

double ogpu_read(long slot, long i) {
  if (slot < 0 || slot >= g_nbufs || i < 0 || i >= g_n) return 0.0;
  if (g_is_int[slot]) { fprintf(stderr, "ogpu_read: slot %ld is int64 -- use ogpu_read_i\n", slot); return 0.0; }
  return (double)((float *)g_bufs[slot].contents)[i];
}

/* E459: int64 path -- values above 2^53 do not survive a double, so :int
 * buffers get their own :long-typed FFI lane. */
void ogpu_write_i(long slot, long i, long v) {
  if (slot < 0 || slot >= g_nbufs || i < 0 || i >= g_n) return;
  if (g_is_atomic[slot]) {   /* E469: 32-bit cells */
    ((int *)g_bufs[slot].contents)[i] = (int)v;
    return;
  }
  if (!g_is_int[slot]) { fprintf(stderr, "ogpu_write_i: slot %ld is float32 -- use ogpu_write\n", slot); return; }
  ((long long *)g_bufs[slot].contents)[i] = (long long)v;
}

long ogpu_read_i(long slot, long i) {
  if (slot < 0 || slot >= g_nbufs || i < 0 || i >= g_n) return 0;
  if (g_is_atomic[slot])   /* E469: 32-bit cells */
    return (long)((int *)g_bufs[slot].contents)[i];
  if (!g_is_int[slot]) { fprintf(stderr, "ogpu_read_i: slot %ld is float32 -- use ogpu_read\n", slot); return 0; }
  return (long)((long long *)g_bufs[slot].contents)[i];
}

/* Dispatch <kernel> over exactly n threads (non-uniform threadgroups, so the
 * generated kernel needs no bounds guard — same contract as the E456 runner).
 * Buffers 0..nbufs-1 are bound at the same indices. Returns 0 on success. */
int ogpu_dispatch(const char *kernel, long n) {
  if (!g_lib) { fprintf(stderr, "ogpu_dispatch: ogpu_init first\n"); return 1; }
  if (n < 1 || n > g_n) { fprintf(stderr, "ogpu_dispatch: bad n=%ld (buffers hold %ld)\n", n, g_n); return 1; }
  id<MTLFunction> fn = [g_lib newFunctionWithName:@(kernel)];
  if (!fn) {
    fprintf(stderr, "ogpu_dispatch: kernel '%s' not in library\n", kernel);
    return 2;
  }
  NSError *err = nil;
  id<MTLComputePipelineState> pso = [g_dev newComputePipelineStateWithFunction:fn error:&err];
  if (!pso) {
    fprintf(stderr, "ogpu_dispatch: pipeline: %s\n", err.localizedDescription.UTF8String);
    return 3;
  }
  id<MTLCommandBuffer> cb = [g_queue commandBuffer];
  id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
  [enc setComputePipelineState:pso];
  for (long i = 0; i < g_nbufs; i++)
    [enc setBuffer:g_bufs[i] offset:0 atIndex:(NSUInteger)i];
  NSUInteger w = pso.maxTotalThreadsPerThreadgroup;
  if (w > 256) w = 256;
  [enc dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(w, 1, 1)];
  [enc endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  if (cb.status != MTLCommandBufferStatusCompleted) {
    fprintf(stderr, "ogpu_dispatch: command buffer status %ld: %s\n",
            (long)cb.status, cb.error.localizedDescription.UTF8String);
    return 4;
  }
  return 0;
}
