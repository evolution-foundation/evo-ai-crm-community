# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The behaviour lives in Labels::OrphanReconcileService and is covered there.
# What this pins is the wiring: the task shipped once with a query Postgres
# refused outright, which no amount of reading caught and one invocation did.
RSpec.describe 'labels:reconcile_orphans rake task', type: :task do
  let(:task) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('labels:reconcile_orphans')
    Rake::Task['labels:reconcile_orphans']
  end

  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@test.com") }

  before do
    task.reenable
    ENV.delete('FIX')
    ENV.delete('PURGE')
  end

  after do
    ENV.delete('FIX')
    ENV.delete('PURGE')
  end

  it 'runs end to end and reports' do
    expect { task.invoke }.to output(/\[labels_reconcile\]/).to_stdout
  end

  it 'passes FIX through to the service' do
    tag = ActsAsTaggableOn::Tag.create!(name: 'Urgente')
    ActsAsTaggableOn::Tagging.create!(tag: tag, taggable: contact, context: 'labels')
    Label.create!(title: 'urgente')
    ENV['FIX'] = '1'

    task.invoke

    expect(contact.reload.label_list.to_a).to eq(['urgente'])
  end
end
