# framework/router.rb -- RESTful routing.
#
# Plays the part of Rails' config/routes.rb. It compares the segments of `split("/")`
# rather than using regular expressions: readable, fast, and sure to work on this target.
#
#   router.get("/posts")             { |req| ... }
#   router.get("/posts/:id")         { |req| ... }   # req.params["id"]
#   router.post("/posts/:id/delete") { |req| ... }
#
# Routes are matched **in the order written**. Unless `/posts/new` is written before
# `/posts/:id`, it is taken as `:id == "new"` (the same as Rails' routes.rb).
#
# An action is a block (Proc), not a Symbol. Calling a method from a string, as in
# `send(:index)`, does not exist under AOT, and if it did, methods not written in routes
# could be called from outside.
class Router
  def initialize
    @routes = []
    @not_found = nil
  end

  def get(pattern, &handler)
    add("GET", pattern, handler)
  end

  def post(pattern, &handler)
    add("POST", pattern, handler)
  end

  def not_found(&handler)
    @not_found = handler
    self
  end

  def add(method, pattern, handler)
    @routes << [method, split_path(pattern), handler]
    self
  end

  # Only recognizes and returns what it found (for tests). nil if nothing is found.
  def recognize(method, path)
    segments = split_path(path)
    @routes.each do |route|
      next if route[0] != method
      captured = match(route[1], segments)
      return [route[2], captured] unless captured.nil?
    end
    nil
  end

  # Request -> Response. This is the front controller.
  def dispatch(request)
    found = recognize(request.method, request.path)
    if found.nil?
      # HEAD is served by the GET route (the worker side drops the body).
      found = recognize("GET", request.path) if request.method == "HEAD"
    end
    if found.nil?
      return @not_found.nil? ? Response.text("404 Not Found\n", 404) : @not_found.call(request)
    end
    request.merge_path_params(found[1])
    found[0].call(request)
  end

  # "/posts/1/" -> ["posts", "1"]  (drops the empty segments at the start and end)
  def split_path(path)
    out = []
    path.to_s.split("/").each do |seg|
      out << seg unless seg.empty?
    end
    out
  end

  # Compares the pattern with the real path one segment at a time: the captured Hash if they match, otherwise nil.
  def match(pattern, segments)
    return nil if pattern.length != segments.length
    captured = {}
    i = 0
    while i < pattern.length
      p = pattern[i]
      s = segments[i]
      # An indexed access goes into a local variable before it is compared (VALIDATION.md 4-1:
      # in a string with multibyte characters, writing `p[0] == ":"` in place
      # compares at a byte position).
      head = p.length > 0 ? p[0] : ""
      if p.length > 1 && head == ":"
        captured[p[1, p.length - 1]] = s
      elsif p != s
        return nil
      end
      i += 1
    end
    captured
  end
end
