require 'faraday'
require 'csv'
require 'json'
require 'date'
require_relative '../../config/settings'

# Synchronisation CSV Trade Republic → API SUR.
#
# Deux types d'entrées selon la nature de l'opération :
#
#   :trade       → POST /api/v1/trades  (BUY/SELL — met à jour les holdings)
#                  Champs : account_id, date, ticker, qty (+achat/-vente), price, fee, currency
#
#   :transaction → POST /api/v1/transactions  (dividendes, dépôts, intérêts, frais, taxes)
#                  Champs : account_id, date, amount, name, notes, external_id, source
#
# Idempotence :
#   - :transaction → external_id + source natifs de SUR (201=créée, 200=déjà là)
#   - :trade       → pas d'external_id SUR ; ne pas importer deux fois le même CSV
class TrImporter
  ACCOUNTS = {
    'DEFAULT' => Settings::SURE_ACCOUNT_DEFAULT,
    'PEA'     => Settings::SURE_ACCOUNT_PEA
  }.freeze

  # ISIN → ticker Yahoo Finance (utilisé pour les trades)
  TICKER_MAP = {
    'FR0000120271' => 'TTE.PA',
    'FR0000131906' => 'RNO.PA',
    'FR0000073272' => 'SAF.PA',
    'FR0000121329' => 'HO.PA',
    'FR0014004L86' => 'AM.PA',
    'FR0010221234' => 'ETL.PA',
    'FR0000120073' => 'AI.PA',
    'FR0000054470' => 'UBI.PA',
    'FR0010220475' => 'ALO.PA',
    'NL0010273215' => 'ASML.AS',
    'LU1598757687' => 'MT.AS',
    'NL00150001Q9' => 'STLAM.MI',
    'DE0007030009' => 'RHM.DE',
    'DE0005313704' => 'AFX.DE',
    'US67066G1040' => 'NVDA',
    'US52661A1088' => 'DRS',
    'US5024413065' => 'LVMUY',
    'KYG982AW1003' => 'XPEV',
    'CNE100000296' => '1211.HK',
    'CA13321L1085' => 'CCO.TO',
    'US5253271028' => 'LDOS',
    'US75513E1010' => 'RTX',
    'FR0013380607' => 'C40.PA',
    'IE000BI8OT95' => 'IWDA.AS',
    'LU1681048804' => 'CSPX.L',
    'FR0011550185' => 'SP5C.PA',
    'FR001400U5Q4' => 'EWLD.PA',
    'IE00BMTM6B32' => 'WITR.AS',
    'DE000SQ4SUR5' => 'DE000SQ4SUR5',
    'BTC'          => 'BTC/EUR',
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

  Result = Struct.new(:ok, :errors, :skipped, :rows, keyword_init: true)
  Row    = Struct.new(:kind, :date, :account, :amount, :name, :tag, :status, :error, keyword_init: true)

  def initialize(dry_run: true, from_date: nil)
    @dry_run       = dry_run
    @from_date     = from_date.is_a?(String) && !from_date.empty? ? Date.parse(from_date) : from_date
    @first_trade   = true
    @first_txn     = true
    @client        = Faraday.new(url: Settings::SURE_API_URL) do |f|
      f.options.timeout      = 30
      f.options.open_timeout = 10
    end
  end

  def import!(csv_content, &on_progress)
    csv_rows = CSV.parse(csv_content, headers: true, quote_char: '"')
    all_items = csv_rows.flat_map { |r| map_row(r) }

    if @from_date
      all_items.select! { |t| Date.parse(t[:date]) >= @from_date }
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

    Result.new(ok: ok, errors: errors, skipped: skipped, rows: result_rows)
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
      ticker = TICKER_MAP[symbol] || symbol
      items << base.merge(
        kind:           :trade,
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
      ticker = TICKER_MAP[symbol] || symbol
      items << base.merge(
        kind:           :trade,
        ticker:         ticker,
        qty:            -(shares.abs.round(8)),  # négatif = vente
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

  # ── Push selon le type ────────────────────────────────────────────────────

  def push(t)
    t[:kind] == :trade ? push_trade(t) : push_transaction(t)
  end

  def push_trade(t)
    payload = {
      trade: {
        account_id: t[:account_id],
        date:       t[:date],
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
    payload = {
      transaction: {
        account_id:  t[:account_id],
        date:        t[:date],
        amount:      t[:amount],
        name:        t[:name],
        notes:       t[:notes],
        external_id: t[:external_id],
        source:      'trade_republic'
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
