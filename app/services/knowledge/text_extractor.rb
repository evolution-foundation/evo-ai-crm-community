require 'pdf-reader'
require 'docx'
require 'nokogiri'

class Knowledge::TextExtractor
  class UnsupportedFormatError < StandardError; end

  SUPPORTED_TYPES = %w[
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    text/html
    text/plain
    text/markdown
  ].freeze

  def initialize(file_path, content_type)
    @file_path = file_path
    @content_type = content_type
  end

  def extract
    case @content_type
    when 'application/pdf' then extract_pdf
    when 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' then extract_docx
    when 'text/html' then extract_html
    when 'text/plain', 'text/markdown' then File.read(@file_path)
    else
      raise UnsupportedFormatError, "Unsupported content type: #{@content_type}"
    end
  end

  private

  def extract_pdf
    PDF::Reader.new(@file_path).pages.map(&:text).join("\n\n")
  end

  def extract_docx
    Docx::Document.open(@file_path).paragraphs.map(&:text).join("\n")
  end

  def extract_html
    Nokogiri::HTML(File.read(@file_path)).text.squish
  end
end
