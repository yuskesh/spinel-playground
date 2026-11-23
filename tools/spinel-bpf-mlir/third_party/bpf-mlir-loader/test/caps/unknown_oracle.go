// Scaffolding only. Probe and cache decisions are extracted verbatim from the
// pinned kload source by unknown-probes.sh. No C code supplies oracle decisions.
package main

import (
 "fmt"
 "sync"
 "github.com/cilium/ebpf"
 "github.com/cilium/ebpf/btf"
 "github.com/yuskesh/go-bpf-mlir/requirements"
)
type LiveCaps struct{}
var family,mode,loads,maps int
var mapFieldMu,argTagMu sync.Mutex
var mapFieldCache map[string]mapFieldResult
var argTagCache map[string]argTagResult
var nullableOnce sync.Once
var nullableMarks bool
var nullableErr error
func stubKMO()btf.MarshalOptions{return btf.MarshalOptions{ReplaceDeclTags:family==1 && mode==2}}
func newFieldMap(name string,value btf.Type)(*ebpf.Map,error){
 maps++
 if mode==9{return nil,fmt.Errorf("creating map: load BTF: load btf: invalid argument: invalid btf")}
 if mode==10{return nil,fmt.Errorf("creating map: load BTF: detect support for Map BTF (Var/Datasec): input/output error")}
 if (mode==2 && maps==1)||(mode==3 && maps==2){return nil,fmt.Errorf("creating map: map create: operation not permitted (MEMLOCK may be too low, consider rlimit.RemoveMemlock)")}
 return nil,nil // Map.Close explicitly accepts a nil receiver.
}
func loadMapFieldProbe(pt ebpf.ProgramType,m *ebpf.Map)probeOutcome{
 i:=loads;loads++
 if mode==4 && i==0{return probeOutcome{verifierReject:true,text:"reject:EINVAL:invalid control"}}
 if mode==5 && i==2{return probeOutcome{verifierReject:true,text:"reject:EINVAL:invalid xdp"}}
 if mode==6 && i==1{return probeOutcome{text:"error:load program: operation not permitted"}}
 if mode!=7 && i==1{return probeOutcome{verifierReject:true,text:"reject:EINVAL:invalid field"}}
 return probeOutcome{accepted:true,text:"accept"}
}
func loadArgTagProbe(tags [][]string)(string,error){
 i:=loads;loads++
 if (mode==3 && i==0)||(mode==5 && i==1){return "",fmt.Errorf("argument-tag probe did not reach the verifier: load program: operation not permitted: %w",requirements.ErrUnknown)}
 if i==0{if mode==4{return "invalid control",nil};return memOrNull,nil}
 if mode==7{return "accept",nil};if mode==8{return memOrNull,nil};return "invalid tagged",nil
}
func loadNullableProbe(tp string,arg int16)(string,error){
 i:=loads;loads++
 if (mode==0 && i==0)||(mode==2 && i==1){return "",fmt.Errorf("nullable-argument probe (%s) did not reach the verifier: load program: operation not permitted: %w",tp,requirements.ErrUnknown)}
 if i==0{if mode==1{return "invalid mem access control",nil};return "accept",nil}
 if mode==4{return "accept",nil};if mode==5{return "invalid mem access 'or_null'",nil};return "invalid mem access other",nil
}
func main(){
 for family=0;family<3;family++{n:=9;if family==0{n=11};if family==2{n=6};for mode=0;mode<n;mode++{
  loads=0;maps=0;mapFieldCache=map[string]mapFieldResult{};argTagCache=map[string]argTagResult{};nullableOnce=sync.Once{}
  call:=func(name string)(bool,error){
   id:=int64(ebpf.XDP);if mode==0{id=int64(ebpf.StructOps)}
   if family==0{field:="bpf_timer";if mode==1{field="bad"};return (LiveCaps{}).AllowsMapField(name,id,field)}
   if family==1{tag:="arg:nonnull";if mode==1{tag="bad"};return (LiveCaps{}).HasArgTagSemantics(name,id,tag,"mem")}
   return (LiveCaps{}).MarksNullableTPArgs()
  }
  v,err:=call("struct_ops");oldloads,oldmaps:=loads,maps;v2,e2:=call("alias")
  if v2!=v || fmt.Sprint(e2)!=fmt.Sprint(err) || oldloads!=loads || oldmaps!=maps{panic("Go cache changed")}
  rc,val,msg:=0,0,"";if err!=nil{rc=1;msg=err.Error()};if v{val=1}
  fmt.Printf("%d/%d\t%d\t%d\t%s\n",family,mode,rc,val,msg)
 }}
}
