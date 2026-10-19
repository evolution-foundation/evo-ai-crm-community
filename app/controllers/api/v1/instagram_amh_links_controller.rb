# frozen_string_literal: true

class Api::V1::InstagramAmhLinksController < Api::V1::BaseController
  require_permissions({ create: 'journeys.update', destroy: 'journeys.update' })
  before_action :enabled!
  after_action :private_headers
  rescue_from Instagram::AmhShortLink::Unavailable, with: :unavailable
  rescue_from Instagram::AmhShortLink::Conflict, with: :conflict

  def create
    proof = Instagram::AmhVisualProof.find(params[:proof_id])
    event = params.require(:event)
    raise Instagram::AmhShortLink::Unavailable unless event.is_a?(ActionController::Parameters)

    link = Instagram::AmhShortLink.issue_qa!(proof: proof, version_id: params[:version_id], event: event.to_unsafe_h)
    success_response(data: link, status: :created)
  end

  def destroy
    Instagram::AmhShortLink.find(params[:id]).revoke!
    head :no_content
  end

  private

  def enabled!
    head :not_found unless ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] == 'true'
  end

  def private_headers
    response.headers.merge!('Cache-Control' => 'private, no-store', 'X-Robots-Tag' => 'noindex, nofollow',
                            'Referrer-Policy' => 'no-referrer')
  end

  def unavailable
    render json: { error: 'Link indisponível' }, status: :not_found
  end

  def conflict
    render json: { error: 'Conflito de escopo ou versão; revisão necessária' }, status: :conflict
  end
end
