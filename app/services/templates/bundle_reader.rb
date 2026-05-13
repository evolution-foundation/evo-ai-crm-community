# frozen_string_literal: true

require 'zip'

module Templates
  # Reads and validates a template bundle ZIP. Surfaces typed errors so the
  # controller can return the right HTTP status:
  #
  #   FileTooLargeError       => 413
  #   InvalidBundleError      => 422 (zip slip, malformed JSON, missing manifest)
  #   UnsupportedSchemaError  => 422
  class BundleReader
    class Error < StandardError; end
    class FileTooLargeError < Error; end
    class InvalidBundleError < Error; end
    class UnsupportedSchemaError < Error; end

    Bundle = Struct.new(:manifest, :categories, keyword_init: true)

    def initialize(io_or_path)
      @source = io_or_path
    end

    # @return [Bundle]
    def read
      validate_size!
      manifest = nil
      categories = {}

      Zip::File.open_buffer(@source) do |zip|
        entries = zip.entries
        raise InvalidBundleError, 'too many entries' if entries.size > Schema::MAX_ENTRIES

        entries.each do |entry|
          ensure_safe_path!(entry.name)
        end

        manifest_entry = zip.find_entry('manifest.json')
        raise InvalidBundleError, 'missing manifest.json' unless manifest_entry

        manifest = parse_json(manifest_entry.get_input_stream.read)
        validate_manifest!(manifest)

        Schema::CATEGORIES.each do |category|
          entry = zip.find_entry("#{category}.json")
          next unless entry

          categories[category] = parse_json(entry.get_input_stream.read)
          raise InvalidBundleError, "#{category}.json must contain an array" unless categories[category].is_a?(Array)
        end
      end

      Bundle.new(manifest: manifest, categories: categories)
    rescue Zip::Error => e
      raise InvalidBundleError, "zip parse error: #{e.message}"
    end

    private

    def validate_size!
      size = if @source.respond_to?(:size)
               @source.size
             elsif @source.is_a?(String) && File.exist?(@source)
               File.size(@source)
             else
               0
             end
      raise FileTooLargeError, "bundle exceeds #{Schema::MAX_BUNDLE_SIZE_BYTES} bytes" if size > Schema::MAX_BUNDLE_SIZE_BYTES
    end

    # Reject zip slip: entry names with ../ or absolute paths.
    def ensure_safe_path!(name)
      raise InvalidBundleError, "unsafe path: #{name}" if name.start_with?('/', '\\')
      raise InvalidBundleError, "unsafe path: #{name}" if name.include?('..')
    end

    def parse_json(str)
      JSON.parse(str)
    rescue JSON::ParserError => e
      raise InvalidBundleError, "malformed JSON: #{e.message}"
    end

    def validate_manifest!(manifest)
      raise InvalidBundleError, 'manifest is not an object' unless manifest.is_a?(Hash)

      version = manifest['schema_version']
      raise UnsupportedSchemaError, "schema_version #{version.inspect} not supported" unless version == Schema::SCHEMA_VERSION
    end
  end
end
