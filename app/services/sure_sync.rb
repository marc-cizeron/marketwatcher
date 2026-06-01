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
    trades   = fetch_all('trades')
    holdings = fetch_all('holdings')

    positions     = build_from_trades(trades)
    current_prices = latest_prices_from_holdings(holdings)

    positions.each do |ticker, data|
      data[:current_price] = current_prices[ticker] if current_prices[ticker]
    end

    results = { created: 0, updated: 0, deleted: 0 }

    DB.transaction do
      positions.each do |ticker, data|
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

      synced_tickers = positions.keys
      deleted = Position.exclude(ticker: synced_tickers).delete
      results[:deleted] = deleted
    end

    results
  end

  private

  # Reconstruit les positions (shares + avg_price) depuis l'historique des trades.
  # qty > 0 = achat, qty < 0 = vente.
  def build_from_trades(trades)
    positions = {}

    trades.sort_by { |t| t['date'] || '' }.each do |t|
      ticker = t.dig('security', 'ticker')
      next if ticker.nil? || ticker.strip.empty?

      qty   = t['qty'].to_f
      price = parse_money(t['price']) || 0.0
      next if qty.zero?

      positions[ticker] ||= {
        name:          (t.dig('security', 'name') || ticker).to_s,
        shares:        0.0,
        avg_price:     0.0,
        current_price: 0.0
      }

      p = positions[ticker]
      if qty > 0
        total        = p[:shares] + qty
        p[:avg_price] = total > 0 ? ((p[:avg_price] * p[:shares]) + (price * qty)) / total : 0.0
        p[:shares]   = total
      else
        p[:shares] = [p[:shares] + qty, 0.0].max
      end
    end

    positions.reject { |_, v| v[:shares] < 0.0001 }
  end

  # Prix de marché courant = dernier snapshot de holdings par ticker.
  def latest_prices_from_holdings(holdings)
    latest = {}
    holdings.each do |h|
      ticker = h.dig('security', 'ticker')
      date   = h['date']
      next unless ticker && date

      if !latest[ticker] || date > latest[ticker]['date']
        latest[ticker] = h
      end
    end

    latest.transform_values { |h| parse_money(h['price']) }.compact
  end

  def fetch_all(resource)
    all  = []
    page = 1
    loop do
      resp = @client.get("/api/v1/#{resource}") do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
        req.params['per_page']   = 100
        req.params['page']       = page
      end
      raise "Sure API #{resp.status}: #{resp.body[0..200]}" unless resp.status == 200

      body  = JSON.parse(resp.body)
      items = body.is_a?(Array) ? body : (body[resource] || body['data'] || [])
      break if items.empty?

      all.concat(items)
      break if items.size < 100
      page += 1
    end
    all
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
