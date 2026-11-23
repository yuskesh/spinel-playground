// Compile MLIR plus canonical schema to BPF ELF with BTF. Usage: spbpf-compile input.mlir --schema
// schema.json -o program.bpf.o. Accept SpBPF and lower internally; schema/ownership checks run by
// default, tying emitted ELF to checked declarations.
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFDialect.h"
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h"
#include "spinel-mlir/Target/SpBPF/ObjectEmitter.h"
#include "spinel-mlir/Target/SpBPF/Schema.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/OwningOpRef.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Pass/PassManager.h"

#include "llvm/Support/CommandLine.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/ToolOutputFile.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

static cl::opt<std::string> inputFile(cl::Positional, cl::desc("<input .mlir>"),
                                      cl::Required);
static cl::opt<std::string> schemaFile("schema",
                                       cl::desc("the canonical schema (JSON)"),
                                       cl::Required);
static cl::opt<std::string> outputFile("o", cl::desc("output .bpf.o"),
                                       cl::Required);
static cl::opt<std::string> licenseOpt("license", cl::init("GPL"),
                                       cl::desc("contents of the license section"));

int main(int argc, char **argv) {
  // Standard LLVM tool setup: signals, stack traces and llvm_shutdown.
  InitLLVM init(argc, argv);
  cl::ParseCommandLineOptions(argc, argv, "spbpf object compiler\n");

  // Create MLIRContext before every early-return path. Returning without creating it caused cleanup
  // double-free (terminate with InitLLVM). It reproduced immediately after command-line parsing;
  // InitLLVM changed symptoms, not the defect. Early context construction fixes it; read/check
  // schema afterward.
  mlir::DialectRegistry registry;
  registry.insert<mlir::spbpf::SpBPFDialect, mlir::func::FuncDialect,
                  mlir::arith::ArithDialect, mlir::cf::ControlFlowDialect,
                  mlir::scf::SCFDialect, mlir::LLVM::LLVMDialect>();
  mlir::MLIRContext ctx(registry);
  ctx.loadAllAvailableDialects();

  auto schemaBuf = MemoryBuffer::getFile(schemaFile);
  if (!schemaBuf) {
    errs() << "spbpf-compile: cannot read " << schemaFile << ": "
           << schemaBuf.getError().message() << "\n";
    return 1;
  }
  auto schema = spbpf::Schema::parseJSON((*schemaBuf)->getBuffer());
  if (!schema) {
    errs() << "spbpf-compile: invalid schema: "
           << toString(schema.takeError()) << "\n";
    return 1;
  }

  auto module = mlir::parseSourceFile<mlir::ModuleOp>(inputFile, &ctx);
  if (!module)
    return 1;

  mlir::PassManager pm(&ctx);
  pm.addPass(mlir::spbpf::createSpBPFVerifyOwnership());
  {
    mlir::spbpf::SpBPFVerifySchemaOptions o;
    o.schemaPath = schemaFile;
    pm.addPass(mlir::spbpf::createSpBPFVerifySchema(o));
  }
  pm.addPass(mlir::spbpf::createConvertSpBPFToLLVM());
  pm.addPass(mlir::createArithToLLVMConversionPass());
  pm.addPass(mlir::createReconcileUnrealizedCastsPass());
  if (mlir::failed(pm.run(*module)))
    return 1;

  std::error_code ec;
  ToolOutputFile out(outputFile, ec, sys::fs::OF_None);
  if (ec) {
    errs() << "spbpf-compile: cannot open " << outputFile << ": "
           << ec.message() << "\n";
    return 1;
  }

  spbpf::Diagnostics diags;
  diags.sink = [](StringRef m) { errs() << "spbpf-compile: " << m << "\n"; };
  if (mlir::failed(spbpf::emitObject(*module, *schema, out.os(), diags,
                                     licenseOpt)))
    return 1;
  out.keep();
  return 0;
}
