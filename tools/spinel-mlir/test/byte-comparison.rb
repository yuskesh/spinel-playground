require 'digest'
if ARGV.first == '--naive'
  module ByteComparison
    def self.equal?(a, b) = a == b
    def self.include?(a, b) = a.include?(b)
  end
else
  require_relative '../scripts/lib/byte-comparison'
end
bytes = File.binread(File.join(__dir__, 'Inputs/byte-comparison.stderr'))
abort 'fixture hash' unless Digest::SHA256.hexdigest(bytes) == '1ba06a043960d14b7bb88de95eac74fcaef5737ec0b9e8a05f71afde6146144f'
text = bytes.dup.force_encoding(Encoding::UTF_8).freeze
ascii = bytes.dup.force_encoding(Encoding::US_ASCII).freeze
failures = []
check = lambda do |name, &body|
  begin
    raise 'false result' unless body.call
    puts "PASS #{name}"
  rescue StandardError => e
    failures << name
    puts "FAIL #{name}: #{e.class}: #{e.message}"
  end
end
check.call('same-bytes-different-encoding') { ByteComparison.equal?(text, bytes) }
check.call('nonascii-needle') { ByteComparison.include?(ascii, '—') }
check.call('different-byte') { !ByteComparison.equal?(bytes, bytes + 'x') }
check.call('raw-nul-invalid-utf8') do
  raw = "\x00\xff".b
  ByteComparison.equal?(raw, raw.dup.force_encoding(Encoding::UTF_8)) && ByteComparison.include?(raw, "\xff".b)
end
check.call('inputs-unchanged') { text.encoding == Encoding::UTF_8 && ascii.encoding == Encoding::US_ASCII && text.frozen? && ascii.frozen? && text.bytes == bytes.bytes }
check.call('non-string-rejected') do
  [[nil, bytes], [bytes, 1]].all? do |a, b|
    %i[equal? include?].all? do |method|
      begin
        ByteComparison.public_send(method, a, b)
        false
      rescue TypeError
        true
      end
    end
  end
end
abort "failed: #{failures.join(', ')}" unless failures.empty?
