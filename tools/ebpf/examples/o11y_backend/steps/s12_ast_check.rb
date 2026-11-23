# P012 Phase 2: Query AST のオフライン検証 (E447)
#   ./s12_ast_check
require_relative "../lib/query_ast"

$fails = 0

def check(q, want_sql_part, want_binds)
  err, sql, binds = QueryAst.compile(q, "SRC")
  if err != ""
    puts "FAIL: #{q}\n  unexpected error: #{err}"
    $fails += 1
    return
  end
  unless sql.include?(want_sql_part)
    puts "FAIL: #{q}\n  sql: #{sql}\n  missing: #{want_sql_part}"
    $fails += 1
    return
  end
  got = binds.map { |b| b[0] + ":" + b[1].to_s }.join(",")
  if got != want_binds
    puts "FAIL: #{q}\n  binds: #{got} (want #{want_binds})"
    $fails += 1
    return
  end
  puts "ok: #{q}"
end

def check_err(q, want_part)
  err, _sql, _binds = QueryAst.compile(q, "SRC")
  if err == ""
    puts "FAIL: #{q}\n  expected error containing '#{want_part}', got success"
    $fails += 1
    return
  end
  unless err.include?(want_part)
    puts "FAIL: #{q}\n  error '#{err}' does not contain '#{want_part}'"
    $fails += 1
    return
  end
  puts "ok(reject): #{q} -> #{err}"
end

check "logs", "ORDER BY ts ASC LIMIT 100", ""
check "logs | service = \"api\"", "service = ?", "s:api"
check "logs | severity >= error", "severity >= ?", "i:17"
check "logs | severity >= 17 | limit 5", "LIMIT 5", "i:17"
check "logs | body contains \"timeout\"", "body LIKE ?", "s:%timeout%"
check "logs | service.name = \"checkout\" | sort ts desc", "ORDER BY ts DESC", "s:checkout"
check "logs | severity >= warn | stats count() by service",
      "SELECT service, count(*) AS count", "i:13"
check "logs | level != \"INFO\"", "severity_text <> ?", "s:INFO"

check_err "metrics | limit 5", "unknown source 'metrics'"
check_err "logs | endpoint = \"x\"", "unknown field 'endpoint'"
check_err "logs | service ~ \"x\"", "unknown operator '~'"
check_err "logs | severity >= verybad", "number or level name"
check_err "logs | service = api", "quoted string"
check_err "logs | limit 999999", "1..10000"
check_err "logs | stats sum(x) by service", "count() by"

# injection 形は「値」なので bind に落ちるだけ (SQL には入らない) — 構造で確認
err, sql, binds = QueryAst.compile("logs | service = \"a' OR '1'='1\"", "SRC")
if err == "" && !sql.include?("OR '1'") && binds.length == 1 && binds[0][1] == "a' OR '1'='1"
  puts "ok: injection stays in bind value"
else
  puts "FAIL: injection handling (err=#{err} sql=#{sql})"
  $fails += 1
end

if $fails > 0
  puts "s12_ast_check: #{$fails} failure(s)"
  exit 1
end
puts "s12_ast_check: all pass"
