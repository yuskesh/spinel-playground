# frozen_string_literal: true
#
# tests/doom-core/partition.rb — is a set of fields split, or just counted?
#
#   ruby tests/doom-core/partition.rb CARRIED NOREF WHOLE
#
# CARRIED is a layout (field name in column 1), NOREF is one name per line,
# and WHOLE is the catalog of every field that ought to be accounted for
# (`prepared\tname\tvalue`, name in column 2). Prints five numbers:
#
#   whole carried noref both neither
#
# `both` and `neither` are the ones that matter. A comparison lane that says
# "152 prepared fields arrive as the original has them" is only saying
# something if the other 74 are NAMED as not arriving: a carried set can be
# grown by dropping a field out of the schema exactly as well as by learning
# to read it, and the count alone cannot tell those apart.
require "set"

abort("usage: partition.rb CARRIED NOREF WHOLE") unless ARGV.length == 3

def column(path, i)
  File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }
      .map { |l| l.chomp.split("\t")[i] }.compact.to_set
end

carried = column(ARGV[0], 0)
noref   = File.readlines(ARGV[1]).map(&:chomp).reject(&:empty?).to_set
whole   = column(ARGV[2], 1)

print [whole.length, carried.length, (whole & noref).length,
       (carried & noref).length, (whole - carried - noref).length].join(" ")
