# app/views/posts_new.rb -- what app/views/posts/new.html.erb would be.
#
# No form_with and no CSRF token: a plain <form method="post">
# (there is no session, so there is nowhere to keep a CSRF token; see
# "What it is not" in the README).
module PostsNewView
  def self.template
    <<~HTML
      <p><a href="/posts">&larr; Posts</a></p>
      <h2>New post</h2>
      %!{errors}
      <form method="post" action="/posts">
      <p><label>Title<br><input name="title" value="%{title}" maxlength="80"></label></p>
      <p><label>Body<br><textarea name="body" rows="8">%{body}</textarea></label></p>
      <p><button type="submit">Create</button></p>
      </form>
    HTML
  end

  def self.errors_template
    <<~HTML
      <div class="errors">
      <p>Could not save:</p>
      <ul>%!{items}</ul>
      </div>
    HTML
  end

  def self.error_item_template
    <<~HTML
      <li>%{message}</li>
    HTML
  end

  def self.locals(post, errors)
    items = []
    errors.each { |m| items << { "message" => m } }
    errors_html = errors.empty? ? "" : View.render(errors_template, {
      "items" => View.render_each(error_item_template, items),
    })
    {
      "title" => post.title,
      "body" => post.body,
      "errors" => errors_html,
    }
  end
end
