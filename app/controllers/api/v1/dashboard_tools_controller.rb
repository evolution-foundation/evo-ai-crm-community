# frozen_string_literal: true

# Devolve o token usado pelas ferramentas de dashboard (Painel Tráfego, Setup
# Marketing, etc. — HTML/JS armazenado em MenuConfig e renderizado num iframe
# sandbox sem allow-same-origin, então sem cookie/sessão pra autenticar
# chamadas a /api/v1/...) pra quem já está de verdade logado no CRM.
#
# Antes esse token ficava copiado em texto puro dentro de cada arquivo HTML
# (visível a qualquer um que abrisse "ver código-fonte" da ferramenta, sem
# precisar de autenticação nenhuma — o arquivo já continha a credencial
# completa). Agora ele só é entregue por aqui, atrás da autenticação normal
# da API (antes de resolveRenderableSrcDoc), e o ContentViewer.tsx repassa
# pro iframe via postMessage — o HTML/JS da ferramenta nunca mais carrega
# com o segredo já embutido.
class Api::V1::DashboardToolsController < Api::V1::BaseController
  def token
    render json: { success: true, data: { token: GlobalConfigService.load('DASHBOARD_TOOLS_ACCESS_TOKEN', nil) } }
  end
end
