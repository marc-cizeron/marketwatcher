require 'faraday'
require 'json'
require_relative '../../config/settings'
require_relative '../models/position'

class SureSync
  def initialize
    @client = Faraday.new(url: Settings::SURE_API_URL) do |f|
      f.options.timeout      = 30
      f.options.open_timeout = 10
    end
  end

  def sync!
    holdings = fetch_all_holdings
    grouped  = group_by_ticker(holdings)
    results  = { created: 0, updated: 0 }

    grouped.each do |ticker, data|
      pos = Position.where(ticker: ticker).first
      if pos
        pos.update(
          shares:        data[:shares].round(6),
          avg_price:     data[:avg_price].round(4),
          current_price: data[:current_price].round(4),
          updated_at:    Time.now
        )
        results[:updated] += 1
      else
        Position.create(
          ticker:        ticker,
          name:          data[:name],
          exchange:      '',
          sector:        'autre',
          horizon:       'long',
          avg_price:     data[:avg_price].round(4),
          current_price: data[:current_price].round(4),
          shares:        data[:shares].round(6),
          conviction:    'haute',
          notes:         'Importé depuis Sure',
          added_at:      Date.today,
          updated_at:    Time.now
        )
        results[:created] += 1
      end
    end

    results
  end

  private

  def fetch_all_holdings
    all  = []
    page = 1
    loop do
      resp = @client.get('/api/v1/holdings') do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
        req.params['per_page']   = 100
        req.params['page']       = page
      end
      raise "Sure API #{resp.status}: #{resp.body[0..200]}" unless resp.status == 200

      body     = JSON.parse(resp.body)
      holdings = body.is_a?(Array) ? body : (body['holdings'] || [])
      break if holdings.empty?

      all.concat(holdings)
      break if holdings.size < 100
      page += 1
    end
    all
  end

  def group_by_ticker(holdings)
    grouped = {}
    holdings.each do |h|
      ticker = h.dig('security', 'ticker')
      next if ticker.nil? || ticker.strip.empty?

      qty           = h['qty'].to_f
      avg_cost      = parse_money(h['avg_cost']) || parse_money(h['price']) || 0.0
      current_price = parse_money(h['price']) || 0.0

      if grouped.key?(ticker)
        e           = grouped[ticker]
        total       = e[:shares] + qty
        e[:avg_price]     = total > 0 ? ((e[:avg_price] * e[:shares]) + (avg_cost * qty)) / total : 0.0
        e[:shares]        = total
        e[:current_price] = current_price
      else
        grouped[ticker] = {
          name:          (h.dig('security', 'name') || ticker).to_s,
          shares:        qty,
          avg_price:     avg_cost,
          current_price: current_price
        }
      end
    end
    grouped
  end

  def parse_money(val)
    return nil if val.nil?
    return val.to_f if val.is_a?(Numeric)
    return val['amount'].to_f if val.is_a?(Hash) && val['amount']
    return val['fractional'].to_f / 100 if val.is_a?(Hash) && val['fractional']
    v = val.to_s.gsub(/[^\d.]/, '')
    v.empty? ? nil : v.to_f
  end
end
