/* tools/shader/draw.c — the drawing harness of the shader lane (made a product from the research probe).
 *
 * Origin: docs/researches/r011_probes/src/p10_draw.c (the probe of the research's stages 1 to 4).
 * **Not a single line rewritten** — it was moved so that the standing gate does not depend on
 * the probe's build/ (the probe is raw experiment data, kept where it may disappear).
 *
 *   cc -O2 -std=c11 -I<wgpu>/include draw.c -o draw <wgpu>/lib/libwgpu_native.a ...
 *   cc -O2 -std=c11 -DR011_DAWN -I<dawn>/include ... (the Dawn version from the same source)
 *
 * The wgpu-native / Dawn builds live in docs/researches/r010_probes/vendor/
 * (fetched by the earlier research's run_probes.sh). Where they are missing, run_shader_gate.sh
 * returns **SKIP (exit 2)** — it does not pass silently.
 */
/*
 * Research probe harness: an off-screen renderer extended from the earlier research's p01_triangle.c.
 *
 *   ./p10_draw <shader.wgsl|.spv> <out.ppm> [--w N] [--h N] [--nv N] [--f32]
 *              [--ub <file.bin>]          the contents of the uniform buffer (group0 binding0)
 *              [--vb <file.bin>] [--stride N] [--attr "2,3"]   vertex buffer and attributes
 *              [--vs NAME] [--fs NAME]    entry names (default vs_main / fs_main)
 *              [--tex <file.rgba> --tex-w N --tex-h N]   RGBA8 texture (binding 1) and
 *                                         a nearest sampler (binding 2)
 *
 * The only differences from the earlier probe are "a uniform / vertex buffer can be passed" and the argument parsing.
 * Compiled with -DR011_DAWN it becomes the Dawn version (the difference is one include line + one devicePoll line,
 * as in the earlier probe).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "webgpu/webgpu.h"
#ifndef R011_DAWN
#include "webgpu/wgpu.h"
#endif

#define ALIGN256(x) (((x) + 255u) & ~255u)
#define MAX_ATTRS 16u   /* WebGPU's guaranteed maxVertexAttributes */

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static WGPUStringView sv(const char *s) {
  WGPUStringView v;
  v.data = s;
  v.length = WGPU_STRLEN;
  return v;
}

static void die(const char *msg) {
  fprintf(stderr, "FATAL: %s\n", msg);
  exit(1);
}

typedef struct { int done; WGPUAdapter adapter; } AdapterReq;
static void on_adapter(WGPURequestAdapterStatus st, WGPUAdapter a, WGPUStringView msg,
                       void *u1, void *u2) {
  (void)u2;
  AdapterReq *r = (AdapterReq *)u1;
  if (st != WGPURequestAdapterStatus_Success) {
    fprintf(stderr, "requestAdapter failed: %.*s\n",
            (int)(msg.length == WGPU_STRLEN ? strlen(msg.data) : msg.length), msg.data);
    exit(1);
  }
  r->adapter = a; r->done = 1;
}

typedef struct { int done; WGPUDevice device; } DeviceReq;
static void on_device(WGPURequestDeviceStatus st, WGPUDevice d, WGPUStringView msg,
                      void *u1, void *u2) {
  (void)u2;
  DeviceReq *r = (DeviceReq *)u1;
  if (st != WGPURequestDeviceStatus_Success) {
    fprintf(stderr, "requestDevice failed: %.*s\n",
            (int)(msg.length == WGPU_STRLEN ? strlen(msg.data) : msg.length), msg.data);
    exit(1);
  }
  r->device = d; r->done = 1;
}

typedef struct { int done; WGPUMapAsyncStatus st; } MapReq;
static void on_map(WGPUMapAsyncStatus st, WGPUStringView msg, void *u1, void *u2) {
  (void)msg; (void)u2;
  MapReq *r = (MapReq *)u1;
  r->st = st; r->done = 1;
}

static void on_error(WGPUDevice const *dev, WGPUErrorType type, WGPUStringView msg,
                     void *u1, void *u2) {
  (void)dev; (void)u1; (void)u2;
  size_t n = (msg.length == WGPU_STRLEN) ? strlen(msg.data) : msg.length;
  fprintf(stderr, "UNCAPTURED ERROR (type=%d): %.*s\n", (int)type, (int)n, msg.data);
  exit(2);
}

static char *read_file(const char *path, size_t *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = (char *)malloc((size_t)n + 1);
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) die("short read");
  buf[n] = 0;
  fclose(f);
  *out_len = (size_t)n;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <shader.wgsl|.spv> <out.ppm> [opts]\n", argv[0]);
    return 64;
  }
  const char *shader_path = argv[1];
  const char *out_path = argv[2];
  uint32_t W = 256, H = 256, NV = 3;
  int fmt_f32 = 0;
  /* An R32Uint mode for the coverage mask: reads the IDs back as u32 unchanged.
   * The existing modes (u8 / --f32) behave byte for byte as before — only a branch was added. */
  int fmt_r32u = 0;
  int vulkan_only = 0;   /* --vulkan-only pins wgpu's backend to Vulkan */
  const char *ub_path = NULL, *vb_path = NULL;
  const char *vs_entry = "vs_main", *fs_entry = "fs_main";
  uint32_t vb_stride = 0;
  uint32_t attr_n = 0, attr_sz[MAX_ATTRS];
  const char *tex_path = NULL;
  uint32_t tex_w = 0, tex_h = 0;
  for (int i = 3; i < argc; i++) {
    if (!strcmp(argv[i], "--w") && i + 1 < argc) W = (uint32_t)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--h") && i + 1 < argc) H = (uint32_t)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--nv") && i + 1 < argc) NV = (uint32_t)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--f32")) fmt_f32 = 1;
    else if (!strcmp(argv[i], "--r32u")) fmt_r32u = 1;
    else if (!strcmp(argv[i], "--vulkan-only")) vulkan_only = 1;
    else if (!strcmp(argv[i], "--ub") && i + 1 < argc) ub_path = argv[++i];
    else if (!strcmp(argv[i], "--vb") && i + 1 < argc) vb_path = argv[++i];
    else if (!strcmp(argv[i], "--stride") && i + 1 < argc) vb_stride = (uint32_t)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--vs") && i + 1 < argc) vs_entry = argv[++i];
    else if (!strcmp(argv[i], "--fs") && i + 1 < argc) fs_entry = argv[++i];
    else if (!strcmp(argv[i], "--attr") && i + 1 < argc) {
      char *s = argv[++i];
      for (char *p = strtok(s, ","); p; p = strtok(NULL, ",")) {
        if (attr_n == MAX_ATTRS) { fprintf(stderr, "--attr: more than %u attributes\n", MAX_ATTRS); return 64; }
        attr_sz[attr_n++] = (uint32_t)atoi(p);
      }
    }
    else if (!strcmp(argv[i], "--tex") && i + 1 < argc) tex_path = argv[++i];
    else if (!strcmp(argv[i], "--tex-w") && i + 1 < argc) tex_w = (uint32_t)atoi(argv[++i]);
    else if (!strcmp(argv[i], "--tex-h") && i + 1 < argc) tex_h = (uint32_t)atoi(argv[++i]);
    else { fprintf(stderr, "unknown option %s\n", argv[i]); return 64; }
  }
  if (fmt_f32 && fmt_r32u) { fprintf(stderr, "--f32 and --r32u cannot be given together\n"); return 64; }
  /* It can also be set from the environment — so a second device can be measured
   * without adding an argument to every call in the gate (the default is unset = as before). */
  if (getenv("SP_DRAW_VULKAN_ONLY")) vulkan_only = 1;
  WGPUTextureFormat FMT = fmt_f32   ? WGPUTextureFormat_RGBA32Float
                        : fmt_r32u  ? WGPUTextureFormat_R32Uint
                                    : WGPUTextureFormat_RGBA8Unorm;
  uint32_t BPP = fmt_f32 ? 16u : 4u;   /* R32Uint is 4 B/px too */

  const char *dot0 = strrchr(shader_path, '.');
  int want_spirv = (dot0 && strcmp(dot0, ".spv") == 0);

  double t0 = now_ms();

  WGPUInstanceDescriptor idesc;
  memset(&idesc, 0, sizeof(idesc));
#ifndef R011_DAWN
  WGPUInstanceFeatureName ifeat[1] = {WGPUInstanceFeatureName_ShaderSourceSPIRV};
  if (want_spirv) { idesc.requiredFeatureCount = 1; idesc.requiredFeatures = ifeat; }
  /* When measuring a second device (llvmpipe), wgpu **falls back to the GL backend** and picks
   * another adapter even with the ICDs narrowed (measured: it picked NVIDIA's GL 3.3 and lost the device).
   * This lets the backend be pinned to Vulkan. The default (unset) is all backends, as before. */
  WGPUInstanceExtras iextra;
  if (vulkan_only) {
    memset(&iextra, 0, sizeof(iextra));
    iextra.chain.sType = (WGPUSType)WGPUSType_InstanceExtras;
    iextra.backends = WGPUInstanceBackend_Vulkan;
    idesc.nextInChain = &iextra.chain;
  }
#else
  (void)want_spirv;
  (void)vulkan_only;   /* Dawn picks llvmpipe once the ICDs are narrowed (measured) */
#endif
  WGPUInstance instance = wgpuCreateInstance(&idesc);
  if (!instance) die("wgpuCreateInstance");

  AdapterReq areq = {0, NULL};
  WGPURequestAdapterOptions aopts;
  memset(&aopts, 0, sizeof(aopts));
  aopts.featureLevel = WGPUFeatureLevel_Core;
  aopts.powerPreference = WGPUPowerPreference_HighPerformance;
  aopts.backendType = WGPUBackendType_Undefined;
  WGPURequestAdapterCallbackInfo acb;
  memset(&acb, 0, sizeof(acb));
  acb.mode = WGPUCallbackMode_AllowProcessEvents;
  acb.callback = on_adapter;
  acb.userdata1 = &areq;
  wgpuInstanceRequestAdapter(instance, &aopts, acb);
  while (!areq.done) wgpuInstanceProcessEvents(instance);

  WGPUAdapterInfo info;
  memset(&info, 0, sizeof(info));
  if (wgpuAdapterGetInfo(areq.adapter, &info) == WGPUStatus_Success) {
    printf("adapter.device=%.*s\n", (int)info.device.length, info.device.data);
    printf("adapter.description=%.*s\n", (int)info.description.length, info.description.data);
    wgpuAdapterInfoFreeMembers(info);
  }

  DeviceReq dreq = {0, NULL};
  WGPUDeviceDescriptor ddesc;
  memset(&ddesc, 0, sizeof(ddesc));
  ddesc.label = sv("r011-device");
  ddesc.uncapturedErrorCallbackInfo.callback = on_error;
  WGPURequestDeviceCallbackInfo dcb;
  memset(&dcb, 0, sizeof(dcb));
  dcb.mode = WGPUCallbackMode_AllowProcessEvents;
  dcb.callback = on_device;
  dcb.userdata1 = &dreq;
  wgpuAdapterRequestDevice(areq.adapter, &ddesc, dcb);
  while (!dreq.done) wgpuInstanceProcessEvents(instance);
  WGPUDevice device = dreq.device;
  WGPUQueue queue = wgpuDeviceGetQueue(device);

  size_t shader_len = 0;
  char *shader_src = read_file(shader_path, &shader_len);
  WGPUShaderModuleDescriptor smdesc;
  memset(&smdesc, 0, sizeof(smdesc));
  smdesc.label = sv("r011-shader");
  const char *dot = strrchr(shader_path, '.');
  int is_spv = (dot && strcmp(dot, ".spv") == 0);
  WGPUShaderSourceWGSL wgsl;
  WGPUShaderSourceSPIRV spirv;
  if (is_spv) {
    memset(&spirv, 0, sizeof(spirv));
    spirv.chain.sType = WGPUSType_ShaderSourceSPIRV;
    spirv.codeSize = (uint32_t)(shader_len / 4);
    spirv.code = (uint32_t const *)shader_src;
    smdesc.nextInChain = (WGPUChainedStruct *)&spirv;
    printf("shader.kind=spirv words=%u\n", spirv.codeSize);
  } else {
    memset(&wgsl, 0, sizeof(wgsl));
    wgsl.chain.sType = WGPUSType_ShaderSourceWGSL;
    wgsl.code = sv(shader_src);
    smdesc.nextInChain = (WGPUChainedStruct *)&wgsl;
    printf("shader.kind=wgsl bytes=%zu\n", shader_len);
  }
  WGPUShaderModule sm = wgpuDeviceCreateShaderModule(device, &smdesc);
  if (!sm) die("createShaderModule returned NULL");

  /* ---- optional vertex buffer ---- */
  WGPUBuffer vbuf = NULL;
  WGPUVertexAttribute vattr[MAX_ATTRS];
  WGPUVertexBufferLayout vlayout;
  memset(&vlayout, 0, sizeof(vlayout));
  if (vb_path) {
    size_t n = 0;
    char *data = read_file(vb_path, &n);
    WGPUBufferDescriptor bd;
    memset(&bd, 0, sizeof(bd));
    bd.label = sv("r011-vb");
    bd.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
    bd.size = (n + 3u) & ~3u;
    vbuf = wgpuDeviceCreateBuffer(device, &bd);
    wgpuQueueWriteBuffer(queue, vbuf, 0, data, n);
    free(data);
    uint64_t off = 0;
    for (uint32_t i = 0; i < attr_n; i++) {
      memset(&vattr[i], 0, sizeof(vattr[i]));
      switch (attr_sz[i]) {
        case 1: vattr[i].format = WGPUVertexFormat_Float32; break;
        case 2: vattr[i].format = WGPUVertexFormat_Float32x2; break;
        case 3: vattr[i].format = WGPUVertexFormat_Float32x3; break;
        default: vattr[i].format = WGPUVertexFormat_Float32x4; break;
      }
      vattr[i].offset = off;
      vattr[i].shaderLocation = i;
      off += 4u * attr_sz[i];
    }
    vlayout.stepMode = WGPUVertexStepMode_Vertex;
    vlayout.arrayStride = vb_stride ? vb_stride : off;
    vlayout.attributeCount = attr_n;
    vlayout.attributes = vattr;
  }

  /* ---- optional uniform buffer ---- */
  WGPUBuffer ubuf = NULL;
  size_t ub_len = 0;
  if (ub_path) {
    char *data = read_file(ub_path, &ub_len);
    WGPUBufferDescriptor bd;
    memset(&bd, 0, sizeof(bd));
    bd.label = sv("r011-ub");
    bd.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst;
    bd.size = (ub_len + 15u) & ~15u;
    ubuf = wgpuDeviceCreateBuffer(device, &bd);
    wgpuQueueWriteBuffer(queue, ubuf, 0, data, ub_len);
    free(data);
  }

  WGPUColorTargetState color_target;
  memset(&color_target, 0, sizeof(color_target));
  color_target.format = FMT;
  color_target.writeMask = WGPUColorWriteMask_All;

  WGPUFragmentState frag;
  memset(&frag, 0, sizeof(frag));
  frag.module = sm;
  frag.entryPoint = sv(fs_entry);
  frag.targetCount = 1;
  frag.targets = &color_target;

  WGPURenderPipelineDescriptor pdesc;
  memset(&pdesc, 0, sizeof(pdesc));
  pdesc.label = sv("r011-pipeline");
  pdesc.layout = NULL; /* auto layout */
  pdesc.vertex.module = sm;
  pdesc.vertex.entryPoint = sv(vs_entry);
  if (vbuf) { pdesc.vertex.bufferCount = 1; pdesc.vertex.buffers = &vlayout; }
  pdesc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
  pdesc.primitive.stripIndexFormat = WGPUIndexFormat_Undefined;
  pdesc.primitive.frontFace = WGPUFrontFace_CCW;
  pdesc.primitive.cullMode = WGPUCullMode_None;
  pdesc.multisample.count = 1;
  pdesc.multisample.mask = 0xFFFFFFFFu;
  pdesc.fragment = &frag;
  WGPURenderPipeline pipeline = wgpuDeviceCreateRenderPipeline(device, &pdesc);
  if (!pipeline) die("createRenderPipeline returned NULL");

  /* ---- optional texture: binding 1, with a nearest sampler at binding 2 ---- */
  WGPUTextureView tex_view = NULL;
  WGPUSampler tex_sampler = NULL;
  if (tex_path) {
    size_t n = 0;
    char *data = read_file(tex_path, &n);
    if (tex_w == 0 || tex_h == 0 || n != (size_t)tex_w * tex_h * 4u) die("--tex: the file is not --tex-w x --tex-h RGBA8 texels");
    WGPUTextureDescriptor d;
    memset(&d, 0, sizeof(d));
    d.label = sv("shader-texture");
    d.usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst;
    d.dimension = WGPUTextureDimension_2D;
    d.size.width = tex_w;
    d.size.height = tex_h;
    d.size.depthOrArrayLayers = 1;
    d.format = WGPUTextureFormat_RGBA8Unorm;
    d.mipLevelCount = 1;
    d.sampleCount = 1;
    WGPUTexture tex = wgpuDeviceCreateTexture(device, &d);
    WGPUTexelCopyTextureInfo where;
    memset(&where, 0, sizeof(where));
    where.texture = tex;
    where.aspect = WGPUTextureAspect_All;
    WGPUTexelCopyBufferLayout layout;
    memset(&layout, 0, sizeof(layout));
    layout.bytesPerRow = tex_w * 4u;
    layout.rowsPerImage = tex_h;
    WGPUExtent3D size;
    size.width = tex_w; size.height = tex_h; size.depthOrArrayLayers = 1;
    wgpuQueueWriteTexture(queue, &where, data, n, &layout, &size);
    free(data);
    tex_view = wgpuTextureCreateView(tex, NULL);
    WGPUSamplerDescriptor sd;
    memset(&sd, 0, sizeof(sd));
    sd.label = sv("shader-sampler");
    sd.addressModeU = WGPUAddressMode_ClampToEdge;
    sd.addressModeV = WGPUAddressMode_ClampToEdge;
    sd.addressModeW = WGPUAddressMode_ClampToEdge;
    sd.magFilter = WGPUFilterMode_Nearest;
    sd.minFilter = WGPUFilterMode_Nearest;
    sd.mipmapFilter = WGPUMipmapFilterMode_Nearest;
    sd.lodMinClamp = 0.0f;
    sd.lodMaxClamp = 32.0f;
    sd.maxAnisotropy = 1;
    tex_sampler = wgpuDeviceCreateSampler(device, &sd);
  }

  WGPUBindGroup bg = NULL;
  if (ubuf || tex_view) {
    WGPUBindGroupLayout bgl = wgpuRenderPipelineGetBindGroupLayout(pipeline, 0);
    WGPUBindGroupEntry be[3];
    uint32_t ben = 0;
    memset(be, 0, sizeof(be));
    if (ubuf) {
      be[ben].binding = 0;
      be[ben].buffer = ubuf;
      be[ben].offset = 0;
      be[ben].size = (ub_len + 15u) & ~15u;
      ben++;
    }
    if (tex_view) {
      be[ben].binding = 1;
      be[ben].textureView = tex_view;
      ben++;
      be[ben].binding = 2;
      be[ben].sampler = tex_sampler;
      ben++;
    }
    WGPUBindGroupDescriptor bgd;
    memset(&bgd, 0, sizeof(bgd));
    bgd.layout = bgl;
    bgd.entryCount = ben;
    bgd.entries = be;
    bg = wgpuDeviceCreateBindGroup(device, &bgd);
  }

  WGPUTextureDescriptor tdesc;
  memset(&tdesc, 0, sizeof(tdesc));
  tdesc.label = sv("r011-color");
  tdesc.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc;
  tdesc.dimension = WGPUTextureDimension_2D;
  tdesc.size.width = W;
  tdesc.size.height = H;
  tdesc.size.depthOrArrayLayers = 1;
  tdesc.format = FMT;
  tdesc.mipLevelCount = 1;
  tdesc.sampleCount = 1;
  WGPUTexture color = wgpuDeviceCreateTexture(device, &tdesc);
  WGPUTextureView view = wgpuTextureCreateView(color, NULL);

  uint32_t bpr = ALIGN256(W * BPP);
  uint64_t rb_size = (uint64_t)bpr * H;
  WGPUBufferDescriptor bdesc;
  memset(&bdesc, 0, sizeof(bdesc));
  bdesc.label = sv("r011-readback");
  bdesc.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
  bdesc.size = rb_size;
  WGPUBuffer readback = wgpuDeviceCreateBuffer(device, &bdesc);

  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(device, NULL);
  WGPURenderPassColorAttachment att;
  memset(&att, 0, sizeof(att));
  att.view = view;
  att.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
  att.loadOp = WGPULoadOp_Clear;
  att.storeOp = WGPUStoreOp_Store;
  att.clearValue.r = 0.0; att.clearValue.g = 0.0;
  att.clearValue.b = 0.0; att.clearValue.a = 1.0;
  WGPURenderPassDescriptor rp;
  memset(&rp, 0, sizeof(rp));
  rp.colorAttachmentCount = 1;
  rp.colorAttachments = &att;
  WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(enc, &rp);
  wgpuRenderPassEncoderSetPipeline(pass, pipeline);
  if (bg) wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, NULL);
  if (vbuf) wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vbuf, 0, WGPU_WHOLE_SIZE);
  wgpuRenderPassEncoderDraw(pass, NV, 1, 0, 0);
  wgpuRenderPassEncoderEnd(pass);
  wgpuRenderPassEncoderRelease(pass);

  WGPUTexelCopyTextureInfo src;
  memset(&src, 0, sizeof(src));
  src.texture = color;
  src.mipLevel = 0;
  src.aspect = WGPUTextureAspect_All;
  WGPUTexelCopyBufferInfo dst;
  memset(&dst, 0, sizeof(dst));
  dst.buffer = readback;
  dst.layout.offset = 0;
  dst.layout.bytesPerRow = bpr;
  dst.layout.rowsPerImage = H;
  WGPUExtent3D ext;
  ext.width = W; ext.height = H; ext.depthOrArrayLayers = 1;
  wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &ext);

  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(queue, 1, &cmd);

  MapReq mreq = {0, 0};
  WGPUBufferMapCallbackInfo mcb;
  memset(&mcb, 0, sizeof(mcb));
  mcb.mode = WGPUCallbackMode_AllowProcessEvents;
  mcb.callback = on_map;
  mcb.userdata1 = &mreq;
  wgpuBufferMapAsync(readback, WGPUMapMode_Read, 0, (size_t)rb_size, mcb);
  while (!mreq.done) {
#ifndef R011_DAWN
    wgpuDevicePoll(device, 1, NULL);
#endif
    wgpuInstanceProcessEvents(instance);
  }
  if (mreq.st != WGPUMapAsyncStatus_Success) die("bufferMapAsync failed");
  const uint8_t *px = (const uint8_t *)wgpuBufferGetConstMappedRange(readback, 0, (size_t)rb_size);
  if (!px) die("getConstMappedRange returned NULL");

  if (!fmt_f32 && !fmt_r32u) {
    FILE *f = fopen(out_path, "wb");
    if (!f) die("cannot open output");
    fprintf(f, "P6\n%u %u\n255\n", W, H);
    for (uint32_t y = 0; y < H; y++) {
      const uint8_t *row = px + (size_t)y * bpr;
      for (uint32_t x = 0; x < W; x++) fwrite(row + x * 4, 1, 3, f);
    }
    fclose(f);
  }

  char raw_path[1024];
  /* The coverage mask is raw u32 values. It gets the extension .r32u so that it is not mistaken for another format. */
  snprintf(raw_path, sizeof(raw_path), fmt_r32u ? "%s.r32u" : "%s.rgba", out_path);
  FILE *g = fopen(raw_path, "wb");
  for (uint32_t y = 0; y < H; y++) fwrite(px + (size_t)y * bpr, 1, W * BPP, g);
  fclose(g);

  printf("size=%ux%u bytesPerRow=%u total_ms=%.2f\n", W, H, bpr, now_ms() - t0);
  printf("out=%s raw=%s\n", out_path, raw_path);

  wgpuBufferUnmap(readback);
  wgpuBufferRelease(readback);
  wgpuTextureViewRelease(view);
  wgpuTextureRelease(color);
  wgpuCommandBufferRelease(cmd);
  wgpuCommandEncoderRelease(enc);
  wgpuRenderPipelineRelease(pipeline);
  wgpuShaderModuleRelease(sm);
  wgpuQueueRelease(queue);
  wgpuDeviceRelease(device);
  wgpuAdapterRelease(areq.adapter);
  wgpuInstanceRelease(instance);
  free(shader_src);
  return 0;
}
