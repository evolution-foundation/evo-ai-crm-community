# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineServiceDefinition, type: :model do
  let(:user) { User.create!(email: 'svc-test@example.com', name: 'Test User') }
  let(:pipeline) do
    Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'sales', created_by: user)
  end

  def build_definition(attrs = {})
    pipeline.pipeline_service_definitions.new(
      { name: 'Consulting', default_value: 150.00, currency: 'BRL' }.merge(attrs)
    )
  end

  describe 'associations' do
    it 'belongs to pipeline' do
      definition = build_definition
      expect(definition.pipeline).to eq(pipeline)
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(build_definition).to be_valid
    end

    it 'requires name' do
      definition = build_definition(name: nil)
      expect(definition).not_to be_valid
      expect(definition.errors[:name]).to include("can't be blank")
    end

    it 'requires name max 255 characters' do
      definition = build_definition(name: 'a' * 256)
      expect(definition).not_to be_valid
      expect(definition.errors[:name]).to be_present
    end

    it 'requires unique name per pipeline' do
      build_definition.save!
      duplicate = build_definition(name: 'Consulting')
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include('has already been taken')
    end

    it 'allows same name on different pipelines' do
      build_definition.save!
      other_pipeline = Pipeline.create!(name: 'Other Pipeline', pipeline_type: 'custom', created_by: user)
      other_def = other_pipeline.pipeline_service_definitions.new(
        name: 'Consulting', default_value: 100.00, currency: 'BRL'
      )
      expect(other_def).to be_valid
    end

    it 'requires default_value' do
      definition = build_definition(default_value: nil)
      expect(definition).not_to be_valid
    end

    it 'requires default_value >= 0' do
      definition = build_definition(default_value: -1)
      expect(definition).not_to be_valid
    end

    it 'allows default_value of 0' do
      definition = build_definition(default_value: 0)
      expect(definition).to be_valid
    end

    it 'requires currency' do
      definition = build_definition(currency: nil)
      expect(definition).not_to be_valid
    end

    it 'requires valid currency' do
      definition = build_definition(currency: 'XYZ')
      expect(definition).not_to be_valid
    end

    SupportedCurrencies::CODES.each do |currency|
      it "accepts #{currency} currency" do
        definition = build_definition(currency: currency)
        expect(definition).to be_valid
      end
    end

    it 'requires pipeline_id' do
      definition = PipelineServiceDefinition.new(name: 'Test', default_value: 10, currency: 'BRL')
      expect(definition).not_to be_valid
      expect(definition.errors[:pipeline_id]).to include("can't be blank")
    end
  end

  describe 'scopes' do
    let!(:active_def) { build_definition(name: 'Active Service').tap(&:save!) }
    let!(:inactive_def) { build_definition(name: 'Inactive Service', active: false).tap(&:save!) }

    describe '.active' do
      it 'returns only active definitions' do
        expect(described_class.active).to include(active_def)
        expect(described_class.active).not_to include(inactive_def)
      end
    end

    describe '.for_pipeline' do
      it 'returns definitions for given pipeline' do
        expect(described_class.for_pipeline(pipeline)).to include(active_def, inactive_def)
      end
    end
  end

  describe '#formatted_default_value' do
    it 'formats BRL with comma separator' do
      definition = build_definition(default_value: 1500.50, currency: 'BRL')
      expect(definition.formatted_default_value).to eq('1500,50')
    end

    it 'formats EUR with comma separator' do
      definition = build_definition(default_value: 1500.50, currency: 'EUR')
      expect(definition.formatted_default_value).to eq('1500,50')
    end

    it 'formats USD with dot separator' do
      definition = build_definition(default_value: 1500.50, currency: 'USD')
      expect(definition.formatted_default_value).to eq('1500.50')
    end

    it 'formats GBP with dot separator' do
      definition = build_definition(default_value: 1500.50, currency: 'GBP')
      expect(definition.formatted_default_value).to eq('1500.50')
    end
  end
end
