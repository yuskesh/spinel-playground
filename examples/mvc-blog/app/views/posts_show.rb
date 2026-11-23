# app/views/posts_show.rb -- what app/views/posts/show.html.erb would be.
module PostsShowView
  def self.template
    <<~HTML
      <p><a href="/posts">&larr; Posts</a></p>
      <h2>%{title}</h2>
      <p class="meta">#%{id} / created_at=%{created_at}</p>
      <div>%!{body_html}</div>
      <form method="post" action="/posts/%{id}/delete">
      <button type="submit">Delete this post</button>
      </form>
    HTML
  end

  # The body has its newlines turned into <br> before it goes in, so it is **escaped
  # first** and then assembled, and the result goes in with %!{...}. With the escaping
  # in the wrong order, either the <br> is escaped too or the body's HTML comes out raw.
  def self.locals(post)
    body_html = View.h(post.body).gsub("\n", "<br>\n")
    {
      "id" => post.id,
      "title" => post.title,
      "created_at" => post.created_at,
      "body_html" => body_html,
    }
  end
end
