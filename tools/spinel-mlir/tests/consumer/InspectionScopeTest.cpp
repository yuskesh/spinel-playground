#include "spinel/Conversion/Consumer.h"
#include "mlir/Parser/Parser.h"
#include <cstdio>
using namespace mlir;
using namespace spinel::consumer;
static void rename(Operation *node,StringRef key,StringRef name) {
  auto attrs=node->getAttrOfType<DictionaryAttr>("strings");
  NamedAttrList fields(attrs);fields.set(key,StringAttr::get(node->getContext(),name));
  node->setAttr("strings",fields.getDictionary(node->getContext()));
}
int main(int argc,char **argv) {
  if (argc!=2)return 2;
  MLIRContext ctx;ctx.loadDialect<spinel::ir::SpinelFactsDialect>();
  auto module=parseSourceFile<ModuleOp>(argv[1],&ctx);if(!module)return 2;
  Operation *sourceDef=nullptr,*sourceEntry=nullptr;
  for(auto table:module->getOps<spinel::ir::TableOp>()) {
    auto rootId=table->getAttrOfType<IntegerAttr>("root_id").getInt();
    Operation *root=nullptr,*statements=nullptr,*def=nullptr;
    for(auto node:table.getBody().front().getOps<spinel::ir::NodeOp>()) {
      if(text(node,"kind")=="DefNode") {rename(node,"name","__int_helper");def=node;}
      if(text(node,"kind")=="SymbolNode" && field(node,"strings","unescaped")=="count_pkts")rename(node,"unescaped","__int_helper");
      if(node->getAttrOfType<IntegerAttr>("id").getInt()==rootId)root=node;
    }
    if(!root||!def)return 2;
    auto statementsId=root->getAttrOfType<DictionaryAttr>("refs").getAs<IntegerAttr>("statements").getInt();
    for(auto node:table.getBody().front().getOps<spinel::ir::NodeOp>())
      if(node->getAttrOfType<IntegerAttr>("id").getInt()==statementsId)statements=node;
    if(!statements)return 2;
    if(text(table,"phase")=="analyzed") {
      auto *clone=def->clone();clone->setAttr("id",IntegerAttr::get(IntegerType::get(&ctx,64),40000));
      rename(clone,"name","__int_clone");table.getBody().front().push_back(clone);
      auto attrs=statements->getAttrOfType<DictionaryAttr>("arrays");NamedAttrList fields(attrs);
      SmallVector<Attribute> body(attrs.getAs<ArrayAttr>("body").begin(),attrs.getAs<ArrayAttr>("body").end());
      body.push_back(IntegerAttr::get(IntegerType::get(&ctx,64),40000));
      fields.set("body",ArrayAttr::get(&ctx,body));statements->setAttr("arrays",fields.getDictionary(&ctx));
    } else sourceDef=def;
  }
  Consumer c(*module);
  for(auto &[id,node]:c.nodes)
    if(text(node,"kind")=="CallNode"&&c.constant(c.ref(node,"receiver"))=="BPF")sourceEntry=node;
  if(!sourceDef||!sourceEntry)return 2;
  c.rootEntries.push_back(sourceEntry);
  auto body=c.array(c.ref(sourceDef,"body"),"body");if(body.empty())return 2;
  auto &evidence=c.evidence[c.id(body.front())];if(evidence.size()!=1)return 2;
  evidence.front()->setAttr("callee",StringAttr::get(&ctx,"__int_clone"));
  spinel::Inspection inspection;c.inspectionOutput=&inspection;
  auto seen=c.userSideMembership();
  if(failed(seen))return 2;
  if(!seen->defs.count("__int_helper")||!seen->sides["__int_helper"].count("bpf")) {
    std::fprintf(stderr,"FAIL synthetic-name-source-def-was-lost\n");return 1;
  }
  if(seen->defs.count("__int_clone")||seen->sides.count("__int_clone")||!seen->edges.empty()) {
    std::fprintf(stderr,"FAIL analyzed-only-clone-is-domain-def\n");return 1;
  }
  c.inspectionOutput=nullptr;
  auto legacy=c.userSideMembership();
  if(failed(legacy)||!legacy->defs.count("__int_clone")) {
    std::fprintf(stderr,"FAIL legacy-membership-census-changed\n");return 1;
  }
  return 0;
}
