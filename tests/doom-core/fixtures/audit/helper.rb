module Doom
  class Game
    def g_ticker
      helper
    end

    # Reachable from the root, and it calls something no catalog covers.
    def helper
      s = "abc"
      s.slice_that_no_catalog_covers
    end
  end
end
