#include "spinel/Conversion/LoopFacts.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel::consumer;
static void require(bool ok,const char *name) {
  if(!ok){llvm::errs()<<"FAIL "<<name<<"\n";std::exit(1);}
}
static void replaceName(Operation *node,StringRef key,StringRef value) {
  NamedAttrList strings(node->getAttrOfType<DictionaryAttr>("strings"));
  strings.set(key,StringAttr::get(node->getContext(),value));
  node->setAttr("strings",strings.getDictionary(node->getContext()));
}
int main(int argc,char **argv) {
  require(argc==2 || argc==3,"facts-path");
  MLIRContext ctx;
  ctx.loadDialect<spinel::ir::SpinelFactsDialect,ebpf::EBPFDialect,arith::ArithDialect>();
  auto module=parseSourceFile<ModuleOp>(argv[1],&ctx);
  require(bool(module),"parse");
  Consumer c(*module);
  unsigned loopCount=0,reads=0,renamed=0,unchanged=0;
  std::map<std::string,std::string> expected{
    {"i","i__bp2148"},{"k","k__bp2163"},{"j","j"}};
  std::map<std::string,loops::Syntax> shapes;
  Operation *jRead=nullptr;
  for(auto &item:c.nodes) {
    auto node=item.second;
    if(!loops::isIterator(c,node))continue;
    auto loc=dyn_cast<FileLineColLoc>(node->getLoc());
    if(!loc || !loc.getFilename().getValue().ends_with("loop_times.rb"))continue;
    auto shape=loops::inspect(c,node,0);
    require(succeeded(shape),"loop-shape");
    require(shape->parameter && shape->analyzedParameter,"explicit-parameter");
    require(expected.count(shape->sourceName) &&
            expected.at(shape->sourceName)==shape->analyzedName,"explicit-binding");
    if(shape->sourceName==shape->analyzedName)++unchanged;else ++renamed;
    require(text(c.types[c.id(shape->block)].front(),"kind")=="unknown","unknown-block-preserved");
    for(auto &candidate:c.nodes) {
      auto read=candidate.second;
      if(text(read,"kind")!="LocalVariableReadNode" ||
         field(read,"strings","name")!=shape->sourceName)continue;
      require(succeeded(loops::knownBoundRead(c,read,*shape)),"bound-read");
      if(shape->sourceName=="j")jRead=read;
      ++reads;
    }
    shapes.emplace(shape->sourceName,*shape);
    ++loopCount;
  }
  require(loopCount==3 && reads==3 && renamed==2 && unchanged==1,
          "three-bindings-two-renamed-one-same");
  if(argc==3) {
    // Modify only this test module: another, distinct lexical parameter is
    // also called j in both phases. Original source/facts stay untouched.
    auto other=shapes.at("i");
    auto targetBlock=c.analyzed.lookup(c.id(other.block));
    replaceName(other.parameter,"name","j");
    replaceName(other.analyzedParameter,"name","j");
    replaceName(other.block,"locals","j");
    replaceName(targetBlock,"locals","j");
    auto wrong=loops::inspect(c,other.call,0);
    require(succeeded(wrong),"distinct-same-name-parameter");
    require(wrong->sourceName=="j" && wrong->analyzedName=="j" &&
            wrong->parameter!=shapes.at("j").parameter,"same-name-different-id");
    require(failed(loops::knownBoundRead(c,jRead,*wrong)),
            "reject-same-name-foreign-scope");
    return 1; // named rejection is checked byte-for-byte by the driver.
  }
  llvm::outs()<<"loop-facts: three bindings, two renamed and one same, unknown blocks preserved\n";
}
