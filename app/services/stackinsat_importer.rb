require 'faraday'
require 'csv'
require 'json'
require 'date'
require_relative '../../config/settings'

class StackinsatImporter
  TICKER = 'BTC-USD'

  Result = Struct.new(:ok, :errors, :skipped, :rows, :trade_cutoff, :unmapped, keyword_init: true)
  Row    = Struct.new(:kind, :date, :account, :amount, :name, :tag, :status, :error, keyword_init: true)

  def initialize(dry_run: true, from_date: nil)
    @dry_run     = dry_run
    @from_date   = from_date.is_a?(String) && !from_date.empty? ? Date.parse(from_date) : from_date
    @first_trade = true
    @account_id  = Settings::SURE_ACCOUNT_BTC
    raise 'SURE_ACCOUNT_BTC non configuré — ajoutez-le dans .env' if @account_id.to_s.empty?

    @client = Faraday.new(url: Settings::SURE_API_URL) do |f|
      f.options.timeout      = 30
      f.options.open_timeout = 10
    end
  end

  def import!(csv_content, &on_progress)
    csv_rows  = CSV.parse(csv_content, headers: true, quote_char: '"')
    all_items = []

    csv_rows.each do |r|
      item = map_row(r)
      all_items << item if item
    end

    all_items.select! { |t| Date.parse(t[:date]) >= @from_date } if @from_date

    trade_cutoff = @dry_run ? nil : fetch_latest_trade_date
    if trade_cutoff
      before = all_items.size
      all_items.reject! { |t| Date.parse(t[:date]) <= trade_cutoff }
      after = all_items.size
      $stdout.puts "[StackinsatImporter] Dernier trade : #{trade_cutoff} — #{before - after} ignorés, #{after} nouveaux"
      $stdout.flush
    end

    total       = all_items.size
    result_rows = []
    ok = errors = skipped = 0

    all_items.each_with_index do |t, i|
      row = Row.new(
        kind:    t[:kind],
        date:    t[:date],
        account: 'BTC',
        amount:  t[:display_amount],
        name:    t[:name],
        tag:     t[:tag]
      )

      if @dry_run
        row.status = 'preview'
      else
        code, body = push_trade(t)
        case code
        when 201 then row.status = 'ok';     ok      += 1
        when 200 then row.status = 'exists'; skipped += 1
        else
          row.status = 'error'
          row.error  = "HTTP #{code}: #{body.to_s[0..300]}"
          errors += 1
        end
        sleep 0.05
      end

      result_rows << row
      on_progress.call(i + 1, total, row) if block_given?
    end

    Result.new(ok: ok, errors: errors, skipped: skipped, rows: result_rows,
               trade_cutoff: trade_cutoff, unmapped: [])
  end

  def purge_trades!
    deleted = 0
    errors  = 0
    page    = 1
    loop do
      resp = @client.get('/api/v1/trades') do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
        req.params['account_id'] = @account_id
        req.params['per_page']   = 100
        req.params['page']       = page
      end
      break unless resp.status == 200

      body  = JSON.parse(resp.body)
      items = body.is_a?(Array) ? body : (body['trades'] || body['data'] || [])
      break if items.empty?

      items.each do |t|
        id = t['id']
        next unless id
        del = @client.delete("/api/v1/trades/#{id}") do |req|
          req.headers['X-Api-Key'] = Settings::SURE_API_KEY
          req.headers['Accept']    = 'application/json'
        end
        del.status == 200 ? deleted += 1 : errors += 1
        sleep 0.03
      end

      break if items.size < 100
      page += 1
    end
    { deleted: deleted, errors: errors }
  rescue => e
    { deleted: deleted, errors: errors, message: e.message }
  end

  private

  def map_row(r)
    return nil unless r['transactionType'].to_s == 'DELIVERY_PERSONAL_VAULT'

    date       = r['deliveryDate'].to_s.split('T').first
    amount_btc = r['amountBtc'].to_f
    price      = r['price'].to_f
    discounted = r['discountedFeesAmountEur'].to_f
    fee_eur    = discounted > 0 ? discounted : r['stackinsatBaseFeesAmountEur'].to_f

    return nil if amount_btc <= 0 || price <= 0

    {
      kind:           :trade,
      account_id:     @account_id,
      date:           date,
      trade_type:     'buy',
      ticker:         TICKER,
      qty:            amount_btc.round(8),
      price:          price,
      fee:            fee_eur,
      currency:       'EUR',
      name:           'Achat BTC StackinSat',
      tag:            'Trade',
      display_amount: -(amount_btc * price).round(2)
    }
  end

  def fetch_latest_trade_date
    latest = nil
    page   = 1
    loop do
      resp = @client.get('/api/v1/trades') do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
        req.params['account_id'] = @account_id
        req.params['per_page']   = 100
        req.params['page']       = page
      end
      break unless resp.status == 200

      body  = JSON.parse(resp.body)
      items = body.is_a?(Array) ? body : (body['trades'] || body['data'] || [])
      break if items.empty?

      items.each do |t|
        d = t['date'].to_s
        next if d.empty?
        parsed = Date.parse(d) rescue next
        latest = parsed if latest.nil? || parsed > latest
      end

      break if items.size < 100
      page += 1
    end
    latest
  rescue => e
    $stderr.puts "[StackinsatImporter] fetch_latest_trade_date: #{e.message}"
    nil
  end

  def push_trade(t)
    payload = {
      trade: {
        account_id: t[:account_id],
        date:       t[:date],
        type:       t[:trade_type],
        qty:        t[:qty],
        price:      t[:price],
        fee:        t[:fee],
        currency:   t[:currency],
        ticker:     t[:ticker]
      }
    }

    if @first_trade
      @first_trade = false
      $stdout.puts "[StackinsatImporter] Premier TRADE → POST #{Settings::SURE_API_URL}/api/v1/trades"
      $stdout.puts "[StackinsatImporter] Payload: #{payload.to_json}"
      $stdout.flush
    end

    resp = @client.post('/api/v1/trades') do |req|
      req.headers['X-Api-Key']    = Settings::SURE_API_KEY
      req.headers['Content-Type'] = 'application/json'
      req.headers['Accept']       = 'application/json'
      req.body = payload.to_json
    end

    parsed = begin; JSON.parse(resp.body); rescue; resp.body; end
    unless [200, 201].include?(resp.status)
      $stdout.puts "[StackinsatImporter] TRADE ERREUR #{resp.status} — #{t[:name]} — #{resp.body[0..300]}"
      $stdout.flush
    end
    [resp.status, parsed]
  rescue => e
    $stdout.puts "[StackinsatImporter] TRADE EXCEPTION: #{e.message}"; $stdout.flush
    [0, e.message]
  end
end
