# Compare raw bytes without changing either String or normalizing its contents.
module ByteComparison
  def self.equal?(left, right)
    strings!(left, right)
    left.b == right.b
  end

  def self.include?(bytes, needle)
    strings!(bytes, needle)
    bytes.b.include?(needle.b)
  end

  def self.strings!(*values)
    raise TypeError, 'byte comparison requires Strings' unless values.all? { |value| value.is_a?(String) }
  end
  private_class_method :strings!
end
