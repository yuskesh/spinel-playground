# app/controllers/posts_controller.rb -- 5 of the 7 actions.
#
# The same shape as Rails' PostsController, except that
#   - `def new` **cannot be written** (the generated C's `sp_PostsController_new`
#     collides with the class's allocator and compilation fails); it is `new_form`
#   - there is no `before_action` (user-defined macros in a class body do not run).
#     If needed, call a method at the start of the action in the ordinary way
#   - there is no `respond_to` / `format.json` (this target has no JSON)
class PostsController < Controller
  # Inserts the layout. Overrides the framework's Controller#layout.
  def layout(inner)
    Layout.render(title, inner, Persistence.adapter, Post.count)
  end

  # GET /posts
  def index
    self.title = "Posts"
    render(PostsIndexView.template, PostsIndexView.locals(Post.all))
  end

  # GET /posts/:id
  def show
    post = Post.find(params["id"].to_s)
    return not_found if post.nil?
    self.title = post.title
    render(PostsShowView.template, PostsShowView.locals(post))
  end

  # GET /posts/new   (Rails' `new`; only the method's name differs)
  def new_form
    self.title = "New post"
    render(PostsNewView.template, PostsNewView.locals(Post.new({}), []))
  end

  # POST /posts
  def create
    post = Post.new({ "title" => params["title"].to_s, "body" => params["body"].to_s })
    if post.save
      redirect_to("/posts/" + post.id)
    else
      # 422 and the form with its input kept. Rails'
      # `render :new, status: :unprocessable_entity`.
      self.title = "New post"
      render(PostsNewView.template, PostsNewView.locals(post, post.errors), 422)
    end
  end

  # POST /posts/:id/delete
  # (An HTML form cannot send DELETE. Rails uses _method=delete;
  #  here the route is simply POST)
  def destroy
    post = Post.find(params["id"].to_s)
    return not_found if post.nil?
    post.destroy
    redirect_to("/posts")
  end

  def not_found
    self.title = "404 Not Found"
    render(NotFoundView.template, NotFoundView.locals(request.path), 404)
  end
end
