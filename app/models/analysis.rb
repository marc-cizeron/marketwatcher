require 'sequel'
require 'json'

class Analysis < Sequel::Model
  one_to_many :bets

  def candidates_parsed
    JSON.parse(candidates)
  rescue JSON::ParserError
    []
  end

  def radar_parsed
    return [] if radar.nil? || radar.empty?
    JSON.parse(radar)
  rescue JSON::ParserError
    []
  end

  def sectors_parsed
    JSON.parse(sectors)
  rescue JSON::ParserError
    []
  end

  def recommendation
    cands = candidates_parsed
    cands.find { |c| c['ticker'] == recommended_ticker } || cands.first
  end

  def recommended_ticker
    cands = candidates_parsed
    # The recommendation field may be stored separately in raw_response
    raw = begin JSON.parse(raw_response || '{}') rescue {} end
    raw['recommendation'] || (cands.first || {})['ticker']
  end
end
