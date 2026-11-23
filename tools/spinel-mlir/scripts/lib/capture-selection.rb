# Opt-in selection and outcome discovery for derived research controls only.
module CaptureSelection
  module_function
  def select(rows, text)
    return rows unless text
    ids=text.split(',',-1)
    raise ArgumentError,'capture-case-ID-set' unless !ids.empty? && ids.none?(&:empty?) && ids.uniq==ids && (ids-rows.map{|r|r[2]}).empty?
    rows.select{|r|ids.include?(r[2])}
  end
  def outcome(kind, record, rc, observe)
    return kind unless observe
    raise ArgumentError,'capture-observe-derived-only' unless record && record.key?('derived_content') && [0,1].include?(rc)
    rc==0 ? 'positive' : 'negative'
  end
end
