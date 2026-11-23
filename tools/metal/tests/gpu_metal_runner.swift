// E456 (P013): Metal host runner for the gpu-metal spike harness.
//
//   swift gpu_metal_runner.swift <file.metal> <kernel_name> <N>
//
// Compiles the emitted MSL at RUNTIME (MTLDevice.makeLibrary(source:) — no
// offline Metal toolchain needed), fills the harness's fixed input convention
// (buffer 0 = x, buffer 1 = y, buffer 2 = out; all float32), dispatches exactly
// N threads (dispatchThreads = non-uniform threadgroups, so the kernel needs no
// bounds guard), and prints "<i> <out[i]>" per element.
//
// Input values are exact in float32 (multiples of 0.25 / 0.125 well below 2^22),
// so the only rounding difference vs the CRuby double oracle is per-operation —
// fast-math is disabled to keep IEEE ordering, and the comparator allows 1e-5
// relative error for the remaining float32-vs-double drift.
import Foundation
import Metal

let args = CommandLine.arguments
guard args.count == 4, let n = Int(args[3]), n > 0 else {
  FileHandle.standardError.write("usage: swift gpu_metal_runner.swift <file.metal> <kernel> <N>\n".data(using: .utf8)!)
  exit(2)
}
guard let src = try? String(contentsOfFile: args[1], encoding: .utf8) else {
  FileHandle.standardError.write("FAIL: cannot read \(args[1])\n".data(using: .utf8)!)
  exit(1)
}
guard let dev = MTLCreateSystemDefaultDevice() else {
  FileHandle.standardError.write("SKIP: no Metal device\n".data(using: .utf8)!)
  exit(3)
}
let opts = MTLCompileOptions()
if #available(macOS 15.0, *) { opts.mathMode = .safe }   // keep IEEE ordering close to the oracle
else { opts.fastMathEnabled = false }
let lib: MTLLibrary
do { lib = try dev.makeLibrary(source: src, options: opts) }
catch {
  FileHandle.standardError.write("FAIL: MSL compile: \(error)\n".data(using: .utf8)!)
  exit(1)
}
guard let fn = lib.makeFunction(name: args[2]) else {
  FileHandle.standardError.write("FAIL: kernel '\(args[2])' not in library (have: \(lib.functionNames))\n".data(using: .utf8)!)
  exit(1)
}
let pso = try! dev.makeComputePipelineState(function: fn)

var x = [Float](repeating: 0, count: n)
var y = [Float](repeating: 0, count: n)
for i in 0..<n {
  x[i] = Float(i % 1000) * 0.25 + 0.5      // exact in float32
  y[i] = Float((i * 7) % 997) * 0.125      // exact in float32
}
let bx = dev.makeBuffer(bytes: &x, length: n * 4)!
let by = dev.makeBuffer(bytes: &y, length: n * 4)!
let bo = dev.makeBuffer(length: n * 4)!

let q = dev.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
enc.setBuffer(bx, offset: 0, index: 0)
enc.setBuffer(by, offset: 0, index: 1)
enc.setBuffer(bo, offset: 0, index: 2)
let w = min(pso.maxTotalThreadsPerThreadgroup, 256)
enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
enc.endEncoding()
cb.commit()
cb.waitUntilCompleted()
if cb.status != .completed {
  FileHandle.standardError.write("FAIL: command buffer status \(cb.status.rawValue) \(String(describing: cb.error))\n".data(using: .utf8)!)
  exit(1)
}

let out = bo.contents().bindMemory(to: Float.self, capacity: n)
var text = ""
for i in 0..<n { text += "\(i) \(out[i])\n" }
print(text, terminator: "")
