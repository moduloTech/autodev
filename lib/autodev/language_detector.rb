# frozen_string_literal: true

# Detects the dominant language of a text using function-word frequency.
# Returns :fr or :en (defaults to :fr for empty or ambiguous input).
module LanguageDetector
  FR_MARKERS = %w[le la les un une des est sont dans pour sur avec par que qui ce cette mais ou et je nous vous ils elle].freeze
  EN_MARKERS = %w[the a an is are in for on with by that which this but or and i we you they she].freeze

  def self.detect(text)
    return :fr if text.nil? || text.strip.empty?

    words = text.downcase.gsub(/[^a-z\s]/, " ").split
    fr_count = words.count { |w| FR_MARKERS.include?(w) }
    en_count = words.count { |w| EN_MARKERS.include?(w) }

    en_count > fr_count ? :en : :fr
  end
end
