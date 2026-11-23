/* tools/shader/draw_metal.m — the drawing harness of the MSL lane (Metal directly), made a product from an experiment probe.
 *
 * Origin: docs/experiments/results/E085/src/metal_run.m (that experiment's probe).
 * It was moved so that the standing gate does not depend on the probe's build/
 * (handled like draw.c). **One change only**: `SP_SHADER_REPS` lets the render pass
 * repeat (fixed costs dominated, so the difference between contraction regimes could not be measured).
 *
 *   clang -O2 -fobjc-arc -framework Metal -framework Foundation draw_metal.m -o draw_metal
 *
 * The three regimes of the shader precision contract are made from this harness's `mode` and a pragma in the generated MSL:
 *   :fused     mode=default (default mathMode=Fast)
 *   :frontend  mode=safe    (mathMode=Safe -- pins where contraction happens to the front end, but
 *                            **FMA does not stop**; found by that experiment)
 *   :separate  writes `#pragma STDC FP_CONTRACT OFF` at the top of the generated MSL
 *              (**the pragma way is the authoritative one** -- the generator governs it without depending on
 *              the application's MTLCompileOptions. The pragma overrides even mathMode=Fast)
 */
/* A drawing harness for the Metal-direct lane (off-screen).
 *
 *   metal_run <shader.metal|.metallib> <mode> <fmt> <out.rgba> [W H]
 *
 *   mode: default | safe | relaxed | fast   (MTLCompileOptions.mathMode)
 *         lib                                (reads a .metallib as it is)
 *   fmt:  u8  (RGBA8Unorm)  | f32 (RGBA32Float)
 *
 * No MTKView. Draws with one render pass into a shared-storage MTLTexture
 * (vs_main / fs_main, a fullscreen triangle of 3 vertices) and writes out the raw bytes.
 * Every failure exits non-zero + stderr (look at the exit code).
 * Prints the measurement conditions (device name / OS) to stderr so they stay with the results.
 */
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(NSString *msg) {
  fprintf(stderr, "FATAL: %s\n", msg.UTF8String);
  exit(1);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 5) {
      fprintf(stderr, "usage: metal_run <shader.metal|.metallib> <default|safe|relaxed|fast|lib> <u8|f32> <out.rgba> [W H]\n");
      return 2;
    }
    NSString *path = [NSString stringWithUTF8String:argv[1]];
    NSString *mode = [NSString stringWithUTF8String:argv[2]];
    NSString *fmt  = [NSString stringWithUTF8String:argv[3]];
    const char *outPath = argv[4];
    NSUInteger W = argc > 5 ? (NSUInteger)atoi(argv[5]) : 256;
    NSUInteger H = argc > 6 ? (NSUInteger)atoi(argv[6]) : 256;

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) die(@"no Metal device");
    fprintf(stderr, "# device=%s\n", dev.name.UTF8String);

    NSError *err = nil;
    id<MTLLibrary> lib = nil;
    if ([mode isEqualToString:@"lib"]) {
      lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
      if (!lib) die([NSString stringWithFormat:@"newLibraryWithURL: %@", err]);
    } else {
      NSString *src = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding error:&err];
      if (!src) die([NSString stringWithFormat:@"read %@: %@", path, err]);
      MTLCompileOptions *opts = [MTLCompileOptions new];
      if ([mode isEqualToString:@"default"]) {
        /* Leaves mathMode alone = observes MTLCompileOptions' default */
        fprintf(stderr, "# mathMode(untouched default)=%ld\n", (long)opts.mathMode);
      } else if ([mode isEqualToString:@"safe"])    { opts.mathMode = MTLMathModeSafe; }
        else if ([mode isEqualToString:@"relaxed"]) { opts.mathMode = MTLMathModeRelaxed; }
        else if ([mode isEqualToString:@"fast"])    { opts.mathMode = MTLMathModeFast; }
        else die(@"bad mode");
      lib = [dev newLibraryWithSource:src options:opts error:&err];
      if (!lib) die([NSString stringWithFormat:@"compile: %@", err]);
      if (err) fprintf(stderr, "# compile warnings: %s\n", err.description.UTF8String);
    }

    id<MTLFunction> vs = [lib newFunctionWithName:@"vs_main"];
    id<MTLFunction> fs = [lib newFunctionWithName:@"fs_main"];
    if (!vs || !fs) die(@"vs_main/fs_main not found");

    BOOL isF32 = [fmt isEqualToString:@"f32"];
    MTLPixelFormat pf = isF32 ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA8Unorm;
    NSUInteger bpp = isF32 ? 16 : 4;

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = vs;
    pd.fragmentFunction = fs;
    pd.colorAttachments[0].pixelFormat = pf;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) die([NSString stringWithFormat:@"pipeline: %@", err]);

    MTLTextureDescriptor *td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared; /* Apple Silicon: getBytes can read it directly */
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    if (!tex) die(@"texture");

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandQueue> q = [dev newCommandQueue];

    /* ★ Added later (the only change from the experiment's probe).
     * SP_SHADER_REPS=N repeats the render pass N times.
     * Why: with a single pass, device initialization + runtime compilation + readback (~70 ms)
     * dominate, and **the difference between contraction regimes (~0.2 ms at 2048^2) cannot be measured**. In fact
     * hyperfine showed :frontend faster than :fused = the noise floor exceeded
     * the effect. Repeating makes the GPU's work dominate.
     * The default is 1, so the gate's behaviour (the correctness check) does not change. */
    long reps = 1;
    { const char *e = getenv("SP_SHADER_REPS");
      if (e && *e) { long v = atol(e); if (v > 0) reps = v; } }

    id<MTLCommandBuffer> cb = nil;
    for (long it = 0; it < reps; it++) {
      cb = [q commandBuffer];
      id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
      [enc setRenderPipelineState:pso];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [enc endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      if (cb.status != MTLCommandBufferStatusCompleted || cb.error)
        die([NSString stringWithFormat:@"command buffer status=%ld error=%@",
             (long)cb.status, cb.error]);
    }

    size_t sz = W * H * bpp;
    void *buf = malloc(sz);
    if (!buf) die(@"malloc");
    [tex getBytes:buf bytesPerRow:W * bpp fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];

    FILE *f = fopen(outPath, "wb");
    if (!f) { perror(outPath); return 1; }
    if (fwrite(buf, 1, sz, f) != sz) { perror("fwrite"); return 1; }
    fclose(f);
    free(buf);
    return 0;
  }
}
