module Doom
  module Helpers
    def helper(n)
      n + 1
    end

    def only_in_module
      2
    end
  end

  # An unrelated class using the same name. The twin of Game#helper must be
  # Helpers#helper because Game includes Helpers, not Elsewhere#helper because
  # it happens to share a name.
  class Elsewhere
    def helper(n)
      n - 1
    end
  end

  class Game
    include Helpers

    def g_ticker
      helper(only_in_module)
    end
  end
end
