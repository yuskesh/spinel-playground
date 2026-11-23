// The browser's side of the terminal: WebGPU, the font rasterizer and the
// keyboard. What to draw, where glyphs live and what keys mean is decided in Ruby.
import { runModule } from "./wasi_shim.mjs";

const ATLAS_SIZE = 2048, PADDING = 8, MIN_COLS = 20, MIN_ROWS = 4;
const params = new URLSearchParams(location.search);
// Icons in prompts such as Starship exist only in Nerd Fonts, so an installed one
// comes first; the symbols-only font fills in those glyphs behind any other font.
// ?font=NAME puts another installed font ahead of them.
const NERD_FONTS = ['"JetBrainsMono Nerd Font"', '"MesloLGS NF"', '"MesloLGS Nerd Font"', '"Hack Nerd Font"', '"FiraCode Nerd Font"'];
const requestedFont = (params.get("font") ?? "").replace(/["\\]/g, "");
const FONT_SIZE = 15, FONT_FAMILY = [
  ...(requestedFont ? [`"${requestedFont}"`] : []),
  ...NERD_FONTS, "ui-monospace", "Menlo", "Consolas", '"Symbols Nerd Font Mono"', "monospace",
].join(", ");
const canvas = document.getElementById("term");
const status = document.getElementById("status");

function fail(message) {
  status.textContent = message;
  throw new Error(message);
}

if (!navigator.gpu) fail("This browser has no WebGPU.");
if (typeof WebAssembly.Suspending !== "function") fail("This browser has no WebAssembly JSPI.");
const adapter = await navigator.gpu.requestAdapter();
if (!adapter) fail("No WebGPU adapter is available.");
const device = await adapter.requestDevice();
device.addEventListener("uncapturederror", (e) => console.error(e.error.message));
device.lost.then((info) => console.error(`GPU device lost: ${info.reason} ${info.message}`));

// ---- fonts ------------------------------------------------------------------
const dpr = window.devicePixelRatio || 1;
const fontFor = (style) => `${style & 2 ? "italic " : ""}${style & 1 ? "bold " : ""}${FONT_SIZE * dpr}px ${FONT_FAMILY}`;
const raster = new OffscreenCanvas(1, 1).getContext("2d", { willReadFrequently: true });
raster.font = fontFor(0);
const metrics = raster.measureText("M");
const cellW = Math.round(metrics.width), cellH = Math.round(FONT_SIZE * 1.2 * dpr);
const baseline = Math.round((cellH + metrics.fontBoundingBoxAscent - metrics.fontBoundingBoxDescent) / 2);
raster.canvas.width = cellW * 2;
raster.canvas.height = cellH;

// The grid that fits the window. ?size=COLSxROWS asks for a fixed one instead.
const fixedSize = /^(\d+)x(\d+)$/.exec(params.get("size") ?? "");
function fittedGrid() {
  if (fixedSize) return [Number(fixedSize[1]), Number(fixedSize[2])];
  return [
    Math.max(MIN_COLS, Math.floor((innerWidth - 2 * PADDING) * dpr / cellW)),
    Math.max(MIN_ROWS, Math.floor((innerHeight - 2 * PADDING) * dpr / cellH)),
  ];
}
let [askedCols, askedRows] = fittedGrid();

const atlas = device.createTexture({
  size: [ATLAS_SIZE, ATLAS_SIZE], format: "rgba8unorm",
  usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
});

// How far a glyph's ink reaches left of its origin, in whole pixels.
function leftOverhang(metrics) {
  return Math.max(0, Math.round(metrics.actualBoundingBoxLeft));
}

// Icons from Nerd Fonts can be wider than the cell their advance claims, so the
// slot is sized by the ink. Ghostty still counts such a glyph as one cell.
function glyphCells(codepoint, style) {
  raster.font = fontFor(style);
  const glyph = raster.measureText(String.fromCodePoint(codepoint));
  if (glyph.width > cellW * 1.5) return 2;
  return glyph.actualBoundingBoxRight + leftOverhang(glyph) > cellW ? 2 : 1;
}

// Rasterizes into the atlas slot Ruby chose; answers 1 for a colour glyph.
function glyphDraw(codepoint, style, x, y, width) {
  raster.font = fontFor(style);
  raster.clearRect(0, 0, cellW * 2, cellH);
  raster.fillStyle = "#fff";
  const text = String.fromCodePoint(codepoint);
  raster.fillText(text, leftOverhang(raster.measureText(text)), baseline);
  const { data } = raster.getImageData(0, 0, width, cellH);
  device.queue.writeTexture({ texture: atlas, origin: [x, y] }, data, { bytesPerRow: width * 4 }, { width, height: cellH });
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] > 32 && (data[i] < 200 || data[i + 1] < 200 || data[i + 2] < 200)) return 1;
  }
  return 0;
}

// ---- WebGPU -----------------------------------------------------------------
const format = navigator.gpu.getPreferredCanvasFormat();
// ?offscreen leaves the canvas alone: headless Chromium loses the device when a
// software adapter presents to one, and tests read frames through __term.capture.
const offscreen = params.has("offscreen");
const gpu = offscreen ? null : canvas.getContext("webgpu");
gpu?.configure({ device, format, alphaMode: "opaque" });

const STAGES = GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT;
// quad.wgsl and glyph.wgsl are generated from quad.rb and glyph.rb by tools/shader.
const quadShader = device.createShaderModule({ code: await (await fetch("quad.wgsl")).text() });
const quadGroupLayout = device.createBindGroupLayout({ entries: [{ binding: 0, visibility: STAGES, buffer: { type: "uniform" } }] });
const back = device.createRenderPipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [quadGroupLayout] }),
  vertex: {
    module: quadShader, entryPoint: "vs_main",
    buffers: [{ arrayStride: 20, attributes: [0, 1, 2, 3, 4].map((i) => ({ shaderLocation: i, offset: i * 4, format: "float32" })) }],
  },
  fragment: { module: quadShader, entryPoint: "fs_main", targets: [{ format }] },
});
const glyphShader = device.createShaderModule({ code: await (await fetch("glyph.wgsl")).text() });
const groupLayout = device.createBindGroupLayout({ entries: [
  { binding: 0, visibility: STAGES, buffer: { type: "uniform" } },
  { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: {} },
  { binding: 2, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
] });
const front = device.createRenderPipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [groupLayout] }),
  vertex: {
    module: glyphShader, entryPoint: "vs_main",
    buffers: [{ arrayStride: 36, attributes: [0, 1, 2, 3, 4, 5, 6, 7, 8].map((i) => ({ shaderLocation: i, offset: i * 4, format: "float32" })) }],
  },
  fragment: { module: glyphShader, entryPoint: "fs_main", targets: [{ format, blend: {
    color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha" },
    alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
  } }] },
});

const quadUniforms = device.createBuffer({ size: 8, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
const quadBindGroup = device.createBindGroup({ layout: quadGroupLayout, entries: [{ binding: 0, resource: { buffer: quadUniforms } }] });
const bindGroup = device.createBindGroup({
  layout: groupLayout,
  entries: [
    { binding: 0, resource: { buffer: quadUniforms } },
    { binding: 1, resource: atlas.createView() },
    { binding: 2, resource: device.createSampler({ magFilter: "nearest", minFilter: "nearest" }) },
  ],
});

let cols = 0, rows = 0, grid = new Uint32Array(0);
let quadBuffer = null, glyphBuffer = null;
const QUAD_BYTES = 3 * 6 * 20, GLYPH_BYTES = 6 * 36;
const vertexBuffer = (size) => device.createBuffer({ size, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });

// Called by Ruby: everything sized by the grid changes together, before Ruby
// fills the new cells.
function setGrid(newCols, newRows) {
  cols = newCols;
  rows = newRows;
  grid = new Uint32Array(cols * rows * 4);
  canvas.width = cols * cellW;
  canvas.height = rows * cellH;
  canvas.style.width = `${canvas.width / dpr}px`;
  canvas.style.height = `${canvas.height / dpr}px`;
  device.queue.writeBuffer(quadUniforms, 0, new Float32Array([canvas.width, canvas.height]));
  pendingUpload = null;
  quadBuffer?.destroy();
  glyphBuffer?.destroy();
  quadBuffer = vertexBuffer(cols * rows * QUAD_BYTES);
  glyphBuffer = vertexBuffer(cols * rows * GLYPH_BYTES);
}

let framePending = false;
const stats = { presents: 0, frames: 0, uploads: 0, rubyMs: 0, glyphs: 0 };

// What Ruby last presented, not yet copied to the GPU. Any number of presents
// between two frames costs one copy; Ruby only writes these buffers inside a
// present, and it is suspended whenever a frame runs.
let pendingUpload = null;

function flushUpload() {
  if (!pendingUpload) return;
  const { state, quads, quadsLen, glyphs, glyphsLen } = pendingUpload;
  pendingUpload = null;
  stats.uploads++;
  device.queue.writeBuffer(quadBuffer, 0, state.mem.buffer, quads, quadsLen);
  device.queue.writeBuffer(glyphBuffer, 0, state.mem.buffer, glyphs, glyphsLen);
}

function render(view) {
  const commands = device.createCommandEncoder();
  const pass = commands.beginRenderPass({ colorAttachments: [{ view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 1] }] });
  pass.setPipeline(back);
  pass.setBindGroup(0, quadBindGroup);
  pass.setVertexBuffer(0, quadBuffer);
  pass.draw(cols * rows * 3 * 6);
  pass.setPipeline(front);
  pass.setBindGroup(0, bindGroup);
  pass.setVertexBuffer(0, glyphBuffer);
  pass.draw(cols * rows * 6);
  pass.end();
  device.queue.submit([commands.finish()]);
}

function drawFrame() {
  framePending = false;
  stats.frames++;
  flushUpload();
  if (gpu) render(gpu.getCurrentTexture().createView());
}

// ---- the keyboard -----------------------------------------------------------
// Every event starts with its kind; Ruby's Screen reads the same numbers.
const KEY = 1, DATA = 2, RESIZE = 3, SCROLL = 4;
const events = [];
let wake = null;
let disconnected = false;
const textEncoder = new TextEncoder();

function enqueue(kind, body) {
  const item = new Uint8Array(body.length + 1);
  item[0] = kind;
  item.set(body, 1);
  events.push(item);
  if (wake) wake();
}

let shellSize = "";

// ?token=... connects to the shell behind bridge.rb; without it the shell is the one in Ruby.
const token = params.get("token");
const socket = token === null ? null : new WebSocket(`ws://${location.host}/shell?token=${encodeURIComponent(token)}&cols=${askedCols}&rows=${askedRows}`);
if (socket) {
  socket.binaryType = "arraybuffer";
  socket.onopen = () => { if (shellSize) socket.send(shellSize); };
  socket.onmessage = (e) => enqueue(DATA, new Uint8Array(e.data));
  socket.onclose = () => { disconnected = true; if (wake) wake(); };
}

canvas.addEventListener("keydown", (e) => {
  if (e.metaKey) return;
  e.preventDefault();
  const mods = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0);
  const text = [...e.key].length === 1 && !e.ctrlKey ? e.key : "";
  enqueue(KEY, textEncoder.encode(`${mods} ${e.code}\n${text}`));
});

// A resize is reported once the window has settled.
let resizeTimer = 0;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    const [c, r] = fittedGrid();
    if (c === askedCols && r === askedRows) return;
    askedCols = c;
    askedRows = r;
    enqueue(RESIZE, textEncoder.encode(`${c} ${r}`));
  }, 60);
});

// Wheel movement is turned into whole rows; the remainder waits for the next event.
let wheelPixels = 0;
window.addEventListener("wheel", (e) => {
  e.preventDefault();
  const rowHeight = cellH / dpr;
  wheelPixels += e.deltaMode === 1 ? e.deltaY * rowHeight : e.deltaMode === 2 ? e.deltaY * rows * rowHeight : e.deltaY;
  const moved = Math.trunc(wheelPixels / rowHeight);
  if (moved === 0) return;
  wheelPixels -= moved * rowHeight;
  enqueue(SCROLL, textEncoder.encode(String(moved)));
}, { passive: false });

const thumb = document.getElementById("thumb");
let scrollPosition = { total: 0, offset: 0, rows: 0 };

function showScrollPosition(total, offset, viewRows) {
  scrollPosition = { total, offset, rows: viewRows };
  thumb.style.display = total > viewRows ? "block" : "none";
  thumb.style.top = `${offset * 100 / total}%`;
  thumb.style.height = `${Math.max(viewRows * 100 / total, 3)}%`;
}

// ---- the module's imports ----------------------------------------------------
let last = { cursor: { x: 0, y: 0, visible: 0 } };
let ranAt = 0;

let moduleState = null;

function host(state) {
  moduleState = state;
  return {
    suspending: ["term_read"],
    fns: {
      remote: () => (socket ? 1 : 0),
      send(ptr, len) {
        if (socket?.readyState === WebSocket.OPEN) socket.send(new Uint8Array(state.mem.buffer, ptr, len).slice());
      },
      resize_shell(c, r) {
        shellSize = `${c} ${r}`;
        if (socket?.readyState === WebSocket.OPEN) socket.send(shellSize);
      },
      initial_cols: () => askedCols,
      initial_rows: () => askedRows,
      grid: setGrid,
      scroll_position: showScrollPosition,
      cell_width: () => cellW,
      cell_height: () => cellH,
      note_cell(index, codepoint, fg, bg, style) { grid.set([codepoint, fg, bg, style], index * 4); },
      glyph_cells: glyphCells,
      glyph_draw(...args) { stats.glyphs++; return glyphDraw(...args); },
      term_read(ptr, cap, timeout) {
        const deliver = () => {
          ranAt = performance.now();
          if (events.length === 0) return disconnected ? -1 : 0;
          const bytes = events.shift().subarray(0, cap);
          new Uint8Array(state.mem.buffer, ptr, bytes.length).set(bytes);
          return bytes.length;
        };
        return new Promise((resolve) => {
          if (events.length > 0 || disconnected) return resolve(deliver());
          const timer = timeout >= 0 ? setTimeout(() => { wake = null; resolve(deliver()); }, timeout) : null;
          wake = () => { clearTimeout(timer); wake = null; resolve(deliver()); };
        });
      },
      term_present(quads, quadsLen, glyphs, glyphsLen, x, y, visible) {
        stats.rubyMs += performance.now() - ranAt;
        stats.presents++;
        pendingUpload = { state, quads, quadsLen, glyphs, glyphsLen };
        last = { cursor: { x, y, visible } };
        if (!framePending) { framePending = true; requestAnimationFrame(drawFrame); }
      },
    },
  };
}

// What a test reads: the cells the page was last given, and a drawn frame.
window.__term = {
  get cols() { return cols; },
  get rows() { return rows; },
  cellW, cellH, dpr, stats,
  scrollPosition: () => scrollPosition,
  memoryBytes: () => moduleState.mem.buffer.byteLength,
  cursor: () => last.cursor,
  cell(x, y) {
    const o = (y * cols + x) * 4;
    return { cp: grid[o], fg: grid[o + 1], bg: grid[o + 2], flags: grid[o + 3] };
  },
  text() {
    const lines = [];
    for (let y = 0; y < rows; y++) {
      let row = "";
      for (let x = 0; x < cols; x++) row += String.fromCodePoint(this.cell(x, y).cp || 32);
      lines.push(row.trimEnd());
    }
    return lines.join("\n");
  },
  async capture() {
    flushUpload();
    const texture = device.createTexture({ size: [canvas.width, canvas.height], format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC });
    render(texture.createView());
    const bytesPerRow = Math.ceil(canvas.width * 4 / 256) * 256;
    const buffer = device.createBuffer({ size: bytesPerRow * canvas.height, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
    const copy = device.createCommandEncoder();
    copy.copyTextureToBuffer({ texture }, { buffer, bytesPerRow }, [canvas.width, canvas.height]);
    device.queue.submit([copy.finish()]);
    await buffer.mapAsync(GPUMapMode.READ);
    const mapped = new Uint8Array(buffer.getMappedRange());
    const rgba = new Uint8ClampedArray(canvas.width * canvas.height * 4);
    const bgra = format.startsWith("bgra");
    for (let y = 0; y < canvas.height; y++) {
      for (let x = 0; x < canvas.width; x++) {
        const i = y * bytesPerRow + x * 4, o = (y * canvas.width + x) * 4;
        rgba[o] = mapped[i + (bgra ? 2 : 0)]; rgba[o + 1] = mapped[i + 1]; rgba[o + 2] = mapped[i + (bgra ? 0 : 2)]; rgba[o + 3] = 255;
      }
    }
    buffer.destroy(); texture.destroy();
    return new ImageData(rgba, canvas.width, canvas.height);
  },
};

const mod = await WebAssembly.compileStreaming(fetch("shell.wasm"));
canvas.focus();
const { code, stderr } = await runModule(mod, { host });
if (stderr) console.error(stderr);
status.textContent = `[exited with status ${code}]`;
