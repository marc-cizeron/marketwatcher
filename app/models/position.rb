require 'sequel'

class Position < Sequel::Model
  SECTORS   = %w[energie tech defense industrie alimentation autre].freeze
  HORIZONS  = %w[long medium].freeze
  CONVICTIONS = %w[haute moyenne faible].freeze

  def pnl_pct
    return nil unless avg_price && avg_price > 0 && current_price
    ((current_price - avg_price) / avg_price * 100).round(2)
  end

  def pnl_eur
    return nil unless pnl_pct && shares
    (avg_price * shares * pnl_pct / 100).round(2)
  end

  def market_value
    return nil unless current_price && shares
    (current_price * shares).round(2)
  end

  def cost_basis
    return nil unless avg_price && shares
    (avg_price * shares).round(2)
  end
end
