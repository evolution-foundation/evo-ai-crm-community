# frozen_string_literal: true

require 'rails_helper'

# CRM-608: on a pt-BR installation the 422 body was still written in English.
#
# The API renders validation failures from rescue_from, and ActionController::Rescue wraps
# AbstractController::Callbacks — so by the time the handler builds the body, the around_action's
# I18n.with_locale has already unwound and what is left is I18n.default_locale. That is why the
# installation language has to reach default_locale (config/initializers/languages.rb) and not
# only the around_action.
RSpec.describe 'API validation errors on a pt-BR installation', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  around do |example|
    previous_default = I18n.default_locale
    # Read before default_locale moves: I18n.locale falls back to it while nothing has pinned a
    # value, so restoring it afterwards would hand pt_BR to every spec that runs after this file.
    previous_locale = I18n.locale
    previous_env = ENV.fetch('DEFAULT_LOCALE', nil)
    # What config/initializers/languages.rb produces from DEFAULT_LOCALE=pt_BR at boot.
    I18n.default_locale = :pt_BR
    I18n.with_locale(:pt_BR) { example.run }
  ensure
    I18n.default_locale = previous_default
    I18n.locale = previous_locale # rubocop:disable Rails/I18nLocaleAssignment
    previous_env.nil? ? ENV.delete('DEFAULT_LOCALE') : ENV['DEFAULT_LOCALE'] = previous_env
  end

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def detail_for(field)
    response.parsed_body.dig('error', 'details').find { |detail| detail['field'] == field }
  end

  describe 'PATCH /api/v1/contacts/:id with an e-mail another contact already uses' do
    let!(:owner) { Contact.create!(name: 'Dona do e-mail', email: 'duplicado@example.com') }
    let!(:contact) { Contact.create!(name: 'Quem edita', email: 'editando@example.com') }

    it 'answers 422 with the envelope message and the field messages in pt-BR' do
      patch "/api/v1/contacts/#{contact.id}",
            params: { email: owner.email },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'code')).to eq('VALIDATION_ERROR')
      # The only part of the envelope the CRM puts on screen (apiErrorMessage reads error.message).
      expect(response.parsed_body.dig('error', 'message')).to eq('Falha na validação')

      email = detail_for('email')
      expect(email['messages']).to eq(['já está em uso'])
      expect(email['full_messages']).to eq(['Email já está em uso'])
    end

    it 'keeps the body in the installation language even when the request ran under another one' do
      # DEFAULT_LOCALE feeds the around_action, so the action body runs in English here. The
      # validation body is built after that block unwinds, so it must still come out in pt-BR —
      # this is exactly what setting the env alone could not deliver.
      ENV['DEFAULT_LOCALE'] = 'en'

      patch "/api/v1/contacts/#{contact.id}",
            params: { email: owner.email },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(detail_for('email')['messages']).to eq(['já está em uso'])
    end
  end

  describe 'PATCH /api/v1/contacts/:id with a name longer than the generic column limit' do
    let!(:contact) { Contact.create!(name: 'Nome curto', email: 'comprido@example.com') }

    it 'translates the length message that ApplicationRecord adds for every string column' do
      patch "/api/v1/contacts/#{contact.id}",
            params: { name: 'a' * 256 },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(detail_for('name')['messages']).to eq(['é muito longo (máximo: 255 caracteres)'])
    end
  end

  describe 'the standard ActiveModel messages the API can emit' do
    it 'has pt-BR text for the types the envelope exposes' do
      {
        taken: 'já está em uso',
        blank: 'não pode ficar em branco',
        invalid: 'não é válido',
        present: 'deve ficar em branco',
        inclusion: 'não está incluído na lista'
      }.each do |type, text|
        errors = ActiveModel::Errors.new(Contact.new)
        errors.add(:name, type)

        expect(errors[:name]).to eq([text])
      end
    end

    # These two sat one level too deep, under errors.conversations, so Contact's format
    # validations resolved to a missing-translation marker in en and pt_BR while es/fr/it/pt
    # were fine. Asserted on the catalogue rather than on a Contact because contact.rb calls
    # I18n.t in the class body, which freezes the text at whatever locale first loaded the class.
    it 'resolves the custom format messages Contact declares, in both shipped defaults' do
      %i[en pt_BR].each do |locale|
        expect(I18n.t('errors.contacts.email.invalid', locale: locale)).not_to match(/translation missing/i)
        expect(I18n.t('errors.contacts.phone_number.invalid', locale: locale)).not_to match(/translation missing/i)
      end
    end
  end

  describe 'an installation left on the default language' do
    around do |example|
      previous_default = I18n.default_locale
      previous_locale = I18n.locale
      I18n.default_locale = :en
      I18n.with_locale(:en) { example.run }
    ensure
      I18n.default_locale = previous_default
      I18n.locale = previous_locale # rubocop:disable Rails/I18nLocaleAssignment
    end

    it 'still answers in English, so the published API keeps its wording' do
      owner = Contact.create!(name: 'Owner', email: 'taken-en@example.com')
      contact = Contact.create!(name: 'Editing', email: 'editing-en@example.com')

      patch "/api/v1/contacts/#{contact.id}",
            params: { email: owner.email },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to eq('Validation failed')
      expect(detail_for('email')['messages']).to eq(['has already been taken'])
    end
  end

  # Four of the six enabled languages (es, fr, it, pt) carry no errors.messages and no
  # errors.api of their own. Feeding default_locale from DEFAULT_LOCALE therefore aims the whole
  # validation body at a catalogue with a hole in it, and error.message is the field the CRM
  # puts on screen. The floor under it is the fallback chain in config/application.rb; without
  # it the body below reads "Translation missing".
  describe 'an installation on an enabled language that ships no error catalogue' do
    around do |example|
      previous_default = I18n.default_locale
      previous_locale = I18n.locale
      I18n.default_locale = :es
      I18n.with_locale(:es) { example.run }
    ensure
      I18n.default_locale = previous_default
      I18n.locale = previous_locale # rubocop:disable Rails/I18nLocaleAssignment
    end

    it 'answers the gaps in English instead of a missing-translation marker' do
      owner = Contact.create!(name: 'Dueña', email: 'taken-es@example.com')
      contact = Contact.create!(name: 'Editando', email: 'editing-es@example.com')

      patch "/api/v1/contacts/#{contact.id}",
            params: { email: owner.email },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to eq('Validation failed')
      expect(detail_for('email')['messages']).to eq(['has already been taken'])
      # The floor does not shadow what the language does carry.
      expect(I18n.t('errors.validations.presence')).to eq('no debe estar en blanco')
    end

    # The language first, English as the floor. `fallbacks = true` yields neither: its chain
    # ends at I18n.default_locale, the value DEFAULT_LOCALE has just moved to :es.
    it 'puts the installation language first and ends every chain at :en' do
      expect(I18n.fallbacks[:es]).to eq(%i[es en])
      # No pt hop on the way: the locale symbol is pt_BR and ancestry splits on a hyphen.
      expect(I18n.fallbacks[:pt_BR]).to eq(%i[pt_BR en])
    end
  end
end
