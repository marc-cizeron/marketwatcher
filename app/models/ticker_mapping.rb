require_relative '../../config/database'

class TickerMapping < Sequel::Model
  plugin :timestamps, update_on_create: true

  # Charge toutes les correspondances sous forme de Hash { isin => ticker }
  # ticker peut être nil (produit non mappable)
  def self.to_map
    all.each_with_object({}) { |m, h| h[m.isin] = m.ticker }
  end
end
