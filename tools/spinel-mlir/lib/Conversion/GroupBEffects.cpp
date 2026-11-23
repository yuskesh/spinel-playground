#include "spinel/Conversion/GroupBEffects.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
namespace spinel::consumer::groupb {
Dispatch<MapEffect> checkMapEffect(Consumer &c,Operation *node) {
  auto name=field(node,"strings","name");
  if(text(node,"kind")!="CallNode" || (name!="update"&&name!="atomic_add"))
    return Dispatch<MapEffect>::declined();
  auto receiver=c.constant(c.ref(node,"receiver"));
  auto found=llvm::find_if(c.maps,[&](auto &m){return m.name==receiver;});
  if(found==c.maps.end())return Dispatch<MapEffect>::declined();
  if(found->kind!="array"&&found->kind!="percpu_array")
    return Dispatch<MapEffect>::declined();
  ScopeGuard restore(c);
  size_t map=found-c.maps.begin();
  if(failed(c.knownMap(node,map)))return Dispatch<MapEffect>::error();
  auto args=c.args(node);
  if(args.size()!=2)return (void)c.error(node,"map store requires two arguments"),Dispatch<MapEffect>::error();
  if(failed(c.rmwFirst(node,args[0],args[1],map,name=="update")))
    return Dispatch<MapEffect>::error();
  auto key=c.checkedMapKey(map,llvm::ArrayRef<Operation*>(args).take_front(1),node);
  if(failed(key))return Dispatch<MapEffect>::error();
  auto value=c.scalar(args[1]);
  if(failed(value)||failed(c.checked(range::checkStoreValue((*value)->range,
      c.rangeMap(map),{c.id(args[1])},name=="atomic_add"?"delta":"value"),args[1])))
    return Dispatch<MapEffect>::error();
  return Dispatch<MapEffect>::handled({node,map,*key,*value,name=="update"});
}
LogicalResult emitMapEffect(Consumer &c,const MapEffect &effect) {
  auto key=c.emitMapKey(effect.key,effect.map);
  auto value=c.scalarStore(effect.value,effect.map);
  if(!key||!value)return failure();
  auto &map=c.maps[effect.map];
  map.used=true;c.usedMap=true;
#ifdef SPINEL_E027_TEST_DROP_MAP_EFFECT
  if(!effect.update)return success();
#endif
  if(effect.update)ebpf::MapUpdateOp::create(c.builder,outputLoc(effect.node),map.value,key,value);
  else ebpf::MapAtomicAddOp::create(c.builder,outputLoc(effect.node),map.value,key,value);
  map.used=true;c.usedMap=true;
  return success();
}
}
