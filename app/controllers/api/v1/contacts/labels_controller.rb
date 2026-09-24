class Api::V1::Contacts::LabelsController < Api::V1::Contacts::BaseController
  include LabelConcern

  require_permissions({
    index: 'contacts.read',
    create: 'contacts.update',
    add: 'contacts.update',
    remove: 'contacts.update'
  })

  # `create` replaces the contact's whole label set; `add` and `remove` only
  # touch the labels sent, so a caller never has to read the set first.
  # Both still rewrite the set, so the contact row is locked meanwhile: two
  # concurrent adds would otherwise each save their own union and drop one.
  def add
    change_labels { |titles| model.add_labels(titles) }
  end

  def remove
    change_labels { |titles| model.remove_labels(titles) }
  end

  private

  def change_labels
    titles = resolve_label_titles(incoming_label_tokens)
    if titles.empty?
      return error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        'labels is required',
        details: { field: 'labels', message: 'must list at least one label' },
        status: :unprocessable_entity
      )
    end

    model.with_lock { yield titles }
    render_labels
  end

  # Shaped like `success_response`, with `payload` kept beside `data`: this is a
  # public API and an integration written against the older shape would read a
  # missing set and post it back, wiping the labels the same way.
  def render_labels
    labels = model.label_list.to_a
    render json: { success: true, data: labels, payload: labels, meta: { timestamp: Time.current.iso8601 } }
  end

  def model
    @model ||= @contact
  end

  def permitted_params
    params.permit(labels: [])
  end
end
