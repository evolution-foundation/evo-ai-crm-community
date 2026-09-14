# frozen_string_literal: true

require 'rails_helper'

# CRM-579 split `transform_user_mention_content` in two: the mention stripping
# went away with the feature, the nil coercion stayed. Only the second half has
# a caller that breaks without it — `EvolutionMarkdownRenderer` hands the content
# straight to CommonMarker, which raises on nil.
RSpec.describe MessageFormatHelper do
  subject(:helper) { Class.new { include MessageFormatHelper }.new }

  describe '#message_body_content' do
    it 'coerces nil to an empty string (attachment message without text)' do
      expect(helper.message_body_content(nil)).to eq('')
    end

    it 'coerces a blank string to an empty string' do
      expect(helper.message_body_content('   ')).to eq('')
    end

    it 'returns the content untouched' do
      expect(helper.message_body_content('hello **world**')).to eq('hello **world**')
    end

    it 'no longer strips mention markup' do
      markup = '[@Agente](mention://user/e3277abc-d614-4850-acd1-6612d694d0f9/Agente)'
      expect(helper.message_body_content(markup)).to eq(markup)
    end
  end

  describe '#render_message_content' do
    it 'renders what #message_body_content returns for a nil body' do
      expect { helper.render_message_content(helper.message_body_content(nil)) }.not_to raise_error
    end

    it 'is the caller that cannot take nil (control for the coercion above)' do
      expect { helper.render_message_content(nil) }.to raise_error(TypeError)
    end
  end
end
