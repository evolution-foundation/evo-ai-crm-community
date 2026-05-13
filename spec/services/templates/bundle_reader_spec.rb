# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::BundleReader' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

require 'zip'
require 'stringio'

RSpec.describe Templates::BundleReader do
  let(:valid_manifest) do
    { schema_version: 1, name: 'T', description: '', author: 'a', created_at: Time.now.iso8601, contents: {} }
  end

  def zip_with(entries)
    Zip::OutputStream.write_buffer do |zip|
      entries.each do |name, content|
        zip.put_next_entry(name)
        zip.write(content)
      end
    end.tap(&:rewind)
  end

  describe '#read' do
    it 'parses a valid bundle' do
      io = zip_with('manifest.json' => valid_manifest.to_json, 'labels.json' => '[]')
      bundle = described_class.new(io).read
      expect(bundle.manifest['schema_version']).to eq(1)
      expect(bundle.categories['labels']).to eq([])
    end

    it 'raises UnsupportedSchemaError on unknown schema_version' do
      io = zip_with('manifest.json' => valid_manifest.merge(schema_version: 99).to_json)
      expect { described_class.new(io).read }.to raise_error(Templates::BundleReader::UnsupportedSchemaError)
    end

    it 'raises InvalidBundleError on missing manifest' do
      io = zip_with('labels.json' => '[]')
      expect { described_class.new(io).read }.to raise_error(Templates::BundleReader::InvalidBundleError, /missing manifest/)
    end

    it 'rejects zip slip via ../' do
      io = zip_with('../escape.txt' => 'no', 'manifest.json' => valid_manifest.to_json)
      expect { described_class.new(io).read }.to raise_error(Templates::BundleReader::InvalidBundleError, /unsafe path/)
    end

    it 'rejects absolute paths' do
      io = zip_with('/etc/passwd' => 'no', 'manifest.json' => valid_manifest.to_json)
      expect { described_class.new(io).read }.to raise_error(Templates::BundleReader::InvalidBundleError, /unsafe path/)
    end

    it 'raises InvalidBundleError when category file is not a JSON array' do
      io = zip_with('manifest.json' => valid_manifest.to_json, 'labels.json' => '{"oops": true}')
      expect { described_class.new(io).read }.to raise_error(Templates::BundleReader::InvalidBundleError, /must contain an array/)
    end
  end
end
