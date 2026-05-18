require 'sequel'

class Bet < Sequel::Model
  many_to_one :analysis

  STATUSES = %w[pending open closed skipped].freeze

  def open!(entry_price, entry_date = Date.today)
    update(
      entry_price: entry_price.to_f,
      entry_date: entry_date,
      status: 'open'
    )
  end

  def close!(exit_price, exit_date = Date.today)
    pct = entry_price && entry_price > 0 ? ((exit_price.to_f - entry_price) / entry_price * 100).round(2) : nil
    gain = pct ? (budget * pct / 100).round(2) : nil
    update(
      exit_price: exit_price.to_f,
      exit_date: exit_date,
      status: 'closed',
      pct_change: pct,
      gain_eur: gain
    )
  end

  def days_remaining
    return nil unless entry_date
    deadline = entry_date + 30
    [0, (deadline - Date.today).to_i].max
  end

  def unrealized_pnl(current_price)
    return nil unless entry_price && entry_price > 0
    pct = (current_price.to_f - entry_price) / entry_price * 100
    { pct: pct.round(2), eur: (budget * pct / 100).round(2) }
  end
end
