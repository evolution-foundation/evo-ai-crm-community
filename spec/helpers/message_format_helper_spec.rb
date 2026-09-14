# frozen_string_literal: true

require 'rails_helper'

# The nil coercion is the load-bearing half: CommonMarker raises on nil, and an
# attachment-only message reaches the renderer with no content.
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
