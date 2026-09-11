# Tax::CalculationService — estima os impostos de uma venda (produto x
# quantidade x preço), cobrindo os dois sistemas em vigor durante a
# transição da Reforma Tributária (EC 132/2023 + LC 214/2025):
#
#   - IBS/CBS (novo): 2026 é o "ano de teste" — a lei fixa alíquotas
#     nacionais reduzidas (CBS 0,9% + IBS 0,1%, Art. 481 da LC 214/2025)
#     só pra calibrar o sistema, ainda sem valer como tributo definitivo.
#     Ficam em GlobalConfig (ORG_ALIQUOTA_CBS_TESTE/ORG_ALIQUOTA_IBS_TESTE)
#     em vez de hardcoded, porque sobem a cada ano da transição (2027+) até
#     o regime pleno em 2033 — o valor aqui é só o ponto de partida.
#   - Legado (ICMS/PIS/COFINS/ISS ou Simples/DAS): continua sendo cobrado
#     integralmente durante toda a transição (reduzido gradualmente só a
#     partir de 2029). Calcular o valor exato por dentro (bracket do Simples
#     por RBT12, alíquota de ICMS por estado/NCM etc.) exige dados que este
#     CRM não tem — em vez de fingir precisão que não existe, usa uma
#     alíquota efetiva única que a empresa configura (com o contador) em
#     Organização > Dados da Empresa.
#
# Nenhum valor fiscal fica fixo no código: todo percentual usado aqui vem
# de GlobalConfig (nível empresa) ou do cadastro do produto (redução
# específica, Imposto Seletivo). Confirme com o contador antes de usar os
# valores calculados em documento fiscal de verdade.
class Tax::CalculationService
  Result = Struct.new(
    :regime, :base_calculo,
    :cbs_valor, :cbs_aliquota,
    :ibs_valor, :ibs_aliquota,
    :imposto_seletivo_valor, :imposto_seletivo_aliquota,
    :legado_valor, :legado_aliquota,
    :total_impostos, :preco_total,
    :avisos,
    keyword_init: true
  )

  DEFAULT_CBS_TESTE = 0.9
  DEFAULT_IBS_TESTE = 0.1
  DEFAULT_ALIQUOTA_LEGADO_SIMPLES = 6.0 # ponto de partida grosseiro (Anexo I, faixa 1) — sempre configurar de verdade
  DEFAULT_ALIQUOTA_LEGADO_PRESUMIDO = 13.25 # PIS 0,65 + COFINS 3 + ISS/ICMS aprox. 9,6 — idem, é só um placeholder

  def initialize(product:, quantity: 1, unit_price: nil)
    @product = product
    @quantity = quantity.to_f
    @unit_price = (unit_price || product.default_price).to_f
  end

  def calculate
    base = @unit_price * @quantity
    avisos = []

    cbs_aliquota = aliquota_ibs_cbs(base: :cbs, avisos: avisos)
    ibs_aliquota = aliquota_ibs_cbs(base: :ibs, avisos: avisos)
    cbs_valor = (base * cbs_aliquota / 100.0).round(2)
    ibs_valor = (base * ibs_aliquota / 100.0).round(2)

    is_aliquota = 0.0
    is_valor = 0.0
    if @product.sujeito_imposto_seletivo?
      if @product.aliquota_imposto_seletivo_pct.present?
        is_aliquota = @product.aliquota_imposto_seletivo_pct.to_f
        is_valor = (base * is_aliquota / 100.0).round(2)
      else
        avisos << 'Produto marcado como sujeito a Imposto Seletivo, mas sem alíquota cadastrada — informe com o contador.'
      end
    end

    legado_aliquota = aliquota_legado(avisos: avisos)
    legado_valor = (base * legado_aliquota / 100.0).round(2)

    total = (cbs_valor + ibs_valor + is_valor + legado_valor).round(2)

    Result.new(
      regime: regime_tributario,
      base_calculo: base.round(2),
      cbs_valor: cbs_valor, cbs_aliquota: cbs_aliquota,
      ibs_valor: ibs_valor, ibs_aliquota: ibs_aliquota,
      imposto_seletivo_valor: is_valor, imposto_seletivo_aliquota: is_aliquota,
      legado_valor: legado_valor, legado_aliquota: legado_aliquota,
      total_impostos: total,
      preco_total: (base + total).round(2),
      avisos: avisos
    )
  end

  private

  def regime_tributario
    GlobalConfigService.load('ORG_REGIME_TRIBUTARIO', 'simples_nacional').presence || 'simples_nacional'
  end

  # Alíquota-base nacional de teste (2026), reduzida pelo % de redução do
  # produto (cesta básica = 100% de redução, por exemplo).
  def aliquota_ibs_cbs(base:, avisos:)
    default = base == :cbs ? DEFAULT_CBS_TESTE : DEFAULT_IBS_TESTE
    config_key = base == :cbs ? 'ORG_ALIQUOTA_CBS_TESTE' : 'ORG_ALIQUOTA_IBS_TESTE'
    aliquota_base = GlobalConfigService.load(config_key, default.to_s).to_f

    reducao = @product.reducao_ibs_cbs_pct.to_f
    if @product.cst_ibs_cbs.blank?
      avisos << 'Produto sem CST do IBS/CBS cadastrado — usando tributação integral (sem redução) até que seja informado.'
    end

    (aliquota_base * (1 - reducao / 100.0)).round(4)
  end

  def aliquota_legado(avisos:)
    case regime_tributario
    when 'simples_nacional'
      rate = GlobalConfigService.load('ORG_ALIQUOTA_EFETIVA_SIMPLES', nil)
      if rate.blank?
        avisos << "Alíquota efetiva do Simples Nacional não configurada — usando #{DEFAULT_ALIQUOTA_LEGADO_SIMPLES}% de referência. Configure a real em Organização > Dados da Empresa."
        DEFAULT_ALIQUOTA_LEGADO_SIMPLES
      else
        rate.to_f
      end
    else
      rate = GlobalConfigService.load('ORG_ALIQUOTA_EFETIVA_SIMPLES', nil) # mesma chave serve de override manual pra qualquer regime
      if rate.blank?
        avisos << "Alíquota efetiva (ICMS+PIS+COFINS+ISS) não configurada — usando #{DEFAULT_ALIQUOTA_LEGADO_PRESUMIDO}% de referência. Configure a real em Organização > Dados da Empresa."
        DEFAULT_ALIQUOTA_LEGADO_PRESUMIDO
      else
        rate.to_f
      end
    end
  end
end
