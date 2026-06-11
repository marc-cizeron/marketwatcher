require 'faraday'
require 'csv'
require 'json'
require 'date'
require_relative '../../config/settings'

# Synchronisation CSV Trade Republic → API SUR.
#
# Chaque ligne CSV génère 1 à 3 transactions SUR (principal, commission, taxe).
# L'idempotence est gérée nativement par SUR via external_id + source :
# SUR retourne 201 pour une nouvelle transaction, 200 si elle existe déjà.
# Relancer le même CSV est donc sans risque de doublon.
class TrImporter
  ACCOUNTS = {
    'DEFAULT' => Settings::SURE_ACCOUNT_DEFAULT,
    'PEA'     => Settings::SURE_ACCOUNT_PEA
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
  Row    = Struct.new(:date, :account, :amount, :name, :tag, :notes, :status, :error, keyword_init: true)

  def initialize(dry_run: true, from_date: nil)
    @dry_run       = dry_run
    @from_date     = from_date.is_a?(String) && !from_date.empty? ? Date.parse(from_date) : from_date
    @first_request = true
    @client        = Faraday.new(url: Settings::SURE_API_URL) do |f|
      f.options.timeout      = 30
      f.options.open_timeout = 10
    end
  end

  # on_progress : appelé après chaque transaction avec (index, total, row)
  def import!(csv_content, &on_progress)
    csv_rows = CSV.parse(csv_content, headers: true, quote_char: '"')
    all_txns = csv_rows.flat_map { |r| map_row(r) }

    if @from_date
      all_txns.select! { |t| Date.parse(t[:date]) >= @from_date }
    end

    total       = all_txns.size
    result_rows = []
    ok = errors = skipped = 0

    all_txns.each_with_index do |t, i|
      row = Row.new(
        date:    t[:date],
        account: t[:account_label],
        amount:  t[:amount],
        name:    t[:name],
        tag:     t[:tag],
        notes:   t[:notes]
      )

      if @dry_run
        row.status = 'preview'
      else
        code, body = push(t)
        case code
        when 201
          row.status = 'ok'
          ok += 1
        when 200
          # Transaction déjà présente dans SUR (idempotence via external_id)
          row.status = 'exists'
          skipped += 1
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

  # ── Mapping CSV → transactions SUR ────────────────────────────────────────

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
    tid         = r['transaction_id'].to_s.strip

    base = { date: date, account_id: account_id, account_label: account_type }
    txns = []

    case type

    when 'BUY'
      info = "ISIN: #{symbol} | #{description}"
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: "Achat #{name_asset} (#{shares} × #{price}€)",
                         tag: 'Investissement', notes: info)
      txns << base.merge(external_id: "#{tid}_f", amount: fee.round(2),
                         name: "Commission courtage — Achat #{name_asset}",
                         tag: 'Frais de courtage', notes: info) if fee != 0
      txns << base.merge(external_id: "#{tid}_t", amount: tax.round(2),
                         name: "TTF — Achat #{name_asset}",
                         tag: 'Taxes', notes: info) if tax != 0

    when 'SELL'
      info = "ISIN: #{symbol} | #{description}"
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: "Vente #{name_asset} (#{shares.abs} × #{price}€)",
                         tag: 'Investissement', notes: info)
      txns << base.merge(external_id: "#{tid}_f", amount: fee.round(2),
                         name: "Commission courtage — Vente #{name_asset}",
                         tag: 'Frais de courtage', notes: info) if fee != 0
      txns << base.merge(external_id: "#{tid}_t", amount: tax.round(2),
                         name: "Impôt — Vente #{name_asset}",
                         tag: 'Taxes', notes: info) if tax != 0

    when 'DIVIDEND'
      info = "ISIN: #{symbol} | #{shares.abs.round(6)} actions"
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: "Dividende #{name_asset}",
                         tag: 'Dividende', notes: info)
      txns << base.merge(external_id: "#{tid}_t", amount: tax.round(2),
                         name: "Prélèvement à la source — #{name_asset}",
                         tag: 'Taxes', notes: info) if tax != 0

    when 'INTEREST_PAYMENT'
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Intérêts Trade Republic',
                         tag: 'Intérêts', notes: description) if amount != 0
      txns << base.merge(external_id: "#{tid}_t", amount: tax.round(2),
                         name: 'Impôt sur intérêts',
                         tag: 'Taxes', notes: nil) if tax != 0

    when 'CUSTOMER_INPAYMENT'
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: description.empty? ? 'Dépôt Trade Republic' : description,
                         tag: 'Dépôt', notes: nil) if amount != 0
      txns << base.merge(external_id: "#{tid}_f", amount: fee.round(2),
                         name: 'Frais dépôt Trade Republic',
                         tag: 'Frais', notes: nil) if fee != 0

    when 'CUSTOMER_INBOUND', 'TRANSFER_INSTANT_INBOUND', 'TRANSFER_INBOUND'
      net = (amount + fee + tax).round(2)
      txns << base.merge(external_id: "#{tid}_p", amount: net,
                         name: description.empty? ? 'Dépôt Trade Republic' : description,
                         tag: 'Dépôt', notes: nil) if net != 0

    when 'TRANSFER_INSTANT_OUTBOUND'
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Retrait Trade Republic',
                         tag: 'Retrait', notes: description)

    when 'TRANSFER_OUT'
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Versement PEA',
                         tag: 'Virement interne', notes: nil)

    when 'TRANSFER_IN'
      txns << base.merge(external_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Versement PEA reçu',
                         tag: 'Virement interne', notes: nil)

    when 'CARD_ORDERING_FEE'
      txns << base.merge(external_id: "#{tid}_f", amount: fee.round(2),
                         name: 'Frais carte Trade Republic',
                         tag: 'Frais', notes: description) if fee != 0

    else
      net = (amount + fee + tax).round(2)
      txns << base.merge(external_id: "#{tid}_p", amount: net,
                         name: description.empty? ? type : description,
                         tag: 'Autre', notes: nil) unless net.zero?
    end

    txns
  end

  # ── Push vers SUR ─────────────────────────────────────────────────────────

  def push(t)
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

    if @first_request
      @first_request = false
      $stdout.puts "[TrImporter] Premier push → POST #{Settings::SURE_API_URL}/api/v1/transactions"
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
      $stdout.puts "[TrImporter] ERREUR HTTP #{resp.status} — #{t[:name]} — #{resp.body[0..300]}"
      $stdout.flush
    end

    [resp.status, parsed]
  rescue => e
    $stdout.puts "[TrImporter] EXCEPTION: #{e.message}"
    $stdout.flush
    [0, e.message]
  end
end
