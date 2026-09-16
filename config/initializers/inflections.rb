# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, '\1en'
#   inflect.singular /^(ox)en/i, '\1'
#   inflect.irregular 'person', 'people'
#   inflect.uncountable %w( fish sheep )
# end

# These inflection rules are supported but not enabled by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.acronym 'RESTful'
# end

# Rails' default inflector singularizes "bases" to "basis" (as in "knowledge
# basis"), which would make the nested `resources :knowledge_bases` route
# derive the foreign key param as `:knowledge_basis_id` instead of the
# `:knowledge_base_id` the KnowledgeDocumentsController expects. Force the
# correct singular so routing, param names and controller code all agree.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.irregular 'knowledge_base', 'knowledge_bases'
end
