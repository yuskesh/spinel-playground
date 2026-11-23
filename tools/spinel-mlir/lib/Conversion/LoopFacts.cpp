#include "spinel/Conversion/LoopFacts.h"
#include "llvm/ADT/StringSwitch.h"
#include <set>
namespace spinel::consumer::loops {
namespace {
constexpr const char *forms =
  "`N.times do |i| … end`, `k.times`, `(0...k).each` or `(0..m).each`";
LogicalResult shapeError(Consumer &c,Operation *node,const std::string &message) {
  return c.diagnostic(node,"SB030","LoopShape",message,true);
}
bool equalExceptString(Operation *a,Operation *b,StringRef key,
                       StringRef before,StringRef after) {
  if(!a || !b || a->getLoc()!=b->getLoc() ||
     a->getAttrs().size()!=b->getAttrs().size())return false;
  for(auto attr:a->getAttrs()) {
    if(attr.getName()!="strings") {
      if(attr.getValue()!=b->getAttr(attr.getName()))return false;
      continue;
    }
    auto x=dyn_cast<DictionaryAttr>(attr.getValue());
    auto y=b->getAttrOfType<DictionaryAttr>("strings");
    if(!x || !y || x.size()!=y.size())return false;
    for(auto field:x) {
      if(field.getName()!=key) {
        if(field.getValue()!=y.get(field.getName()))return false;
      } else {
        auto s=dyn_cast<StringAttr>(field.getValue());
        auto t=y.getAs<StringAttr>(key);
        if(!s || !t || s.getValue()!=before || t.getValue()!=after)return false;
      }
    }
  }
  return true;
}
Operation *phaseRef(Consumer &c,Operation *node,StringRef key) {
  auto refs=node?node->getAttrOfType<DictionaryAttr>("refs"):DictionaryAttr();
  auto value=refs?refs.getAs<IntegerAttr>(key):IntegerAttr();
  return value?c.analyzed.lookup(value.getInt()):nullptr;
}
SmallVector<Operation *> phaseArray(Consumer &c,Operation *node,StringRef key) {
  SmallVector<Operation *> result;
  auto arrays=node?node->getAttrOfType<DictionaryAttr>("arrays"):DictionaryAttr();
  auto values=arrays?arrays.getAs<ArrayAttr>(key):ArrayAttr();
  if(values)for(auto value:values)
    result.push_back(c.analyzed.lookup(cast<IntegerAttr>(value).getInt()));
  return result;
}
bool oneType(Consumer &c,Operation *node) {
  return node && c.types[c.id(node)].size()==1;
}
} // namespace
bool isIterator(Consumer &c,Operation *node) {
  if(text(node,"kind")!="CallNode" ||
     text(c.ref(node,"block"),"kind")!="BlockNode")return false;
  return llvm::StringSwitch<bool>(field(node,"strings","name"))
    .Cases({"times","each","upto","downto","step"},true)
    .Cases({"each_with_index","each_with_object","map","select","reject"},true)
    .Cases({"each_slice","each_cons","reverse_each","loop"},true).Default(false);
}
FailureOr<Syntax> inspect(Consumer &c,Operation *node,unsigned depth,
                         std::function<LogicalResult(const Syntax &)> precheck) {
  Syntax out;
  out.call=node;out.block=c.ref(node,"block");
  auto name=field(node,"strings","name");
  auto receiver=c.ref(node,"receiver");
  if(name=="loop" && !receiver) {
    (void)c.error(node,std::string("`loop do` has no bound — write ")+forms+
                       " with a bound ≤ 64 (P015)");
    return failure();
  }
  if(name=="times" && receiver && c.args(node).empty())out.count=receiver;
  else if(name=="each" && c.args(node).empty()) {
    auto body=c.ref(receiver,"body");
    auto list=c.array(body,"body");
    auto range=list.size()==1?list[0]:nullptr;
    if(text(receiver,"kind")!="ParenthesesNode" ||
       text(body,"kind")!="StatementsNode" || text(range,"kind")!="RangeNode" ||
       !c.ref(range,"right")) {
      (void)shapeError(c,node,std::string("`each` is accepted only on a range `(0...k)` / `(0..m)` — the bounded loops are ")+forms+" (P015)");
      return failure();
    }
    auto lo=c.ref(range,"left");
    if(text(lo,"kind")!="IntegerNode" || text(lo,"literal_decimal")!="0") {
      (void)shapeError(c,node,"the range must start at literal 0 — write `(0...k).each` and add the start inside the body (P015)");
      return failure();
    }
    auto flags=field(range,"integers","flags");
    unsigned value;
    if(flags.empty() || flags.getAsInteger(10,value)) {
      (void)c.error(node,"E012 range lacks exact flags");
      return failure();
    }
    out.count=c.ref(range,"right");out.inclusive=!(value&4);
  } else {
    (void)shapeError(c,node,"`"+name.str()+"` with a block is not accepted on the eBPF side — the bounded loops are "+forms+" (P015)");
    return failure();
  }
  if(depth>=2) {
    (void)shapeError(c,node,"loops nest at most 2 deep on the eBPF side (bpf-mlir's ebpf.loop) — move the innermost loop out (P015)");
    return failure();
  }
  auto targetBlock=c.analyzed.lookup(c.id(out.block));
  auto oldLocals=field(out.block,"strings","locals");
  auto newLocals=field(targetBlock,"strings","locals");
  SmallVector<StringRef> oldNames,newNames;
  if(!oldLocals.empty())oldLocals.split(oldNames,',',-1,false);
  if(!newLocals.empty())newLocals.split(newNames,',',-1,false);
  std::set<std::string> targets;
  if(oldNames.size()!=newNames.size() ||
     !equalExceptString(out.block,targetBlock,"locals",oldLocals,newLocals)) {
    (void)c.error(node,"E012 block local tables differ in structure");
    return failure();
  }
  for(size_t i=0;i<oldNames.size();++i) {
    if(oldNames[i].empty() || newNames[i].empty() ||
       !out.localNames.emplace(oldNames[i].str(),newNames[i].str()).second ||
       !targets.insert(newNames[i].str()).second) {
      (void)c.error(node,"E012 block local tables are not one-to-one");
      return failure();
    }
  }
  auto bp=c.ref(out.block,"parameters");
  if(bp) {
    auto ps=c.ref(bp,"parameters");
    if(text(bp,"kind")!="BlockParametersNode" ||
       !c.array(bp,"locals").empty() || !ps) {
      (void)shapeError(c,bp,"the loop block takes one parameter `|i|` (or none) — no block-local `;` names (P015)");
      return failure();
    }
    auto req=c.array(ps,"requireds");
    bool extra=!c.array(ps,"optionals").empty() || !c.array(ps,"keywords").empty() ||
               !c.array(ps,"posts").empty() || c.ref(ps,"rest") ||
               c.ref(ps,"keyword_rest") || c.ref(ps,"block");
    if(req.size()!=1 || extra || text(req[0],"kind")!="RequiredParameterNode") {
      (void)shapeError(c,bp,"the loop block takes one parameter `|i|` (the index 0, 1, …) or none (P015)");
      return failure();
    }
    out.parameter=req[0];
    auto targetBP=phaseRef(c,targetBlock,"parameters");
    auto targetPS=phaseRef(c,targetBP,"parameters");
    auto targetReq=phaseArray(c,targetPS,"requireds");
    if(!targetBP || !targetPS || targetReq.size()!=1 ||
       c.id(targetBP)!=c.id(bp) || c.id(targetPS)!=c.id(ps) ||
       !c.equivalentNode(bp,targetBP) || !c.equivalentNode(ps,targetPS)) {
      (void)c.error(node,"E012 loop parameter structure differs between phases");
      return failure();
    }
    out.analyzedParameter=targetReq[0];
    out.sourceName=field(out.parameter,"strings","name").str();
    out.analyzedName=field(out.analyzedParameter,"strings","name").str();
    if(out.sourceName.empty() || out.analyzedName.empty() ||
       !equalExceptString(out.parameter,out.analyzedParameter,"name",
                          out.sourceName,out.analyzedName) ||
       !out.localNames.count(out.sourceName) ||
       out.localNames.at(out.sourceName)!=out.analyzedName ||
       !oneType(c,out.parameter) ||
       text(c.types[c.id(out.parameter)].front(),"kind")!="int") {
      (void)c.error(node,"E012 loop parameter binding is not structurally proved");
      return failure();
    }
  }
  out.body=c.ref(out.block,"body");
  if(out.body && text(out.body,"kind")!="StatementsNode") {
    (void)shapeError(c,out.body,"the loop body must be a plain sequence of statements, got "+text(out.body,"kind").str()+" (P015)");
    return failure();
  }
  auto &ev=c.evidence[c.id(out.block)];
  auto inlined=ev.size()==1?ev[0]->getAttrOfType<BoolAttr>("inlined"):BoolAttr();
  if(!oneType(c,out.block) || !inlined || !inlined.getValue()) {
    (void)c.error(node,"E012 loop block lacks inlined evidence");
    return failure();
  }
  if(precheck && failed(precheck(out)))return failure();
  if(failed(c.known(node,true)))return failure();
  return out;
}
LogicalResult knownBoundLocal(Consumer &c,Operation *node,const Syntax &shape) {
  auto target=c.analyzed.lookup(c.id(node));
  auto name=field(node,"strings","name");
  auto binding=shape.localNames.find(name.str());
  auto kind=text(node,"kind");
  if(!kind.starts_with("LocalVariable") || binding==shape.localNames.end() ||
     !equalExceptString(node,target,"name",name,binding->second) || !oneType(c,node))
    return c.error(node,"E012 loop local does not match its explicit block binding");
  auto parent=c.parent(node);
  while(parent && parent!=shape.block) {
    if(text(parent,"kind")=="BlockNode") {
      SmallVector<StringRef> locals;
      field(parent,"strings","locals").split(locals,',',-1,false);
      if(llvm::is_contained(locals,name))
        return c.error(node,"E012 loop local is shadowed by a different block binding");
    }
    parent=c.parent(parent);
  }
  if(parent!=shape.block)return c.error(node,"E012 loop local is outside its binding scope");
  return success();
}
LogicalResult knownBoundRead(Consumer &c,Operation *node,const Syntax &shape) {
  if(text(node,"kind")!="LocalVariableReadNode")
    return c.error(node,"E012 bound read requires a local read node");
  return knownBoundLocal(c,node,shape);
}
} // namespace spinel::consumer::loops
