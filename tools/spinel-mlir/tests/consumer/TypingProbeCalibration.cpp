#include "spinel/Conversion/TypingProbeComparison.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
using namespace spinel::consumer;
namespace {
int reject(const char *reason) {llvm::errs()<<"typing-probe-calibration: "<<reason<<"\n";return 2;}
}
int main(int argc,char **argv) {
  if(argc!=2)return reject("input required");
  auto text=llvm::MemoryBuffer::getFile(argv[1]);if(!text)return reject("cannot read input");
  auto j=llvm::json::parse((*text)->getBuffer());
  if(!j){llvm::errs()<<llvm::toString(j.takeError());return 2;}
  auto *o=j->getAsObject();if(!o)return reject("object required");
  auto *rows=o->getArray("nodes");auto *definitions=o->getObject("defs");
  auto *rootNames=o->getArray("roots");auto file=o->getString("file");
  auto before=o->getString("before"),after=o->getString("after");
  auto lines=o->getInteger("lines");
  auto *sourceList=o->getArray("source_paths");std::set<std::string> sourcePaths;
  if(!sourceList||sourceList->empty())return reject("SourceOps paths required");
  for(auto &v:*sourceList){auto path=v.getAsString();if(!path||path->empty()||!sourcePaths.insert(path->str()).second)return reject("invalid SourceOps path set");}
  if(!rows||rows->empty()||!definitions||!rootNames||rootNames->empty()||
     !file||file->empty()||!before||!after||!lines||*lines<1)
    return reject("missing/invalid input fields");
  std::map<int64_t,ProbeNode> nodes;
  for(auto &v:*rows) {
    auto *a=v.getAsObject();if(!a)return reject("node object required");
    auto id=a->getInteger("id");auto path=a->getString("file");
    auto kind=a->getString("kind"),name=a->getString("name");
    auto *span=a->getArray("span");auto *refs=a->getObject("refs");
    auto *arrays=a->getObject("arrays");
    if(!id||*id<0||nodes.count(*id)||!path||!kind||kind->empty()||!name||!span||!refs||!arrays)
      return reject("invalid node identity/shape");
    ProbeNode n;n.name=name->str();n.span.file=path->str();n.span.kind=kind->str();
    if(span->empty()) {
      if(!path->empty())return reject("source node has empty span");
      // Go AST's absent location is zero, never a guessed source position.
    } else {
      if(span->size()!=4||path->empty())return reject("source span requires four integers and path");
      int64_t values[4];
      for(unsigned i=0;i<4;++i){auto x=(*span)[i].getAsInteger();if(!x||*x<0)return reject("invalid span element");values[i]=*x;}
      if(values[0]<1||values[2]<values[0]||
         (values[2]==values[0]&&values[3]<values[1]))return reject("invalid span order");
      n.span.line=values[0];n.span.col=values[1];n.span.endLine=values[2];n.span.endCol=values[3];
    }
    for(auto &r:*refs){auto id=r.second.getAsInteger();if(!id||*id< -1)return reject("invalid reference");n.refs[r.first.str()]=*id;}
    for(auto &r:*arrays){auto *ids=r.second.getAsArray();if(!ids)return reject("array reference required");for(auto &value:*ids){auto id=value.getAsInteger();if(!id||*id<0)return reject("invalid array reference");n.arrays[r.first.str()].push_back(*id);}}
    nodes[*id]=std::move(n);
  }
  for(auto &item:nodes) {
    for(auto &r:item.second.refs)if(r.second>=0&&!nodes.count(r.second))return reject("missing referenced node");
    for(auto &a:item.second.arrays)for(auto id:a.second)if(!nodes.count(id))return reject("missing array node");
  }
  std::map<std::string,int64_t> defs;
  for(auto &r:*definitions){auto id=r.second.getAsInteger();if(!id||!nodes.count(*id))return reject("invalid def identity");const auto &n=nodes.at(*id);if(n.span.kind!="DefNode"||n.name!=r.first||n.span.file!=*file)return reject("def evidence mismatch");defs[r.first.str()]=*id;}
  std::set<std::string> roots;
  for(auto &r:*rootNames){auto name=r.getAsString();if(!name||!defs.count(name->str())||!roots.insert(name->str()).second)return reject("invalid root set");}
  auto deps=typingProbeDependencies(nodes,defs,roots);
  if(!deps){llvm::errs()<<llvm::toString(deps.takeError());return 2;}
  auto diff=compareTypingProbe(before->str(),after->str(),file->str(),*lines,roots,*deps,sourcePaths);
  if(!diff){llvm::errs()<<llvm::toString(diff.takeError());return 2;}
  for(auto &d:*diff)llvm::outs()<<d.span.line<<":"<<(d.span.col+1)<<": rejected SB010 (TypingProbe): "<<d.message<<"\n";
  return 0;
}
