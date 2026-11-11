# Parser for the `comments` field of an Instagram webhook entry.
#
#   { "field": "comments",
#     "value": { "from": { "id": "<IGSID>", "username": "someone" },
#                "media": { "id": "<MEDIA_ID>", "media_product_type": "FEED" },
#                "id": "<COMMENT_ID>", "parent_id": "<COMMENT_ID>" (replies only),
#                "text": "Qual o valor" } }
class Instagram::CommentParser
  attr_reader :value

  def initialize(value)
    @value = (value || {}).with_indifferent_access
  end

  def comment_id
    value[:id]
  end

  def text
    value[:text]
  end

  def from_id
    value.dig(:from, :id)
  end

  def username
    value.dig(:from, :username)
  end

  def media_id
    value.dig(:media, :id)
  end

  def media_product_type
    value.dig(:media, :media_product_type)
  end

  # Present only when the comment is a reply to another comment.
  def parent_id
    value[:parent_id]
  end

  def valid?
    comment_id.present? && from_id.present?
  end
end
