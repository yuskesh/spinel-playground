// E063: drive the workerd probe over HTTP with E040's differential table.
//
//   node worker_probe.mjs http://127.0.0.1:8791 cases.json node.tsv
//
// The point is not that HTTP works.  It is that the SAME 31 cases that the
// host (native C back end), the Cortex-M33, the RV32 and node all answered come
// back unchanged through workerd -- so "it runs on Workers" is the same claim
// as "it runs", not a separate, weaker one.
//
// A trap arrives as a 422 whose body starts `trap code=<n>`; it is normalised
// to node.tsv's `trap:code=<n>` spelling so the two files can be compared
// literally.  Everything else (a 500, a 404, a wasm trap that bypassed the
// hook) is left in its raw form so that it can never accidentally match.
import { readFileSync } from "node:fs";

const [base, casesPath, nodePath] = process.argv.slice(2);
const cases = JSON.parse(readFileSync(casesPath, "utf8"));
const expected = new Map(
  readFileSync(nodePath, "utf8").split("\n").slice(1).filter(Boolean)
    .map((l) => l.split("\t")).map(([c, r]) => [c, r]));

const rows = [];
let fail = 0;
for (const c of cases) {
  const short = c.export.replace(/^spinel_/, "");
  const q = c.args.map((a, i) => `${"abcd"[i]}=${encodeURIComponent(a)}`).join("&");
  const res = await fetch(`${base}/${short}${q ? "?" + q : ""}`);
  const body = (await res.text()).trim();
  let got;
  if (res.status === 200) got = body;
  else if (res.status === 422 && body.startsWith("trap code="))
    got = "trap:code=" + body.slice("trap code=".length).split(" ")[0];
  else got = `http${res.status}:${body}`;
  const want = expected.get(c.case) ?? "(no node row)";
  const verdict = got === want ? "PASS" : "FAIL";
  if (verdict === "FAIL") fail++;
  rows.push([c.case, String(res.status), got, want, verdict]);
}

// The isolate must survive a fault: one bad request may not take the worker
// with it.  This is the wasm/Workers counterpart of E040's k_panic() row, and
// the answers are opposite ON PURPOSE -- see the Edoc's s6.
const after = await fetch(`${base}/add?a=20&b=22`);
rows.push(["(after a trap) add(20,22)", String(after.status),
           (await after.text()).trim(), "42",
           after.status === 200 ? "PASS" : "FAIL"]);

console.log(["case", "status", "workerd", "expected(node)", "verdict"].join("\t"));
for (const r of rows) console.log(r.join("\t"));
process.exitCode = fail ? 1 : 0;
