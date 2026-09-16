require 'rails_helper'

RSpec.describe Knowledge::IngestJob, type: :job do
  it 'calls IngestionService for the given document' do
    document = create(:knowledge_document)
    service = instance_double(Knowledge::IngestionService, call: true)
    allow(Knowledge::IngestionService).to receive(:new).with(document).and_return(service)

    described_class.perform_now(document)

    expect(service).to have_received(:call)
  end
end
