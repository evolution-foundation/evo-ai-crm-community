# frozen_string_literal: true

class Api::V1::InstagramAmhProofsController < Api::V1::BaseController
  require_permissions({ index: 'journeys.read', show: 'journeys.read', create: 'journeys.create',
                        update: 'journeys.update', publish: 'journeys.toggle_active', simulate: 'journeys.update' })
  before_action :fetch_proof, except: %i[index create]
  rescue_from Instagram::AmhVisualEngine::Invalid, with: :invalid_graph
  rescue_from ActiveRecord::StaleObjectError, with: :stale

  def index
    success_response(data: Instagram::AmhVisualProof.order(updated_at: :desc).limit(100).select(:id, :name).as_json(only: %i[id name]))
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
    @proof.update!(draft: graph, lock_version: expected_lock_version)
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

  def invalid_graph(error)
    error_response(ApiErrorCodes::VALIDATION_ERROR, error.message, status: :unprocessable_entity)
  end

  def stale
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Outra edição foi salva. Reabra antes de alterar.', status: :conflict)
  end
end
