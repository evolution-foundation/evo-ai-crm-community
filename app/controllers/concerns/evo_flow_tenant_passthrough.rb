# frozen_string_literal: true

# Multi-tenant evo-flow needs the caller's tenant (X-Evo-Tenant-Id) and identity
# (JWT `sub`; auth stays on the integration key) or it answers 401 TENANT_REQUIRED.
# With no header (tenant picked by cookie) the tenant the request resolved fills
# it; single-tenant deployments resolve none and send nothing.
module EvoFlowTenantPassthrough
  extend ActiveSupport::Concern

  private

  def evo_flow_passthrough_headers
    {
      'X-Evo-Tenant-Id' => request.headers['X-Evo-Tenant-Id'].presence || EvoExtensionPoints::RuntimeContext.current_scope_id,
      'Authorization' => request.headers['Authorization']
    }.compact
  end
end
