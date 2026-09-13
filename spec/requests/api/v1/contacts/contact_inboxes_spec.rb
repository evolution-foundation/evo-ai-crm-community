# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/contacts/:contact_id/contact_inboxes', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:contact) { Contact.create!(name: 'Existing Contact', phone_number: '+5511900000003') }
  let(:whatsapp_channel) do
    channel = Channel::Whatsapp.new(
      phone_number: "+55119#{rand(10_000_000..99_999_999)}",
      provider: 'evolution',
      provider_config: { 'api_url' => 'https://evo.example.com', 'admin_token' => 'x', 'instance_name' => 'inst' }
    )
    channel.save(validate: false)
    channel
  end
  let(:whatsapp_inbox) { Inbox.create!(name: 'WA Inbox', channel: whatsapp_channel) }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  it 'blocks with a 422 when the provider confirms the contact phone number is not on WhatsApp' do
    allow_any_instance_of(Channel::Whatsapp).to receive(:check_whatsapp_number_exists?).and_return(false) # rubocop:disable RSpec/AnyInstance

    expect do
      post "/api/v1/contacts/#{contact.id}/contact_inboxes",
           params: { inbox_id: whatsapp_inbox.id },
           headers: headers,
           as: :json
    end.not_to change(ContactInbox, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response.dig('error', 'code')).to eq('WHATSAPP_API_ERROR')
  end

  it 'proceeds when the provider confirms the number exists' do
    allow_any_instance_of(Channel::Whatsapp).to receive(:check_whatsapp_number_exists?).and_return(true) # rubocop:disable RSpec/AnyInstance

    post "/api/v1/contacts/#{contact.id}/contact_inboxes",
         params: { inbox_id: whatsapp_inbox.id },
         headers: headers,
         as: :json

    expect(ContactInbox.find_by(contact: contact, inbox: whatsapp_inbox)).to be_present
  end
end
