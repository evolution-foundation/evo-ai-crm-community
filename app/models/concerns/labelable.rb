module Labelable
  extend ActiveSupport::Concern

  included do
    acts_as_taggable_on :labels

    # Contact and Conversation share the account-wide label catalog. Product
    # labels are free text typed per product and must stay out of it.
    class_attribute :labels_in_catalog, instance_writer: false, default: false

    # Must live in `included do`: the gem inserts its Core module above this
    # concern, so an override in the module body never runs. And it must be the
    # setter: `cached_label_list` is written from the list handed to it, so
    # normalising lower down leaves the tag canonical and the cache raw.
    def label_list=(value)
      if self.class.labels_in_catalog
        super(Array(value).map { |name| Labelable.canonical_label_title(name) })
      else
        super
      end
    end
  end

  # Mirrors `Label`'s own normalisation, then makes sure the catalog holds the
  # entry. A title `Label`'s format validation rejects stays applied but
  # uncatalogued. A bare UUID is applied without being promoted: it only reaches
  # here when it no longer resolves, and a UUID in the label picker is garbage.
  def self.canonical_label_title(name)
    title = name.to_s.strip.downcase
    return title if title.blank?
    return title if Labels::TokenResolver::UUID_FORMAT.match?(title)

    # Non-bang on purpose: a rejected title stays applied but uncatalogued,
    # it does not blow up the write that carried it.
    Label.find_or_create_by(title: title) # rubocop:disable Rails/SaveBang
    title
  end

  # F-2: label-change publishing moved to `after_update_commit` on Contact
  # (see `Contact#publish_label_changes`). Every write path that mutates
  # `label_list` and persists hits that callback, so update_labels/add_labels
  # no longer need to emit explicitly.
  #
  # EVO-1932: persistence robustness. `acts_as_taggable_on` only writes
  # taggings when the `label_list` *setter* runs and dirty-tracks the virtual
  # attribute — `update!(label_list: array)`/`record.label_list = array`. We
  # deliberately keep that setter path (rather than in-place `label_list.add`)
  # because Conversation/Contact callbacks key off `saved_change_to_label_list?`
  # (cached label list, label activity messages, EvoFlow `label.added/removed`
  # events); in-place mutation would persist the tagging but NOT dirty-track,
  # silently dropping those side effects. To stop the setter receiving values
  # the gem can't turn into a tagging — `nil`, blanks, `Tag` records, symbols —
  # every entry point normalises to an array of non-blank strings first. The
  # journey add-label/remove-label node reaches `update_labels` by NAME, so a
  # malformed token must never become a false-success that fails to persist.

  # REPLACE the contact/conversation/product label set with `labels`.
  # `[]` (or all-blank input) clears the set — this is how the UI removes the
  # last label and how a re-post of the desired set deletes a label.
  def update_labels(labels = nil)
    update!(label_list: normalize_label_tokens(labels))
  end

  # ADD `new_labels` to the existing set (union, idempotent). Builds on
  # `label_list` (the string TagList), NOT the `labels` Tag association, so the
  # setter receives plain strings rather than `Tag` records.
  def add_labels(new_labels = nil)
    combined = label_list.to_a + normalize_label_tokens(new_labels)
    update!(label_list: combined.uniq)
  end

  # REMOVE `labels` from the existing set (idempotent). Symmetric counterpart
  # to `add_labels`. Matches ignoring case, as the gem does when it resolves a
  # name to a tag on write: otherwise `VIP` could be added onto `vip` but never
  # removed from it.
  def remove_labels(labels = nil)
    targets = normalize_label_tokens(labels).map(&:downcase)
    update!(label_list: label_list.to_a.reject { |label| targets.include?(label.downcase) })
  end

  private

  # Coerce arbitrary input (array, scalar, `Tag` record, symbol, nil) into a
  # flat array of trimmed, non-blank strings the tagging setter accepts.
  def normalize_label_tokens(tokens)
    Array(tokens).map { |token| token.to_s.strip }.reject(&:blank?)
  end
end
