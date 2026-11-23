#include "spinel/Conversion/Inspection.h"
#include <cstdio>
using namespace spinel::inspection;
static unsigned failures;
static void same(const std::string &got, const std::string &want, const char *name) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s\nGOT:\n%s\nWANT:\n%s\n", name, got.c_str(), want.c_str());
    ++failures;
  }
}
int main() {
  same(quote("<top>&>"), "\"\\u003ctop\\u003e\\u0026\\u003e\"", "domain-go-html-escape");
  same(quote("\"\\\b\f\n\r\t\x01/"), "\"\\\"\\\\\\b\\f\\n\\r\\t\\u0001/\"", "domain-control-escape");
  same(quote("\xe2\x80\xa8\xe2\x80\xa9"), "\"\\u2028\\u2029\"", "domain-javascript-separators");
  same(quote(std::string("\xc0\x80\xff",3)), "\"\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\"", "domain-invalid-utf8-per-byte");
  same(quote("\xe6\x97\xa5\xf0\x9f\x98\x80"), "\"\xe6\x97\xa5\xf0\x9f\x98\x80\"", "domain-valid-utf8");
  same(quote(std::string("\xed\xa0\x80",3)), "\"\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\"", "domain-invalid-surrogate");
  Domain d;
  d.source="p.rb";
  same(writeDomain(d), "{\n  \"source\": \"p.rb\",\n  \"roots\": [],\n  \"functions\": [],\n  \"edges\": [],\n  \"diagnostics\": []\n}\n", "domain-empty-go-format");
  d.diagnostics.push_back({"rejected","SB001","UnsupportedConstruct",{"p.rb",2,3},{},"x < 1"});
  same(writeDomain(d), R"({
  "source": "p.rb",
  "roots": [],
  "functions": [],
  "edges": [],
  "diagnostics": [
    {
      "verdict": "rejected",
      "code": "SB001",
      "name": "UnsupportedConstruct",
      "pos": {
        "file": "p.rb",
        "line": 2,
        "col": 3
      },
      "message": "x \u003c 1"
    }
  ]
}
)", "domain-diagnostic-key-order-omitted-path");
  return failures ? 1 : 0;
}
