# Campos fiscais do produto — tanto o sistema antigo (ICMS/PIS/COFINS,
# usado até a transição terminar) quanto os novos códigos da Reforma
# Tributária (EC 132/2023 + LC 214/2025): CST do IBS/CBS e cClassTrib.
# Nenhuma alíquota fica hardcoded no código — todas ficam configuráveis
# (ver GlobalConfig ORG_* e os campos aqui) porque tanto a legislação quanto
# a alíquota efetiva de cada empresa mudam com o tempo.
class AddFiscalFieldsToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :ncm, :string, limit: 10, if_not_exists: true
    add_column :products, :cest, :string, limit: 10, if_not_exists: true
    add_column :products, :cfop_padrao, :string, limit: 10, if_not_exists: true

    # Sistema antigo — CST (Lucro Presumido/Real) ou CSOSN (Simples Nacional).
    # Guardamos os dois porque a empresa pode trocar de regime; o serviço de
    # cálculo escolhe qual usar a partir do regime tributário cadastrado.
    add_column :products, :cst_icms, :string, limit: 10, if_not_exists: true
    add_column :products, :csosn, :string, limit: 10, if_not_exists: true
    add_column :products, :cst_pis_cofins, :string, limit: 10, if_not_exists: true

    # Reforma Tributária — CST do IBS/CBS (3 dígitos, ex: "000", "200", "830")
    # e cClassTrib (6 dígitos, identifica o benefício/redução específico).
    add_column :products, :cst_ibs_cbs, :string, limit: 10, if_not_exists: true
    add_column :products, :cclasstrib, :string, limit: 10, if_not_exists: true
    # Percentual de redução de alíquota do IBS/CBS aplicável a este produto
    # (0, 30, 60 ou 100 — cesta básica nacional é 100% de redução = isento).
    add_column :products, :reducao_ibs_cbs_pct, :decimal, precision: 5, scale: 2, if_not_exists: true

    # Imposto Seletivo (IS) — novo imposto da reforma sobre itens específicos
    # (bebidas açucaradas, álcool, tabaco, etc.). Relevante pra um cardápio
    # com refrigerante — fica marcável por produto, sem alíquota fixa no código
    # (a lei ainda não fixa um percentual universal por categoria).
    add_column :products, :sujeito_imposto_seletivo, :boolean, default: false, null: false, if_not_exists: true
    add_column :products, :aliquota_imposto_seletivo_pct, :decimal, precision: 5, scale: 2, if_not_exists: true

    add_index :products, :ncm, if_not_exists: true
  end
end
