/* mock_cuda.c -- E471 (P013 Phase 0): a stand-in exporting the CUDA driver
 * API's REAL symbol names with fake bodies, so the gpu_host_probe plumbing
 * (uprobe fire -> keyed latency -> OTLP push) can be exercised end to end
 * without NVIDIA hardware. When the hardware exists, the probe attaches to
 * libcuda.so instead and this file stays as the deterministic harness target.
 *
 * The bodies sleep distinct amounts so the three latency series are visibly
 * different in the decoded OTLP output (launch ~200us, HtoD ~500us, DtoH
 * ~300us). noinline + used keep the symbols real under -O2. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((noinline, used)) int cuLaunchKernel(void *f) {
  usleep(200);
  return f ? 0 : 0;
}

__attribute__((noinline, used)) int cuMemcpyHtoD(void *dst) {
  usleep(500);
  return dst ? 0 : 0;
}

__attribute__((noinline, used)) int cuMemcpyDtoH(void *dst) {
  usleep(300);
  return dst ? 0 : 0;
}

int main(int argc, char **argv) {
  long n = argc > 1 ? strtol(argv[1], NULL, 10) : 20;
  int x = 0;
  for (long i = 0; i < n; i++) {
    cuMemcpyHtoD(&x);
    cuLaunchKernel(&x);
    cuMemcpyDtoH(&x);
  }
  printf("mock_cuda: %ld rounds (HtoD + LaunchKernel + DtoH each)\n", n);
  return 0;
}
