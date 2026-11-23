# P012 S2: ExportLogsServiceRequest の手書き protobuf decoder (E438)
#
# 設計 6.1 章の decode 3 案のうち「手書き Ruby varint」を最初に通す (依存ゼロ)。
# 対象フィールドは Phase 1 の内部 schema (設計 7.1 章の縮小版) に必要な分だけ:
#   resource.attributes["service.name"]                  (KeyValue/AnyValue)
#   LogRecord.time_unix_nano / severity_number / severity_text / body.string_value
# それ以外のフィールドは wire type に従って skip する (未知フィールドで落ちない)。
#
# 出力は列指向 (設計 34 章 "Batch, not objects"): 1 decode 呼び出しで
# ts[] / severity[] / severity_text[] / service[] / body[] に並行 append する。
#
# フィールド番号の正本: third_party/opentelemetry-proto v1.10.0
#   ExportLogsServiceRequest.resource_logs = 1
#   ResourceLogs.resource = 1 / .scope_logs = 2
#   Resource.attributes = 1
#   ScopeLogs.log_records = 2
#   LogRecord.time_unix_nano = 1 (fixed64) / .severity_number = 2 /
#             .severity_text = 3 / .body = 5 / .observed_time_unix_nano = 11
#   KeyValue.key = 1 / .value = 2、AnyValue.string_value = 1

class OtlpLogsDecoder
  attr_reader :ts, :severity, :severity_text, :service, :body, :errors

  def initialize
    @ts = []
    @severity = []
    @severity_text = []
    @service = []
    @body = []
    @errors = 0
  end

  # ---- protobuf primitives (String を getbyte で直走査 — E443 で Array walk から変更。
  #      unpack("C*") の 10k 要素 Array/呼び出しが allocation-bound の主因だった) ----

  # varint を読み [value, new_pos] を返す。壊れていたら value = -1。
  def varint(b, pos, limit)
    v = 0
    shift = 0
    while pos < limit && shift <= 63
      byte = b.getbyte(pos)
      pos += 1
      v |= (byte & 0x7f) << shift
      return [v, pos] if (byte & 0x80) == 0
      shift += 7
    end
    @errors += 1
    [-1, limit]
  end

  def fixed64(b, pos, limit)
    if pos + 8 > limit
      @errors += 1
      return [-1, limit]
    end
    v = 0
    i = 7
    while i >= 0
      v = (v << 8) | b.getbyte(pos + i)
      i -= 1
    end
    [v, pos + 8]
  end

  def str_of(b, pos, len)
    b.byteslice(pos, len)
  end

  # len-delim フィールドの長さを読む。壊れ (varint 破損 or limit 超過) は
  # @errors に数えて -1 を返す — 途中 truncation を黙って握り潰さない (E438 負の対照で検出)。
  def len_field(b, pos, limit)
    len, pos = varint(b, pos, limit)
    return [-1, pos] if len < 0            # varint 側で計上済み
    if pos + len > limit
      @errors += 1
      return [-1, pos]
    end
    [len, pos]
  end

  # 読まないフィールドを wire type に従って読み飛ばす。new_pos を返す。
  def skip(b, pos, limit, wt)
    if wt == 0
      _v, pos = varint(b, pos, limit)
      pos
    elsif wt == 1
      pos + 8
    elsif wt == 2
      len, pos = len_field(b, pos, limit)
      len < 0 ? limit : pos + len
    elsif wt == 5
      pos + 4
    else
      @errors += 1
      limit
    end
  end

  # ---- message walkers ----

  # AnyValue.string_value (field 1, len-delim)。無ければ ""。
  def any_string(b, pos, limit)
    s = ""
    while pos < limit
      tag, pos = varint(b, pos, limit)
      return s if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 1 && wt == 2
        len, pos = len_field(b, pos, limit)
        return s if len < 0
        s = str_of(b, pos, len)
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
    s
  end

  # KeyValue → [key, string_value]
  def key_value(b, pos, limit)
    k = ""
    v = ""
    while pos < limit
      tag, pos = varint(b, pos, limit)
      return [k, v] if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 1 && wt == 2
        len, pos = len_field(b, pos, limit)
        return [k, v] if len < 0
        k = str_of(b, pos, len)
        pos += len
      elsif f == 2 && wt == 2
        len, pos = len_field(b, pos, limit)
        return [k, v] if len < 0
        v = any_string(b, pos, pos + len)
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
    [k, v]
  end

  # Resource → service.name (attributes から)。無ければ "unknown"。
  def resource_service(b, pos, limit)
    svc = "unknown"
    while pos < limit
      tag, pos = varint(b, pos, limit)
      return svc if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 1 && wt == 2
        len, pos = len_field(b, pos, limit)
        return svc if len < 0
        k, v = key_value(b, pos, pos + len)
        svc = v if k == "service.name" && v != ""
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
    svc
  end

  # LogRecord → 列に 1 行 append
  def log_record(b, pos, limit, svc)
    t = 0
    sev = 0
    sevtext = ""
    bodystr = ""
    while pos < limit
      tag, pos = varint(b, pos, limit)
      break if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 1 && wt == 1
        t, pos = fixed64(b, pos, limit)
      elsif f == 2 && wt == 0
        sev, pos = varint(b, pos, limit)
      elsif f == 3 && wt == 2
        len, pos = len_field(b, pos, limit)
        break if len < 0
        sevtext = str_of(b, pos, len)
        pos += len
      elsif f == 5 && wt == 2
        len, pos = len_field(b, pos, limit)
        break if len < 0
        bodystr = any_string(b, pos, pos + len)
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
    @ts << t
    @severity << sev
    @severity_text << sevtext
    @service << svc
    @body << bodystr
  end

  # ScopeLogs
  def scope_logs(b, pos, limit, svc)
    while pos < limit
      tag, pos = varint(b, pos, limit)
      return if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 2 && wt == 2
        len, pos = len_field(b, pos, limit)
        return if len < 0
        log_record(b, pos, pos + len, svc)
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
  end

  # ResourceLogs: resource (svc) を先に確定してから scope_logs を歩く。
  # protobuf はフィールド順を保証しないので 2 パス (resource → scope_logs)。
  def resource_logs(b, pos, limit)
    svc = "unknown"
    p2 = pos
    while p2 < limit
      tag, p2 = varint(b, p2, limit)
      break if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 1 && wt == 2
        len, p2 = len_field(b, p2, limit)
        break if len < 0
        svc = resource_service(b, p2, p2 + len)
        p2 += len
      else
        p2 = skip(b, p2, limit, wt)
      end
    end
    while pos < limit
      tag, pos = varint(b, pos, limit)
      return if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 2 && wt == 2
        len, pos = len_field(b, pos, limit)
        return if len < 0
        scope_logs(b, pos, pos + len, svc)
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
  end

  # entry: ExportLogsServiceRequest のバイト列 (binary String) を食い、
  # 追加した record 数を返す。
  def decode(payload)
    n0 = @ts.length
    b = payload
    pos = 0
    limit = b.bytesize
    while pos < limit
      tag, pos = varint(b, pos, limit)
      break if tag < 0
      f = tag >> 3
      wt = tag & 7
      if f == 1 && wt == 2
        len, pos = len_field(b, pos, limit)
        break if len < 0
        resource_logs(b, pos, pos + len)
        pos += len
      else
        pos = skip(b, pos, limit, wt)
      end
    end
    @ts.length - n0
  end
end
