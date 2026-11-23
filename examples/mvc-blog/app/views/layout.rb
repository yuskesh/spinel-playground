# app/views/layout.rb -- what app/views/layouts/application.html.erb would be.
#
# There is no ERB, so **a template is a heredoc literal**. Do not write `#{}`
# inside `<<~HTML`: every value goes in through View.render's placeholders.
# Otherwise the layer that "passes values to a template" disappears, and who
# is responsible for escaping becomes unclear.
module Layout
  def self.template
    <<~HTML
      <!doctype html>
      <html lang="ja">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>%{title}</title>
      <style>
      body { font-family: system-ui, sans-serif; max-width: 44rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
      header { border-bottom: 1px solid #ddd; margin-bottom: 1.5rem; }
      header a { text-decoration: none; color: inherit; }
      .meta { color: #666; font-size: .85rem; }
      .errors { background: #fee; border: 1px solid #f99; padding: .75rem 1rem; }
      article { border-bottom: 1px solid #eee; padding: .75rem 0; }
      footer { margin-top: 3rem; color: #888; font-size: .8rem; }
      input, textarea { width: 100%%; font: inherit; padding: .4rem; }
      button { font: inherit; padding: .4rem .9rem; }
      </style>
      </head>
      <body>
      <header><h1><a href="/posts">spinel-mvc blog</a></h1></header>
      %!{content}
      <footer>store: %{adapter} / posts: %{count}</footer>
      </body>
      </html>
    HTML
  end

  # content is HTML already rendered, so it goes in with %!{...} (raw).
  def self.render(title, content, adapter, count)
    View.render(template, {
      "title" => title,
      "content" => content,
      "adapter" => adapter,
      "count" => count.to_s,
    })
  end
end
