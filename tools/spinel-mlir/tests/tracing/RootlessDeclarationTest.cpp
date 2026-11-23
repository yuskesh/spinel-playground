#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
using namespace mlir;
using namespace spinel::consumer;
int main(int argc,char **argv) {
  if(argc!=3)return 2;
  StringRef mode=argv[2];
  if(mode!="reject"&&mode!="multiple"&&mode!="mark-only"&&mode!="unmarked-error"&&mode!="valid")return 2;
  MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto input=parseSourceFile<ModuleOp>(argv[1],&ctx);if(!input)return 2;
  if(mode=="multiple") {
    // Build the synthetic two-declaration fixture before Consumer snapshots
    // its facts. Keep both phases and metadata consistent; no product hook.
    int64_t newID=1,oldID=-1;
    for(auto table:input->getOps<spinel::ir::TableOp>())for(auto &n:table.getBody().front()) {
      auto id=n.getAttrOfType<IntegerAttr>("id");newID=std::max(newID,id.getInt()+1);
      if(text(table,"phase")=="pristine"&&text(&n,"kind")=="CallNode"&&field(&n,"strings","name")=="kernel_type"&&n.getAttrOfType<IntegerAttr>("file_id").getInt()==0)oldID=id.getInt();
    }
    if(oldID<0)return 2;
    for(auto table:input->getOps<spinel::ir::TableOp>()) {
      llvm::DenseMap<int64_t,Operation*> nodes;
      for(auto &n:table.getBody().front())nodes[n.getAttrOfType<IntegerAttr>("id").getInt()]=&n;
      auto original=nodes.lookup(oldID);if(!original)return 2;
      auto clone=original->clone();original->getBlock()->getOperations().insert(original->getIterator(),clone);
      clone->setAttr("id",IntegerAttr::get(IntegerType::get(&ctx,64),newID));
      auto root=nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
      auto ref=root->getAttrOfType<DictionaryAttr>("refs").getAs<IntegerAttr>("statements");
      auto statements=nodes.lookup(ref.getInt());
      NamedAttrList arrays(statements->getAttrOfType<DictionaryAttr>("arrays"));
      auto old=cast<ArrayAttr>(arrays.get("body"));SmallVector<Attribute> ids(old.begin(),old.end());
      ids.push_back(IntegerAttr::get(IntegerType::get(&ctx,64),newID));arrays.set("body",ArrayAttr::get(&ctx,ids));statements->setAttr("arrays",arrays.getDictionary(&ctx));
    }
    SmallVector<Operation*> metadata;
    for(auto &op:input->getBody()->getOperations())if(auto id=op.getAttrOfType<IntegerAttr>("node_id"))if(id.getInt()==oldID)metadata.push_back(&op);
    for(auto op:metadata) {
      auto clone=op->clone();op->getBlock()->getOperations().insert(op->getIterator(),clone);
      clone->setAttr("node_id",IntegerAttr::get(IntegerType::get(&ctx,64),newID));
    }
  }
  Consumer c(*input);c.useIsolatedRegistryForTesting();
  unsigned calls=0;
  c.registry.addDeclaration({"BPF","kernel_type"},[&](Consumer &running,Operation *n) {
    ++calls;
    if(mode=="valid")return Dispatch<bool>::handled(true);
    if(mode=="reject"||mode=="multiple")
      (void)running.diagnostic(n,"SB033","KernelTypeShape","rootless-control rejection");
    if(mode=="mark-only") {
      running.dependentDeclarationErrors.insert(running.id(n));
      running.blocking=true;
    }
    return Dispatch<bool>::error();
  });
  auto result=spinel::lowerWithDiagnosticGate(c);
  unsigned wanted=mode=="multiple"?2:1;
  if(succeeded(result)||calls!=wanted||!c.programs.empty()) {
    llvm::errs()<<"FAIL rootless "<<mode<<" calls="<<calls<<" expected="<<wanted<<"\n";return 1;
  }
  llvm::outs()<<"rootless "<<mode<<" calls="<<calls<<" failure/no-programs GREEN\n";
  return 0;
}
