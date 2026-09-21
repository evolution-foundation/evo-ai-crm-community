class MessageFinder
  class InvalidParams < StandardError; end

  def initialize(conversation, params, includes: nil)
    @conversation = conversation
    @params = params
    @includes = includes
  end

  def perform
    validate_page!

    query = Message.where(conversation_id: @conversation.id)
                   .includes(@includes || [:sender, :attachments])

    # Filtrar mensagens internas se necessário
    if @params[:filter_internal_messages].present?
      query = query.where(private: false).where.not(message_type: :activity)
    end

    # Provider timestamps have second resolution, so created_at ties are common
    # (media bursts); id breaks the tie so no message falls between pages.
    if @params[:after].present?
      after_message = Message.find_by(id: @params[:after])
      query = query.where('(messages.created_at, messages.id) > (?, ?)', after_message.created_at, after_message.id) if after_message
    end

    if @params[:before].present?
      before_message = Message.find_by(id: @params[:before])
      query = query.where('(messages.created_at, messages.id) < (?, ?)', before_message.created_at, before_message.id) if before_message
    end

    # Aplicar paginação orientada por cursor:
    # - sem cursor: últimas mensagens
    # - before: página anterior
    # - after: novas mensagens após cursor
    limit = limit_for_params
    messages =
      if @params[:before].present? && @params[:after].blank?
        query.reorder(created_at: :desc, id: :desc).limit(limit).to_a.reverse
      elsif @params[:after].present? && @params[:before].blank?
        query.reorder(created_at: :asc, id: :asc).limit(limit).to_a
      elsif @params[:before].blank? && @params[:after].blank?
        query.reorder(created_at: :desc, id: :desc).offset((page - 1) * limit).limit(limit).to_a.reverse
      else
        query.reorder(created_at: :asc, id: :asc).limit(limit).to_a
      end

    # Carregar attachments se não foram incluídos
    unless @includes&.include?(:attachments)
      message_ids = messages.map(&:id)
      attachments_by_message = Attachment.where(attachable_type: 'Message', attachable_id: message_ids)
                                         .group_by(&:attachable_id)

      messages.each do |message|
        message.attachments = attachments_by_message[message.id] || []
      end
    end

    messages
  end

  private

  def validate_page!
    return if @params[:page].blank?

    if @params[:before].present? || @params[:after].present?
      raise InvalidParams, 'page cannot be combined with before/after; paginate with the cursor only'
    end
    raise InvalidParams, 'page must be a positive integer' unless @params[:page].to_s.match?(/\A[1-9]\d*\z/)
  end

  def page
    @params[:page].present? ? @params[:page].to_i : 1
  end

  def limit_for_params
    return 1000 if @params[:after].present? && @params[:before].present?
    return 20 if @params[:before].present?
    return 100 if @params[:after].present?
    20
  end
end
