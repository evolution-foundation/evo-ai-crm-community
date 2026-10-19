# frozen_string_literal: true

class Api::V1::InstagramAmhProofsController < Api::V1::BaseController
  require_permissions({ index: 'journeys.read', show: 'journeys.read', create: 'journeys.create',
                        update: 'journeys.update', publish: 'journeys.toggle_active', simulate: 'journeys.read' })
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
    proof = Instagram::AmhVisualProof.create!(name: params.require(:name), draft: graph)
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
    @proof.publish_version!(expected_lock_version, Current.user&.id.to_s)
    success_response(data: @proof.snapshot)
  end

  def simulate
    @run = @proof.simulate_version!(params[:version_id], params.require(:fixture), params[:text])
    success_response(data: { proof: @proof.snapshot, run: @run })
  end

  private

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
