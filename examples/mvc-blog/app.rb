# examples/mvc/app.rb -- the entry point. It plays the part of Rails' config/routes.rb + config.ru.
#
# This is the only place that meets the CGI contract:
#   ARGV[0] = path / ARGV[1] = query string / $stdin = body / ENV = CGI variables
#   $stdout = response (the header block takes effect when SPINEL_CGI_HEADERS=1)
#
# The files are joined with **`require_relative`**. Spinel **pastes require /
# require_relative into one text at compile time**, so no file system is needed at
# run time (this target has none). A file required twice is pasted only
# once.
#
# Build:
#   ../../../spinel-wasm app.rb --emit-worker ../../../../../myblog --host-api
#   (for native debugging, see "Build and run" in the README)

# --- framework ------------------------------------------------------------------
require_relative "framework/codec"
require_relative "framework/view"
require_relative "framework/model"
require_relative "framework/controller"
require_relative "framework/router"

# --- application ----------------------------------------------------------------
require_relative "app/models/post"
require_relative "app/views/layout"
require_relative "app/views/posts_index"
require_relative "app/views/posts_show"
require_relative "app/views/posts_new"
require_relative "app/views/not_found"
require_relative "app/controllers/posts_controller"

# --- routes ---------------------------------------------------------------------
# Rails' config/routes.rb. Routes are matched **from the top**, so
# put `/posts/new` before `/posts/:id` (otherwise id == "new").
#
#   resources :posts, only: [:index, :show, :new, :create, :destroy]
router = Router.new
router.get("/") { |req| Response.redirect("/posts") }
router.get("/posts") { |req| PostsController.new(req).index }
router.get("/posts/new") { |req| PostsController.new(req).new_form }
router.get("/posts/:id") { |req| PostsController.new(req).show }
router.post("/posts") { |req| PostsController.new(req).create }
router.post("/posts/:id/delete") { |req| PostsController.new(req).destroy }
router.not_found { |req| PostsController.new(req).not_found }

# --- one request = one process --------------------------------------------------
# The program is **instantiated per request**, so global state kept here
# does not survive to the next request. That is why state lives only in
# the Store (= KV) of framework/model.rb.
request = Request.from_cgi(ARGV, $stdin)

# Without SPINEL_CGI_HEADERS, Status:/Location: are not read as headers, and
# the header block comes back as the body. Say so rather than break quietly.
#
# Do **not write the name of the collection class (the 3 letters S-e-t) bare**
#   in a message, in a string or in a comment. When that word appears in the
#   source, Spinel pastes in all of packages/set/set.rb, whose `Enumerator#to_a`
#   trips wasm32's unsupported-syntax gate and stops the build.
#   This file itself fell into that trap (VALIDATION.md, 4-3).
if ENV["SPINEL_CGI_HEADERS"].to_s != "1"
  $stderr.puts "spinel-mvc: SPINEL_CGI_HEADERS is not 1 -- status codes and redirects"
  $stderr.puts "spinel-mvc: come back as body text.  Add it to wrangler.toml [vars]."
end

begin
  response = router.dispatch(request)
rescue NotImplementedError => e
  # Raised by the raise policy (it touched a feature this target does not have).
  # It is not a StandardError, so `rescue => e` does not catch it.
  response = Response.text("501 Not Implemented\n" + e.message + "\n", 501)
rescue => e
  response = Response.text("500 Internal Server Error\n" + e.message + "\n", 500)
end

response.write($stdout)
