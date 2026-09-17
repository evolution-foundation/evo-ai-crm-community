# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::TemplateButtonParams do
  describe '.split' do
    it 'keeps a body-only template exactly as it was (no button component)' do
      body, buttons = described_class.split({ '1' => 'João', '2' => 'sexta' })

      expect(body).to eq({ '1' => 'João', '2' => 'sexta' })
      expect(buttons).to eq([])
    end

    it 'turns a button-only template into a url button component with no body params' do
      body, buttons = described_class.split({ 'button_0_1' => 'abc123' })

      expect(body).to eq({})
      expect(buttons).to eq([
                              { type: 'button', sub_type: 'url', index: '0',
                                parameters: [{ type: 'text', text: 'abc123' }] }
                            ])
    end

    # The evidence template: {{1}} in the body AND {{1}} in the button url. Same
    # number, two scopes — they must never collapse into one body parameter.
    it 'separates the body {{1}} from the button {{1}}' do
      body, buttons = described_class.split({ '1' => 'João', 'button_0_1' => 'abc123' })

      expect(body).to eq({ '1' => 'João' })
      expect(buttons.map { |b| b[:index] }).to eq(['0'])
      expect(buttons.first[:parameters]).to eq([{ type: 'text', text: 'abc123' }])
    end

    it 'orders components by button index and parameters by {{n}}, whatever the hash order' do
      _, buttons = described_class.split({ 'button_2_1' => 'c', 'button_0_2' => 'a2', 'button_0_1' => 'a1' })

      expect(buttons.map { |b| b[:index] }).to eq(%w[0 2])
      expect(buttons.first[:parameters].map { |p| p[:text] }).to eq(%w[a1 a2])
    end

    it 'treats a key that only looks like a button key as a body parameter' do
      body, buttons = described_class.split({ 'button_0' => 'x', 'button_a_1' => 'y', 'button_0_1_extra' => 'z' })

      expect(body.keys).to eq(%w[button_0 button_a_1 button_0_1_extra])
      expect(buttons).to eq([])
    end

    it 'accepts symbol keys and stringifies the value' do
      body, buttons = described_class.split({ button_0_1: 42, '1': 'x' })

      expect(body).to eq({ '1': 'x' })
      expect(buttons.first[:parameters]).to eq([{ type: 'text', text: '42' }])
    end

    it 'is a no-op on nil or a non-hash' do
      expect(described_class.split(nil)).to eq([{}, []])
      expect(described_class.split('oops')).to eq([{}, []])
    end
  end
end
