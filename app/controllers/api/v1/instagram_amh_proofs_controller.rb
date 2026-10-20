# frozen_string_literal: true

class Api::V1::InstagramAmhProofsController < Api::V1::BaseController
  require_permissions({ operations: 'journeys.read', index: 'journeys.read', show: 'journeys.read', create: 'journeys.create',
                        update: 'journeys.update', publish: 'journeys.toggle_active', simulate: 'journeys.update',
                        catalog: 'journeys.read', test_events: 'journeys.read', deliveries: 'journeys.read',
                        activate: 'journeys.toggle_active', test_reply: 'journeys.toggle_active' })
  before_action :fetch_proof, except: %i[index create operations catalog test_events]
  rescue_from Instagram::AmhVisualEngine::Invalid, with: :invalid_graph
  rescue_from ActiveRecord::StaleObjectError, with: :stale

  rescue_from Instagram::AmhCatalog::Unavailable, Instagram::AmhExecutor::Unavailable, Instagram::AmhConnection::ConfigurationError, with: :unavailable

  def catalog
    response.headers['Cache-Control'] = 'no-store'
    success_response(data: Instagram::AmhCatalog.snapshot)
  end

  def test_events
    response.headers['Cache-Control'] = 'no-store'
    inbox = Instagram::AmhConnection.bound_inbox!
    events = Instagram::AmhInboundEvent.where(inbox_id: inbox.id).where('created_at > ?', 7.days.ago)
                                     .order(created_at: :desc).limit(100).filter_map do |event|
      contract = event.contract
      next unless contract['kind'] == 'comment' && Instagram::AmhExecutor.test_identity?(contract)

      { id: event.id, media: contract['media_id'], text: contract['comment_text'].to_s.truncate(200),
        at: contract['occurred_at'], delivered: Instagram::AmhDelivery.exists?(inbound_event_id: event.id) }
    end
    success_response(data: events)
  end

  def deliveries
    response.headers['Cache-Control'] = 'no-store'
    success_response(data: Instagram::AmhDelivery.where(proof_id: @proof.id).order(created_at: :desc).limit(50).map(&:snapshot))
  end

  def activate
    audience = params.require(:audience).to_s
    raise Instagram::AmhVisualEngine::Invalid, 'Estado inválido' unless %w[paused test active].include?(audience)

    Instagram::AmhVisualProof.with_mapping_lock do
      @proof.reload
      raise ActiveRecord::StaleObjectError.new(@proof, 'activate') unless @proof.lock_version == expected_lock_version

      version = @proof.versions.find { |v| v['id'] == params[:version_id] }
      unless audience == 'paused'
        raise Instagram::AmhExecutor::Unavailable unless Instagram::AmhExecutor.enabled? && version
        Instagram::AmhVisualEngine.validate!(version['graph'])
        reply = version['graph']['nodes'].find { |n| n['id'] == 'reply' }['data']
        unless reply['confirmationRequired'] == true
          raise Instagram::AmhVisualEngine::Invalid, 'Publique uma versão com confirmação antes da entrega'
        end
        scope = version['graph']['nodes'].find { |n| n['id'] == 'scope' }['data']
        raise Instagram::AmhExecutor::Unavailable unless Instagram::AmhConnection.managed_account?(scope['account'])
        unless %w[media ad].all? { |key| scope[key].blank? || /\A[0-9]{1,64}\z/.match?(scope[key]) }
          raise Instagram::AmhVisualEngine::Invalid, 'Use o ID numérico da publicação ou anúncio'
        end
        # A successful controlled provider receipt is required for the selected version.
        if audience == 'active' && !Instagram::AmhDelivery.where(proof_id: @proof.id, version_id: version['id'], state: 'accepted').where.not(confirmation_event_id: nil).exists?
          raise Instagram::AmhVisualEngine::Invalid, 'Conclua o teste real desta versão antes de ativar'
        end
        if audience == 'test' && ENV.fetch('INSTAGRAM_AMH_TEST_IGSIDS', '').split(',').reject(&:blank?).empty?
          raise Instagram::AmhExecutor::Unavailable
        end
      end
      waiting = Instagram::AmhDelivery.where(proof_id: @proof.id, state: 'awaiting_confirmation')
      waiting = waiting.where.not(version_id: version['id']) unless audience == 'paused'
      waiting.update_all(state: 'blocked', reason: 'rule_paused_or_version_replaced', updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      @proof.update!(audience: audience, active_version_id: audience == 'paused' ? nil : version['id'], activated_at: Time.current)
    end
    success_response(data: @proof.snapshot)
  end

  def test_reply
    event = Instagram::AmhInboundEvent.find(params.require(:event_id))
    result = Instagram::AmhExecutor.call(event: event, proof: @proof, explicit_test: true)
    success_response(data: result.snapshot)
  end

  def index
    success_response(data: Instagram::AmhVisualProof.order(updated_at: :desc).limit(100).select(:id, :name).as_json(only: %i[id name]))
  end

  def operations
    response.headers['Cache-Control'] = 'no-store'
    success_response(data: Instagram::AmhOperations.snapshot)
  end

  def show
    success_response(data: @proof.snapshot)
  end

  def create
    graph = graph_params
    Instagram::AmhVisualEngine.validate!(graph)
    key = params.require(:create_key).to_s
    raise Instagram::AmhVisualEngine::Invalid, 'Chave de criação inválida' unless /\A[0-9a-f-]{36}\z/i.match?(key)

    proof = Instagram::AmhVisualProof.create_or_find_by!(create_key: key) do |record|
      record.name = params.require(:name)
      record.draft = graph
    end
    success_response(data: proof.snapshot, status: :created)
  end

  def update
    graph = graph_params
    Instagram::AmhVisualEngine.validate!(graph)
    @proof.update!(draft: graph, name: params[:name].presence || @proof.name, lock_version: expected_lock_version)
    success_response(data: @proof.snapshot)
  end

  # 'Published' means an immutable simulation version, never channel activation.
  def publish
    @proof.publish_version!(expected_lock_version, publication_actor)
    success_response(data: @proof.snapshot)
  end

  def simulate
    @run = @proof.simulate_version!(params[:version_id], params.require(:fixture), params[:text])
    success_response(data: { proof: @proof.snapshot, run: @run })
  end

  private

  def publication_actor
    return Current.user.id.to_s if Current.user
    return 'service:EVOAI_CRM_API_TOKEN' if Current.service_authenticated

    raise Instagram::AmhVisualEngine::Invalid, 'Publicador não identificado'
  end

  def graph_params
    graph = params.require(:graph)
    raise Instagram::AmhVisualEngine::Invalid, 'Grafo deve ser um objeto' unless graph.is_a?(ActionController::Parameters)

    graph.to_unsafe_h
  end

  def expected_lock_version
    value = params.require(:lock_version).to_s
    raise Instagram::AmhVisualEngine::Invalid, 'Revisão inválida' unless /\A\d{1,10}\z/.match?(value)

    value.to_i
  end

  def fetch_proof
    @proof = Instagram::AmhVisualProof.find(params[:id])
  end

  def unavailable
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Recurso indisponível: confira conexão, liberação de envio, publicação e perfil de teste.', status: :unprocessable_entity)
  end

  def invalid_graph(error)
    error_response(ApiErrorCodes::VALIDATION_ERROR, error.message, status: :unprocessable_entity)
  end

  def stale
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Outra edição foi salva. Reabra antes de alterar.', status: :conflict)
  end
end
