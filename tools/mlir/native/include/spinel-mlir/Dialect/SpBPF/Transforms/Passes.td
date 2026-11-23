// SpBPF pass declarations.
#ifndef SPBPF_TRANSFORMS_PASSES
#define SPBPF_TRANSFORMS_PASSES

include "mlir/Pass/PassBase.td"

def SpBPFVerifyOwnership : Pass<"spbpf-verify-ownership", "mlir::ModuleOp"> {
  let summary = "check that every CFG path from a reserve reaches submit/discard exactly once";
  let description = [{
    The original verifier counted uses only, accepting path-dependent consumption such as submit on only one branch. Walk the control-flow graph to refuse it.
  }];
}

def ConvertSpBPFToLLVM : Pass<"convert-spbpf-to-llvm", "mlir::ModuleOp"> {
  let summary = "lower spbpf to the LLVM dialect";
  let description = [{
    Do not expose helper numbers to the frontend. The target-profile table in this pass determines helper availability by program kind and the helper numbers.
  }];
  let dependentDialects = ["::mlir::LLVM::LLVMDialect", "::mlir::cf::ControlFlowDialect"];
}

def SpBPFVerifySchema : Pass<"spbpf-verify-schema", "mlir::ModuleOp"> {
  let summary = "check the program's map bindings against the schema";
  let description = [{
    The original maps [...] check covered structure and duplicates only. This pass checks schema existence and kind/key/value agreement. Supply --schema=<path>; keep matching in the pass rather than embedding schema in the dialect.
  }];
  let options = [
    Option<"schemaPath", "schema", "std::string", /*default=*/"\"\"",
           "location of the canonical schema (JSON)">
  ];
}

#endif // SPBPF_TRANSFORMS_PASSES
