# app/views/not_found.rb -- what app/views/errors/not_found.html.erb would be.
#
# Even a 404 has **exit status 0**. Under the CGI contract an exit other than 0 is a
#   500, and the body is replaced with $stderr. The application's 404 is "a request
#   handled normally", so the status goes out as `Status: 404` in the CGI header block.
module NotFoundView
  def self.template
    <<~HTML
      <h2>404 Not Found</h2>
      <p>No route matches <code>%{path}</code>.</p>
      <p><a href="/posts">To the posts</a></p>
    HTML
  end

  def self.locals(path)
    { "path" => path }
  end
end
