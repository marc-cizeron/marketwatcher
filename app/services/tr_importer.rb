require 'faraday'
require 'csv'
require 'json'
require 'date'
require_relative '../../config/settings'
require_relative '../models/ticker_mapping'

# Synchronisation CSV Trade Republic → API SUR.
#
# Deux types d'entrées selon la nature de l'opération :
#
#   :trade       → POST /api/v1/trades  (BUY/SELL — met à jour les holdings)
#   :transaction → POST /api/v1/transactions  (dividendes, dépôts, intérêts, frais, taxes)
#
# Les correspondances ISIN → ticker Yahoo Finance sont stockées en base
# (table ticker_mappings). Les ISINs inconnus sont remontés dans Result#unmapped
# pour que l'utilisateur puisse les mapper avant d'importer.
class TrImporter
  ACCOUNTS = {
    'DEFAULT' => Settings::SURE_ACCOUNT_DEFAULT,
    'PEA'     => Settings::SURE_ACCOUNT_PEA
  }.freeze

  # Fallback statique si la DB n'est pas disponible
  TICKER_MAP = {
    # Actions françaises
    'FR0000120271' => 'TTE.PA',
    'FR0000131906' => 'RNO.PA',
    'FR0000120073' => 'AI.PA',
    'FR0000121329' => 'HO.PA',
    'FR0000073272' => 'SAF.PA',
    'FR0014004L86' => 'AM.PA',
    'FR0010220475' => 'ALO.PA',
    'FR0000054470' => 'UBI.PA',
    'FR0010221234' => 'ETL.PA',
    # ETFs
    'FR001400U5Q4' => 'DCAM.PA',
    'FR0011550185' => 'ESE.PA',
    'FR0013380607' => 'CACC.PA',
    'LU1681048804' => '500.PA',
    'IE000BI8OT95' => 'MWRD.PA',
    'IE00BMTM6B32' => '3OIL.L',
    # Actions européennes
    'LU1598757687' => 'MT.AS',
    'NL0010273215' => 'ASML.AS',
    'NL00150001Q9' => 'NL00150001Q9.SG',
    'DE0005313704' => 'AFX.DE',
    'DE0007030009' => 'RHM.DE',
    # Actions US / Canada / Asie
    'US67066G1040' => 'NVDA',
    'US5253271028' => 'LDOS',
    'US75513E1010' => 'RTX',
    'US52661A1088' => 'DRS',
    'US5024413065' => 'LVMUY',
    'CA13321L1085' => 'CCJ',
    'CNE100000296' => '1211.HK',
    'KYG982AW1003' => '9868.HK',
    # Crypto
    'BTC'          => 'BTC-USD',
    # Produits structurés sans ticker Yahoo — ignorés (trade non créé)
    # 'DE000SQ4SUR5' => nil,
  }.freeze

  # Correspondance tag interne → investment_activity_label SUR
  TAG_TO_ACTIVITY = {
    'Dividende'         => 'Dividend',
    'Taxes'             => 'Fee',
    'Intérêts'          => 'Interest',
    'Dépôt'             => 'Contribution',
    'Frais'             => 'Fee',
    'Frais de courtage' => 'Fee',
    'Retrait'           => 'Withdrawal',
    'Virement interne'  => 'Transfer',
    'Autre'             => 'Other',
  }.freeze

  SKIP_TYPES = %w[
    MIGRATION
    BONUS_ISSUE
    BONUS_ISSUE_CANCELLED
    WORTHLESS
    WORTHLESS_CANCELLED
    INTERMEDIATE_SECURITIES_DISTRIBUTION
    PEA_MARKETING
  ].freeze

  Result = Struct.new(:ok, :errors, :skipped, :rows, :trade_cutoff, :unmapped, keyword_init: true)
  Row    = Struct.new(:kind, :date, :account, :amount, :name, :tag, :status, :error, keyword_init: true)

  def initialize(dry_run: true, from_date: nil)
    @dry_run       = dry_run
    @from_date     = from_date.is_a?(String) && !from_date.empty? ? Date.parse(from_date) : from_date
    @first_trade   = true
    @first_txn     = true
    @ticker_map    = load_ticker_map
    @client        = Faraday.new(url: Settings::SURE_API_URL) do |f|
      f.options.timeout      = 30
      f.options.open_timeout = 10
    end
  end

  def import!(csv_content, &on_progress)
    csv_rows  = CSV.parse(csv_content, headers: true, quote_char: '"')
    all_items = []
    unmapped  = {}   # isin => name (dédupliqué)

    csv_rows.each do |r|
      map_row(r).each do |item|
        if item[:kind] == :unmapped
          unmapped[item[:isin]] ||= item[:name]
        else
          all_items << item
        end
      end
    end

    if @from_date
      all_items.select! { |t| Date.parse(t[:date]) >= @from_date }
    end

    # Pour les trades : récupère le dernier trade dans SUR et ignore les plus anciens.
    # Les transactions utilisent external_id pour leur propre déduplication.
    trade_cutoff = @dry_run ? nil : fetch_latest_trade_date
    if trade_cutoff
      before = all_items.count { |t| t[:kind] == :trade }
      all_items.reject! { |t| t[:kind] == :trade && Date.parse(t[:date]) <= trade_cutoff }
      after = all_items.count { |t| t[:kind] == :trade }
      $stdout.puts "[TrImporter] Dernier trade SUR : #{trade_cutoff} — #{before - after} trades ignorés, #{after} nouveaux"
      $stdout.flush
    end

    total       = all_items.size
    result_rows = []
    ok = errors = skipped = 0

    all_items.each_with_index do |t, i|
      row = Row.new(
        kind:    t[:kind],
        date:    t[:date],
        account: t[:account_label],
        amount:  t[:display_amount],
        name:    t[:name],
        tag:     t[:tag]
      )

      if @dry_run
        row.status = 'preview'
      else
        code, body = push(t)
        case code
        when 201      then row.status = 'ok';     ok      += 1
        when 200      then row.status = 'exists';  skipped += 1
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

    unmapped_list = unmapped.map { |isin, name| { isin: isin, name: name } }
    Result.new(ok: ok, errors: errors, skipped: skipped, rows: result_rows,
               trade_cutoff: trade_cutoff, unmapped: unmapped_list)
  end

  private

  # ── Mapping CSV → items (trade ou transaction) ────────────────────────────

  def map_row(r)
    type         = r['type'].to_s
    account_type = r['account_type'].to_s
    account_id   = ACCOUNTS[account_type]

    return [] unless account_id
    return [] if SKIP_TYPES.include?(type)

    date        = r['date'].to_s.split('T').first
    amount      = r['amount'].to_f
    fee         = r['fee'].to_f
    tax         = r['tax'].to_f
    name_asset  = r['name'].to_s.strip
    symbol      = r['symbol'].to_s.strip
    shares      = r['shares'].to_f
    price       = r['price'].to_f
    description = r['description'].to_s.strip
    currency    = r['currency'].to_s.strip.upcase
    tid         = r['transaction_id'].to_s.strip

    base = { date: date, account_id: account_id, account_label: account_type }
    items = []

    case type

    # ── Achats → trade (fee inclus) + TTF en transaction séparée ────────────
    when 'BUY'
      ticker = @ticker_map[symbol]
      return [{ kind: :unmapped, isin: symbol, name: name_asset }] if ticker.nil? && !@ticker_map.key?(symbol)
      return [] if ticker.nil?  # ticker NULL en base = produit ignoré volontairement
      items << base.merge(
        kind:           :trade,
        trade_type:     'buy',
        ticker:         ticker,
        qty:            shares.abs.round(8),
        price:          price,
        fee:            fee.abs,
        currency:       currency.empty? ? 'EUR' : currency,
        name:           "Achat #{name_asset}",
        tag:            'Trade',
        display_amount: -(shares.abs * price).round(2)
      )
      items << base.merge(
        kind:        :transaction,
        external_id: "#{tid}_t",
        amount:      tax.round(2),
        name:        "TTF — Achat #{name_asset}",
        notes:       "ISIN: #{symbol}",
        tag:         'Taxes',
        display_amount: tax.round(2)
      ) if tax != 0

    # ── Ventes → trade (fee inclus) + impôt éventuel ────────────────────────
    when 'SELL'
      ticker = @ticker_map[symbol]
      return [{ kind: :unmapped, isin: symbol, name: name_asset }] if ticker.nil? && !@ticker_map.key?(symbol)
      return [] if ticker.nil?
      items << base.merge(
        kind:           :trade,
        trade_type:     'sell',
        ticker:         ticker,
        qty:            shares.abs.round(8),  # toujours positif, type="sell" indique la direction
        price:          price,
        fee:            fee.abs,
        currency:       currency.empty? ? 'EUR' : currency,
        name:           "Vente #{name_asset}",
        tag:            'Trade',
        display_amount: (shares.abs * price).round(2)
      )
      items << base.merge(
        kind:        :transaction,
        external_id: "#{tid}_t",
        amount:      tax.round(2),
        name:        "Impôt — Vente #{name_asset}",
        notes:       "ISIN: #{symbol}",
        tag:         'Taxes',
        display_amount: tax.round(2)
      ) if tax != 0

    # ── Dividendes ──────────────────────────────────────────────────────────
    when 'DIVIDEND'
      info = "ISIN: #{symbol} | #{shares.abs.round(6)} actions"
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         amount.round(2),
        name:           "Dividende #{name_asset}",
        notes:          info,
        tag:            'Dividende',
        display_amount: amount.round(2)
      )
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_t",
        amount:         tax.round(2),
        name:           "Prélèvement à la source — #{name_asset}",
        notes:          info,
        tag:            'Taxes',
        display_amount: tax.round(2)
      ) if tax != 0

    # ── Intérêts ────────────────────────────────────────────────────────────
    when 'INTEREST_PAYMENT'
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         amount.round(2),
        name:           'Intérêts Trade Republic',
        notes:          description,
        tag:            'Intérêts',
        display_amount: amount.round(2)
      ) if amount != 0
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_t",
        amount:         tax.round(2),
        name:           'Impôt sur intérêts',
        notes:          nil,
        tag:            'Taxes',
        display_amount: tax.round(2)
      ) if tax != 0

    # ── Dépôts Apple Pay ────────────────────────────────────────────────────
    when 'CUSTOMER_INPAYMENT'
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         amount.round(2),
        name:           description.empty? ? 'Dépôt Trade Republic' : description,
        notes:          nil,
        tag:            'Dépôt',
        display_amount: amount.round(2)
      ) if amount != 0
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_f",
        amount:         fee.round(2),
        name:           'Frais dépôt Trade Republic',
        notes:          nil,
        tag:            'Frais',
        display_amount: fee.round(2)
      ) if fee != 0

    # ── Virements entrants ──────────────────────────────────────────────────
    when 'CUSTOMER_INBOUND', 'TRANSFER_INSTANT_INBOUND', 'TRANSFER_INBOUND'
      net = (amount + fee + tax).round(2)
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         net,
        name:           description.empty? ? 'Dépôt Trade Republic' : description,
        notes:          nil,
        tag:            'Dépôt',
        display_amount: net
      ) if net != 0

    # ── Retraits ────────────────────────────────────────────────────────────
    when 'TRANSFER_INSTANT_OUTBOUND'
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         amount.round(2),
        name:           'Retrait Trade Republic',
        notes:          description,
        tag:            'Retrait',
        display_amount: amount.round(2)
      )

    # ── Virements internes CTO ↔ PEA ────────────────────────────────────────
    when 'TRANSFER_OUT'
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         amount.round(2),
        name:           'Versement PEA',
        notes:          nil,
        tag:            'Virement interne',
        display_amount: amount.round(2)
      )
    when 'TRANSFER_IN'
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         amount.round(2),
        name:           'Versement PEA reçu',
        notes:          nil,
        tag:            'Virement interne',
        display_amount: amount.round(2)
      )

    # ── Frais carte ─────────────────────────────────────────────────────────
    when 'CARD_ORDERING_FEE'
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_f",
        amount:         fee.round(2),
        name:           'Frais carte Trade Republic',
        notes:          description,
        tag:            'Frais',
        display_amount: fee.round(2)
      ) if fee != 0

    else
      net = (amount + fee + tax).round(2)
      items << base.merge(
        kind:           :transaction,
        external_id:    "#{tid}_p",
        amount:         net,
        name:           description.empty? ? type : description,
        notes:          nil,
        tag:            'Autre',
        display_amount: net
      ) unless net.zero?
    end

    items
  end

  # ── Chargement des correspondances ISIN → ticker ─────────────────────────

  def load_ticker_map
    TickerMapping.to_map
  rescue => e
    $stderr.puts "[TrImporter] Fallback sur TICKER_MAP statique: #{e.message}"
    TICKER_MAP.dup
  end

  # ── Purge : supprime toutes les transactions des comptes TR dans SUR ──────

  def purge_transactions!
    deleted = 0
    errors  = 0
    ACCOUNTS.each_value do |account_id|
      page = 1
      loop do
        resp = @client.get('/api/v1/transactions') do |req|
          req.headers['X-Api-Key'] = Settings::SURE_API_KEY
          req.headers['Accept']    = 'application/json'
          req.params['account_id'] = account_id
          req.params['per_page']   = 100
          req.params['page']       = page
        end
        break unless resp.status == 200

        body  = JSON.parse(resp.body)
        items = body.is_a?(Array) ? body : (body['transactions'] || body['data'] || [])
        break if items.empty?

        items.each do |t|
          id = t['id']
          next unless id
          del = @client.delete("/api/v1/transactions/#{id}") do |req|
            req.headers['X-Api-Key'] = Settings::SURE_API_KEY
            req.headers['Accept']    = 'application/json'
          end
          del.status == 200 ? deleted += 1 : errors += 1
          sleep 0.03
        end

        break if items.size < 100
        page += 1
      end
    end
    { deleted: deleted, errors: errors }
  rescue => e
    { deleted: deleted, errors: errors, message: e.message }
  end

  # ── Purge trades : supprime tous les trades des comptes TR dans SUR ───────

  def purge_trades!
    deleted = 0
    errors  = 0
    page = 1
    loop do
      resp = @client.get('/api/v1/trades') do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
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

  # ── Date du dernier trade dans SUR ───────────────────────────────────────

  def fetch_latest_trade_date
    latest = nil
    page   = 1
    loop do
      resp = @client.get('/api/v1/trades') do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
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
    $stderr.puts "[TrImporter] fetch_latest_trade_date: #{e.message}"
    nil
  end

  # ── Push selon le type ────────────────────────────────────────────────────

  def push(t)
    t[:kind] == :trade ? push_trade(t) : push_transaction(t)
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
      $stdout.puts "[TrImporter] Premier TRADE → POST #{Settings::SURE_API_URL}/api/v1/trades"
      $stdout.puts "[TrImporter] Payload: #{payload.to_json}"
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
      $stdout.puts "[TrImporter] TRADE ERREUR #{resp.status} — #{t[:name]} — #{resp.body[0..300]}"
      $stdout.flush
    end
    [resp.status, parsed]
  rescue => e
    $stdout.puts "[TrImporter] TRADE EXCEPTION: #{e.message}"; $stdout.flush
    [0, e.message]
  end

  def push_transaction(t)
    # SUR utilise la convention comptable inversée :
    #   amount négatif = entrée d'argent (revenu, dépôt, dividende)
    #   amount positif = sortie d'argent (dépense, taxe, frais)
    # On inverse donc le signe du CSV avant envoi.
    payload = {
      transaction: {
        account_id:                t[:account_id],
        date:                      t[:date],
        amount:                    -t[:amount],
        name:                      t[:name],
        notes:                     t[:notes],
        external_id:               t[:external_id],
        source:                    'trade_republic',
        investment_activity_label: TAG_TO_ACTIVITY[t[:tag]]
      }
    }

    if @first_txn
      @first_txn = false
      $stdout.puts "[TrImporter] Première TRANSACTION → POST #{Settings::SURE_API_URL}/api/v1/transactions"
      $stdout.puts "[TrImporter] Payload: #{payload.to_json}"
      $stdout.flush
    end

    resp = @client.post('/api/v1/transactions') do |req|
      req.headers['X-Api-Key']    = Settings::SURE_API_KEY
      req.headers['Content-Type'] = 'application/json'
      req.headers['Accept']       = 'application/json'
      req.body = payload.to_json
    end

    parsed = begin; JSON.parse(resp.body); rescue; resp.body; end
    unless [200, 201].include?(resp.status)
      $stdout.puts "[TrImporter] TXN ERREUR #{resp.status} — #{t[:name]} — #{resp.body[0..300]}"
      $stdout.flush
    end
    [resp.status, parsed]
  rescue => e
    $stdout.puts "[TrImporter] TXN EXCEPTION: #{e.message}"; $stdout.flush
    [0, e.message]
  end
end
