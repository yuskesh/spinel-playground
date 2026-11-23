# framework/controller.rb -- the HTTP boundary.
#
# The layer that maps the CGI contract (tools/wasm/README.md) onto Rails-like words as it is.
# It uses no new host API.
#
#   ARGV[0]  -> Request#path          ("/posts/1")
#   ARGV[1]  -> Request#query_string  ("page=2")
#   $stdin   -> Request#body          (the form's bytes; empty for GET)
#   ENV      -> Request#method / #header / bindings
#   $stdout  <- Response (the CGI header block + a blank line + the body)
#   exit(n)  n != 0 becomes a 500, so **the application's 404 is exit 0 + Status: 404**
#
# Choosing the status and Content-Type from Ruby needs
#   SPINEL_CGI_HEADERS = "1"
# in wrangler.toml. It is off by default so that the output of a program writing
# binary is not read as headers on its own.
require_relative "codec"

# ---- Request -----------------------------------------------------------------
# Plays the part of Rails' ActionDispatch::Request, but it is just CGI inside.
class Request
  attr_reader :method, :path, :query_string, :body, :params, :content_type

  def initialize(method, path, query_string, body, content_type = "")
    @method = method
    @path = path
    @query_string = query_string
    @body = body
    @content_type = content_type
    # Overridden in the order query -> body -> path variables (the same precedence as Rails).
    @params = Codec.parse_form(query_string)
    if form_post?
      Codec.parse_form(body).each { |k, v| @params[k] = v }
    end
  end

  # Makes one request from ARGV / ENV / $stdin. This is layer 0's entrance.
  #
  # ENV cannot be taken as an argument: Spinel models ENV at compile time **only as
  # the receiver of a call**, so passing it as a value stops compilation
  # ("`ENV` cannot flow as a value"). Read ENV["KEY"] where it is used.
  def self.from_cgi(argv, io)
    method = ENV["REQUEST_METHOD"].to_s
    method = "GET" if method.empty?
    path = argv[0].to_s
    path = "/" if path.empty?
    query = argv.length > 1 ? argv[1].to_s : ""
    # worker.mjs passes an empty body for GET/HEAD, so read gives an empty string.
    body = (method == "GET" || method == "HEAD") ? "" : io.read.to_s
    Request.new(method, path, query, body, ENV["CONTENT_TYPE"].to_s)
  end

  def form_post?
    return false if @body.nil? || @body.empty?
    ct = @content_type.to_s
    ct.empty? || ct.index("application/x-www-form-urlencoded") != nil
  end

  # The router fills in `:id` and the like.
  def merge_path_params(extra)
    extra.each { |k, v| @params[k] = v }
    self
  end

  def param(name, default = "")
    @params.key?(name) ? @params[name] : default
  end

  def get?
    @method == "GET"
  end

  def post?
    @method == "POST"
  end
end

# ---- Response ----------------------------------------------------------------
# A value object that only assembles the CGI header block.
class Response
  attr_reader :status, :body, :headers

  def initialize(status, body, headers = {})
    @status = status
    @body = body.to_s
    @headers = { "Content-Type" => "text/html; charset=utf-8" }
    headers.each { |k, v| @headers[k] = v }
  end

  def self.html(body, status = 200)
    new(status, body)
  end

  def self.text(body, status = 200)
    new(status, body, { "Content-Type" => "text/plain; charset=utf-8" })
  end

  # 303 See Other: a redirect after a POST should fall back to GET
  # (Rails' redirect_to relies on browsers turning a 302 after POST into GET by
  # convention, but 303 leaves no ambiguity in the specification).
  def self.redirect(location, status = 303)
    new(status, "", { "Location" => location })
  end

  def self.head(status)
    new(status, "")
  end

  # Makes one byte string in CGI form: the header block + a blank line + the body.
  #
  # It accumulates with Array + join. In a version during development, writing this as
  # `+=` on a String captured by a block made the generated C `sp_int_add`, and
  # **the C compilation failed** (VALIDATION.md 4-4). It no longer reproduces since the
  # model layer was fixed, but this form does not depend on unrelated type inference, so it stays.
  def to_cgi
    lines = ["Status: " + @status.to_s]
    @headers.each { |k, v| lines << (k.to_s + ": " + v.to_s) }
    lines.join("\n") + "\n\n" + @body
  end

  # Uses $stdout.write (puts adds a newline, so it would not be byte-transparent).
  def write(io)
    io.write(to_cgi)
  end
end

# ---- Controller ---------------------------------------------------------------
# The base class that plays the part of Rails' ActionController::Base.
#
# There is no action dispatch by `send`: AOT has no way to choose a reachable method
# name from a string at run time, and if it had, methods not written in routes could
# be called. The router holds blocks directly (framework/router.rb).
class Controller
  attr_reader :request, :params

  def initialize(request)
    @request = request
    @params = request.params
    @page_title = "spinel-mvc"
  end

  def title=(t)
    @page_title = t
  end

  def title
    @page_title
  end

  # Renders a view (a heredoc template) and wraps it in the layout.
  # locals have String keys.
  def render(template, locals = {}, status = 200)
    inner = View.render(template, locals)
    Response.html(layout(inner), status)
  end

  # For returning without a layout.
  def render_bare(template, locals = {}, status = 200)
    Response.html(View.render(template, locals), status)
  end

  def redirect_to(location, status = 303)
    Response.redirect(location, status)
  end

  def head(status)
    Response.head(status)
  end

  # Passes through by default. The application's controller overrides it to insert a layout.
  def layout(inner)
    inner
  end
end
