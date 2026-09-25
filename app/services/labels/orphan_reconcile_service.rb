# Reconciles label taggings whose name has no matching `Label`. Such rows are
# invisible: the filter matches `tags.name` exactly against a downcased title,
# and the picker only offers catalog titles. Report-only by default; `fix`
# applies, `purge` deletes the uncatalogued rows instead of cataloguing them.
class Labels::OrphanReconcileService
  # Product labels are free text per product and share no catalog with contacts
  # and conversations, so their taggings are left alone.
  TAGGABLE_TYPES = %w[Contact Conversation].freeze
  UUID_NAME = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def self.call(...) = new(...).call

  def initialize(fix: false, purge: false, io: $stdout)
    @fix = fix
    @purge = purge
    @io = io
    @summary = { rewired: 0, catalogued: 0, purged: 0, tags_deleted: 0, uuid_left: 0, conversations_refreshed: 0 }
  end

  def call
    report_scope
    rows = orphan_rows
    if rows.empty?
      say 'every label tagging matches a catalog entry, nothing to do.'
      return @summary
    end

    rows.each { |row| handle(row) }
    report_totals
    @summary
  end

  private

  attr_reader :fix, :purge

  # States what the run can see, so "nothing to do" is never mistaken for a
  # scope that holds nothing.
  def report_scope
    counts = {
      labels: Label.count,
      tags: ActsAsTaggableOn::Tag.count,
      applications: label_taggings.count
    }
    say "visible here: #{counts[:labels]} catalog entries, #{counts[:tags]} tags, " \
        "#{counts[:applications]} applications"
    return unless counts.values.all?(&:zero?)

    say 'NOTE: this scope holds no label rows at all.'
  end

  def label_taggings
    ActsAsTaggableOn::Tagging.where(context: 'labels', taggable_type: TAGGABLE_TYPES)
  end

  def catalog_titles
    @catalog_titles ||= Label.pluck(:title).compact
  end

  def by_downcased
    @by_downcased ||= catalog_titles.index_by(&:downcase)
  end

  # Driven from Tag, not from Tagging: `Tagging.joins(:tag).where.not(tag: {...})`
  # makes Rails alias the joined table `tag` while the select says `tags`, and
  # Postgres refuses the query outright.
  def orphan_rows
    ActsAsTaggableOn::Tag
      .joins(:taggings)
      .where(taggings: { context: 'labels', taggable_type: TAGGABLE_TYPES })
      .where.not(name: catalog_titles)
      .group('tags.id', 'tags.name')
      .select('tags.name AS tag_name, tags.id AS tag_id, count(*) AS applications')
      .to_a
  end

  def handle(row)
    name = row.tag_name.to_s
    kind = family_of(name)
    say "#{kind.to_s.ljust(7)} tag=#{name.inspect} applications=#{row.applications}"

    # A UUID with no Label behind it is reported and left alone in every mode:
    # cataloguing it puts an id in the picker, deleting it destroys history.
    if kind == :uuid
      @summary[:uuid_left] += row.applications
      return
    end
    return unless fix

    kind == :case ? rewire_onto(row, by_downcased[name.downcase]) : handle_missing(row, name)
  end

  def family_of(name)
    return :case if by_downcased.key?(name.downcase)
    return :uuid if UUID_NAME.match?(name)

    :missing
  end

  def handle_missing(row, name)
    if purge
      purge_applications(row)
      return
    end

    label = Label.create(title: name.strip.downcase)
    unless label.persisted?
      say "  -> SKIPPED: #{name.inspect} is not a valid Label title (#{label.errors.full_messages.join(', ')})"
      return
    end

    @summary[:catalogued] += row.applications
    say "  -> catalogued as #{label.title.inspect}"
    # The tag still carries the original casing, which the exact filter never
    # matches. Without this the title needs a second run to become visible.
    rewire_onto(row, label.title)
  end

  def purge_applications(row)
    ids = conversation_ids_for(row.tag_id)
    deleted = label_taggings.where(tag_id: row.tag_id).delete_all
    @summary[:purged] += deleted
    delete_tag_if_unused(row.tag_id)
    refresh_conversation_cache(ids)
    say "  -> purged #{deleted} applications"
  end

  # Moves this tag's contact/conversation taggings onto the canonical tag,
  # dropping pairs that would duplicate one already there.
  def rewire_onto(row, canonical_title)
    good = ActsAsTaggableOn::Tag.find_or_create_by!(name: canonical_title)
    return if good.id == row.tag_id

    ids = conversation_ids_for(row.tag_id)
    moved = 0

    ActiveRecord::Base.transaction do
      label_taggings.where(tag_id: row.tag_id).find_each do |tagging|
        if duplicate_of?(tagging, good)
          tagging.destroy!
        else
          tagging.update_column(:tag_id, good.id) # rubocop:disable Rails/SkipsModelValidations
          moved += 1
        end
      end

      recount(good)
      delete_tag_if_unused(row.tag_id)
    end

    @summary[:rewired] += moved
    refresh_conversation_cache(ids)
    say "  -> rewired #{moved} onto #{canonical_title.inspect}"
  end

  def duplicate_of?(tagging, good)
    ActsAsTaggableOn::Tagging.exists?(
      tag_id: good.id,
      taggable_id: tagging.taggable_id,
      taggable_type: tagging.taggable_type,
      context: tagging.context
    )
  end

  # Only when nothing is left on it: a Product may still be using the same tag,
  # and this task must not touch product labels.
  def delete_tag_if_unused(tag_id)
    return if ActsAsTaggableOn::Tagging.exists?(tag_id: tag_id)

    ActsAsTaggableOn::Tag.where(id: tag_id).delete_all
    @summary[:tags_deleted] += 1
  end

  def recount(tag)
    tag.update_column(:taggings_count, ActsAsTaggableOn::Tagging.where(tag_id: tag.id).count) # rubocop:disable Rails/SkipsModelValidations
  end

  def conversation_ids_for(tag_id)
    label_taggings.where(tag_id: tag_id, taggable_type: 'Conversation').pluck(:taggable_id)
  end

  # `label_list` reads this column whenever it is set, so a tagging moved by SQL
  # stays invisible and a purged one comes back on the next write. Column-wise
  # on purpose: a repair pass must not emit a conversation event per row.
  def refresh_conversation_cache(conversation_ids)
    return if conversation_ids.blank?

    Conversation.where(id: conversation_ids).find_each do |conversation|
      # Through TagList, not a plain join: it is what writes the column on a
      # normal save, quoting included, so a repaired row reads back identically.
      cached = ActsAsTaggableOn::TagList.new(conversation.labels.reload.map(&:name)).to_s
      conversation.update_column(:cached_label_list, cached) # rubocop:disable Rails/SkipsModelValidations
      @summary[:conversations_refreshed] += 1
    end
  end

  def report_totals
    say "#{fix ? 'APPLIED' : 'DRY-RUN'}: rewired=#{@summary[:rewired]} catalogued=#{@summary[:catalogued]} " \
        "purged=#{@summary[:purged]} tags_deleted=#{@summary[:tags_deleted]} " \
        "conversations_refreshed=#{@summary[:conversations_refreshed]} uuid_left=#{@summary[:uuid_left]}"
    say 're-run with FIX=1 to apply changes' unless fix
    return unless @summary[:uuid_left].positive?

    say "#{@summary[:uuid_left]} application(s) point at a UUID with no Label. Decide per case: " \
        'recreate the label with the right title, or remove the applications.'
  end

  def say(message)
    @io.puts "[labels_reconcile] #{message}"
  end
end
