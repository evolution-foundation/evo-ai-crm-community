# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Conversation, type: :model do
  let(:user) { User.create!(email: 'owner@example.com', name: 'Owner') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4)) }

  let(:default_pipeline) do
    Pipeline.create!(
      name: 'Default Pipeline',
      pipeline_type: Pipeline::VALID_TYPES.first,
      created_by: user,
      is_default: true
    )
  end
  let(:default_stage) { PipelineStage.create!(pipeline: default_pipeline, name: 'Stage 1', position: 1) }

  let(:vendas_pipeline) do
    Pipeline.create!(
      name: 'Vendas',
      pipeline_type: Pipeline::VALID_TYPES.first,
      created_by: user
    )
  end
  let(:vendas_stage) { PipelineStage.create!(pipeline: vendas_pipeline, name: 'Qualificado', position: 1) }

  def create_conversation(opts = {})
    Conversation.create!({
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    }.merge(opts))
  end

  describe '#assign_to_default_pipeline' do
    context 'quando o contato não está em nenhum pipeline' do
      it 'adiciona a conversa ao pipeline padrão' do
        default_stage # garante que o pipeline padrão existe com stage
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).to exist
      end

      it 'não falha se não existe pipeline padrão' do
        expect { create_conversation }.not_to raise_error
        expect(PipelineItem.count).to eq(0)
      end
    end

    context 'quando o contato tem lead histórico com completed_at preenchido' do
      before do
        default_stage
        vendas_stage
        # lead fechado — não deve ser considerado pelo .active scope
        PipelineItem.create!(
          pipeline: vendas_pipeline,
          pipeline_stage: vendas_stage,
          contact: contact,
          completed_at: 1.day.ago
        )
      end

      it 'ignora o lead fechado e cai no pipeline padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).to exist
        expect(PipelineItem.where(conversation: conversation, pipeline: vendas_pipeline)).not_to exist
      end
    end

    context 'quando o contato já está em um pipeline ativo (lead)' do
      before do
        default_stage
        vendas_stage
        PipelineItem.create!(
          pipeline: vendas_pipeline,
          pipeline_stage: vendas_stage,
          contact: contact
        )
      end

      it 'adiciona a conversa ao pipeline do contato, não ao padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: vendas_pipeline)).to exist
      end

      it 'não cria item no pipeline padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).not_to exist
      end

      it 'usa o stage onde o contato já está' do
        conversation = create_conversation
        item = PipelineItem.find_by(conversation: conversation, pipeline: vendas_pipeline)
        expect(item.pipeline_stage).to eq(vendas_stage)
      end
    end

    context 'quando o contato está em múltiplos pipelines' do
      let(:suporte_pipeline) do
        Pipeline.create!(
          name: 'Suporte',
          pipeline_type: Pipeline::VALID_TYPES.first,
          created_by: user
        )
      end
      let(:suporte_stage) { PipelineStage.create!(pipeline: suporte_pipeline, name: 'Aberto', position: 1) }

      before do
        default_stage
        vendas_stage
        suporte_stage
      end

      it 'usa o pipeline mais recente do contato' do
        # Controla tempo para garantir ordem determinística
        travel_to(2.days.ago) do
          PipelineItem.create!(
            pipeline: vendas_pipeline,
            pipeline_stage: vendas_stage,
            contact: contact
          )
        end
        travel_to(1.hour.ago) do
          PipelineItem.create!(
            pipeline: suporte_pipeline,
            pipeline_stage: suporte_stage,
            contact: contact
          )
        end

        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: suporte_pipeline)).to exist
        expect(PipelineItem.where(conversation: conversation, pipeline: vendas_pipeline)).not_to exist
      end
    end

    context 'quando não há contato associado' do
      before { default_stage }

      it 'usa o pipeline padrão como fallback' do
        contact2 = Contact.create!(name: 'No Contact', email: 'nocontact@example.com')
        ci2 = ContactInbox.create!(contact: contact2, inbox: inbox, source_id: SecureRandom.hex(4))
        conversation = Conversation.create!(inbox: inbox, contact: contact2, contact_inbox: ci2)
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).to exist
      end
    end

    context 'prevenção de duplicatas' do
      before { vendas_stage }

      it 'não cria PipelineItem duplicado se chamado duas vezes' do
        PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)
        conversation = create_conversation
        # simula segundo disparo do callback
        conversation.send(:assign_to_default_pipeline)
        expect(PipelineItem.where(conversation: conversation).count).to eq(1)
      end
    end

    context 'quando o contato tem apenas deals (itens com conversa vinculada)' do
      before do
        default_stage
        vendas_stage
        old_conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
        PipelineItem.where(conversation: old_conversation).destroy_all
        PipelineItem.create!(
          pipeline: vendas_pipeline,
          pipeline_stage: vendas_stage,
          conversation: old_conversation
        )
      end

      it 'cai no pipeline padrão pois não há lead ativo do contato' do
        new_ci = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
        new_conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: new_ci)
        expect(PipelineItem.where(conversation: new_conversation, pipeline: default_pipeline)).to exist
      end
    end
  end

  describe '#resolve_target_pipeline' do
    before { vendas_stage }

    # Usa uma conversa persistida para evitar fragilidade do Conversation.new sem atributos obrigatórios
    let(:persisted_conversation) { create_conversation }

    it 'retorna pipeline e stage do lead ativo do contato' do
      # ORDEM: força a conversa (callback roda) e LIMPA o que ela criou ANTES de criar o lead —
      # senão o callback promoveria/consumiria o lead recém-criado (semântica de fusão nova).
      conv = persisted_conversation
      PipelineItem.where(conversation: conv).destroy_all
      PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)

      pipeline, stage = conv.send(:resolve_target_pipeline)
      expect(pipeline).to eq(vendas_pipeline)
      expect(stage).to eq(vendas_stage)
    end

    it 'retorna pipeline padrão quando contato não tem lead ativo' do
      default_stage
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      pipeline, stage = persisted_conversation.send(:resolve_target_pipeline)
      expect(pipeline).to eq(default_pipeline)
      expect(stage).to be_nil
    end

    it 'retorna [nil, nil] quando não há pipeline padrão nem lead do contato' do
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      pipeline, stage = persisted_conversation.send(:resolve_target_pipeline)
      expect(pipeline).to be_nil
      expect(stage).to be_nil
    end

    it 'retorna o lead-card do contato como 3º valor (para promoção)' do
      conv = persisted_conversation
      PipelineItem.where(conversation: conv).destroy_all
      lead = PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)

      _pipeline, _stage, lead_item = conv.send(:resolve_target_pipeline)
      expect(lead_item).to eq(lead)
    end
  end

  describe '#assign_to_default_pipeline fusão (promoção do lead-card)' do
    before { vendas_stage }

    # Conversa persistida; LIMPAMOS o que o callback after_create_commit já criou para montar o
    # estado de teste do zero (lead-card por-contato + chamada manual de assign).
    let(:persisted_conversation) { create_conversation }

    it 'PROMOVE o lead-card (seta conversation_id, LIMPA contact_id) sem criar 2º card' do
      conv = persisted_conversation
      PipelineItem.where(conversation: conv).destroy_all # zera o que o callback fez
      lead = PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)

      expect do
        conv.send(:assign_to_default_pipeline)
      end.not_to change(PipelineItem, :count) # promove o lead existente, não cria outro

      lead.reload
      expect(lead.conversation_id).to eq(conv.id)
      expect(lead.contact_id).to be_nil # invariante OU-contact-OU-conversation
      expect(lead.contact).to eq(contact) # ainda resolve o contato via conversa (fallback)
      expect(PipelineItem.active.where(conversation: conv).count).to eq(1)
    end

    it 'sem lead-card, CAI no fluxo normal e cria o card da conversa (NUNCA fica sem card)' do
      default_stage
      conv = persisted_conversation
      PipelineItem.where(conversation: conv).destroy_all # sem nenhum card do contato

      expect do
        conv.send(:assign_to_default_pipeline)
      end.to change { PipelineItem.where(conversation: conv).count }.from(0).to(1)
    end
  end

  describe 'creation callbacks vs source enum (EVO-2007 AC 2)' do
    before { default_stage } # default pipeline exists, so a skip is meaningful

    it 'skips the three creation callbacks for imported conversations' do
      conversation = described_class.new(inbox: inbox, contact: contact, contact_inbox: contact_inbox, source: :imported)

      expect(conversation).not_to receive(:notify_conversation_creation)
      expect(conversation).not_to receive(:publish_conversation_created)
      conversation.save!

      expect(PipelineItem.where(conversation: conversation)).not_to exist
    end

    it 'runs the three creation callbacks for live (default source) conversations' do
      conversation = described_class.new(inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      expect(conversation).to receive(:notify_conversation_creation)
      expect(conversation).to receive(:publish_conversation_created)
      conversation.save!

      expect(conversation.live?).to be(true)
      expect(PipelineItem.where(conversation: conversation)).to exist
    end
  end

  describe '#bump_ai_session_epoch_if_reopened' do
    it 'bumps the epoch and records when it was bumped on a resolved -> reopened transition' do
      conversation = create_conversation
      conversation.update!(status: :resolved)

      travel_to(Time.utc(2026, 9, 25, 12, 0, 0)) do
        conversation.update!(status: :open)
      end

      conversation.reload
      expect(conversation.custom_attributes['ai_session_epoch']).to eq(1)
      expect(conversation.custom_attributes['ai_session_epoch_bumped_at']).to eq('2026-09-25T12:00:00Z')
    end

    it 'does not set a bump timestamp when the conversation has never been reopened' do
      conversation = create_conversation
      expect(conversation.custom_attributes['ai_session_epoch_bumped_at']).to be_nil
    end
  end
end
