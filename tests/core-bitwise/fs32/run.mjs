// tests/core-bitwise/fs32/run.mjs -- instantiates the wasm32 module and prints
// one line per call, as fs/drive.c does for the 64-bit build. A trap prints
// its code and stops.
import { readFileSync } from "node:fs";
const bytes = readFileSync(process.argv[2]);
const env = {
  spinel_trap(code) { console.log(`trap ${code}`); process.exit(3); },
};
const { instance } = await WebAssembly.instantiate(bytes, { env });
const k = instance.exports;
const MIN = -2147483648, MAX = 2147483647;
const rows = [
  ["band 12 10", k.spinel_band(12, 10)],
  ["band -12 255", k.spinel_band(-12, 255)],
  ["band MIN -1", k.spinel_band(MIN, -1)],
  ["bor 12 3", k.spinel_bor(12, 3)],
  ["bor -16 5", k.spinel_bor(-16, 5)],
  ["bxor 12 10", k.spinel_bxor(12, 10)],
  ["bxor -1 5", k.spinel_bxor(-1, 5)],
  ["bxor MIN -1", k.spinel_bxor(MIN, -1)],
  ["bnot 5", k.spinel_bnot(5)],
  ["bnot MAX", k.spinel_bnot(MAX)],
  ["bnot MIN", k.spinel_bnot(MIN)],
  ["field 0xa7", k.spinel_field(0xa7)],
  ["set_clear 0x41", k.spinel_set_clear(0x41)],
  ["mask31 -1", k.spinel_mask31(-1)],
  ["op_write 0x1234", k.spinel_op_write(0x1234)],
  ["opw_shift 3", k.spinel_opw_shift(3)],
  ["opw_pow 3", k.spinel_opw_pow(3)],
];
for (const [label, v] of rows) console.log(`${label} ${v}`);
