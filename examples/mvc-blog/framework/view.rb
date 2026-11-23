# framework/view.rb -- rendering templates and HTML escaping.
#
# ERB cannot be used. ERB "evaluates a template string as Ruby", and this
# target has no eval (AOT: there is no compiler at run time).
# So **a template is a heredoc literal**, and values go in by **placeholder substitution**.
#
#   %{name}    inserts the value HTML-escaped (the default, the safe side)
#   %!{name}   inserts the value as it is (for assembling partial templates)
#   %%         a literal "%"
#
# locals are **a Hash with String keys** (not Symbols). For why, see the README's
# "Writing Rails-style code in the Spinel subset".
#
# Substitution **scans the template only once** and does not rescan inserted values.
# So even if user input contains "%{...}", it is never read as the next key.
# An implementation that stacks one gsub per key would let that happen.
module View
  # HTML escaping. Unless & is replaced first, the result is escaped twice.
  def self.h(value)
    s = value.to_s
    s = s.gsub("&", "&amp;")
    s = s.gsub("<", "&lt;")
    s = s.gsub(">", "&gt;")
    s = s.gsub("\"", "&quot;")
    s = s.gsub("'", "&#39;")
    s
  end

  # template: a heredoc string / locals: { "title" => "...", ... }
  def self.render(template, locals = {})
    out = ""
    i = 0
    n = template.length
    while i < n
      c = template[i]
      if c != "%"
        out += c
        i += 1
        next
      end

      # **Do not compare an indexed access with a 1-byte string literal in place**,
      #   as in `template[i + 1] == "%"`: in a string with multibyte characters it is
      #   compared at a byte position and quietly gives a different answer (VALIDATION.md
      #   4-1). Always put it in a local variable before comparing.
      nxt = i + 1 < n ? template[i + 1] : ""
      nxt2 = i + 2 < n ? template[i + 2] : ""
      if nxt == "%"
        out += "%"
        i += 2
        next
      end

      raw = false
      start = 0
      if nxt == "{"
        start = i + 2
      elsif nxt == "!" && nxt2 == "{"
        raw = true
        start = i + 3
      else
        out += c
        i += 1
        next
      end

      close = template.index("}", start)
      if close.nil?
        raise ArgumentError, "unterminated placeholder in template at #{i}"
      end
      key = template[start, close - start]
      unless locals.key?(key)
        raise ArgumentError, "no local named #{key.inspect} for this template"
      end
      value = locals[key].to_s
      out += raw ? value : h(value)
      i = close + 1
    end
    out
  end

  # Repeats a partial template. The smallest equivalent of Rails' `render partial:, collection:`;
  # the result is raw HTML meant to be inserted with %!{...}.
  def self.render_each(template, rows)
    out = ""
    rows.each { |locals| out += render(template, locals) }
    out
  end
end
