# E091 reject subject k1: a user program defining the reserved top-level name
# `Edge` (R016 T-4).  Same shape as E081 k6/k7: one spelling must not mean two
# things.  Expected: REJECT reserved-name naming the file, the line and the name.
require "edge/http"

module Edge
  def self.mine
    1
  end
end

puts Edge.mine
