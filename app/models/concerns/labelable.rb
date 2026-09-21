module Labelable
  extend ActiveSupport::Concern

  included do
    acts_as_taggable_on :labels
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
