require 'faraday'
require 'csv'
require 'json'
require 'date'
require 'set'
require_relative '../../config/settings'

# Synchronisation idempotente CSV Trade Republic → API SUR.
#
# Chaque ligne CSV génère 1 à 3 transactions SUR (principal, commission, taxe).
# Un marqueur "#TR:{uuid}_{suffix}" est embarqué dans les notes de chaque
# transaction créée. Avant chaque import, les transactions SUR existantes sont
# scannées pour collecter les IDs déjà présents — seules les nouvelles sont envoyées.
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

  # Regex pour extraire les marqueurs depuis les notes SUR
  TR_ID_RE = /#TR:([a-f0-9-]+_\w+)/.freeze

  Result = Struct.new(:ok, :errors, :skipped, :rows, keyword_init: true)
  Row    = Struct.new(:date, :account, :amount, :name, :tag, :notes, :status, :error, keyword_init: true)

  def initialize(dry_run: true, from_date: nil)
    @dry_run   = dry_run
    @from_date = from_date.is_a?(String) && !from_date.empty? ? Date.parse(from_date) : from_date
    @client    = Faraday.new(url: Settings::SURE_API_URL) do |f|
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

    # En dry-run : pas d'appel SUR, on montre tout le CSV tel quel.
    # En import réel : on scanne les transactions existantes pour dédupliquer.
    existing_ids = @dry_run ? Set.new : fetch_existing_tr_ids

    new_txns      = all_txns.reject { |t| existing_ids.include?(t[:tr_id]) }
    skipped_count = all_txns.size - new_txns.size
    total         = new_txns.size

    result_rows = []
    ok = errors = 0

    new_txns.each_with_index do |t, i|
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
        if code == 200 || code == 201
          row.status = 'ok'
          ok += 1
        else
          row.status = 'error'
          row.error  = "HTTP #{code}: #{body.to_s[0..200]}"
          errors += 1
        end
        sleep 0.05
      end

      result_rows << row
      on_progress.call(i + 1, total, row) if block_given?
    end

    Result.new(ok: ok, errors: errors, skipped: skipped_count, rows: result_rows)
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
    tid         = r['transaction_id'].to_s.strip   # UUID unique Trade Republic

    base  = { date: date, account_id: account_id, account_label: account_type }
    txns  = []

    case type

    when 'BUY'
      info = "ISIN: #{symbol} | #{description}"
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: "Achat #{name_asset} (#{shares} × #{price}€)",
                         tag: 'Investissement', notes: "#{info} | #TR:#{tid}_p")
      txns << base.merge(tr_id: "#{tid}_f", amount: fee.round(2),
                         name: "Commission courtage — Achat #{name_asset}",
                         tag: 'Frais de courtage', notes: "#{info} | #TR:#{tid}_f") if fee != 0
      txns << base.merge(tr_id: "#{tid}_t", amount: tax.round(2),
                         name: "TTF — Achat #{name_asset}",
                         tag: 'Taxes', notes: "#{info} | #TR:#{tid}_t") if tax != 0

    when 'SELL'
      info = "ISIN: #{symbol} | #{description}"
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: "Vente #{name_asset} (#{shares.abs} × #{price}€)",
                         tag: 'Investissement', notes: "#{info} | #TR:#{tid}_p")
      txns << base.merge(tr_id: "#{tid}_f", amount: fee.round(2),
                         name: "Commission courtage — Vente #{name_asset}",
                         tag: 'Frais de courtage', notes: "#{info} | #TR:#{tid}_f") if fee != 0
      txns << base.merge(tr_id: "#{tid}_t", amount: tax.round(2),
                         name: "Impôt — Vente #{name_asset}",
                         tag: 'Taxes', notes: "#{info} | #TR:#{tid}_t") if tax != 0

    when 'DIVIDEND'
      info = "ISIN: #{symbol} | #{shares.abs.round(6)} actions"
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: "Dividende #{name_asset}",
                         tag: 'Dividende', notes: "#{info} | #TR:#{tid}_p")
      txns << base.merge(tr_id: "#{tid}_t", amount: tax.round(2),
                         name: "Prélèvement à la source — #{name_asset}",
                         tag: 'Taxes', notes: "#{info} | #TR:#{tid}_t") if tax != 0

    when 'INTEREST_PAYMENT'
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Intérêts Trade Republic',
                         tag: 'Intérêts', notes: "#TR:#{tid}_p") if amount != 0
      txns << base.merge(tr_id: "#{tid}_t", amount: tax.round(2),
                         name: 'Impôt sur intérêts',
                         tag: 'Taxes', notes: "#TR:#{tid}_t") if tax != 0

    when 'CUSTOMER_INPAYMENT'
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: description.empty? ? 'Dépôt Trade Republic' : description,
                         tag: 'Dépôt', notes: "#TR:#{tid}_p") if amount != 0
      txns << base.merge(tr_id: "#{tid}_f", amount: fee.round(2),
                         name: 'Frais dépôt Trade Republic',
                         tag: 'Frais', notes: "#TR:#{tid}_f") if fee != 0

    when 'CUSTOMER_INBOUND', 'TRANSFER_INSTANT_INBOUND', 'TRANSFER_INBOUND'
      net = (amount + fee + tax).round(2)
      txns << base.merge(tr_id: "#{tid}_p", amount: net,
                         name: description.empty? ? 'Dépôt Trade Republic' : description,
                         tag: 'Dépôt', notes: "#TR:#{tid}_p") if net != 0

    when 'TRANSFER_INSTANT_OUTBOUND'
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Retrait Trade Republic',
                         tag: 'Retrait', notes: "#TR:#{tid}_p")

    when 'TRANSFER_OUT'
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Versement PEA',
                         tag: 'Virement interne', notes: "#TR:#{tid}_p")

    when 'TRANSFER_IN'
      txns << base.merge(tr_id: "#{tid}_p", amount: amount.round(2),
                         name: 'Versement PEA reçu',
                         tag: 'Virement interne', notes: "#TR:#{tid}_p")

    when 'CARD_ORDERING_FEE'
      txns << base.merge(tr_id: "#{tid}_f", amount: fee.round(2),
                         name: 'Frais carte Trade Republic',
                         tag: 'Frais', notes: "#TR:#{tid}_f") if fee != 0

    else
      net = (amount + fee + tax).round(2)
      txns << base.merge(tr_id: "#{tid}_p", amount: net,
                         name: description.empty? ? type : description,
                         tag: 'Autre', notes: "#TR:#{tid}_p") unless net.zero?
    end

    txns
  end

  # ── Déduplication : IDs déjà présents dans SUR ───────────────────────────

  def fetch_existing_tr_ids
    ids = Set.new
    ACCOUNTS.each_value do |account_id|
      fetch_account_transactions(account_id).each do |txn|
        m = txn['notes'].to_s.match(TR_ID_RE)
        ids << m[1] if m
      end
    end
    ids
  rescue => e
    $stderr.puts "[TrImporter] Impossible de vérifier les doublons: #{e.message}"
    Set.new
  end

  def fetch_account_transactions(account_id)
    all  = []
    page = 1
    loop do
      resp = @client.get("/api/v1/accounts/#{account_id}/transactions") do |req|
        req.headers['X-Api-Key'] = Settings::SURE_API_KEY
        req.headers['Accept']    = 'application/json'
        req.params['per_page']   = 100
        req.params['page']       = page
      end
      break unless resp.status == 200

      body  = JSON.parse(resp.body)
      items = body.is_a?(Array) ? body : (body['transactions'] || body['data'] || [])
      break if items.empty?

      all.concat(items)
      break if items.size < 100
      page += 1
    end
    all
  rescue
    []
  end

  # ── Push vers SUR ─────────────────────────────────────────────────────────

  def push(t)
    payload = {
      transaction: {
        date:      t[:date],
        amount:    t[:amount],
        name:      t[:name],
        notes:     t[:notes],
        tag_names: [t[:tag]].compact
      }
    }
    resp = @client.post("/api/v1/accounts/#{t[:account_id]}/transactions") do |req|
      req.headers['X-Api-Key']    = Settings::SURE_API_KEY
      req.headers['Content-Type'] = 'application/json'
      req.headers['Accept']       = 'application/json'
      req.body = payload.to_json
    end
    parsed = begin; JSON.parse(resp.body); rescue; resp.body; end
    [resp.status, parsed]
  rescue => e
    [0, e.message]
  end
end
