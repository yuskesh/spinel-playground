# E091 control for k1: `Outer::Edge` is NOT the reserved top-level name, so it
# must build.  Without this row the k1 gate would also pass if the check simply
# refused every occurrence of the word.
require "edge/http"

module Outer
  module Edge
    def self.mine
      2
    end
  end
end

puts Outer::Edge.mine
