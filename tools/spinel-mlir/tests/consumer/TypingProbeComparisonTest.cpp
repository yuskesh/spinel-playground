#include "spinel/Conversion/TypingProbeComparison.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/raw_ostream.h"
#include <iostream>
using namespace spinel::consumer;
int main() {
  const std::string before=R"({"types":[{"file":"x.rb","line":2,"col":3,"end_line":2,"end_col":8,"kind":"CallNode","name":"|","type":"poly","rbs":"untyped"}],"diagnostics":[],"codegen":[]})";
  const std::string after=R"({"types":[{"file":"x.rb","line":2,"col":3,"end_line":2,"end_col":8,"kind":"CallNode","name":"|","type":"int","rbs":"Integer"}],"diagnostics":[],"codegen":[]})";
  ProbeSpan span{"x.rb",2,3,2,8,"CallNode"};
  auto bad=compareTypingProbe(before,after,"x.rb",3,{}, {span});
  if(!bad){llvm::consumeError(bad.takeError());return 1;}
  if(bad->size()!=1||bad->front().message.find("without: \"||untyped|\", with: \"||Integer|\"")==std::string::npos)return 2;
  auto same=compareTypingProbe(after,after,"x.rb",3,{},{});if(!same){llvm::consumeError(same.takeError());return 3;}if(!same->empty())return 4;
  auto encode=[](const llvm::json::Value &v){std::string s;llvm::raw_string_ostream os(s);os<<v;return s;};
  auto reject=[&](const std::string &a,const std::string &b,const char *name){auto result=compareTypingProbe(a,b,"x.rb",3,{}, {span});if(result){std::cerr<<"FAIL accepted "<<name<<"\n";return false;}auto message=llvm::toString(result.takeError());return !message.empty();};
  auto unknown=llvm::cantFail(llvm::json::parse(after));(*unknown.getAsObject()->getArray("types"))[0].getAsObject()->operator[]("file")="ghost.rb";
  if(!reject(encode(unknown),encode(unknown),"unknown source file"))return 5;
  for(const char *key:{"diagnostics","codegen"}){auto v=llvm::cantFail(llvm::json::parse(before));v.getAsObject()->erase(key);if(!reject(encode(v),after,key))return 6;}
  for(const char *key:{"type","name","owner","signature","singleton","widened"}){auto v=llvm::cantFail(llvm::json::parse(before));(*v.getAsObject()->getArray("types"))[0].getAsObject()->operator[](key)=42;if(!reject(encode(v),after,key))return 7;}
  for(const char *key:{"type","end_col"}){auto v=llvm::cantFail(llvm::json::parse(before));(*v.getAsObject()->getArray("types"))[0].getAsObject()->erase(key);if(!reject(encode(v),after,key))return 8;}
  const std::string empty=R"({"types":[],"diagnostics":[],"codegen":[]})";if(!reject(empty,empty,"zero compared records"))return 9;
  std::cout<<"PASS typing-probe real delimiter / unchanged / strict shapes / unknown files / zero target\n";
}
