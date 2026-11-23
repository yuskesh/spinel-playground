#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/PacketLoop.h"
#include "spinel/Conversion/PacketSubprogram.h"
#include "spinel/Conversion/Subprograms.h"
#include "spinel/Conversion/PacketDiagnostics.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include <set>

namespace spinel::consumer {
namespace {
using I = math::Integer;
using DExpr = Dispatch<Expr>;
using DStmt = Dispatch<StatementResult>;
struct PacketValue : Payload {
  unsigned bits = 0;
  int64_t index = -1;
  std::string field;
};
struct Window {
  Operation *binding = nullptr, *check = nullptr;
  int64_t length = 0;
};
struct Packet {
  static std::string contextClass(StringRef kind) {
    if(kind=="xdp")return "XdpMd";
    if(kind=="sched_cls")return "SkBuff";
    if(kind=="flow_dissector")return "FlowCtx";
    if(kind=="cgroup_skb")return "CgroupSkb";
    return "";
  }
  std::map<std::string, Window> windows;
  Operation *def = nullptr;
  std::string param;
  std::string finalVerdict, guardVerdict;
  Operation *finalNode = nullptr;
  Value fired;
  void reset(Consumer &c, Operation *function) {
    def = function;
    windows.clear();
    finalVerdict.clear();guardVerdict.clear();finalNode=nullptr;fired={};
    auto ps = c.array(c.ref(function,"parameters"),"requireds");
    param = ps.size()==1 ? field(ps[0],"strings","name").str() : "";
  }
  std::string verdict(StringRef name,StringRef kind) {
    if(kind=="xdp")return name=="BPF::XDP_PASS"?"pass":name=="BPF::XDP_DROP"?"drop":name=="BPF::XDP_TX"?"tx":name=="BPF::XDP_ABORTED"?"aborted":"";
    if(kind=="sched_cls")return name=="BPF::TC_PASS"?"pass":name=="BPF::TC_DROP"?"drop":"";
    if(kind=="cgroup_skb")return name=="BPF::CG_ALLOW"?"allow":name=="BPF::CG_DENY"?"deny":"";
    if(kind=="flow_dissector")return name=="BPF::FLOW_OK"?"ok":name=="BPF::FLOW_DROP"?"drop":name=="BPF::FLOW_CONTINUE"?"continue":"";
    return "";
  }
  Dispatch<ProgramDecl> root(Consumer &c,Operation *n) {
    auto name=field(n,"strings","name");auto as=c.args(n);
    auto shape=[&]() {
      std::string message=name=="tcx"
          ? "a sched_cls program is declared as `BPF.tcx :name, :ingress` or `BPF.tcx :name, :egress` (two Symbol literals — the second is the tcx direction) (P019)"
          : name=="cgroup_skb"
          ? "a cgroup_skb program is declared as `BPF.cgroup_skb :name, :ingress` or `BPF.cgroup_skb :name, :egress` (two Symbol literals — the second is the direction) (E127)"
          : name=="flow_dissector"
          ? "`BPF.flow_dissector` takes exactly one Symbol literal (`BPF.flow_dissector :name` — it is attached to a network namespace in user space with `obj.attach_netns`) (E130)"
          : "`BPF.xdp` takes exactly one Symbol literal (`BPF.xdp :name`)";
#ifdef SPINEL_E046_TEST_DIAGNOSTIC_BYTE
      if(name=="flow_dissector")message.back()='!';
#endif
      (void)c.diagnostic(n,"SB008","ProgramShape",message);
      return Dispatch<ProgramDecl>::error();
    };
    if(as.empty()||text(as[0],"kind")!="SymbolNode" ||
       as.size()!=((name=="tcx"||name=="cgroup_skb")?2u:1u)) {
      return shape();
    }
    ProgramDecl p;p.kind=name=="tcx"?"sched_cls":name.str();
    p.analysisContext="obj_BPF::"+contextClass(p.kind);
    if(name=="tcx"||name=="cgroup_skb") {
      p.attachTarget=c.spelling(as[1],true).str();
      if(text(as[1],"kind")!="SymbolNode" || (p.attachTarget!="ingress"&&p.attachTarget!="egress")) {
        return shape();
      }
    }
    if(!callee(c,n,"BPF."+name.str()))return Dispatch<ProgramDecl>::error();
    auto method=c.spelling(as[0],true);
    Operation *function=nullptr;
    for(auto x:c.selectedTop)if(text(x,"kind")=="DefNode"&&field(x,"strings","name")==method)function=x;
    if(!function){(void)c.error(n,"root target must be a declared method");return Dispatch<ProgramDecl>::error();}
    reset(c,function);
    auto body=c.array(c.ref(function,"body"),"body");
    if(!body.empty()) {finalNode=body.back();auto v=finalNode;if(text(v,"kind")=="ReturnNode"){auto a=c.args(v);v=a.size()==1?a[0]:nullptr;} finalVerdict=verdict(c.constant(v),p.kind);}
    Operation *bad=nullptr;std::string badName;
    walk(c,function,[&](Operation *x){
      auto cn=c.constant(x);if(cn.empty()||!StringRef(cn).starts_with("BPF::"))return;
      auto tail=StringRef(cn).drop_front(5);
      if(!(tail.starts_with("XDP_")||tail.starts_with("TC_")||tail.starts_with("FLOW_")||tail.starts_with("CG_")||tail.starts_with("NF_")||tail.starts_with("SF_")||tail=="FMOD_CALL"))return;
      if(!verdict(cn,p.kind).empty())return;
      if(!bad||c.id(x)<c.id(bad)){bad=x;badName=cn;}
    });
    if(bad) {
      auto tail=StringRef(badName).drop_front(5);std::string label=tail.starts_with("XDP_")?"an XDP":tail.starts_with("TC_")?"a sched_cls (tcx)":tail.starts_with("FLOW_")?"a flow_dissector":tail.starts_with("CG_")?"a cgroup_skb":tail.starts_with("NF_")?"a netfilter":tail=="FMOD_CALL"?"a fmod_ret":"a socket_filter";
      std::string message;
      if(p.kind=="sched_cls"&&tail.starts_with("XDP_")) {
        bool guard=false;for(auto x=bad;x;x=c.parent(x))if(text(x,"kind")=="ReturnNode")guard=true;
        message=badName+" is an XDP verdict — a sched_cls (`BPF.tcx`) program returns BPF::TC_PASS or BPF::TC_DROP (P019)";
        if(!guard)message=badName+" is an XDP verdict — a sched_cls (`BPF.tcx`) program returns BPF::TC_PASS or BPF::TC_DROP (P019)";
      } else {
        std::string returns=p.kind=="xdp"?"an XDP program returns BPF::XDP_ABORTED / XDP_DROP / XDP_PASS / XDP_TX":p.kind=="sched_cls"?"a sched_cls (`BPF.tcx`) program returns BPF::TC_PASS or BPF::TC_DROP":p.kind=="cgroup_skb"?"a cgroup_skb program returns BPF::CG_ALLOW or BPF::CG_DENY":"a flow_dissector program returns BPF::FLOW_OK / FLOW_DROP / FLOW_CONTINUE";
        message=badName+" is "+label+" verdict — "+returns+(p.kind=="xdp"&&tail.starts_with("TC_")?" (P019)":" (P026)");
      }
      // Root validation precedes body diagnostics, as in Go program.go.
      auto saved=c.programName;c.programName=method.str();
      (void)issue(c,bad,"SB028","TracingKind",message);c.programName=saved;
      return Dispatch<ProgramDecl>::error();
    }
    // Go guard.go:30-58 / program.go:1798. Shape-only precheck does not
    // consume expressions or publish IR; failed programs have no unused-map
    // warning pass. Direct guards are the only non-final accepted returns.
    std::set<Operation *> guardReturns;
    std::string priorGuard;
    auto shapeIssue=[&](Operation *at,const std::string &message) {
      auto saved=c.programName;c.programName=method.str();
      (void)c.diagnostic(at,"SB008","ProgramShape",message,true);
      c.programName=saved;
      return Dispatch<ProgramDecl>::error();
    };
    for(auto statement:body) {
      auto k=text(statement,"kind");
      if((k!="IfNode"&&k!="UnlessNode")||c.ref(statement,"subsequent")||c.ref(statement,"else_clause"))continue;
      auto arm=c.array(c.ref(statement,"statements"),"body");
      if(arm.size()!=1||text(arm[0],"kind")!="ReturnNode")continue;
      auto ret=arm[0];guardReturns.insert(ret);auto values=c.args(ret);
      if(values.size()!=1)return shapeIssue(ret,"a guard `return` must return one "+packetVerdictWant(p.kind,"BPF::XDP_* constant")+" ("+packetVerdictWant(p.kind,"`return BPF::XDP_DROP if cond`")+")");
      auto v=verdict(c.constant(values[0]),p.kind);
      if(text(values[0],"kind")!="ConstantPathNode"||v.empty())return shapeIssue(ret,"a guard `return` must return one "+packetVerdictWant(p.kind,"BPF::XDP_* constant")+", got "+text(values[0],"kind").str());
      if(!priorGuard.empty()&&priorGuard!=v)return shapeIssue(ret,"the early returns return "+priorGuard+" and "+v+" — bpf-mlir's ebpf.verdict.if chooses between only two verdicts (the early one and the last one), so every guard returns the same verdict (E073)");
      priorGuard=v;
    }
    Operation *misplaced=nullptr;
    walk(c,function,[&](Operation *node) {
      if(text(node,"kind")=="ReturnNode"&&node!=finalNode&&!guardReturns.count(node)&&(!misplaced||c.id(node)<c.id(misplaced)))misplaced=node;
    });
    if(misplaced)return shapeIssue(misplaced,"`return` is accepted only as the last statement or as a top-level guard "+packetVerdictWant(p.kind,"`return BPF::XDP_X if cond`")+" (E073)");
    p.finalizeBody=packetFinalizeBody;
    return Dispatch<ProgramDecl>::handled(std::move(p));
  }
  bool local(Operation *n, StringRef name) {
    return text(n,"kind")=="LocalVariableReadNode" && field(n,"strings","name")==name;
  }
  bool context(Consumer &c, Operation *n) {
    if (def != c.activeDef) reset(c,c.activeDef);
    return !param.empty() && local(n,param);
  }
  Dispatch<int64_t> checkedFunctionWindow(Consumer &c, StringRef name) {
    auto window = windows.find(name.str());
    auto binding = c.bindings.find("packet:" + name.str());
    if (window == windows.end() && binding == c.bindings.end()) return Dispatch<int64_t>::declined();
    if (window == windows.end() || binding == c.bindings.end() || def != c.activeDef ||
        window->second.length < 1 || window->second.length > 65535)
      return (void)c.error(c.activeDef, "subprogram packet window is not active"), Dispatch<int64_t>::error();
    if (!c.probing) {
      auto type = binding->second.value ? dyn_cast<ebpf::PktWindowType>(binding->second.value.getType()) : ebpf::PktWindowType{};
      if (!type || type.getLen() != window->second.length)
        return (void)c.error(c.activeDef, "subprogram packet window value has a different length"), Dispatch<int64_t>::error();
    }
    return Dispatch<int64_t>::handled(window->second.length);
  }
  struct FunctionScope : PacketSubprogramScope {
    std::function<void()> restore;
    explicit FunctionScope(std::function<void()> restore) : restore(std::move(restore)) {}
    ~FunctionScope() override { restore(); }
  };
  llvm::Expected<std::unique_ptr<PacketSubprogramScope>> enterFunction(
      Consumer &c, Operation *function, StringRef contextParameter,
      std::optional<PacketFunctionWindow> window) {
    auto parameters = c.array(c.ref(function,"parameters"),"requireds");
    auto hasParameter = [&](StringRef name) {
      return llvm::any_of(parameters, [&](Operation *p) { return field(p,"strings","name") == name; });
    };
    if (!function || text(function,"kind") != "DefNode" || function != c.activeDef ||
        (!contextParameter.empty() && (!hasParameter(contextParameter) || contextClass(c.activeKind).empty())) ||
        (window && (!contextParameter.empty() || window->name.empty() || !hasParameter(window->name) || window->length < 1 ||
                    window->length > 65535 || window->name == contextParameter)))
      return llvm::createStringError("invalid subprogram packet descriptor");
    if (!contextParameter.empty() && !c.probing &&
        (!c.contextValue || c.contextValue.getType() != ebpf::ContextType::get(c.ctx,c.activeKind)))
      return llvm::createStringError("invalid subprogram context value");
    if (window && !c.probing) {
      auto type = window->value ? dyn_cast<ebpf::PktWindowType>(window->value.getType()) : ebpf::PktWindowType{};
      if (!type || type.getLen() != window->length)
        return llvm::createStringError("invalid subprogram packet window value");
    }
    auto saved = *this;
    auto savedBindings = c.bindings;
    auto scope = std::make_unique<FunctionScope>([this, &c, saved, savedBindings]() mutable {
      *this = std::move(saved);
      c.bindings = std::move(savedBindings);
    });
    reset(c,function);
    param = contextParameter.str();
    for (auto it = c.bindings.begin(); it != c.bindings.end();)
      if (StringRef(it->first).starts_with("packet:")) it = c.bindings.erase(it);
      else ++it;
    if (window) {
      windows[window->name] = {function,function,window->length};
      c.bindings["packet:"+window->name] = {function,c.analyzed.lookup(c.id(function)),window->value};
    }
    return std::unique_ptr<PacketSubprogramScope>(std::move(scope));
  }
  static LogicalResult issue(Consumer &c, Operation *n, StringRef code,
                             StringRef label, const std::string &message) {
    return c.diagnostic(n,code,label,message,true);
  }
  static DExpr error(Consumer &c, Operation *n, const std::string &s) {
    (void)c.error(n,s); return DExpr::error();
  }
  static bool literal(Consumer &c, Operation *n, StringRef role, int64_t &v) {
    if (text(n,"kind")!="IntegerNode") {
      (void)issue(c,n,"SB006","NonConstant","the "+role.str()+" must be an integer literal (P004 §1)");
      return false;
    }
    auto value=c.integer(n);
    if (failed(value)) return false;
    v=*value; return true;
  }
  static std::optional<math::Interval> finite(Consumer &c, const Expr &e) {
    auto v=e->range.interval.finite();
    if (!v) { (void)c.rangeFailure(v.takeError(),e->node); return std::nullopt; }
    return *v;
  }
  static Expr value(Operation *n, StringRef kind, unsigned bits) {
    auto e=std::make_shared<ScalarExpr>(); e->node=n; e->kind=kind.str();
    e->range.interval=math::MathInterval(math::Interval{I::from(0), I::fromUnsigned(bits==64 ? UINT64_MAX : (uint64_t(1)<<bits)-1)});
    return e;
  }
  std::string windowMessage(const std::string &name) {
    return "window `"+name+"` may be read only as `if "+name+"` and as `"+name+".u8(i)` / `be16` / `be32` / `le16` / `le32` inside it (P004 §1)";
  }
  bool callee(Consumer &c, Operation *n, const std::string &want) {
    return succeeded(c.known(n,CalleePolicy{want}));
  }
  static unsigned readBits(StringRef name) {
    return name=="u8" ? 8 : name=="be16"||name=="le16" ? 16 : name=="be32"||name=="le32" ? 32 : 0;
  }
  static std::optional<std::pair<unsigned,unsigned>> flowField(StringRef name) {
    static const std::map<std::string,std::pair<unsigned,unsigned>> fields={
      {"nhoff",{16,1}},{"thoff",{16,1}},{"addr_proto",{16,1}},
      {"is_frag",{8,1}},{"is_first_frag",{8,1}},{"is_encap",{8,1}},{"ip_proto",{8,1}},
      {"n_proto",{16,1}},{"sport",{16,1}},{"dport",{16,1}},
      {"ipv4_src",{32,1}},{"ipv4_dst",{32,1}},{"ipv6_src",{32,4}},{"ipv6_dst",{32,4}},
      {"flags",{32,1}},{"flow_label",{32,1}}};
    auto f=fields.find(name.str()); if(f==fields.end()) return std::nullopt; return f->second;
  }
  void walk(Consumer &c,Operation *n,const std::function<void(Operation*)> &visit) {
    llvm::DenseSet<int64_t> seen;
    auto recur=[&](auto &&self,Operation *x)->void {
      if(!x||!seen.insert(c.id(x)).second)return;
      visit(x);
      for(auto attr:x->getAttrOfType<DictionaryAttr>("refs")) {
        auto id=cast<IntegerAttr>(attr.getValue()).getInt();if(id>=0)self(self,c.nodes.lookup(id));
      }
      for(auto attr:x->getAttrOfType<DictionaryAttr>("arrays"))
        for(auto id:cast<ArrayAttr>(attr.getValue()))self(self,c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
    };recur(recur,n);
  }
  bool inside(Consumer &c,Operation *n,Operation *ancestor) {
    for(unsigned d=0;n&&d<128;++d,n=c.parent(n))if(n==ancestor)return true;
    return false;
  }
  struct WindowScope final : PacketLoopScope {
    Packet &packet;
    Consumer &consumer;
    std::map<std::string,Window> oldWindows;
    std::map<std::string,ScopeBinding> oldBindings;
    WindowScope(Packet &p,Consumer &c,const PacketLoopWindow &w)
        :packet(p),consumer(c),oldWindows(p.windows),oldBindings(c.bindings) {
      packet.windows[w.name]={w.binding,w.branch,w.length};
      consumer.bindings["packet:"+w.name]={
        w.binding,c.analyzed.lookup(c.id(w.binding)),{}};
    }
    ~WindowScope() override {
#ifndef SPINEL_E027_TEST_NO_PACKET_RESTORE
      packet.windows=std::move(oldWindows);
      consumer.bindings=std::move(oldBindings);
#endif
    }
  };
  llvm::Expected<std::unique_ptr<PacketLoopScope>> enterWindow(
      Consumer &c,const PacketLoopWindow &w) {
    if(!w.binding || !w.branch || !w.offset || w.name.empty() ||
       w.length<1 || w.length>65535)
      return llvm::createStringError("E027 invalid checked packet window descriptor");
    return std::unique_ptr<PacketLoopScope>(new WindowScope(*this,c,w));
  }
  LogicalResult emitWindow(Consumer &c,const PacketLoopWindow &window,
      llvm::function_ref<LogicalResult()> emitThen,
      llvm::function_ref<LogicalResult()> emitElse) {
    auto binding=window.binding,ifn=window.branch;
    auto pre=c.locals;
    auto preBorrows=c.borrows;
    Locals output;
    std::vector<bool> usedMaps,usedGlobals,usedRecords,usedRings;
    bool usedMap=false;
    {
      // Packet scope below is destroyed before this Consumer snapshot.
      ScopeGuard restore(c);
      auto yes=std::make_unique<Block>(),no=std::make_unique<Block>();
      Locals thenEnv,elseEnv;
      auto off=c.emitScalar(window.offset);if(!off)return failure();
      {
        OpBuilder::InsertionGuard insertion(c.builder);
        c.builder.setInsertionPointToStart(yes.get());
        auto scope=enterWindow(c,window);
        if(!scope)return c.rangeFailure(scope.takeError(),binding);
        if(!*scope)return c.error(binding,"E027 packet scope returned null");
        Value w=yes->addArgument(
          ebpf::PktWindowType::get(c.ctx,window.length),c.builder.getUnknownLoc());
        c.bindings["packet:"+window.name].value=w;
        if(failed(emitThen()))return failure();
        thenEnv=c.locals;
        scope->reset();
        c.locals=pre;c.borrows=preBorrows;
        c.builder.setInsertionPointToStart(no.get());
        if(failed(emitElse()))return failure();
        elseEnv=c.locals;c.locals=pre;
      }
      SmallVector<Type> types;SmallVector<Value> a,b;std::vector<std::string> names;
      range::Environment ar,br;
      for(auto &[n,l]:thenEnv)ar[n]=l.expr->range;
      for(auto &[n,l]:elseEnv)br[n]=l.expr->range;
      auto joined=range::joinEnvironment(ar,br);
      if(!joined)return c.rangeFailure(joined.takeError(),ifn);
      for(auto &[n,l]:thenEnv) {
        auto other=elseEnv.find(n);
        if(other==elseEnv.end()||!joined->count(n))continue;
        auto before=pre.find(n);
        if(before!=pre.end()&&l.value==before->second.value&&
           other->second.value==pre.at(n).value)continue;
        names.push_back(n);types.push_back(l.value.getType());
        a.push_back(l.value);b.push_back(other->second.value);
      }
      auto op=ebpf::PacketCheckOp::create(c.builder,outputLoc(binding),types,
                                        c.contextValue,off,window.length);
      op->getRegion(0).push_back(yes.release());
      op->getRegion(1).push_back(no.release());
      {
        OpBuilder::InsertionGuard insertion(c.builder);
        c.builder.setInsertionPointToEnd(&op->getRegion(0).front());
        ebpf::YieldOp::create(c.builder,outputLoc(ifn),a);
        c.builder.setInsertionPointToEnd(&op->getRegion(1).front());
        ebpf::YieldOp::create(c.builder,outputLoc(ifn),b);
      }
      for(size_t i=0;i<names.size();++i) {
        auto e=std::make_shared<ScalarExpr>(*thenEnv.at(names[i]).expr);
        e->range=range::asLocal(joined->at(names[i]));
        auto &more=elseEnv.at(names[i]).expr->reads;
        e->reads.insert(e->reads.end(),more.begin(),more.end());
        c.locals[names[i]]={e,op->getResult(i)};
      }
      output=c.locals;usedMap=c.usedMap;
      for(auto &m:c.maps)usedMaps.push_back(m.used);
      for(auto &g:c.globals)usedGlobals.push_back(g.used);
      for(auto &r:c.records)usedRecords.push_back(r.used);
      for(auto &r:c.rings)usedRings.push_back(r.used);
    }
    c.locals=std::move(output);c.usedMap=usedMap;
    for(size_t i=0;i<usedMaps.size();++i)c.maps[i].used=usedMaps[i];
    for(size_t i=0;i<usedGlobals.size();++i)c.globals[i].used=usedGlobals[i];
    for(size_t i=0;i<usedRecords.size();++i)c.records[i].used=usedRecords[i];
    for(size_t i=0;i<usedRings.size();++i)c.rings[i].used=usedRings[i];
    return success();
  }
  Dispatch<PacketLoopWindow> checkWindow(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    using Result=Dispatch<PacketLoopWindow>;
    if(index>=list.size())return Result::declined();
    auto ps=c.array(c.ref(c.activeDef,"parameters"),"requireds");
    std::string parameter=ps.size()==1?field(ps[0],"strings","name").str():"";
    auto binding=list[index];auto call=c.ref(binding,"value");
    if(text(binding,"kind")!="LocalVariableWriteNode"||text(call,"kind")!="CallNode"||field(call,"strings","name")!="check"||!local(c.ref(call,"receiver"),parameter))return Result::declined();
    auto wn=field(binding,"strings","name").str();auto as=c.args(call);
    auto fail=[&](Operation *n,StringRef code,StringRef label,const std::string &message){(void)issue(c,n,code,label,message);return Result::error();};
    if(index+1>=list.size() || text(list[index+1],"kind")!="IfNode" || !local(c.ref(list[index+1],"predicate"),wn))
      return fail(binding,"SB005","RefCheckShape","`"+wn+" = "+parameter+".check(off, len)` must be followed immediately by `if "+wn+"` (the in-range / out-of-range check — P004 §1)");
    auto ifn=list[index+1];
    unsigned writes=0;walk(c,c.activeDef,[&](Operation *n){if((text(n,"kind")=="LocalVariableWriteNode"||text(n,"kind")=="LocalVariableOperatorWriteNode")&&field(n,"strings","name")==wn)++writes;});
    if(writes>1)return fail(binding,"SB005","RefCheckShape","`"+wn+"` is typed \"untyped\", not BPF::Window — `"+wn+"` is reassigned elsewhere in `"+c.programName+"` ("+std::to_string(writes)+" assignments), which makes Spinel widen its type; a window is bound once");
    if(c.locals.count(wn)||c.borrows.count(wn)||windows.count(wn))return fail(binding,"SB005","RefCheckShape","`"+wn+"` is already a local — a window needs a fresh name");
    if(c.ref(call,"block"))return fail(call,"SB005","RefCheckShape","`check` takes no block — write `"+wn+" = "+parameter+".check(off, len)` then `if "+wn+"` (P004 §1)");
    auto klass=contextClass(c.activeKind);
    if(klass.empty())return Result::declined();
    if(!callee(c,call,klass+"#check"))return Result::error();
    if(as.size()!=2)return fail(call,"SB002","UnsupportedCall","`check` takes exactly two arguments (offset, length)");
    int64_t len;if(!literal(c,as[1],"window length",len))return Result::error();
    if(len<1||len>65535)return fail(as[1],"SB022","WindowIndex","the window length "+std::to_string(len)+" is outside [1, 65535] (P004 §2)");
    auto off=c.scalar(as[0]);if(failed(off))return Result::error();auto iv=finite(c,*off);if(!iv)return Result::error();
    if((*off)->range.isBool||(*off)->range.wide)return fail(as[0],"SB001","UnsupportedConstruct","the window offset must be an Integer (not a bool, not an unnarrowed u64 value)");
#ifndef SPINEL_E015_TEST_NO_OFFSET_RANGE
    if(!iv->within({I::from(0),I::from(65535-len)}))
      return fail(as[0],"SB023","PacketOffset","the window offset's range "+iv->str()+" is not within [0, "+std::to_string(65535-len)+"] (65535 − "+std::to_string(len)+") — a negative offset does not count from the end of the packet (unlike Ruby's a[-1]) and would silently give nil, Ruby does not wrap, and a packet offset beyond 0xffff has no meaning; narrow it (e.g. `x & 0xFFF`) (P004 §2)");
#endif
    // Validate all uses before region construction, including uses after an
    // adjust. Scope is source ancestry, never the numeric range of a value.
    Operation *bad=nullptr;walk(c,c.activeDef,[&](Operation *n){
      if(!local(n,wn)||n==c.ref(ifn,"predicate"))return;
      auto parent=c.parent(n);
      if(text(parent,"kind")=="ArgumentsNode") {
        auto call=c.parent(parent);
        if(inside(c,n,c.ref(ifn,"statements")) && isSubprogramCall(c,call))return;
      }
      if(inside(c,n,c.ref(ifn,"statements"))&&text(parent,"kind")=="CallNode"&&
         (c.ref(parent,"receiver")==n || isSubprogramCall(c,parent)))return;
      if(!bad||c.id(n)<c.id(bad))bad=n;
    });
    if(bad)return fail(bad,"SB005","RefCheckShape",windowMessage(wn));
    return Result::handled({binding,ifn,*off,len,wn,2});
  }
  DStmt check(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    auto checked=checkWindow(c,list,index,depth);
    if(checked.state==Disposition::Declined)return DStmt::declined();
    if(checked.state==Disposition::Error)return DStmt::error();
    const auto &window=*checked.value;
    auto prior=windows;
    windows[window.name]={window.binding,window.branch,window.length};
    auto result=emitWindow(c,window,
      [&]{return c.scalarBody(c.ref(window.branch,"statements"),depth+1);},
      [&]{
        auto sub=c.ref(window.branch,"subsequent");
        if(sub&&text(sub,"kind")!="ElseNode")
          return issue(c,sub,"SB005","RefCheckShape","`elsif` is not accepted after `if "+window.name+"` (P004 §1)");
        return c.scalarBody(c.ref(sub,"statements"),depth+1);
      });
    if(failed(result)){windows=std::move(prior);return DStmt::error();}
    return DStmt::handled({window.consumed});
  }
  std::shared_ptr<PacketValue> flowArgs(Consumer &c, Operation *n,
                                      ArrayRef<Operation*> args, StringRef method) {
    auto fail=[&](Operation *at,StringRef code,const std::string &message){
      (void)issue(c,at,code,code=="SB014"?"SemanticGap":"UnsupportedCall",message);
      return std::shared_ptr<PacketValue>();
    };
    if(args.empty() || text(args[0],"kind")!="SymbolNode")
      return fail(n,"SB002","`"+param+"."+method.str()+"` takes the flow key's name as a Symbol literal (`:nhoff`, `:ipv4_src`, `:ipv6_src` with an index …) (E130)");
    auto name=c.spelling(args[0],true).str(); auto f=flowField(name);
    if(!f) return fail(args[0],"SB002","`:"+name+"` is not a field of struct bpf_flow_keys (nhoff thoff addr_proto is_frag is_first_frag is_encap ip_proto n_proto sport dport ipv4_src ipv4_dst ipv6_src[i] ipv6_dst[i] flags flow_label) (E130)");
    auto payload=std::make_shared<PacketValue>();payload->field=name;payload->bits=f->first;
    if(f->second==4) {
      if(args.size()!=2) return fail(n,"SB002","`:"+name+"` has 4 elements — give an Integer literal index 0..3 (`"+param+"."+method.str()+"(:"+name+", i…)`) (E130)");
      if(text(args[1],"kind")!="IntegerNode") return fail(args[1],"SB014","the index of `:"+name+"` is an Integer literal 0..3 (E130)");
      auto i=c.integer(args[1]);if(failed(i))return {};
      if(*i<0||*i>3)return fail(args[1],"SB014","the index of `:"+name+"` is an Integer literal 0..3 (E130)");
      payload->index=*i;
    } else if(args.size()!=1) return fail(n,"SB002","`:"+name+"` has no index (E130)");
    return payload;
  }
  DExpr expression(Consumer &c, Operation *n) {
    if(contextClass(c.activeKind).empty()) {
      auto receiver = c.ref(n,"receiver");
      auto name = text(n,"kind")=="LocalVariableReadNode" ? field(n,"strings","name")
          : text(receiver,"kind")=="LocalVariableReadNode" ? field(receiver,"strings","name") : StringRef{};
      if(c.activeKind!="func" || def!=c.activeDef || !windows.count(name.str()))return DExpr::declined();
    }
    if(text(n,"kind")=="LocalVariableReadNode") {
      auto name=field(n,"strings","name").str();
      if(windows.count(name)) {(void)issue(c,n,"SB005","RefCheckShape",windowMessage(name));return DExpr::error();}
      return DExpr::declined();
    }
    if(text(n,"kind")!="CallNode") return DExpr::declined();
    auto name=field(n,"strings","name"); auto recv=c.ref(n,"receiver");auto args=c.args(n);
    if(context(c,recv)) {
      if(name=="len" || name=="mark" || name=="ingress_ifindex") {
        if((c.activeKind=="xdp" && name!="ingress_ifindex") ||
           (c.activeKind=="sched_cls" && name=="ingress_ifindex") || c.activeKind=="flow_dissector")
          return unsupportedContext(c,n,name);
        if((c.activeKind=="cgroup_skb"&&name!="len") || !args.empty())return unsupportedContext(c,n,name);
        auto klass=contextClass(c.activeKind);
        if(!callee(c,n,klass+"#"+name.str())) return DExpr::error();
        auto e=value(n,"packet.ctx",32);auto p=std::make_shared<PacketValue>();p->field=name.str();p->bits=32;e->payload=p;return DExpr::handled(e);
      }
      if(c.activeKind=="flow_dissector" && name=="key") {
        if(!callee(c,n,"FlowCtx#key")) return DExpr::error();
        auto p=flowArgs(c,n,args,name);if(!p)return DExpr::error();
        auto e=value(n,"packet.flow",p->bits);e->payload=p;return DExpr::handled(e);
      }
      if(name=="set_key" && c.activeKind=="flow_dissector") {
        (void)issue(c,n,"SB002","UnsupportedCall","`"+param+".set_key(…)` is a statement — not a value (E130)");return DExpr::error();
      }
      if(name=="adjust_head"||name=="adjust_tail") {
        if(c.activeKind!="xdp") {
          (void)issue(c,n,"SB002","UnsupportedCall","call `"+name.str()+"` is not accepted on the eBPF side");return DExpr::error();
        }
        auto binding=c.parent(n);auto st=c.parent(binding);
        if(text(binding,"kind")!="LocalVariableWriteNode" || c.ref(binding,"value")!=n) {
          auto call=param+"."+name.str()+"(d)";
          (void)issue(c,n,"SB026","StatusIgnored","the status of `"+call+"` (0 or −errno) is accepted only as `st = "+call+"` (read later) or `_ = "+call+"` — not as an argument, an operand or another value (E122)");return DExpr::error();
        }
        if(st!=c.ref(c.activeDef,"body")) {
          auto variable=field(binding,"strings","name").str();
          (void)issue(c,binding,"SB002","UnsupportedCall","`"+variable+" = "+param+"."+name.str()+"(d)` is accepted only as a statement directly in the program's body — not inside an arm or a loop (the helper invalidates the packet windows; decide the delta in the arm and move the packet at the top level) (E122)");return DExpr::error();
        }
        if(!callee(c,n,"XdpMd#"+name.str())||args.size()!=1)return DExpr::error();
        if(name=="adjust_tail" && (text(args[0],"kind")!="IntegerNode" || failed(c.integer(args[0])) || *c.integer(args[0])>0)) {
          (void)issue(c,args[0],"SB014","SemanticGap","`"+param+".adjust_tail(k)` takes an Integer literal k ≤ 0 (it only shrinks the tail; bpf-mlir accepts only a constant non-positive delta — E208) (E123)");return DExpr::error();
        }
        auto a=c.scalar(args[0]);if(failed(a))return DExpr::error();auto iv=finite(c,*a);if(!iv)return DExpr::error();
        if(!iv->within({I::from(INT32_MIN),I::from(INT32_MAX)})) {
          (void)issue(c,args[0],"SB014","SemanticGap","the delta's range "+iv->str()+" does not fit the helper's int (i32 [-2147483648, 2147483647]) — narrow it (E122)");return DExpr::error();
        }
        auto e=value(n,"packet.adjust",32);e->op=name.str();e->args={*a};
        e->range.interval=math::MathInterval({I::from(-4095),I::from(0)});return DExpr::handled(e);
      }
      if(readBits(name)) {
        (void)issue(c,n,"SB002","UnsupportedCall","the context has no `"+name.str()+"` — packet reads go through a checked window (`w = "+param+".check(off, len)`, `if w`, `w."+name.str()+"(i)`) (P004 §1)");return DExpr::error();
      }
      return unsupportedContext(c,n,name);
    }
    if(text(recv,"kind")=="LocalVariableReadNode") {
      auto w=windows.find(field(recv,"strings","name").str());
      if(w!=windows.end()) {
        auto wn=w->first; auto active=c.bindings.find("packet:"+wn);
        if(active==c.bindings.end()) {
          (void)issue(c,recv,"SB005","RefCheckShape",windowMessage(wn));return DExpr::error();
        }
        auto bits=readBits(name);
        if(!bits) { (void)issue(c,n,"SB002","UnsupportedCall","call `"+name.str()+"` is not accepted on the eBPF side");return DExpr::error(); }
        if(!callee(c,n,"Window#"+name.str())||args.size()!=1)return DExpr::error();
        int64_t index;if(!literal(c,args[0],"window index",index))return DExpr::error();
        if(index<0 || index>w->second.length-bits/8) {
          (void)issue(c,args[0],"SB022","WindowIndex","`"+wn+"."+name.str()+"("+std::to_string(index)+")` reads bytes ["+std::to_string(index)+", "+std::to_string(index+bits/8)+") outside the window [0, "+std::to_string(w->second.length)+") (P004 §1)");return DExpr::error();
        }
        auto e=value(n,"packet.load",bits);e->name=wn;e->op=name.str();auto p=std::make_shared<PacketValue>();p->bits=bits;p->index=index;e->payload=p;return DExpr::handled(e);
      }
    }
    return DExpr::declined();
  }
  Dispatch<Value> emit(Consumer &c,const Expr &e) {
    auto loc=outputLoc(e->node);auto &b=c.builder;auto i64=b.getI64Type();Value raw;
    if(e->kind=="packet.adjust") {
      auto a=c.emitScalar(e->args[0]);if(!a)return Dispatch<Value>::error();
      if(e->op=="adjust_tail") {
        auto lit=e->args[0]->range.interval.finite();if(!lit)return Dispatch<Value>::error();
        auto v=c.integer(e->args[0]->node);if(failed(v))return Dispatch<Value>::error();
        // Tail requires the literal i32 operand itself, not a truncation.
        if(auto op=a.getDefiningOp();op&&op->use_empty())op->erase();
        a=arith::ConstantIntOp::create(b,loc,*v,32);
        raw=ebpf::XdpAdjustTailOp::create(b,loc,i64,c.contextValue,a);
      }
      else {a=arith::TruncIOp::create(b,loc,b.getI32Type(),a);raw=ebpf::XdpAdjustHeadOp::create(b,loc,i64,c.contextValue,a);}
      return Dispatch<Value>::handled(raw);
    }
    auto &p=static_cast<const PacketValue&>(*e->payload);auto type=b.getIntegerType(p.bits);
    if(e->kind=="packet.ctx")raw=ebpf::CtxFieldOp::create(b,loc,type,c.contextValue,p.field,IntegerAttr{});
    else if(e->kind=="packet.flow")raw=ebpf::FlowKeysLoadOp::create(b,loc,type,c.contextValue,p.field,p.index<0?IntegerAttr{}:b.getI64IntegerAttr(p.index));
    else if(e->kind=="packet.load") {
      auto w=c.bindings.find("packet:"+e->name);if(w==c.bindings.end())return Dispatch<Value>::error();
      raw=ebpf::PacketWindowLoadOp::create(b,loc,type,w->second.value,p.index);
      if(StringRef(e->op).starts_with("be"))raw=ebpf::ByteorderFromBeOp::create(b,loc,type,raw);
    } else return Dispatch<Value>::declined();
    return Dispatch<Value>::handled(arith::ExtUIOp::create(b,loc,i64,raw));
  }
  DStmt statement(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    if(contextClass(c.activeKind).empty())return DStmt::declined();
    auto n=list[index];auto kind=text(n,"kind");
    if(def!=c.activeDef)reset(c,c.activeDef);
    if(kind=="LocalVariableWriteNode")return check(c,list,index,depth);
    if(kind=="IfNode"||kind=="UnlessNode") {
      auto predicate=c.ref(n,"predicate");
      while(text(predicate,"kind")=="ParenthesesNode") {
        auto values=c.array(c.ref(predicate,"body"),"body");
        if(values.size()!=1)break;
        predicate=values.front();
      }
      if(text(predicate,"kind")=="LocalVariableWriteNode") {
        auto variable=field(predicate,"strings","name").str();
        (void)issue(c,n,"SB005","RefCheckShape","an assignment inside the condition is not accepted — write `"+variable+" = …` on its own line, then `if "+variable+"` (P004 §1 (a))");return DStmt::error();
      }
      auto body=c.array(c.ref(n,"statements"),"body");
      if(depth||body.size()!=1||text(body[0],"kind")!="ReturnNode"||c.ref(n,"subsequent")||c.ref(n,"else_clause"))return DStmt::declined();
      auto a=c.args(body[0]);if(a.size()!=1)return DStmt::error();auto v=verdict(c.constant(a[0]),c.activeKind);
      if(v.empty()||(!guardVerdict.empty()&&guardVerdict!=v)){(void)c.error(body[0],"guard verdict differs from prior early return");return DStmt::error();}
      guardVerdict=v;auto cond=c.scalar(c.ref(n,"predicate"));if(failed(cond)||!(*cond)->range.isBool)return DStmt::error();
      auto cv=c.emitScalar(*cond);if(!cv)return DStmt::error();
      if(kind=="UnlessNode")cv=arith::XOrIOp::create(c.builder,outputLoc((*cond)->node),cv,arith::ConstantIntOp::create(c.builder,outputLoc((*cond)->node),1,1));
      auto pre=c.locals;auto old=c.borrows;auto binds=c.bindings;
      auto yes=std::make_unique<Block>(),no=std::make_unique<Block>();Value aValue,bValue;
      {
        OpBuilder::InsertionGuard guard(c.builder);
        c.builder.setInsertionPointToStart(yes.get());aValue=arith::ConstantIntOp::create(c.builder,outputLoc(n),1,1);
        ebpf::IfYieldOp::create(c.builder,outputLoc(n),ValueRange{aValue});
        c.builder.setInsertionPointToStart(no.get());
        if(failed(c.refineLocals(*cond,kind=="UnlessNode")))return DStmt::error();
        auto rest=list.drop_front(index+1);if(!rest.empty()&&rest.back()==finalNode)rest=rest.drop_back();
        auto oldFired=fired;fired={};
        if(failed(c.scalarStatements(rest,depth)))return DStmt::error();
        bValue=fired?fired:arith::ConstantIntOp::create(c.builder,outputLoc(n),0,1).getResult();
        ebpf::IfYieldOp::create(c.builder,outputLoc(n),ValueRange{bValue});fired=oldFired;
        c.locals=pre;c.borrows=old;c.bindings=binds;
      }
      auto op=ebpf::IfOp::create(c.builder,outputLoc(n),TypeRange{c.builder.getI1Type()},cv);
      op->getRegion(0).push_back(yes.release());op->getRegion(1).push_back(no.release());fired=op->getResult(0);
      if(list.back()==finalNode)ebpf::VerdictIfOp::create(c.builder,outputLoc(finalNode),fired,guardVerdict,finalVerdict);
      return DStmt::handled({list.size()-index});
    }
    if(kind=="CallNode") {
      auto name=field(n,"strings","name");auto recv=c.ref(n,"receiver");auto as=c.args(n);
      if(context(c,recv)&&name=="check") {
        (void)issue(c,n,"SB005","RefCheckShape","`check` must be assigned to a local and checked with `if` (`w = "+param+".check(off, len)` then `if w` — no block form) (P004 §1)");return DStmt::error();
      }
      if(context(c,recv)&&c.activeKind=="xdp"&&(name=="adjust_head"||name=="adjust_tail")) {
        auto call=param+"."+name.str()+"(d)";
        (void)issue(c,n,"SB026","StatusIgnored","the status of `"+call+"` (0 or −errno) is dropped — use `st = "+call+"` (read later) or `_ = "+call+"` (E122)");return DStmt::error();
      }
      bool store=context(c,recv)&&((name=="set_key"&&c.activeKind=="flow_dissector")||(name=="mark="&&c.activeKind=="sched_cls"));
      if(store) {
        std::shared_ptr<PacketValue> p;
        if(name=="set_key") {if(as.size()<2){(void)c.error(n,"set_key requires field and value");return DStmt::error();}p=flowArgs(c,n,ArrayRef<Operation*>(as).drop_back(),name);}
        else {p=std::make_shared<PacketValue>();p->bits=32;p->field="mark";}
        if(!p||!callee(c,n,name=="set_key"?"FlowCtx#set_key":"SkBuff#mark="))return DStmt::error();
        auto e=c.scalar(as.back());if(failed(e))return DStmt::error();auto iv=finite(c,*e);if(!iv)return DStmt::error();
        math::Interval allowed{I::from(0),I::fromUnsigned((uint64_t(1)<<p->bits)-1)};
        if((*e)->range.isBool||(*e)->range.wide||!iv->within(allowed)) {
          auto message=name=="set_key"?"the value's range "+iv->str()+" does not fit bpf_flow_keys."+p->field+" (u"+std::to_string(p->bits)+" "+allowed.str()+") — the store would truncate silently; narrow it (E130)":"the value's range "+iv->str()+" does not fit __sk_buff.mark (u32 [0, 4294967295]) — the store would truncate silently; narrow it (e.g. `& 0xFFFF_FFFF`) (E120)";
          (void)issue(c,as.back(),"SB014","SemanticGap",message);return DStmt::error();
        }
        auto v=c.emitScalar(*e);if(!v)return DStmt::error();
        v=arith::TruncIOp::create(c.builder,outputLoc(n),c.builder.getIntegerType(p->bits),v);
        if(name=="set_key")ebpf::FlowKeysStoreOp::create(c.builder,outputLoc(n),c.contextValue,p->field,p->index<0?IntegerAttr{}:c.builder.getI64IntegerAttr(p->index),v);
        else ebpf::CtxFieldStoreOp::create(c.builder,outputLoc(n),c.contextValue,p->field,v);
        return DStmt::handled({1});
      }
      if(text(recv,"kind")=="LocalVariableReadNode"&&windows.count(field(recv,"strings","name").str())&&!readBits(name)) {
        (void)issue(c,n,"SB002","UnsupportedCall","call `"+name.str()+"` is not accepted on the eBPF side");return DStmt::error();
      }
      if(context(c,recv)) {
        (void)unsupportedContext(c,n,name);return DStmt::error();
      }
    }
    auto v=n;
    if(kind=="ReturnNode"){auto as=c.args(n);if(as.size()!=1&&depth==0&&index+1==list.size()){(void)packetEndingDiagnostic(c,n);return DStmt::error();}v=as.size()==1?as[0]:nullptr;}
    auto name=verdict(c.constant(v),c.activeKind);
    if(!name.empty()&&index+1==list.size()&&depth==0) {
      ebpf::VerdictOp::create(c.builder,outputLoc(n),name);return DStmt::handled({1});
    }
    return DStmt::declined();
  }
  static DExpr unsupportedContext(Consumer &c,Operation *n,StringRef name) {
    (void)issue(c,n,"SB002","UnsupportedCall","call `"+name.str()+"` is not accepted on the eBPF side");
    return DExpr::error();
  }
};
} // namespace

void registerGroupC(Registry &registry) {
  auto packet=std::make_shared<Packet>();
  auto hooks=std::make_shared<PacketLoopHooks>();
  hooks->check=[packet](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){
    return packet->checkWindow(c,list,i,depth);
  };
  hooks->enterCheck=[packet](Consumer &c,const PacketLoopWindow &w){
    return packet->enterWindow(c,w);
  };
  hooks->emit=[packet](Consumer &c,const PacketLoopWindow &w,
      llvm::function_ref<LogicalResult()> yes,
      llvm::function_ref<LogicalResult()> no){
    return packet->emitWindow(c,w,yes,no);
  };
  registry.packetLoop=std::move(hooks);
  auto functions=std::make_shared<PacketSubprogramHooks>();
  functions->checkedWindow=[packet](Consumer &c,StringRef name){return packet->checkedFunctionWindow(c,name);};
  functions->enter=[packet](Consumer &c,Operation *def,StringRef param,std::optional<PacketFunctionWindow> w){
    return packet->enterFunction(c,def,param,std::move(w));
  };
  registry.packetSubprogram=std::move(functions);
  registry.addExpression("CallNode",[packet](Consumer &c,Operation *n){return packet->expression(c,n);});
  registry.addExpression("LocalVariableReadNode",[packet](Consumer &c,Operation *n){return packet->expression(c,n);});
  for(auto kind:{"LocalVariableWriteNode","CallNode","IfNode","UnlessNode","ConstantPathNode","ReturnNode"})
    registry.addStatement(kind,[packet](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){return packet->statement(c,list,i,depth);});
  for(auto method:{"xdp","tcx","flow_dissector","cgroup_skb"})
    registry.addRoot(method,[packet](Consumer &c,Operation *n){return packet->root(c,n);});
  for(auto kind:{"packet.ctx","packet.flow","packet.load","packet.adjust"})
    registry.addEmitter(kind,[packet](Consumer &c,const Expr &e){return packet->emit(c,e);});
}
} // namespace spinel::consumer
