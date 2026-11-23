# app/models/post.rb -- the example's domain: a plain blog post.
#
# In Rails you would write
#
#   class Post < ApplicationRecord
#     validates :title, presence: true, length: { maximum: 80 }
#     validates :body,  presence: true
#   end
#
# Here the same is declared with **3 class methods that can be overridden**
# (class macros do not run under Spinel's AOT compilation; see the README).
class Post < Model
  def self.table
    "posts"
  end

  def self.fields
    ["title", "body", "created_at"]
  end

  def self.validations
    [
      ["title", "presence", 0],
      ["title", "max_length", 80],
      ["body", "presence", 0],
    ]
  end

  def title
    self["title"]
  end

  def body
    self["body"]
  end

  def created_at
    self["created_at"]
  end

  # Records the creation time before saving. Time.now works on wasm too, since
  # clock_time_get was added (tools/wasm/README.md).
  def save
    self["created_at"] = Time.now.to_i.to_s if self["created_at"].empty?
    super
  end

  # A one-line summary for the list.
  def summary(limit = 60)
    text = body.gsub("\n", " ")
    return text if text.length <= limit
    text[0, limit] + "..."
  end
end
