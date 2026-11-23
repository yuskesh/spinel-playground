// E063: the import/export surface of a module, as V8 itself reports it.
//
// This is the wasm spelling of the undefined-symbol gate.  undef-check.py reads
// the OBJECT and says what it is allowed to need; this reads the LINKED MODULE
// and says what the host is actually asked for.  The two have to agree, and on
// a target where the linker synthesises symbols (__stack_pointer) the module is
// the more convincing of the two: an import section with one row in it cannot
// be argued with.
//
//   node wasm_shape.mjs a.wasm [b.wasm ...]   -> TSV on stdout
import { readFileSync } from "node:fs";
import { basename } from "node:path";

console.log(["file", "direction", "module", "name", "kind"].join("\t"));
for (const path of process.argv.slice(2)) {
  const mod = await WebAssembly.compile(readFileSync(path));
  const f = basename(path);
  for (const i of WebAssembly.Module.imports(mod)) {
    console.log([f, "import", i.module, i.name, i.kind].join("\t"));
  }
  for (const e of WebAssembly.Module.exports(mod)) {
    console.log([f, "export", "", e.name, e.kind].join("\t"));
  }
}
