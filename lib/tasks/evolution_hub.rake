# Replaces the placeholder instagram_id / page_id of Hub channels the Hub already connected.
# Report-only by default; APPLY=1 writes.
namespace :evolution_hub do
  desc 'Replace placeholder ids on Hub-connected Instagram and Facebook channels'
  task repair_placeholder_ids: :environment do
    EvolutionHub::PlaceholderIdRepairService.call(apply: ENV['APPLY'].to_s == '1')
  end
end
