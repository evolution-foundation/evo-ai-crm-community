# Reconciles label taggings that have no matching entry in the Label catalog.
# The report states what the run can see before it states what it found.
#
#   FIX=1 catalogs and rewires; FIX=1 PURGE=1 deletes those rows instead.
namespace :labels do
  desc 'Reconcile label taggings with no matching Label in the catalog'
  task reconcile_orphans: :environment do
    Labels::OrphanReconcileService.call(fix: ENV['FIX'].to_s == '1', purge: ENV['PURGE'].to_s == '1')
  end
end
