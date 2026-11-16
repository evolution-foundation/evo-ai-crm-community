# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Internal::RemoveStaleContactsService do
  let(:user) { User.create!(email: %w[stale-owner example.com].join('@'), name: 'Stale Owner') }
  let(:pipeline) { Pipeline.create!(name: 'Stale Pipeline', pipeline_type: Pipeline::VALID_TYPES.first, created_by: user) }
  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }

  def stale_contact(name, **attrs)
    Contact.create!(name: name, **attrs).tap { |contact| contact.update_columns(created_at: 31.days.ago) }
  end

  it 'removes a stale contact and keeps one that sits in a pipeline' do
    orphan = stale_contact('Orphan')
    in_pipeline = stale_contact('In pipeline')
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: in_pipeline)

    expect { described_class.new.perform }.not_to raise_error

    expect(Contact.exists?(orphan.id)).to be(false)
    expect(Contact.exists?(in_pipeline.id)).to be(true)
  end

  it 'keeps contacts linked to a company, on either side of the link' do
    member = stale_contact('Member')
    company = stale_contact('Company', type: 'company')
    ContactCompany.create!(contact: member, company: company)

    expect { described_class.new.perform }.not_to raise_error

    expect(Contact.exists?(member.id)).to be(true)
    expect(Contact.exists?(company.id)).to be(true)
  end

  it 'keeps recent contacts and contacts with an email' do
    recent = Contact.create!(name: 'Recent')
    with_email = stale_contact('With email', email: %w[with-email example.com].join('@'))

    described_class.new.perform

    expect(Contact.exists?(recent.id)).to be(true)
    expect(Contact.exists?(with_email.id)).to be(true)
  end
end
