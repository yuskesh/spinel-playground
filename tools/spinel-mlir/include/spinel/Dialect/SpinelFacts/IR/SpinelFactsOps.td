#ifndef SPINEL_FACTS_OPS
#define SPINEL_FACTS_OPS
include "mlir/IR/OpBase.td"
include "mlir/IR/AttrTypeBase.td"

def SpinelFacts_Dialect : Dialect {
  let name = "spinel_facts";
  let cppNamespace = "::spinel::ir";
  let useDefaultTypePrinterParser = 1;
}
class SpinelBPF_Type<string name, string spelling>
    : TypeDef<SpinelFacts_Dialect, name> {
  let mnemonic = spelling;
  let assemblyFormat = "";
}
def SpinelBPF_IntegerType : SpinelBPF_Type<"Integer", "integer">;
def SpinelBPF_UnknownType : SpinelBPF_Type<"Unknown", "unknown">;
def SpinelBPF_VoidType : SpinelBPF_Type<"Void", "void">;
def SpinelBPF_NilType : SpinelBPF_Type<"Nil", "nil">;
def SpinelBPF_BoolType : SpinelBPF_Type<"Bool", "bool">;
class SpinelBPF_Op<string name, list<Trait> traits = []>
    : Op<SpinelFacts_Dialect, name, traits> {
  let hasVerifier = 1;
}
def SpinelBPF_SourceOp : SpinelBPF_Op<"source">;
def SpinelBPF_SpliceOp : SpinelBPF_Op<"splice">;
def SpinelBPF_TableOp : SpinelBPF_Op<"table", [SingleBlock, NoTerminator]> {
  let regions = (region AnyRegion:$body);
}
def SpinelBPF_NodeOp : SpinelBPF_Op<"node">;
def SpinelBPF_TypeOp : SpinelBPF_Op<"type">;
def SpinelBPF_EvidenceOp : SpinelBPF_Op<"evidence">;
def SpinelBPF_DiagnosticOp : SpinelBPF_Op<"diagnostic">;
#endif
