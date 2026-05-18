require 'json'
require 'logger'
require_relative '../../config/database'
require_relative '../../app/models/analysis'
require_relative '../../app/models/bet'
require_relative '../../app/models/position'
require_relative '../../app/models/watchlist'
require_relative '../../app/agent/analyzer'

class MonthlyAnalysisJob
  def self.run!
    new.run
  end

  def run
    @logger = Logger.new($stdout)
    month = Date.today.strftime('%Y-%m')

    if Analysis.where(month: month).count > 0
      @logger.info("Analysis for #{month} already exists. Skipping.")
      return
    end

    portfolio = Position.all.map do |p|
      { ticker: p.ticker, name: p.name, sector: p.sector, conviction: p.conviction }
    end

    watchlist = Watchlist.where(status: 'watching').map do |w|
      { ticker: w.ticker, name: w.name, sector: w.sector }
    end

    analyzer = Agent::Analyzer.new
    result   = analyzer.run(portfolio: portfolio, watchlist: watchlist)

    DB.transaction do
      analysis = Analysis.create(
        month:        month,
        sectors:      Settings::SECTORS.to_json,
        macro:        result[:macro],
        candidates:   result[:candidates].to_json,
        radar:        result[:radar].to_json,
        raw_response: { short: result[:raw_short], long: result[:raw_long] }.to_json
      )

      recommended = result[:candidates].find { |c| c['ticker'] == result[:recommendation] }
      if recommended
        Bet.create(
          analysis_id: analysis.id,
          month:       month,
          ticker:      recommended['ticker'],
          name:        recommended['name'],
          exchange:    recommended['exchange'] || '',
          thesis:      [recommended['thesis'], recommended['recommendation_rationale']].compact.join(' — '),
          budget:      Settings::DEFAULT_BUDGET,
          status:      'pending'
        )
      end

      result[:radar].each do |r|
        next if Watchlist.where(ticker: r['ticker']).count > 0
        Watchlist.create(
          ticker:       r['ticker'],
          name:         r['name'],
          exchange:     r['exchange'] || '',
          sector:       r['sector'],
          thesis:       r['thesis_long'],
          horizon:      r['horizon'],
          status:       'watching',
          source_month: month
        )
      end

      @logger.info("Analysis #{month} saved. Bet: #{recommended&.dig('ticker')}. Radar: #{result[:radar].map { |r| r['ticker'] }.join(', ')}")
    end
  end
end
