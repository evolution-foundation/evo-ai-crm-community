module Whatsapp::EvolutionGoHandlers::ContentHandlers
  private

  def handle_location
    location_msg = @evolution_go_message&.dig(:locationMessage)
    return unless location_msg

    @message.content_attributes[:location] = {
      latitude: location_msg[:degreesLatitude],
      longitude: location_msg[:degreesLongitude],
      name: location_msg[:name],
      address: location_msg[:address]
    }
  end

  def handle_contacts
    contact_msg = @evolution_go_message&.dig(:contactMessage)
    contacts = contact_msg ? [contact_msg] : Array(@evolution_go_message&.dig(:contactsArrayMessage, :contacts))

    @message.content_attributes[:contacts] = contacts.map do |contact|
      {
        display_name: contact[:displayName],
        vcard: contact[:vcard]
      }
    end
  end
end
