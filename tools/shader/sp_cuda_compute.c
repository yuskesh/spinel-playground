/* tools/shader/sp_cuda_compute.c -- the CUDA half of a spinel-rb2comp host.
 *
 * A singleton: one unit per process, not open -> open -> closed. Every check
 * here has the same rule in tools/wasm/compute_host.mjs, so that one input is
 * accepted or refused alike on both hosts. A negative return carries its text
 * in sp_comp_last_error; the generated Ruby raises it.
 *
 * The kernel's entry takes the expanded memref of LLVM's calling convention:
 * five arguments per buffer (allocated, aligned, offset, size, stride).
 * Decision 0031 records why the bare-pointer convention is not used.
 */
#include <cuda.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define SP_COMP_MAX_BUFFERS 8
#define SP_COMP_MAX_GROUPS 65535

static char err[512];
static int state; /* 0 not open, 1 open, 2 closed */
static int nbuf, group, capacity;
static CUcontext ctx;
static CUmodule mod;
static CUfunction fn;
static CUdeviceptr dev[SP_COMP_MAX_BUFFERS];

static int fail(const char *what) {
  snprintf(err, sizeof err, "%s", what);
  return -1;
}

static int check_cu(CUresult r, const char *what) {
  if (r == CUDA_SUCCESS) return 0;
  const char *m = "unknown CUDA error";
  cuGetErrorString(r, &m);
  snprintf(err, sizeof err, "%s: %s", what, m);
  return -1;
}

#define CU(call, what) do { if (check_cu((call), (what))) return -1; } while (0)

const char *sp_comp_last_error(void) { return err; }

static int check_count(int n, const char *what) {
  if (n <= 0 || n > INT32_MAX / 4) { snprintf(err, sizeof err, "%s: n=%d is out of range", what, n); return -1; }
  if (n % group) { snprintf(err, sizeof err, "%s: n=%d is not a multiple of the workgroup size %d", what, n, group); return -1; }
  if (n / group > SP_COMP_MAX_GROUPS) { snprintf(err, sizeof err, "%s: %d workgroups is over the limit of %d", what, n / group, SP_COMP_MAX_GROUPS); return -1; }
  return 0;
}

int sp_comp_open(const char *source, const char *entry, int buffers, int workgroup, int n) {
  if (state == 1) return fail("open: already open");
  if (state == 2) return fail("open: this process has closed its unit");
  if (buffers < 1 || buffers > SP_COMP_MAX_BUFFERS || workgroup < 1) return fail("open: bad layout");
  group = workgroup;
  if (check_count(n, "open")) return -1;
  CU(cuInit(0), "cuInit");
  CUdevice d;
  CU(cuDeviceGet(&d, 0), "cuDeviceGet");
  CU(cuCtxCreate(&ctx, NULL, 0, d), "cuCtxCreate");
  CU(cuModuleLoadData(&mod, source), "cuModuleLoadData");
  CU(cuModuleGetFunction(&fn, mod, entry), "cuModuleGetFunction");
  for (int i = 0; i < buffers; i++) {
    CU(cuMemAlloc(&dev[i], (size_t)n * 4), "cuMemAlloc");
    CU(cuMemsetD32(dev[i], 0, (size_t)n), "cuMemsetD32");
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
  CU(cuMemcpyHtoD(dev[k], buf, (size_t)capacity * 4), "cuMemcpyHtoD");
  return 0;
}

int sp_comp_read(int k, void *buf, int cap) {
  if (check_transfer(k, buf, cap, "read")) return -1;
  CU(cuMemcpyDtoH(buf, dev[k], (size_t)capacity * 4), "cuMemcpyDtoH");
  return 0;
}

int sp_comp_dispatch(int n) {
  if (state != 1) return fail("dispatch: the unit is not open");
  if (check_count(n, "dispatch")) return -1;
  if (n > capacity) { snprintf(err, sizeof err, "dispatch: n=%d is over the opened capacity %d", n, capacity); return -1; }
  void *args[SP_COMP_MAX_BUFFERS * 5];
  long long offset = 0, stride = 1, size = capacity;
  for (int i = 0; i < nbuf; i++) {
    args[5 * i] = &dev[i];
    args[5 * i + 1] = &dev[i];
    args[5 * i + 2] = &offset;
    args[5 * i + 3] = &size;
    args[5 * i + 4] = &stride;
  }
  CU(cuLaunchKernel(fn, (unsigned)(n / group), 1, 1, (unsigned)group, 1, 1, 0, NULL, args, NULL), "cuLaunchKernel");
  CU(cuStreamSynchronize(NULL), "cuStreamSynchronize");
  return 0;
}

int sp_comp_close(void) {
  if (state != 1) return fail("close: the unit is not open");
  for (int i = 0; i < nbuf; i++) CU(cuMemFree(dev[i]), "cuMemFree");
  CU(cuModuleUnload(mod), "cuModuleUnload");
  CU(cuCtxDestroy(ctx), "cuCtxDestroy");
  state = 2;
  return 0;
}
