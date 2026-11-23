# P012 Phase 2: pipeline query language → AST → SQL (E447)
#
# 設計 13/14 章の最小実装。ユーザーには DuckDB SQL を晒さず、observability の
# 意味論だけを持つ小さな pipeline 言語を提供する:
#
#   logs | service = "api" | severity >= error | stats count() by service
#   logs | body contains "timeout" | sort ts desc | limit 50
#
# 規律 (E440 から継承): 値は全て bind。SQL に入る識別子・演算子は allowlist のみ。
# エラーは「何が・どこで・何なら受けるか」を返す (E435 基準)。
#
# compile 結果: [err, sql, binds, columns_note]
#   binds = [["i", 17], ["s", "api"], ...] (順序どおり duckdb_bind_int64/varchar)
#   sql は WHERE に必ず「ts >= ? AND ts < ?」を先頭に含む (time range は呼び手が bind)

class QueryAst
  FIELDS = {
    "service" => "service", "service.name" => "service",
    "severity" => "severity", "severity_text" => "severity_text",
    "level" => "severity_text", "body" => "body", "ts" => "ts"
  }
  INT_FIELDS = { "severity" => true, "ts" => true }
  OPS = { "=" => "=", "==" => "=", "!=" => "<>", ">=" => ">=", ">" => ">", "<=" => "<=", "<" => "<" }
  SEVERITY_NAMES = {
    "trace" => 1, "debug" => 5, "info" => 9, "warn" => 13, "error" => 17, "fatal" => 21
  }

  # 戻り: [err, sql, binds]
  def self.compile(q, src_sql)
    stages = q.split("|")
    return ["empty query (expected: logs | <filter> | ...)", "", []] if stages.length == 0
    source = stages[0].strip
    if source != "logs"
      return ["unknown source '#{source}' (supported: logs)", "", []]
    end

    wheres = []       # SQL 断片 ("col op ?")
    binds = []        # [kind, value]
    group = ""
    order = ""
    limit = 100

    i = 1
    while i < stages.length
      st = stages[i].strip
      if st.start_with?("stats ")
        rest = st[6..-1].strip
        # 対応形は count() by <field> のみ (最小)
        if rest.start_with?("count()")
          by = rest["count()".length..-1].strip
          if by.start_with?("by ")
            f = by[3..-1].strip
            col = FIELDS[f]
            return ["unknown field '#{f}' in stats by (supported: #{FIELDS.keys.join(", ")})", "", []] if col == nil
            group = col
          else
            return ["stats needs 'by <field>' (got '#{rest}')", "", []]
          end
        else
          return ["unsupported stats '#{rest}' (supported: count() by <field>)", "", []]
        end
      elsif st.start_with?("sort ")
        rest = st[5..-1].strip
        parts = rest.split(" ")
        col = FIELDS[parts[0]]
        return ["unknown field '#{parts[0]}' in sort (supported: #{FIELDS.keys.join(", ")})", "", []] if col == nil
        dir = "ASC"
        if parts.length >= 2
          d = parts[1].downcase
          return ["sort direction must be asc or desc (got '#{parts[1]}')", "", []] if d != "asc" && d != "desc"
          dir = d.upcase
        end
        order = col + " " + dir
      elsif st.start_with?("limit ")
        n = st[6..-1].strip.to_i
        return ["limit must be 1..10000 (got '#{st[6..-1].strip}')", "", []] if n < 1 || n > 10000
        limit = n
      else
        err = parse_filter(st, wheres, binds)
        return [err, "", []] if err != ""
      end
      i += 1
    end

    where_sql = "ts >= ? AND ts < ?"
    wheres.each { |w| where_sql = where_sql + " AND " + w }

    if group != ""
      sql = "SELECT " + group + ", count(*) AS count FROM (" + src_sql + ") WHERE " + where_sql +
            " GROUP BY " + group + " ORDER BY count DESC LIMIT " + limit.to_s
    else
      order = "ts ASC" if order == ""
      sql = "SELECT ts, service, severity, severity_text, body FROM (" + src_sql + ") WHERE " + where_sql +
            " ORDER BY " + order + " LIMIT " + limit.to_s
    end
    ["", sql, binds]
  end

  # "<field> <op> <value>" / "body contains \"x\"" を wheres/binds に積む
  def self.parse_filter(st, wheres, binds)
    parts = tokenize3(st)
    return "cannot parse filter '#{st}' (expected: <field> <op> <value>)" if parts == nil
    f = parts[0]
    op = parts[1]
    v = parts[2]
    col = FIELDS[f]
    return "unknown field '#{f}' (supported: #{FIELDS.keys.join(", ")})" if col == nil

    if op == "contains"
      return "contains is only for string fields (#{f} is numeric)" if INT_FIELDS[col]
      s = unquote(v)
      return "contains needs a quoted string (got '#{v}')" if s == nil
      wheres << col + " LIKE ?"
      binds << ["s", "%" + s + "%"]
      return ""
    end

    sqlop = OPS[op]
    return "unknown operator '#{op}' (supported: #{OPS.keys.join(" ")} contains)" if sqlop == nil

    if INT_FIELDS[col]
      # 数値 or severity 名 (error 等)
      s = unquote(v)
      v = s if s != nil
      if SEVERITY_NAMES[v.downcase] != nil && col == "severity"
        binds << ["i", SEVERITY_NAMES[v.downcase]]
      elsif v == v.to_i.to_s || (v.start_with?("-") && v[1..-1] == v.to_i.abs.to_s)
        binds << ["i", v.to_i]
      else
        return "field #{f} needs a number#{col == "severity" ? " or level name (" + SEVERITY_NAMES.keys.join("/") + ")" : ""} (got '#{v}')"
      end
      wheres << col + " " + sqlop + " ?"
    else
      s = unquote(v)
      return "field #{f} needs a quoted string (got '#{v}')" if s == nil
      wheres << col + " " + sqlop + " ?"
      binds << ["s", s]
    end
    ""
  end

  # 3 トークン (field, op, value)。value は "..." を 1 トークンとして扱う
  def self.tokenize3(st)
    rest = st.strip
    sp1 = rest.index(" ")
    return nil if sp1 == nil
    f = rest[0, sp1]
    rest = rest[sp1..-1].strip
    sp2 = rest.index(" ")
    return nil if sp2 == nil
    op = rest[0, sp2]
    v = rest[sp2..-1].strip
    return nil if v == ""
    [f, op, v]
  end

  # "..." を剥がす。quoted でなければ nil
  def self.unquote(v)
    return nil if v.length < 2
    return nil unless v.start_with?("\"") && v.end_with?("\"")
    v[1..-2]
  end
end
