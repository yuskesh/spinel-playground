/* tools/shader/sp_metal_compute.m -- the Metal half of a spinel-rb2comp host.
 *
 * A singleton: one unit per process, not open -> open -> closed. The checks and
 * their texts are those of tools/shader/sp_cuda_compute.c, so that one input is
 * accepted or refused alike on every host. A negative return carries its text
 * in sp_comp_last_error; the generated Ruby raises it.
 *
 * The source is naga's MSL with the bindings the generator wrote: buffer k at
 * index k, shared memory at the indices the pipeline reports. Metal does not
 * diagnose a threadgroup argument with no length set; the kernel simply computes
 * wrong values, so every one reported is given its length at each dispatch.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define SP_COMP_MAX_BUFFERS 8
#define SP_COMP_MAX_SHARED 8
#define SP_COMP_MAX_GROUPS 65535

static char err[512];
static int state; /* 0 not open, 1 open, 2 closed */
static int nbuf, group, capacity, nshared;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> pipeline;
static id<MTLBuffer> dev[SP_COMP_MAX_BUFFERS];
static NSUInteger shared_index[SP_COMP_MAX_SHARED], shared_length[SP_COMP_MAX_SHARED];

static int fail(const char *what) {
  snprintf(err, sizeof err, "%s", what);
  return -1;
}

static int fail_ns(const char *what, NSError *e) {
  snprintf(err, sizeof err, "%s: %s", what, e ? e.localizedDescription.UTF8String : "unknown Metal error");
  return -1;
}

const char *sp_comp_last_error(void) { return err; }

static int check_count(int n, const char *what) {
  if (n <= 0 || n > INT32_MAX / 4) { snprintf(err, sizeof err, "%s: n=%d is out of range", what, n); return -1; }
  if (n % group) { snprintf(err, sizeof err, "%s: n=%d is not a multiple of the workgroup size %d", what, n, group); return -1; }
  if (n / group > SP_COMP_MAX_GROUPS) { snprintf(err, sizeof err, "%s: %d workgroups is over the limit of %d", what, n / group, SP_COMP_MAX_GROUPS); return -1; }
  return 0;
}

/* The pipeline says which threadgroup arguments the kernel uses and how long they
 * are. Metal requires a length that is a multiple of 16. */
static int collect_shared(MTLComputePipelineReflection *reflection) {
  NSUInteger total = 0;
  nshared = 0;
  for (id<MTLBinding> b in reflection.bindings) {
    if (b.type != MTLBindingTypeThreadgroupMemory) continue;
    if (nshared == SP_COMP_MAX_SHARED) return fail("open: too many shared memory arguments");
    NSUInteger bytes = ((id<MTLThreadgroupBinding>)b).threadgroupMemoryDataSize;
    NSUInteger length = (bytes + 15) & ~(NSUInteger)15;
    shared_index[nshared] = b.index;
    shared_length[nshared] = length;
    nshared++;
    total += length;
  }
  if (total > device.maxThreadgroupMemoryLength) {
    snprintf(err, sizeof err, "open: shared memory of %lu bytes is over this device's limit of %lu",
             (unsigned long)total, (unsigned long)device.maxThreadgroupMemoryLength);
    return -1;
  }
  return 0;
}

int sp_comp_open(const char *source, const char *entry, int buffers, int workgroup, int n) {
  if (state == 1) return fail("open: already open");
  if (state == 2) return fail("open: this process has closed its unit");
  if (buffers < 1 || buffers > SP_COMP_MAX_BUFFERS || workgroup < 1) return fail("open: bad layout");
  group = workgroup;
  if (check_count(n, "open")) return -1;
  @autoreleasepool {
    device = MTLCreateSystemDefaultDevice();
    if (device == nil) return fail("open: no Metal device");
    queue = [device newCommandQueue];
    if (queue == nil) return fail("open: no command queue");
    MTLCompileOptions *options = [MTLCompileOptions new];
    if (@available(macOS 15.0, *)) options.mathMode = MTLMathModeSafe;
    else options.fastMathEnabled = NO;
    NSError *e = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:source] options:options error:&e];
    if (library == nil) return fail_ns("newLibraryWithSource", e);
    id<MTLFunction> function = [library newFunctionWithName:[NSString stringWithUTF8String:entry]];
    if (function == nil) { snprintf(err, sizeof err, "open: no function %s in the library", entry); return -1; }
    MTLComputePipelineReflection *reflection = nil;
    pipeline = [device newComputePipelineStateWithFunction:function options:MTLPipelineOptionBindingInfo reflection:&reflection error:&e];
    if (pipeline == nil) return fail_ns("newComputePipelineState", e);
    if ((NSUInteger)workgroup > pipeline.maxTotalThreadsPerThreadgroup) {
      snprintf(err, sizeof err, "open: workgroup size %d is over this kernel's limit of %lu on this device",
               workgroup, (unsigned long)pipeline.maxTotalThreadsPerThreadgroup);
      return -1;
    }
    if (collect_shared(reflection)) return -1;
    for (int i = 0; i < buffers; i++) {
      dev[i] = [device newBufferWithLength:(NSUInteger)n * 4 options:MTLResourceStorageModeShared];
      if (dev[i] == nil) return fail("open: buffer allocation failed");
      memset(dev[i].contents, 0, (size_t)n * 4);
    }
  }
  nbuf = buffers;
  capacity = n;
  state = 1;
  return 0;
}

static int check_transfer(int k, const void *buf, int cap, const char *what) {
  if (state != 1) { snprintf(err, sizeof err, "%s: the unit is not open", what); return -1; }
  if (k < 0 || k >= nbuf) { snprintf(err, sizeof err, "%s: no buffer %d", what, k); return -1; }
  if (buf == NULL || (uintptr_t)buf % 4 || cap % 4) { snprintf(err, sizeof err, "%s: the buffer is not 4-byte aligned", what); return -1; }
  if (cap < capacity * 4) { snprintf(err, sizeof err, "%s: the buffer holds %d bytes, %d are needed", what, cap, capacity * 4); return -1; }
  return 0;
}

int sp_comp_write(int k, const void *buf, int cap) {
  if (check_transfer(k, buf, cap, "write")) return -1;
  memcpy(dev[k].contents, buf, (size_t)capacity * 4);
  return 0;
}

int sp_comp_read(int k, void *buf, int cap) {
  if (check_transfer(k, buf, cap, "read")) return -1;
  memcpy(buf, dev[k].contents, (size_t)capacity * 4);
  return 0;
}

int sp_comp_dispatch(int n) {
  if (state != 1) return fail("dispatch: the unit is not open");
  if (check_count(n, "dispatch")) return -1;
  if (n > capacity) { snprintf(err, sizeof err, "dispatch: n=%d is over the opened capacity %d", n, capacity); return -1; }
  @autoreleasepool {
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
    if (encoder == nil) return fail("dispatch: no compute encoder");
    [encoder setComputePipelineState:pipeline];
    for (int i = 0; i < nbuf; i++) [encoder setBuffer:dev[i] offset:0 atIndex:(NSUInteger)i];
    for (int i = 0; i < nshared; i++) [encoder setThreadgroupMemoryLength:shared_length[i] atIndex:shared_index[i]];
    [encoder dispatchThreadgroups:MTLSizeMake((NSUInteger)(n / group), 1, 1)
            threadsPerThreadgroup:MTLSizeMake((NSUInteger)group, 1, 1)];
    [encoder endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    if (commands.status != MTLCommandBufferStatusCompleted) return fail_ns("dispatch", commands.error);
  }
  return 0;
}

int sp_comp_close(void) {
  if (state != 1) return fail("close: the unit is not open");
  for (int i = 0; i < nbuf; i++) dev[i] = nil;
  pipeline = nil;
  queue = nil;
  device = nil;
  state = 2;
  return 0;
}
