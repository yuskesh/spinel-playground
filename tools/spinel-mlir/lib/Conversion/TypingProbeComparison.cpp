#include "spinel/Conversion/TypingProbeComparison.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>
#include <functional>
namespace spinel::consumer {
namespace {
struct Record {ProbeSpan span;std::string name,rbs,signature,owner;};
llvm::Error malformed(llvm::StringRef reason="malformed comparison observations") {return llvm::createStringError(llvm::inconvertibleErrorCode(),"typing_probe: "+reason.str());}
llvm::Expected<std::vector<Record>> records(const std::string &text,const std::set<std::string> &sourcePaths) {
  auto value=llvm::json::parse(text);if(!value)return value.takeError();
  auto *object=value->getAsObject();auto *types=object?object->getArray("types"):nullptr;
  if(!types||!object->getArray("diagnostics")||!object->getArray("codegen"))return malformed("types/diagnostics/codegen must be arrays");std::vector<Record> out;
  for(const auto &v:*types) {
    const auto *o=v.getAsObject();if(!o)return malformed();
    auto file=o->getString("file"),kind=o->getString("kind"),rbs=o->getString("rbs");
    auto line=o->getInteger("line"),col=o->getInteger("col");
if(!file||!kind||!rbs||!o->getString("type")||!line||!col||*line<1||*col<0)return malformed("invalid required type record fields");
if(!sourcePaths.count(file->str()))return malformed("observation file is absent from SourceOps");
for(auto key:{"name","owner","signature"})if(auto *v=o->get(key))if(!v->getAsString())return malformed("optional type text must be a string");
for(auto key:{"singleton","widened"})if(auto *v=o->get(key))if(!v->getAsBoolean())return malformed("optional type flag must be a bool");
auto *endLine=o->get("end_line"),*endCol=o->get("end_col");
bool noEndLine=!endLine||bool(endLine->getAsNull()),noEndCol=!endCol||bool(endCol->getAsNull());
if(noEndLine!=noEndCol)return malformed("type end positions must be a complete pair");
if(!noEndLine) {
  auto el=endLine->getAsInteger(),ec=endCol->getAsInteger();
  if(!el||!ec||*el<*line||*ec<0)return malformed("invalid type end positions");
}

    // Library/synthetic observations may omit ends; Go never compares those.
    Record r;r.span={file->str(),*line,*col,o->getInteger("end_line").value_or(0),o->getInteger("end_col").value_or(0),kind->str()};r.rbs=rbs->str();
    r.name=o->getString("name").value_or("").str();r.signature=o->getString("signature").value_or("").str();r.owner=o->getString("owner").value_or("").str();out.push_back(std::move(r));
  }
  return out;
}
bool inside(const ProbeSpan &a,const ProbeSpan &b) {
  return std::tie(a.line,a.col)>=std::tie(b.line,b.col)&&std::tie(a.endLine,a.endCol)<=std::tie(b.endLine,b.endCol);
}
std::string join(const std::vector<std::string> &v) {std::string s;for(auto &x:v){if(!s.empty())s+=';';s+=x;}return s;}
bool untypedOnly(const std::vector<std::string> &v) {
  for(auto &x:v){auto a=x.find('|');if(a==std::string::npos)return false;auto b=x.find('|',a+1);if(b==std::string::npos||x.substr(a+1,b-a-1)!="untyped"||b+1!=x.size())return false;}return true;
}
std::string quoted(const std::string &s) {std::string r;llvm::raw_string_ostream out(r);out<<llvm::json::Value(s);return r;}
}
llvm::Expected<std::vector<ProbeDifference>> compareTypingProbe(
    const std::string &before,const std::string &after,const std::string &file,
    int64_t userLines,const std::set<std::string> &roots,const std::set<ProbeSpan> &dependent,const std::set<std::string> &sources) {
  auto sourcePaths=sources;if(sourcePaths.empty())sourcePaths.insert(file);
  auto p=records(before,sourcePaths);if(!p)return p.takeError();auto t=records(after,sourcePaths);if(!t)return t.takeError();
  using Groups=std::map<ProbeSpan,std::vector<std::string>>;Groups pm,tm;std::map<ProbeSpan,Record> tone;
  auto collect=[&](const auto &rows,Groups &m,bool typed){for(auto &r:rows){if(r.span.file!=file||r.span.endLine>userLines)continue;m[r.span].push_back(r.name+"|"+r.rbs+"|"+r.signature);if(typed)tone[r.span]=r;}};
for(const auto *rows:{&*p,&*t})for(const auto &r:*rows)
  if(r.span.file==file&&(r.span.endLine<r.span.line||r.span.line<1||r.span.col<0||r.span.endCol<0))return malformed();
  collect(*p,pm,false);collect(*t,tm,true);std::set<ProbeSpan> allowed,keys;
  for(auto &item:tone){auto &r=item.second;if(r.span.kind=="DefNode"&&roots.count(r.name)&&r.owner=="Object")allowed.insert(r.span);}
  auto rootDefs=allowed;
  for(auto &item:tone)if(item.first.kind=="RequiredParameterNode")for(auto &d:rootDefs)if(inside(item.first,d))allowed.insert(item.first);
  for(auto &item:pm)keys.insert(item.first);for(auto &item:tm)keys.insert(item.first);
  if(keys.empty())return malformed("zero source comparison records");
  std::vector<ProbeDifference> out;
  for(auto &k:keys){auto a=join(pm[k]),b=join(tm[k]);if(a==b||allowed.count(k))continue;if(dependent.count(k)&&(untypedOnly(pm[k])||k.kind=="DefNode"))continue;
    out.push_back({k,"the typing probe changed Spinel's inference of this "+k.kind+" (without: "+quoted(a)+", with: "+quoted(b)+") — the eBPF side's types must not depend on the injected call"});}
  std::stable_sort(out.begin(),out.end(),[](auto &a,auto &b){return std::tie(a.span.line,a.span.col,a.span.kind)<std::tie(b.span.line,b.span.col,b.span.kind);});return out;
}
llvm::Expected<std::set<ProbeSpan>> typingProbeDependencies(
 const std::map<int64_t,ProbeNode> &nodes,const std::map<std::string,int64_t> &defs,const std::set<std::string> &roots) {
  bool invalid=false;
  auto node=[&](int64_t id)->const ProbeNode*{if(id<0)return nullptr;auto i=nodes.find(id);if(i==nodes.end()){invalid=true;return nullptr;}return &i->second;};
  auto ref=[&](const ProbeNode *n,const std::string &key)->const ProbeNode*{if(!n)return nullptr;auto i=n->refs.find(key);return i==n->refs.end()?nullptr:node(i->second);};
  auto arr=[&](const ProbeNode *n,const std::string &key){std::vector<int64_t> r;if(n){auto i=n->arrays.find(key);if(i!=n->arrays.end())r=i->second;}return r;};
  std::function<void(const ProbeNode*,const std::function<bool(const ProbeNode*)>&)> walk;
  walk=[&](const ProbeNode *n,const auto &visit){if(!n||!visit(n))return;for(auto &a:n->arrays)for(auto id:a.second)walk(node(id),visit);for(auto &r:n->refs)walk(node(r.second),visit);};
  std::map<std::string,std::set<size_t>> parameters;std::vector<std::string> work;
  for(auto &name:roots){auto d=defs.find(name);if(d==defs.end())continue;auto n=node(d->second);if(arr(ref(n,"parameters"),"requireds").size()==1){parameters[name].insert(0);work.push_back(name);}}
  std::set<ProbeSpan> out;std::set<std::string> done;
  for(size_t wi=0;wi<work.size();++wi){auto name=work[wi];auto n=node(defs.at(name));auto ps=arr(ref(n,"parameters"),"requireds");std::set<std::string> tainted;
    for(auto i:parameters[name])if(i<ps.size())if(auto p=node(ps[i]))tainted.insert(p->name);
    auto reads=[&](const ProbeNode *n){bool found=false;walk(n,[&](auto x){if(x->span.kind=="LocalVariableReadNode"&&tainted.count(x->name))found=true;return !found;});return found;};
    for(bool changed=true;changed;){changed=false;walk(n,[&](auto x){if((x->span.kind=="LocalVariableWriteNode"||x->span.kind=="LocalVariableOperatorWriteNode")&&!tainted.count(x->name)&&reads(ref(x,"value"))){tainted.insert(x->name);changed=true;}if(x->span.kind=="MultiWriteNode"&&reads(ref(x,"value")))for(auto id:arr(x,"lefts"))if(auto t=node(id))if(t->span.kind=="LocalVariableTargetNode"&&tainted.insert(t->name).second)changed=true;return true;});}
    if(!roots.count(name)&&!done.count(name)){out.insert(n->span);for(auto i:parameters[name])if(i<ps.size())if(auto p=node(ps[i]))out.insert(p->span);}done.insert(name);
    walk(n,[&](auto x){if(x!=n&&reads(x))out.insert(x->span);if(x->span.kind=="CallNode"&&!ref(x,"receiver")&&defs.count(x->name)&&!roots.count(x->name)){auto as=arr(ref(x,"arguments"),"arguments");for(size_t i=0;i<as.size();++i)if(reads(node(as[i]))&&parameters[x->name].insert(i).second)work.push_back(x->name);}return true;});
  }
  if(invalid)return malformed();return out;
}
}
