class DataImport::ContactManager
  def initialize(_account = nil)
  end

  def build_contact(params)
    contact = find_or_initialize_contact(params)
    update_contact_attributes(params, contact)
    contact
  end

  def find_or_initialize_contact(params)
    contact = find_existing_contact(params)
    contact_params = params.slice(:email, :identifier, :phone_number)
    contact_params[:phone_number] = format_phone_number(contact_params[:phone_number]) if contact_params[:phone_number].present?
    contact_params[:type] = params[:tipo] || params[:type] || 'person'
    contact ||= Contact.new(contact_params)
    contact
  end

  def find_existing_contact(params)
    contact = find_contact_by_identifier(params)
    contact ||= find_contact_by_email(params)
    contact ||= find_contact_by_phone_number(params)
    contact ||= find_contact_by_tax_id(params)

    update_contact_with_merged_attributes(params, contact) if contact.present? && contact.valid?
    contact
  end

  def find_contact_by_identifier(params)
    return unless params[:identifier]

    Contact.find_by(identifier: params[:identifier])
  end

  def find_contact_by_email(params)
    return unless params[:email]

    Contact.from_email(params[:email])
  end

  def find_contact_by_phone_number(params)
    return unless params[:phone_number]

    Contact.find_by(phone_number: format_phone_number(params[:phone_number]))
  end

  def find_contact_by_tax_id(params)
    tax_id = sanitize_tax_id(params[:cpf_cnpj] || params[:cpf] || params[:cnpj] || params[:tax_id])
    return unless tax_id.present?

    Contact.find_by(tax_id: tax_id)
  end

  def format_phone_number(phone_number)
    return unless phone_number.present?

    cleaned = phone_number.to_s.gsub(/\D/, '')
    cleaned.start_with?('+') ? cleaned : "+#{cleaned}"
  end

  def sanitize_tax_id(tax_id)
    tax_id.to_s.gsub(/\D/, '') if tax_id.present?
  end

  def update_contact_with_merged_attributes(params, contact)
    contact.identifier = params[:identifier] if params[:identifier].present?
    contact.email = params[:email] if params[:email].present?
    contact.phone_number = format_phone_number(params[:phone_number]) if params[:phone_number].present?
    update_contact_attributes(params, contact)
    contact.save # rubocop:disable Rails/SaveBang
  end

  private

  def update_contact_attributes(params, contact)
    # Tipo de contato
    contact.type = params[:tipo] || params[:type] || 'person'

    # Campos base
    contact.name = build_name(params)
    contact.last_name = params[:sobrenome] if params[:sobrenome].present?
    contact.email = params[:email] if params[:email].present?
    contact.phone_number = format_phone_number(params[:telefone] || params[:phone_number]) if (params[:telefone] || params[:phone_number]).present?
    contact.tax_id = sanitize_tax_id(params[:cpf_cnpj] || params[:cpf] || params[:cnpj] || params[:tax_id])

    # Campos específicos
    contact.website = params[:website] if params[:website].present?
    contact.industry = params[:segmento_industria] || params[:industry] if (params[:segmento_industria] || params[:industry]).present?

    # Localização
    process_location_attributes(params, contact)

    # Redes sociais
    process_social_attributes(params, contact)

    # Descrição
    process_description(params, contact)

    # Atributos customizados (campos não reconhecidos)
    process_custom_attributes(params, contact)

    contact
  end

  def build_name(params)
    # Para pessoa física: primeiro_nome
    if params[:tipo] == 'person' || params[:type] == 'person'
      first_name = params[:primeiro_nome] || params[:first_name] || params[:nome] || params[:name]
      last_name = params[:sobrenome] || params[:last_name]
      return "#{first_name} #{last_name}".strip if first_name.present?
    end

    # Para empresa: razao_social ou name
    params[:razao_social] || params[:nome] || params[:name] || ''
  end

  def process_location_attributes(params, contact)
    contact.additional_attributes ||= {}
    contact.additional_attributes[:city] = params[:cidade] if params[:cidade].present?
    contact.additional_attributes[:country] = params[:pais] if params[:pais].present?
    contact.country_code = params[:codigo_pais] if params[:codigo_pais].present?
  end

  def process_social_attributes(params, contact)
    contact.additional_attributes ||= {}
    contact.additional_attributes[:social_profiles] ||= {}

    social_fields = %w[linkedin facebook instagram twitter github]
    social_fields.each do |field|
      contact.additional_attributes[:social_profiles][field] = params[field.to_sym] if params[field.to_sym].present?
    end
  end

  def process_description(params, contact)
    contact.additional_attributes ||= {}
    contact.additional_attributes[:description] = params[:descricao] if params[:descricao].present?
  end

  def process_custom_attributes(params, contact)
    contact.custom_attributes ||= {}

    # Campos conhecidos que NÃO são custom_attributes
    known_fields = %i[
      id tipo type name nome primeiro_nome first_name sobrenome last_name email telefone phone_number
      cpf_cnpj cpf cnpj tax_id website segmento_industria industry cidade pais codigo_pais
      linkedin facebook instagram twitter github descricao empresas_vinculadas company
      identifier ip_address custom_attribute_1 custom_attribute_2
    ]

    # Qualquer outro campo vira custom_attribute
    params.except(*known_fields).each do |key, value|
      contact.custom_attributes[key] = value if value.present?
    end
  end
end
