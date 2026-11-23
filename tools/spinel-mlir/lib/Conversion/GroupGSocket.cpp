#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/PacketDiagnostics.h"
#include "spinel/Analysis/KernelTypes.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
namespace spinel::consumer {
namespace {
struct SocketProgram : Payload {};
struct SocketFilter {
  std::string programKind="socket_filter";
  Operation *def=nullptr,*finalNode=nullptr;
  std::string param,finalVerdict,guardVerdict;
  Value fired;
  std::string verdict(StringRef n) const {
    if(programKind=="netfilter")return n=="BPF::NF_ACCEPT"?"accept":n=="BPF::NF_DROP"?"drop":"";
    if(programKind=="sk_lookup")return n=="BPF::SK_PASS"?"pass":n=="BPF::SK_DROP"?"drop":"";
    return n=="BPF::SF_KEEP"?"keep":n=="BPF::SF_DROP"?"drop":"";
  }
  Dispatch<ProgramDecl> root(Consumer &c,Operation *n) {
    auto as=c.args(n);
    if(as.size()!=1||text(as[0],"kind")!="SymbolNode") {
      (void)c.diagnostic(n,"SB008","ProgramShape",programKind=="sk_lookup"?"`BPF.sk_lookup` takes exactly one Symbol literal (`BPF.sk_lookup :name`) (E129)":"`BPF.socket_filter` takes exactly one Symbol literal (`BPF.socket_filter :name` — it is attached to a socket in user space with `obj.attach_socket`) (E126)");
      return Dispatch<ProgramDecl>::error();
    }
    CalleePolicy policy;policy.expected="BPF."+programKind;
    if(failed(c.known(n,policy)))return Dispatch<ProgramDecl>::error();
    def=nullptr;finalNode=nullptr;finalVerdict.clear();guardVerdict.clear();fired={};
    for(auto x:c.selectedTop)if(text(x,"kind")=="DefNode"&&field(x,"strings","name")==c.spelling(as[0],true))def=x;
    if(!def){(void)c.error(n,"root target must be a declared method");return Dispatch<ProgramDecl>::error();}
    auto ps=c.array(c.ref(def,"parameters"),"requireds");
    if(ps.size()!=1){(void)c.error(def,"root requires one context parameter");return Dispatch<ProgramDecl>::error();}
    param=field(ps[0],"strings","name").str();
    if(programKind=="socket_filter") {
      Operation *bad=nullptr;std::string badName;
      llvm::DenseSet<Operation*> seen;
      std::function<void(Operation*)> scan=[&](Operation *x) {
        if(!x||!seen.insert(x).second)return;
        auto cn=c.constant(x);
        const std::set<std::string> wrong={"BPF::XDP_ABORTED","BPF::XDP_DROP","BPF::XDP_PASS","BPF::XDP_TX","BPF::TC_PASS","BPF::TC_DROP","BPF::CG_ALLOW","BPF::CG_DENY","BPF::NF_ACCEPT","BPF::NF_DROP","BPF::FLOW_OK","BPF::FLOW_DROP","BPF::FLOW_CONTINUE"};
        if(wrong.count(cn)&&(!bad||c.id(x)<c.id(bad))){bad=x;badName=cn;}
        if(auto refs=x->getAttrOfType<DictionaryAttr>("refs"))for(auto item:refs)scan(c.nodes.lookup(cast<IntegerAttr>(item.getValue()).getInt()));
        if(auto arrays=x->getAttrOfType<DictionaryAttr>("arrays"))for(auto item:arrays)for(auto id:cast<ArrayAttr>(item.getValue()))scan(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
      };scan(def);
      if(bad) {
        auto cn=StringRef(badName);
        std::string label=cn.starts_with("BPF::XDP_")?"an XDP":cn.starts_with("BPF::TC_")?"a sched_cls (tcx)":cn.starts_with("BPF::CG_")?"a cgroup_skb":cn.starts_with("BPF::NF_")?"a netfilter":"a flow_dissector";
        auto saved=c.programName;c.programName=c.spelling(as[0],true).str();
        (void)c.diagnostic(bad,"SB028","TracingKind",badName+" is "+label+" verdict — a socket_filter program returns BPF::SF_KEEP or BPF::SF_DROP (P026)",true);
        c.programName=saved;return Dispatch<ProgramDecl>::error();
      }
    }
    auto body=c.array(c.ref(def,"body"),"body");
    if(!body.empty()) {
      finalNode=body.back();auto v=finalNode;
      if(text(v,"kind")=="ReturnNode"){auto a=c.args(v);v=a.size()==1?a[0]:nullptr;}
      finalVerdict=verdict(c.constant(v));
    }
    ProgramDecl p;p.kind=programKind;p.analysisContext=programKind=="sk_lookup"?"obj_BPF::SkLookupCtx":"obj_BPF::SocketFilterCtx";
    p.payload=std::make_shared<SocketProgram>();
    p.finalizeBody=packetFinalizeBody;
    return Dispatch<ProgramDecl>::handled(std::move(p));
  }
  Dispatch<Expr> expression(Consumer &c,Operation *n) {
    if(c.activeKind!=programKind||c.activeDef!=def)return Dispatch<Expr>::declined();
    auto recv=c.ref(n,"receiver");
    auto name=field(n,"strings","name");
if(programKind=="sk_lookup"&&name=="assign"&&text(n,"kind")=="CallNode") {
  auto receiver=c.constant(recv);
  if(llvm::any_of(c.maps,[&](const MapDecl &m){return m.name==receiver&&m.kind=="sockmap";})) {
    (void)c.diagnostic(n,"SB002","UnsupportedCall","call `assign` is not accepted on the eBPF side",true);
    return Dispatch<Expr>::error();
  }
}
    const std::set<std::string> skFields={"family","protocol","remote_ip4","remote_port","local_ip4","local_port","ingress_ifindex"};
    if(text(recv,"kind")!="LocalVariableReadNode"||field(recv,"strings","name")!=param)return Dispatch<Expr>::declined();
    if(programKind=="socket_filter"&&name!="len") {
      (void)c.diagnostic(n,"SB028","TracingKind","the socket_filter context has no `"+name.str()+"` — it reads `ctx.len` (the packet length, u32 — a socket_filter cannot read the packet itself in bpf-mlir v1.14.0) (E126) (P013)",true);
      return Dispatch<Expr>::error();
    }
    if(programKind=="sk_lookup"&&!skFields.count(name.str()))return Dispatch<Expr>::declined();
    CalleePolicy policy;policy.expected=(programKind=="sk_lookup"?"SkLookupCtx#":"SocketFilterCtx#")+name.str();
    if(failed(c.known(n,policy)))return Dispatch<Expr>::error();
    if(!c.args(n).empty()){(void)c.error(n,"socket_filter len takes no arguments");return Dispatch<Expr>::error();}
    auto range=tracing::integerRange(32,false,tracing::IntegerSource::ContextField);
    if(!range){(void)c.rangeFailure(range.takeError(),n);return Dispatch<Expr>::error();}
    auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="gsocket.len";e->name=name.str();e->range=*range;
    return Dispatch<Expr>::handled(e);
  }
  Dispatch<StatementResult> statement(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    if(c.activeKind!=programKind)return Dispatch<StatementResult>::declined();
    if(c.activeDef!=def) {
      if(programKind!="netfilter")return Dispatch<StatementResult>::declined();
      def=c.activeDef;guardVerdict.clear();fired={};finalNode=nullptr;finalVerdict.clear();
      auto body=c.array(c.ref(def,"body"),"body");
      if(!body.empty()) {
        finalNode=body.back();auto v=finalNode;
        if(text(v,"kind")=="ReturnNode"){auto a=c.args(v);v=a.size()==1?a[0]:nullptr;}
        finalVerdict=verdict(c.constant(v));
      }
    }
    auto n=list[index];auto kind=text(n,"kind");
    if(depth==0&&n==finalNode&&finalVerdict.empty()&&
        (kind=="IntegerNode"||kind=="ReturnNode")) {
      (void)packetEndingDiagnostic(c,n);return Dispatch<StatementResult>::error();
    }
    if(kind=="LocalVariableWriteNode"&&programKind=="sk_lookup")return assign(c,n);
    if(kind=="IfNode"||kind=="UnlessNode") {
      auto body=c.array(c.ref(n,"statements"),"body");
      if(depth||body.size()!=1||text(body[0],"kind")!="ReturnNode"||c.ref(n,"subsequent")||c.ref(n,"else_clause"))return Dispatch<StatementResult>::declined();
      auto a=c.args(body[0]);auto v=a.size()==1?verdict(c.constant(a[0])):"";
      if(v.empty()||finalVerdict.empty()||(!guardVerdict.empty()&&guardVerdict!=v)){(void)c.error(body[0],"socket_filter guard requires a consistent verdict");return Dispatch<StatementResult>::error();}
      guardVerdict=v;auto cond=c.scalar(c.ref(n,"predicate"));
      if(failed(cond)||!(*cond)->range.isBool)return Dispatch<StatementResult>::error();
      auto cv=c.emitScalar(*cond);if(!cv)return Dispatch<StatementResult>::error();
      if(kind=="UnlessNode")cv=arith::XOrIOp::create(c.builder,outputLoc((*cond)->node),cv,arith::ConstantIntOp::create(c.builder,outputLoc((*cond)->node),1,1));
      auto pre=c.locals;auto old=c.borrows;auto binds=c.bindings;
      auto yes=std::make_unique<Block>(),no=std::make_unique<Block>();
      {
        OpBuilder::InsertionGuard guard(c.builder);
        c.builder.setInsertionPointToStart(yes.get());
        auto hit=arith::ConstantIntOp::create(c.builder,outputLoc(n),1,1);
        ebpf::IfYieldOp::create(c.builder,outputLoc(n),ValueRange{hit});
        c.builder.setInsertionPointToStart(no.get());
        auto rest=list.drop_front(index+1);if(!rest.empty()&&rest.back()==finalNode)rest=rest.drop_back();
        auto saved=fired;fired={};
        if(failed(c.scalarStatements(rest,depth)))return Dispatch<StatementResult>::error();
        Value miss=fired?fired:arith::ConstantIntOp::create(c.builder,outputLoc(n),0,1).getResult();
        ebpf::IfYieldOp::create(c.builder,outputLoc(n),ValueRange{miss});fired=saved;
        c.locals=pre;c.borrows=old;c.bindings=binds;
      }
      auto branch=ebpf::IfOp::create(c.builder,outputLoc(n),TypeRange{c.builder.getI1Type()},cv);
      branch->getRegion(0).push_back(yes.release());branch->getRegion(1).push_back(no.release());fired=branch->getResult(0);
      if(list.back()==finalNode)ebpf::VerdictIfOp::create(c.builder,outputLoc(finalNode),fired,guardVerdict,finalVerdict);
      return Dispatch<StatementResult>::handled({list.size()-index});
    }
    auto v=n;if(kind=="ReturnNode"){auto a=c.args(n);v=a.size()==1?a[0]:nullptr;}
    auto name=verdict(c.constant(v));
    if(!name.empty()&&depth==0&&index+1==list.size()) {
      ebpf::VerdictOp::create(c.builder,outputLoc(n),name);return Dispatch<StatementResult>::handled({1});
    }
    return Dispatch<StatementResult>::declined();
  }
  Dispatch<StatementResult> assign(Consumer &c,Operation *n) {
    auto call=c.ref(n,"value"),recv=c.ref(call,"receiver");
    if(text(call,"kind")!="CallNode"||field(call,"strings","name")!="assign"||text(recv,"kind")!="ConstantReadNode")return Dispatch<StatementResult>::declined();
    auto bad=[&](Operation *at,StringRef code,StringRef label,const std::string &m){(void)c.diagnostic(at,code,label,m,true);return Dispatch<StatementResult>::error();};
    auto mn=c.constant(recv),name=field(n,"strings","name").str();
    auto map=llvm::find_if(c.maps,[&](const MapDecl &m){return m.name==mn;});
    if(map==c.maps.end()){(void)c.error(call,"assign receiver is not a declared map");return Dispatch<StatementResult>::error();}
    if(map->kind!="sockmap")return bad(call,"SB002","UnsupportedCall","`"+mn+".assign` needs a sockmap (`BPF::SockMap.new`) — "+mn+" is a "+map->kind+" (E129)");
    CalleePolicy policy;policy.expected="SockMap#assign";if(failed(c.known(call,policy)))return Dispatch<StatementResult>::error();
    auto as=c.args(call);
    if(as.size()!=2||text(as[0],"kind")!="LocalVariableReadNode"||field(as[0],"strings","name")!=param)return bad(call,"SB028","TracingKind","`"+mn+".assign("+param+", k)` takes the program's context and a slot key (E129)");
    if(name=="_")return bad(n,"SB026","StatusIgnored","the status of `"+mn+".assign` is dropped — receive it as `st = "+mn+".assign("+param+", k)` and read `st` (0 is assigned, a negative errno or -2 (no socket in the slot) is not) (E129)");
    if(c.locals.count(name)||c.borrows.count(name)||name==param)return bad(n,"SB026","StatusIgnored","`"+name+"` is already bound — the status of `"+mn+".assign` takes a fresh local (E129)");
    unsigned writes=0,reads=0;llvm::DenseSet<Operation*> seen;
    std::function<void(Operation*)> walk=[&](Operation *x) {
      if(!x||!seen.insert(x).second)return;
      auto k=text(x,"kind");
      if(field(x,"strings","name")==name) {
        if(k=="LocalVariableReadNode")++reads;
        if(k=="LocalVariableWriteNode"||k=="LocalVariableOperatorWriteNode"||k=="LocalVariableOrWriteNode"||k=="LocalVariableAndWriteNode"||k=="LocalVariableTargetNode")++writes;
      }
      if(auto refs=x->getAttrOfType<DictionaryAttr>("refs"))for(auto v:refs)walk(c.nodes.lookup(cast<IntegerAttr>(v.getValue()).getInt()));
      if(auto arrays=x->getAttrOfType<DictionaryAttr>("arrays"))for(auto v:arrays)for(auto id:cast<ArrayAttr>(v.getValue()))walk(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
    };walk(def);
    if(writes!=1)return bad(n,"SB026","StatusIgnored","`"+name+"` holds the status of `"+mn+".assign` but is assigned "+std::to_string(writes)+" times — a status local is assigned once (P026)");
    if(!reads)return bad(n,"SB026","StatusIgnored","`"+name+"` holds the status of `"+mn+".assign` but is never read — check it (e.g. `if "+name+" == 0`): an empty slot or a refused socket is not an assigned one (P026)");
    auto key=c.scalar(as[1]);if(failed(key))return Dispatch<StatementResult>::error();
    if((*key)->range.isBool)return bad(as[1],"SB001","UnsupportedConstruct","the key of `"+mn+".assign` is an Integer (a sockmap slot), not a bool (E129)");
    if((*key)->range.wide){(void)c.error(as[1],"sockmap key requires a representable i64 value");return Dispatch<StatementResult>::error();}
    if(c.probing){(void)c.error(n,"socket assign cannot emit during Probe");return Dispatch<StatementResult>::error();}
    auto value=c.emitScalar(*key);if(!value)return Dispatch<StatementResult>::error();
    auto loc=outputLoc(n);auto i64=c.builder.getI64Type();
    auto k32=arith::TruncIOp::create(c.builder,loc,c.builder.getI32Type(),value);
    auto absent=arith::ConstantIntOp::create(c.builder,loc,-2,64);
    auto socket=ebpf::SockMapLookupOp::create(c.builder,loc,ebpf::SockRefOrNullType::get(c.ctx),map->value,k32);
    auto check=ebpf::SockRefCheckOp::create(c.builder,loc,TypeRange{i64},socket);
    auto yes=new Block(),no=new Block();check.getPresentRegion().push_back(yes);check.getAbsentRegion().push_back(no);
    auto ref=yes->addArgument(ebpf::SockRefType::get(c.ctx),c.builder.getUnknownLoc());
    {
      OpBuilder::InsertionGuard guard(c.builder);c.builder.setInsertionPointToStart(yes);
      auto result=ebpf::SkAssignOp::create(c.builder,loc,i64,c.contextValue,ref,UnitAttr{},UnitAttr{});
      ebpf::SockReleaseOp::create(c.builder,loc,ref);ebpf::YieldOp::create(c.builder,loc,ValueRange{result});
      c.builder.setInsertionPointToStart(no);ebpf::YieldOp::create(c.builder,loc,ValueRange{absent});
    }
    auto status=std::make_shared<ScalarExpr>();status->node=n;status->kind="local";status->name=name;status->range=tracing::readStatusRange();
    c.locals[name]={status,check->getResult(0)};
    return Dispatch<StatementResult>::handled({1});
  }
};
std::string quote(StringRef s) {
  std::string out; llvm::raw_string_ostream os(out);
  os << llvm::json::Value(s); return out;
}
Dispatch<bool> sockMap(Consumer &c,Operation *n) {
  auto call=c.ref(n,"value");
  bool devmap=c.constant(c.ref(call,"receiver"))=="BPF::DevMap";
  std::string className=devmap?"DevMap":"SockMap";
  auto constant=field(n,"strings","name").str();
  auto reject=[&](Operation *at,const std::string &message) {
    (void)c.diagnostic(at,"SB013","MapDeclShape",message);
    return Dispatch<bool>::error();
  };
  if(llvm::any_of(c.maps,[&](const MapDecl &m){return m.name==constant;}))
    return reject(n,"constant "+constant+" is assigned twice");
  auto as=c.args(call);
  if(as.size()==3 && text(as[1],"kind")=="IntegerNode")
    return reject(as[1],"the value type is a Symbol since P002 — write `:u32`, `:u64`, `:i32` or `:i64` (e.g. `BPF::"+className+".new(\""+constant+"\", :u64, n)`)");
  if(as.size()!=3 || text(as[0],"kind")!="StringNode" ||
     text(as[1],"kind")!="SymbolNode" || text(as[2],"kind")!="IntegerNode")
    return reject(n,"a map is declared as `"+constant+" = BPF::"+className+".new(\""+constant+"\", :u32|:u64|:i32|:i64, max_entries)` with literal arguments");
  auto name=c.spelling(as[0],false).str();
  if(name!=constant)
    return reject(as[0],"the map name "+quote(name)+" differs from its constant "+constant+" — both sides look the map up by this name, so they must be the same");
  auto type=c.spelling(as[1],true).str();
  if(type!=(devmap?"u32":"u64"))
    return reject(as[1],devmap?"the value type of a devmap is :u32 (an ifindex), got :"+type+" (E124)":"the value type of a sockmap is :u64 (a socket — user space puts its fd), got :"+type+" (E129)");
  auto entries=c.integer(as[2]);
  if(failed(entries)) return Dispatch<bool>::error();
  if(*entries<=0 || uint64_t(*entries)>UINT32_MAX)
    return reject(as[2],"max_entries must be a positive integer below 2^32, got "+std::to_string(*entries));
  if(StringRef(name).starts_with("spinelbpf_")) {
    (void)c.diagnostic(n,"SB007","ReservedName","map name "+quote(name)+" uses the reserved prefix spinelbpf_");
    return Dispatch<bool>::error();
  }
  CalleePolicy policy; policy.expected=className+".new";policy.requireCallee=false;
  if(failed(c.known(call,policy))) return Dispatch<bool>::error();
  MapDecl m; m.node=n; m.name=name; m.kind=devmap?"devmap":"sockmap"; m.className=className;
  m.bits=devmap?32:64; m.entries=*entries;
  c.maps.push_back(std::move(m));
  return Dispatch<bool>::handled(true);
}
Dispatch<StatementResult> redirect(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
  auto n=list[index],call=n;
  if(text(n,"kind")=="ReturnNode"){auto args=c.args(n);call=args.size()==1?args[0]:nullptr;}
  if(text(call,"kind")!="CallNode"||field(call,"strings","name")!="redirect")return Dispatch<StatementResult>::declined();
  auto bad=[&](Operation *at,StringRef code,StringRef label,const std::string &message){(void)c.diagnostic(at,code,label,message,true);return Dispatch<StatementResult>::error();};
  if(c.activeKind!="xdp")return bad(call,"SB028","TracingKind","`redirect` (bpf_redirect_map) ends only an XDP program — a "+c.activeKind+" program returns its own verdict (E124)");
  if(depth)return bad(call,"SB002","UnsupportedCall","call `redirect` is not accepted on the eBPF side");
  if(index+1!=list.size())return bad(call,"SB008","ProgramShape","redirect must be the final top-level verdict (E124)");
  auto name=c.constant(c.ref(call,"receiver"));auto map=llvm::find_if(c.maps,[&](const MapDecl &m){return m.name==name;});
  if(map==c.maps.end()){(void)c.error(call,"redirect receiver is not a declared map");return Dispatch<StatementResult>::error();}
  if(map->kind!="devmap")return bad(call,"SB002","UnsupportedCall","`"+name+".redirect` needs a devmap (`BPF::DevMap.new`) — "+name+" is a "+map->kind+" (E124)");
  CalleePolicy policy;policy.expected="DevMap#redirect";if(failed(c.known(call,policy)))return Dispatch<StatementResult>::error();
  auto args=c.args(call);
  if(args.size()!=2)return bad(call,"SB008","ProgramShape","`"+name+".redirect(k, BPF::XDP_PASS)` takes the key and the fallback verdict (E124)");
  auto cn=c.constant(args[1]);std::string fallback=cn=="BPF::XDP_PASS"?"pass":cn=="BPF::XDP_DROP"?"drop":cn=="BPF::XDP_TX"?"tx":cn=="BPF::XDP_ABORTED"?"aborted":"";
  if(text(args[1],"kind")!="ConstantPathNode"||fallback.empty())return bad(args[1],"SB008","ProgramShape","the fallback of `"+name+".redirect` is an XDP verdict constant (BPF::XDP_ABORTED / XDP_DROP / XDP_PASS / XDP_TX) (E124)");
  auto key=c.scalar(args[0]);if(failed(key))return Dispatch<StatementResult>::error();
  if((*key)->range.isBool)return bad(args[0],"SB001","UnsupportedConstruct","the key of `"+name+".redirect` is an Integer (a devmap index), not a bool (E124)");
  if((*key)->range.wide){(void)c.error(args[0],"devmap key requires a representable i64 value");return Dispatch<StatementResult>::error();}
  if(c.probing){(void)c.error(n,"redirect cannot emit during Probe");return Dispatch<StatementResult>::error();}
  auto value=c.emitScalar(*key);if(!value)return Dispatch<StatementResult>::error();
  auto loc=outputLoc(n);auto k32=arith::TruncIOp::create(c.builder,loc,c.builder.getI32Type(),value);
  ebpf::RedirectMapOp::create(c.builder,loc,map->value,k32,fallback,Value{},StringAttr{},StringAttr{});
  return Dispatch<StatementResult>::handled({1});
}
} // namespace
void registerGroupGSocket(Registry &r) {
  r.addDeclaration({"BPF::SockMap","new"},sockMap);
  r.addDeclaration({"BPF::DevMap","new"},sockMap);
  for(auto mapKind:{"sockmap","devmap"})r.addMapExporter(mapKind,[](Consumer &c,size_t index,bool schema) {
    auto &m=c.maps[index];ExportFields fields;
    if(schema) {
      fields.emplace_back("symbol",m.name);fields.emplace_back("kind",m.kind);
      for(auto pair:{std::make_pair("key",32),std::make_pair("value",int(m.bits))})fields.emplace_back(pair.first,ExportValue::write([bits=pair.second](llvm::json::OStream &j) {
        j.object([&]{j.attribute("kind","int");j.attribute("bits",bits);j.attribute("signed",false);j.attribute("endianness","little");j.attribute("alignment",bits/8);});
      }));
      fields.emplace_back("max_entries",m.entries);fields.emplace_back("flags",int64_t(0));fields.emplace_back("record","");fields.emplace_back("note","Ruby constant "+m.name);
    } else {
      fields.emplace_back("name",m.name);fields.emplace_back("kind",m.kind);fields.emplace_back("key","u32");fields.emplace_back("value",m.bits==32?"u32":"u64");fields.emplace_back("max_entries",m.entries);
    }
    return Dispatch<ExportFields>::handled(std::move(fields));
  });
  for(auto kind:{"CallNode","ReturnNode"})r.addStatement(kind,redirect);
  auto socket=std::make_shared<SocketFilter>();
  auto network=std::make_shared<SocketFilter>();network->programKind="netfilter";
  auto lookup=std::make_shared<SocketFilter>();lookup->programKind="sk_lookup";
  r.addRoot("socket_filter",[socket](Consumer &c,Operation *n){return socket->root(c,n);});
  r.addRoot("sk_lookup",[lookup](Consumer &c,Operation *n){return lookup->root(c,n);});
  r.addExpression("CallNode",[socket](Consumer &c,Operation *n){return socket->expression(c,n);});
  r.addExpression("CallNode",[lookup](Consumer &c,Operation *n){return lookup->expression(c,n);});
  r.addStatement("LocalVariableWriteNode",[lookup](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){
    auto call=c.ref(list[i],"value");
    if(c.activeKind!="sk_lookup"&&text(call,"kind")=="CallNode"&&field(call,"strings","name")=="assign"&&text(c.ref(call,"receiver"),"kind")=="ConstantReadNode") {
      (void)c.diagnostic(call,"SB028","TracingKind","`assign` (bpf_sk_assign) is accepted only in an sk_lookup program — a "+c.activeKind+" program has no socket lookup (E129)",true);
      return Dispatch<StatementResult>::error();
    }
    return lookup->statement(c,list,i,depth);
  });
  for(auto kind:{"IfNode","UnlessNode","ReturnNode","ConstantPathNode","IntegerNode"}) {
    r.addStatement(kind,[socket](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){return socket->statement(c,list,i,depth);});
    r.addStatement(kind,[network](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){return network->statement(c,list,i,depth);});
    r.addStatement(kind,[lookup](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){return lookup->statement(c,list,i,depth);});
  }
  r.addEmitter("gsocket.len",[](Consumer &c,const Expr &e)->Dispatch<Value> {
    auto loc=outputLoc(e->node);auto value=ebpf::CtxFieldOp::create(c.builder,loc,c.builder.getI32Type(),c.contextValue,e->name,IntegerAttr{});
    return Dispatch<Value>::handled(arith::ExtUIOp::create(c.builder,loc,c.builder.getI64Type(),value));
  });
}
} // namespace spinel::consumer
