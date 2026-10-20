# Splits Meta envelopes without mixing phone numbers, contacts or directions.
class Whatsapp::CloudEventNormalizer
  KINDS = %w[messages message_echoes statuses].freeze
  FIELDS = %w[messages smb_message_echoes standby].freeze

  def self.call(params)
    new(params.with_indifferent_access).call
  end

  def initialize(params)
    @params = params
  end

  def call
    Array(@params[:entry]).flat_map do |entry|
      next [] unless entry.is_a?(Hash)

      Array(entry[:changes]).flat_map { |change| normalize_change(entry, change) }
    end
  end

  private

  def normalize_change(entry, change)
    return [] unless valid_change?(change)
    return [@params.merge(entry: [entry.merge(changes: [change])])] unless FIELDS.include?(change[:field])

    standby = change[:field] == 'standby'
    body = standby ? change[:value][:standby] : change[:value]
    return [] unless body.is_a?(Hash)

    normalize_items(entry, change, body)
  end

  def normalize_items(entry, change, body)
    standby = change[:field] == 'standby'
    KINDS.flat_map do |kind|
      Array(body[kind]).filter_map do |raw|
        item = normalize_item(raw, kind, standby)
        build_event(entry, change, body, kind, item) if item
      end
    end
  end

  def normalize_item(item, kind, standby)
    return unless item.is_a?(Hash) && item[:id].present?

    if kind == 'message_echoes' && standby
      return unless item[:message].is_a?(Hash)

      item = item[:message].merge(id: item[:id], timestamp: item[:timestamp],
                                  standby_template: item[:template], standby_flow: item[:flow])
    end
    return unless valid_content?(item, kind)

    item
  end

  def valid_change?(change)
    change.is_a?(Hash) && change[:value].is_a?(Hash)
  end

  def valid_content?(item, kind)
    kind == 'statuses' || (item[:type].present? && item[:timestamp].present?)
  end

  def build_event(entry, change, body, kind, item)
    value = change[:value]
    standby = change[:field] == 'standby'
    identity = kind == 'statuses' ? [item[:recipient_id], item[:recipient_user_id]] : [item[:from], item[:to]]
    contacts = Array(body[:contacts]).select do |contact|
      contact.is_a?(Hash) && ([contact[:wa_id], contact[:user_id]].compact & identity.compact).any?
    end
    field = kind == 'message_echoes' ? 'smb_message_echoes' : 'messages'
    normalized = value.except(:standby, :messages, :message_echoes, :statuses, :contacts)
                      .merge(kind => [item], 'contacts' => contacts)
    @params.except(:entry).merge(
      observed: standby || kind == 'message_echoes',
      entry: [entry.except(:changes).merge(changes: [{ field: field, value: normalized }])]
    )
  end
end
