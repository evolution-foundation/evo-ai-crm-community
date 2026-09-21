# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledActions::ExecutorService do
  subject(:service) { described_class.allocate }

  def with_contact_phone(phone_number)
    action = instance_double(ScheduledAction, contact: instance_double(Contact, phone_number: phone_number))
    service.define_singleton_method(:scheduled_action) { action }
  end

  it 'derives the WhatsApp source_id in the channel form, not from the stored number' do
    with_contact_phone('+5531988887777')

    expect(service.send(:whatsapp_source_id)).to eq('553188887777')
  end

  it 'is the same source_id the contact inbox builder derives' do
    with_contact_phone('+5531988887777')

    expect(service.send(:whatsapp_source_id)).to eq(ContactInboxBuilder.whatsapp_source_id('+5531988887777'))
  end

  it 'is nil without a phone' do
    with_contact_phone(nil)

    expect(service.send(:whatsapp_source_id)).to be_nil
  end
end
