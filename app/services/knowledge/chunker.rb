class Knowledge::Chunker
  def initialize(max_chars: 4000, overlap: 200)
    @max_chars = max_chars
    @overlap = overlap
  end

  def chunks(text)
    return [] if text.blank?
    return [text] if text.length <= @max_chars

    result = []
    start = 0

    while start < text.length
      finish = [start + @max_chars, text.length].min
      result << text[start...finish]
      break if finish == text.length

      start = finish - @overlap
    end

    result
  end
end
