# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ai::ModelResolver do
  it 'removes the OpenRouter provider marker from a model selector value' do
    expect(described_class.resolve('openrouter/anthropic/claude-sonnet', provider: 'openrouter'))
      .to eq('anthropic/claude-sonnet')
  end

  it 'keeps an OpenRouter model ID in author/model format' do
    expect(described_class.resolve('google/gemini-flash', provider: 'openrouter'))
      .to eq('google/gemini-flash')
  end

  it 'maps a bare OpenAI model name to its OpenRouter model ID' do
    expect(described_class.resolve('gpt-4.1-nano', provider: 'openrouter'))
      .to eq('openai/gpt-4.1-nano')
  end

  it 'uses the dedicated OpenRouter model without changing the OpenAI model' do
    expect(
      described_class.resolve(
        'gpt-4o', provider: 'openrouter', openrouter_model: 'anthropic/claude-sonnet'
      )
    ).to eq('anthropic/claude-sonnet')
  end

  it 'does not change model names for other providers' do
    expect(described_class.resolve('gpt-4.1-nano', provider: 'openai'))
      .to eq('gpt-4.1-nano')
  end
end
