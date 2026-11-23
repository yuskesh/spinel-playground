# app/views/posts_index.rb -- what app/views/posts/index.html.erb would be.
#
# A view provides two things:
#   template  the heredoc template itself
#   locals    a Hash with String keys to insert into it
# The controller then only writes `render(View.template, View.locals(...))`.
#
# `%{...}` inserts with HTML escaping; `%!{...}` inserts raw.
# The list's rows repeat a partial template (post_template) with View.render_each,
# and the resulting HTML goes into `%!{posts}`: the smallest form of Rails'
# `render partial: "post", collection: @posts`.
module PostsIndexView
  def self.template
    <<~HTML
      <p><a href="/posts/new">New post</a></p>
      %!{posts}
      %!{empty}
    HTML
  end

  def self.post_template
    <<~HTML
      <article>
      <h2><a href="/posts/%{id}">%{title}</a></h2>
      <p>%{summary}</p>
      <p class="meta">#%{id} / created_at=%{created_at}
      <form method="post" action="/posts/%{id}/delete" style="display:inline">
      <button type="submit">Delete</button>
      </form>
      </p>
      </article>
    HTML
  end

  def self.empty_template
    <<~HTML
      <p>No posts yet.</p>
    HTML
  end

  def self.locals(posts)
    rows = []
    posts.each do |post|
      rows << {
        "id" => post.id,
        "title" => post.title,
        "summary" => post.summary,
        "created_at" => post.created_at,
      }
    end
    {
      "posts" => View.render_each(post_template, rows),
      "empty" => posts.empty? ? View.render(empty_template, {}) : "",
    }
  end
end
