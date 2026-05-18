require 'sequel'

class Watchlist < Sequel::Model
  STATUSES = %w[watching entered passed].freeze

  def enter!
    update(status: 'entered')
  end
end
