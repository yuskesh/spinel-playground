// tests/ghostty-terminal/remote-check.mjs BRIDGE WEB_DIR -- the terminal attached
// to a real shell through bridge.rb, and the bridge's refusals.
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import net from "node:net";
const require = createRequire(process.env.PLAYWRIGHT_DIR + "/");
const { chromium } = require("playwright");

const [bridgePath, webDir] = process.argv.slice(2);
let bad = 0;
const check = (name, ok, detail = "") => { if (!ok) bad++; console.log(ok ? "ok  " : "BAD ", name, detail); };

const bridge = spawn(bridgePath, [webDir, "0"], { env: { ...process.env, SHELL: "/bin/bash" }, stdio: ["ignore", "pipe", "inherit"] });
process.on("exit", () => bridge.kill());
const url = await new Promise((resolve, reject) => {
  let text = "";
  bridge.stdout.on("data", (d) => { text += d; if (text.includes("\n")) resolve(text.trim()); });
  bridge.on("exit", (c) => reject(new Error(`the bridge exited: ${c}`)));
});
const { port, searchParams } = new URL(url);
const token = searchParams.get("token");

// The first status code the bridge answers a raw HTTP request with.
const statusOf = (lines) => new Promise((resolve) => {
  const socket = net.connect(Number(port), "127.0.0.1", () => socket.write([...lines, "", ""].join("\r\n")));
  let text = "";
  socket.on("data", (d) => { text += d; if (text.includes("\r\n")) { socket.destroy(); resolve(Number(text.split(" ")[1])); } });
  socket.on("error", () => resolve(0));
});
const host = `127.0.0.1:${port}`, origin = `http://${host}`;
const upgrade = (target, h = host, o = origin) => [`GET ${target} HTTP/1.1`, `Host: ${h}`, `Origin: ${o}`, "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="];
const shellPath = `/shell?token=${token}`;

check("no token is refused", await statusOf(upgrade("/shell")) === 403);
check("a wrong token is refused", await statusOf(upgrade("/shell?token=00")) === 403);
check("another origin is refused", await statusOf(upgrade(shellPath, host, "http://example.com")) === 403);
check("no origin is refused", await statusOf(upgrade(shellPath).filter((l) => !l.startsWith("Origin"))) === 403);
check("another host is refused", await statusOf(upgrade(shellPath, "example.com", origin)) === 403);
check("a file outside the page is not served", await statusOf(["GET /../../../etc/passwd HTTP/1.1", `Host: ${host}`]) === 404);
check("a request with no request line is refused", await statusOf([""]) === 400);
check("the page is served, also after that", await statusOf(["GET / HTTP/1.1", `Host: ${host}`]) === 200);

const browser = await chromium.launch({ args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-vulkan=swiftshader", "--use-webgpu-adapter=swiftshader", "--ignore-gpu-blocklist"] });
const page = await browser.newPage({ viewport: { width: 800, height: 520 } });
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
await page.goto(`${url}&offscreen`);
const text = () => page.evaluate(() => (window.__term ? window.__term.text() : ""));
const until = async (want, ms = 15000) => {
  const start = Date.now();
  while (Date.now() - start < ms) { const t = await text(); if (want(t)) return t; await page.waitForTimeout(50); }
  return null;
};
const run = async (line) => { await page.keyboard.type(line); await page.keyboard.press("Enter"); };

await until((t) => t.length > 0);
await run("export PS1='P> '; clear");
check("the shell answers a prompt", await until((t) => t.startsWith("P>")) !== null, (await text()).slice(0, 40));
await run("echo $((6*7))");
check("a command's output reaches the screen", await until((t) => t.includes("\n42")) !== null);

await run("printf '\\033[31mred\\033[0m\\n'");
await until((t) => /\nred/.test(t));
const redRow = (await text()).split("\n").findIndex((row) => row.startsWith("red"));
const red = await page.evaluate((y) => __term.cell(0, y), redRow);
check("colour escapes from the shell are applied", red.cp === 114 && red.fg !== 0xffffff, JSON.stringify(red));

// Needs the terminal's own answer to get back to the program.
await run("printf '\\033[6n'; IFS= read -r -s -t 3 -d R r; echo \"got:${r:1}\"");
const report = await until((t) => /\ngot:/.test(t));
check("the terminal's reply reaches the program", report !== null && /\ngot:\[\d+;\d+/.test(report), report ? report.split("\n").find((l) => l.startsWith("got:")) : "");

// The handler for this query takes more than wasm-ld's default 64 KiB of stack.
await run("printf '\\033_Gi=1,a=q;\\033\\\\'; echo; echo after-kitty-query");
check("a kitty graphics query leaves the terminal running", await until((t) => t.includes("\nafter-kitty-query")) !== null);

await run("sleep 30");
await page.waitForTimeout(300);
await page.keyboard.press("Control+c");
await run("echo after-interrupt");
check("Ctrl-C interrupts the program", await until((t) => t.includes("\nafter-interrupt"), 5000) !== null);

const grid = () => page.evaluate(() => [__term.cols, __term.rows]);
const [firstCols, firstRows] = await grid();
await run("stty size");
check("the shell starts at the size of the window", await until((t) => t.includes(`\n${firstRows} ${firstCols}`)) !== null, `${firstRows} ${firstCols}`);

await page.setViewportSize({ width: 1100, height: 700 });
await page.waitForFunction((c) => __term.cols !== c, firstCols, { timeout: 5000 }).catch(() => {});
const [wideCols, wideRows] = await grid();
check("the grid follows a larger window", wideCols > firstCols && wideRows > firstRows, `${wideCols}x${wideRows}`);
await run("clear; trap 'echo winched' WINCH; stty size");
check("the shell sees the larger size", await until((t) => t.split("\n").includes(`${wideRows} ${wideCols}`)) !== null);
await run(`printf '%*s\\n' ${wideCols} X`);
const lastColumn = await until((t) => t.split("\n").some((row) => row.length === wideCols && row.endsWith("X")));
check("text reaches the new last column", lastColumn !== null);
await page.waitForTimeout(150);
const rightEdge = await page.evaluate(async (columns) => {
  const image = await __term.capture();
  let lit = 0;
  for (let y = 0; y < image.height; y++) {
    for (let x = (columns - 1) * __term.cellW; x < image.width; x++) if (image.data[(y * image.width + x) * 4 + 1] > 128) lit++;
  }
  return { lit, width: image.width, expected: columns * __term.cellW };
}, wideCols);
check("the new last column is drawn", rightEdge.lit > 0 && rightEdge.width === rightEdge.expected, JSON.stringify(rightEdge));

await run("echo armed");
await until((t) => t.includes("\narmed"));
await page.setViewportSize({ width: 800, height: 520 });
await page.waitForFunction((c) => __term.cols !== c, wideCols, { timeout: 5000 }).catch(() => {});
check("a running shell is told about the change", await until((t) => t.includes("winched")) !== null);
const [narrowCols, narrowRows] = await grid();
await run("clear; stty size");
check("the shell sees the smaller size", await until((t) => t.split("\n").includes(`${narrowRows} ${narrowCols}`)) !== null);

// Resizing replaces the page's buffers and Ruby's. The heap settles after some
// growth; a leak of the old buffers would be megabytes per resize.
const resizeRound = async () => {
  for (let i = 0; i < 40; i++) {
    await page.setViewportSize({ width: 700 + (i % 2) * 400, height: 480 + (i % 2) * 220 });
    await page.waitForTimeout(90);
  }
  return page.evaluate(() => __term.memoryBytes());
};
await resizeRound();
const memoryBefore = await resizeRound();
const memoryAfter = await resizeRound();
await page.setViewportSize({ width: 800, height: 520 });
await page.waitForFunction(([c, r]) => __term.cols === c && __term.rows === r, [narrowCols, narrowRows], { timeout: 5000 }).catch(() => {});
await run("echo settled");
check("the shell is alive after many resizes", await until((t) => t.includes("\nsettled")) !== null);
check("memory stops growing under repeated resizes", memoryBefore > 0 && memoryAfter <= memoryBefore + (8 << 20), `${memoryBefore} -> ${memoryAfter}`);

// The GPU copy happens once a frame, however many times Ruby presents.
const before = await page.evaluate(() => ({ ...__term.stats }));
await run("clear; seq 1 20000; echo copies-done");
await until((t) => t.split("\n").includes("copies-done"));
await page.waitForTimeout(200);
const after = await page.evaluate(() => ({ ...__term.stats }));
const copies = { presents: after.presents - before.presents, uploads: after.uploads - before.uploads, frames: after.frames - before.frames };
check("presents between frames share one GPU copy", copies.uploads > 0 && copies.uploads <= copies.frames && copies.uploads < copies.presents, JSON.stringify(copies));

await run("clear; seq 1 500 | sed 's/^/line-/'");
await until((t) => t.includes("line-500"));
const atBottom = await page.evaluate(() => __term.scrollPosition());
check("the history is longer than the screen", atBottom.total > 480 && atBottom.offset + atBottom.rows === atBottom.total, JSON.stringify(atBottom));
const firstVisible = async () => Number(/line-(\d+)/.exec(await text())?.[1] ?? 0);
const bottomFirst = await firstVisible();
await page.mouse.move(300, 200);
await page.mouse.wheel(0, -1000);
await page.waitForFunction((o) => __term.scrollPosition().offset < o, atBottom.offset, { timeout: 5000 }).catch(() => {});
const wheelFirst = await firstVisible();
check("the wheel shows earlier lines", wheelFirst > 0 && wheelFirst < bottomFirst, `${bottomFirst} -> ${wheelFirst}`);
await page.keyboard.press("Shift+PageUp");
await page.waitForTimeout(200);
const pagedFirst = await firstVisible();
check("Shift+PageUp moves a screen up", pagedFirst > 0 && wheelFirst - pagedFirst === narrowRows - 1, `${wheelFirst} -> ${pagedFirst}`);
check("the scroll indicator is shown", await page.evaluate(() => getComputedStyle(document.getElementById("thumb")).display) === "block");
await page.keyboard.press("Shift+Home");
await page.waitForTimeout(200);
check("Shift+Home reaches the oldest history", (await text()).includes("line-1\n"), (await text()).slice(0, 30));
await run("echo $((40+2))end");
check("typing returns to the bottom", await until((t) => t.includes("\n42end")) !== null);
const afterTyping = await page.evaluate(() => __term.scrollPosition());
check("the view is at the bottom again", afterTyping.offset + afterTyping.rows === afterTyping.total, JSON.stringify(afterTyping));

check("a second connection is refused while one is open", await statusOf(upgrade(shellPath)) === 409);

await run("exit");
await page.waitForFunction(() => document.getElementById("status").textContent.includes("exited"), null, { timeout: 15000 }).catch(() => {});
check("the page ends when the shell exits", (await page.evaluate(() => document.getElementById("status").textContent)).includes("exited"));
check("no page errors", errors.length === 0, errors.slice(0, 3).join(" | "));
await browser.close();

await new Promise((r) => setTimeout(r, 200));
check("a valid connection is accepted again (the control)", await statusOf(upgrade(shellPath)) === 101);
bridge.kill();
console.log("bad =", bad);
process.exit(bad ? 1 : 0);
