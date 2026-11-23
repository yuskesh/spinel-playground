// tools/wasm/compute_host.mjs -- the WebGPU half of a spinel-rb2comp host.
//
// The JS counterpart of tools/shader/sp_cuda_compute.c, with the same rules, so
// that one input is accepted or refused alike on both hosts. cp_open,
// cp_dispatch and cp_read wait for the GPU through JSPI. The wasm stack is
// suspended while they wait, so Ruby cannot run and cannot free or resize a
// buffer until the call returns; `busy` refuses a second call from JS.
//
// Memory is read through state.mem.buffer at call time: memory.grow during a
// suspension detaches an older view.

export const COMPUTE_SUSPENDING = ["cp_open", "cp_dispatch", "cp_read"];

const MAX_GROUPS = 65535;
const MAX_INT = 0x7fffffff;

export function makeComputeApi(state, gpu = globalThis.navigator?.gpu) {
  const s = { phase: 0, busy: false, err: "", buffers: [], n: 0, group: 1 };
  const dec = new TextDecoder();
  const u8 = () => new Uint8Array(state.mem.buffer);
  const cstr = (p) => { const m = u8(); let e = p; while (m[e]) e++; return dec.decode(m.subarray(p, e)); };
  const fail = (m) => { s.err = m; return -1; };

  const countErr = (n, what) => {
    if (n <= 0 || n > MAX_INT / 4) return `${what}: n=${n} is out of range`;
    if (n % s.group) return `${what}: n=${n} is not a multiple of the workgroup size ${s.group}`;
    if (n / s.group > MAX_GROUPS) return `${what}: ${n / s.group} workgroups is over the limit of ${MAX_GROUPS}`;
    return null;
  };
  const transferErr = (k, p, cap, what) => {
    if (s.phase !== 1) return `${what}: the unit is not open`;
    if (s.busy) return `${what}: another compute call is in progress`;
    if (k < 0 || k >= s.buffers.length) return `${what}: no buffer ${k}`;
    if (p === 0 || p % 4 || cap % 4) return `${what}: the buffer is not 4-byte aligned`;
    if (cap < s.n * 4) return `${what}: the buffer holds ${cap} bytes, ${s.n * 4} are needed`;
    return null;
  };
  // Run an async step with the reentry guard and turn any rejection into -1.
  const guarded = async (what, body) => {
    s.busy = true;
    try { await body(); return 0; }
    catch (e) { return fail(`${what}: ${e && e.message ? e.message : e}`); }
    finally { s.busy = false; }
  };

  const fns = {
    async cp_open(sourcePtr, entryPtr, buffers, workgroup, n) {
      if (s.busy) return fail("open: another compute call is in progress");
      if (s.phase === 1) return fail("open: already open");
      if (s.phase === 2) return fail("open: this process has closed its unit");
      if (buffers < 1 || buffers > 8 || workgroup < 1) return fail("open: bad layout");
      s.group = workgroup;
      const bad = countErr(n, "open");
      if (bad) return fail(bad);
      if (!gpu) return fail("open: this browser has no WebGPU");
      const code = cstr(sourcePtr), entry = cstr(entryPtr);
      const rc = await guarded("open", async () => {
        const adapter = await gpu.requestAdapter();
        if (!adapter) throw new Error("no WebGPU adapter");
        const device = await adapter.requestDevice();
        device.lost.then((info) => { s.lost = info.message || "device lost"; });
        device.pushErrorScope("validation");
        const usage = GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST;
        const made = [];
        for (let i = 0; i < buffers; i++) made.push(device.createBuffer({ size: n * 4, usage }));
        const entries = made.map((_, binding) => ({ binding, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } }));
        const layout = device.createBindGroupLayout({ entries });
        const module = device.createShaderModule({ code });
        const pipeline = device.createComputePipeline({
          layout: device.createPipelineLayout({ bindGroupLayouts: [layout] }),
          compute: { module, entryPoint: entry },
        });
        const bind = device.createBindGroup({ layout, entries: made.map((buffer, binding) => ({ binding, resource: { buffer } })) });
        const ve = await device.popErrorScope();
        if (ve) throw new Error(ve.message);
        Object.assign(s, { device, pipeline, bind, buffers: made, n });
      });
      if (rc === 0) s.phase = 1;
      return rc;
    },
    cp_write(k, p, cap) {
      const bad = transferErr(k, p, cap, "write");
      if (bad) return fail(bad);
      s.device.queue.writeBuffer(s.buffers[k], 0, state.mem.buffer, p, s.n * 4);
      return 0;
    },
    async cp_dispatch(n) {
      if (s.phase !== 1) return fail("dispatch: the unit is not open");
      if (s.busy) return fail("dispatch: another compute call is in progress");
      const bad = countErr(n, "dispatch");
      if (bad) return fail(bad);
      if (n > s.n) return fail(`dispatch: n=${n} is over the opened capacity ${s.n}`);
      return guarded("dispatch", async () => {
        if (s.lost) throw new Error(s.lost);
        s.device.pushErrorScope("validation");
        const enc = s.device.createCommandEncoder();
        const pass = enc.beginComputePass();
        pass.setPipeline(s.pipeline);
        pass.setBindGroup(0, s.bind);
        pass.dispatchWorkgroups(n / s.group);
        pass.end();
        s.device.queue.submit([enc.finish()]);
        await s.device.queue.onSubmittedWorkDone();
        const ve = await s.device.popErrorScope();
        if (ve) throw new Error(ve.message);
      });
    },
    async cp_read(k, p, cap) {
      const bad = transferErr(k, p, cap, "read");
      if (bad) return fail(bad);
      return guarded("read", async () => {
        const bytes = s.n * 4;
        const staging = s.device.createBuffer({ size: bytes, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
        const enc = s.device.createCommandEncoder();
        enc.copyBufferToBuffer(s.buffers[k], 0, staging, 0, bytes);
        s.device.queue.submit([enc.finish()]);
        await staging.mapAsync(GPUMapMode.READ);
        new Uint8Array(state.mem.buffer, p, bytes).set(new Uint8Array(staging.getMappedRange()));
        staging.unmap();
        staging.destroy();
      });
    },
    cp_close() {
      if (s.phase !== 1) return fail("close: the unit is not open");
      if (s.busy) return fail("close: another compute call is in progress");
      s.buffers.forEach((b) => b.destroy());
      s.device.destroy();
      s.buffers = [];
      s.phase = 2;
      return 0;
    },
    cp_last_error(ptr, cap) {
      const t = new TextEncoder().encode(s.err).subarray(0, Math.max(0, cap - 1));
      u8().set(t, ptr);
      u8()[ptr + t.length] = 0;
      return t.length;
    },
  };
  return { fns, suspending: COMPUTE_SUSPENDING };
}
