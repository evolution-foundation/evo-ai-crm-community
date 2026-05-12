# Cleanup task for taggings/tags that ended up storing the Label UUID as the
# tag name. This happened because automation rules (add_label / apply_label)
# used to receive the Label id from the frontend and feed it directly into
# acts_as_taggable_on, which then created a brand-new tag named after the
# UUID instead of attaching the existing one (which has the title as name).
#
# Usage:
#   bundle exec rake automation:cleanup_label_uuid_tags          # report only
#   bundle exec rake automation:cleanup_label_uuid_tags FIX=1    # apply changes
#
# The task is idempotent — running it twice with FIX=1 produces no further
# changes once the data is consistent.
namespace :automation do
  desc 'Find/rewrite taggings whose tag.name is a Label UUID, replacing them with the title-tag'
  task cleanup_label_uuid_tags: :environment do
    uuid_regex = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    apply = ENV['FIX'].to_s == '1'

    uuid_named_tags = ActsAsTaggableOn::Tag.where('name ~* ?', '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')

    if uuid_named_tags.empty?
      puts '[labels_cleanup] no UUID-named tags found, nothing to do.'
      next
    end

    summary = { rewired: 0, deleted_tags: 0, skipped: 0 }

    uuid_named_tags.find_each do |bad_tag|
      bad_name = bad_tag.name.to_s

      unless uuid_regex.match?(bad_name)
        summary[:skipped] += 1
        next
      end

      label = Label.find_by(id: bad_name)
      good_title = label&.title

      taggings_count = ActsAsTaggableOn::Tagging.where(tag_id: bad_tag.id).count

      if good_title.blank?
        puts "[labels_cleanup] tag #{bad_tag.id} name=#{bad_name} has no matching Label — keeping (#{taggings_count} taggings)"
        summary[:skipped] += 1
        next
      end

      good_tag = ActsAsTaggableOn::Tag.find_or_create_by(name: good_title)

      puts "[labels_cleanup] tag #{bad_tag.id} name=#{bad_name} -> tag #{good_tag.id} name=#{good_title} (taggings=#{taggings_count})"

      next unless apply

      ActiveRecord::Base.transaction do
        rewired = 0
        skipped_duplicates = 0

        ActsAsTaggableOn::Tagging.where(tag_id: bad_tag.id).find_each do |tagging|
          duplicate = ActsAsTaggableOn::Tagging.where(
            tag_id: good_tag.id,
            taggable_id: tagging.taggable_id,
            taggable_type: tagging.taggable_type,
            context: tagging.context
          ).exists?

          if duplicate
            tagging.destroy!
            skipped_duplicates += 1
          else
            tagging.update_column(:tag_id, good_tag.id) # rubocop:disable Rails/SkipsModelValidations
            rewired += 1
          end
        end

        # Recount good_tag taggings in case the cached counter drifted.
        good_tag.update_column(:taggings_count, ActsAsTaggableOn::Tagging.where(tag_id: good_tag.id).count) # rubocop:disable Rails/SkipsModelValidations

        bad_tag.destroy!
        summary[:deleted_tags] += 1
        summary[:rewired]      += rewired

        puts "  rewired=#{rewired} duplicates_removed=#{skipped_duplicates}"
      end
    end

    mode = apply ? 'APPLIED' : 'DRY-RUN'
    puts "[labels_cleanup] #{mode}: taggings rewired=#{summary[:rewired]} tags deleted=#{summary[:deleted_tags]} skipped=#{summary[:skipped]}"
    puts '[labels_cleanup] re-run with FIX=1 to apply changes' unless apply
  end
end
