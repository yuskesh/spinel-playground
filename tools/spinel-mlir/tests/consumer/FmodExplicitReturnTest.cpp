// E065 source-review regression: a consumer-only synthetic AST shape. Reuse
// the checked guard's ReturnNode as the last statement in both phase tables;
// this is not a new Spinel capture or a Go-oracle comparison.
#include "spinel/Conversion/Consumer.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "mlir/IR/Verifier.h"
#include <cstdlib>
using namespace spinel::consumer;
using namespace mlir;
static void require(bool ok,const char *name) {
  if(!ok){llvm::outs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
int main(int argc,char **argv) {
  require(argc==2,"fixture argument");
  MLIRContext context;context.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto module=parseSourceFile<ModuleOp>(argv[1],&context);require(bool(module),"parse fixed facts");
  OpBuilder b(&context);unsigned changed=0;
  for(auto table:module->getOps<spinel::ir::TableOp>()) {
    llvm::DenseMap<int64_t,Operation*> nodes;
    for(auto node:table.getBody().front().getOps<spinel::ir::NodeOp>())nodes[node->getAttrOfType<IntegerAttr>("id").getInt()]=node;
    auto ref=[&](Operation *node,StringRef key){auto a=node->getAttrOfType<DictionaryAttr>("refs").getAs<IntegerAttr>(key);return a?nodes.lookup(a.getInt()):nullptr;};
    auto array=[&](Operation *node){return node->getAttrOfType<DictionaryAttr>("arrays").getAs<ArrayAttr>("body");};
    for(auto &entry:nodes) {
      auto def=entry.second;
      if(text(def,"kind")!="DefNode"||field(def,"strings","name")!="on_guard")continue;
      auto body=ref(def,"body");auto statements=array(body);Operation *ret=nullptr;
      for(auto id:statements) {
        auto n=nodes.lookup(cast<IntegerAttr>(id).getInt());
        if(text(n,"kind")!="IfNode")continue;
        auto arm=ref(n,"statements");if(!arm)continue;auto entries=array(arm);
        if(entries.size()==1){auto candidate=nodes.lookup(cast<IntegerAttr>(entries[0]).getInt());if(text(candidate,"kind")=="ReturnNode")ret=candidate;}
      }
      require(ret!=nullptr,"fixed guard return exists");
      SmallVector<Attribute> values(statements.begin(),statements.end());values.back()=ret->getAttr("id");
      NamedAttrList attrs(body->getAttrOfType<DictionaryAttr>("arrays"));attrs.set("body",b.getArrayAttr(values));body->setAttr("arrays",attrs.getDictionary(&context));++changed;
    }
  }
  require(changed==2,"matching pristine and analyzed synthetic last ReturnNode");
  Consumer c(*module);auto artifacts=c.run();require(succeeded(artifacts),"synthetic guard+explicit return consumer success");
  Operation *program=nullptr;
  for(auto p:module->getOps<ebpf::ProgramOp>())if(p.getSymName()=="on_guard")program=p;
  require(program!=nullptr,"on_guard program");auto &block=program->getRegion(0).front();auto ret=&block.back();
  require(ret->getName().getStringRef()=="ebpf.return","guard has program-level return");
  auto select=ret->getOperand(0).getDefiningOp<arith::SelectOp>();require(bool(select),"guard selects terminal values");
  auto last=select.getFalseValue().getDefiningOp<arith::TruncIOp>();require(bool(last),"explicit last return is not original-function zero");
  auto literal=last.getIn().getDefiningOp<arith::ConstantIntOp>();require(literal&&literal.value()==-1,"explicit last return keeps literal -1");
  require(succeeded(verify(*module)),"synthetic consumer output verifies");
  llvm::outs()<<"explicit-return-tail: last literal -1 preserved\n";
}
